/// ChunkLoadThread - Dedicated background thread for chunk load/unload decisions
/// Decouples chunk management scanning from the main thread (C2ME-style).
/// Submits terrain tasks directly to the worker pool — main thread never scans.
///
/// Owns (thread-local, no synchronization needed):
/// - SpiralIterator for closest-first position generation
/// - PosSet tracking all positions we've decided to load
///
/// Communicates via:
/// - Direct pool.submit() for terrain tasks (thread-safe, mutex-protected)
/// - unload_requests: SPSCQueue(ChunkPos) — this thread → main thread
/// - Atomic player position — main thread → this thread
/// - Atomic in_flight_terrain counter — this thread increments, workers decrement
const std = @import("std");
const Io = std.Io;
const shared = @import("Shared");

const Logger = shared.Logger;
const profiler = shared.profiler;
const ChunkPos = shared.ChunkPos;
const ChunkPosContext = shared.ChunkPosContext;

const SpiralIterator = @import("ChunkManager.zig").SpiralIterator;

const tp = @import("ThreadPool.zig");
const ThreadPool = tp.ThreadPool;
const Task = tp.Task;

const SPSCQueue = @import("SPSCQueue.zig").SPSCQueue;

pub const ChunkLoadThread = struct {
    const Self = @This();
    const logger = Logger.scoped(Self);

    const PosSet = std.HashMap(ChunkPos, void, ChunkPosContext, std.hash_map.default_max_load_percentage);

    /// Max load requests to produce per iteration cycle before rechecking player position
    /// Higher = better worker utilization, at the cost of slower response to position changes
    /// At ~10μs per submit, 512 iterations ≈ 5ms between position checks
    const LOADS_PER_CYCLE: u32 = 512;

    /// Max concurrent terrain tasks in the worker pool (backpressure)
    /// 128 × ~448KB ChunkTask = ~56MB max memory for in-flight terrain tasks
    const MAX_IN_FLIGHT: u32 = 128;

    allocator: std.mem.Allocator,
    io: Io,

    // Thread control
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool),

    // Direct pool submission (thread-safe via mutex)
    pool: *ThreadPool,

    // Backpressure: tracks terrain tasks submitted but not yet completed
    // Incremented by this thread, decremented by worker threads after terrain generation
    in_flight_terrain: *std.atomic.Value(u32),

    // Unload queue (this thread produces, main thread consumes)
    unload_requests: SPSCQueue(ChunkPos),

    // Atomic player position (main thread writes, this thread reads)
    player_chunk_x: std.atomic.Value(i32),
    player_chunk_z: std.atomic.Value(i32),
    player_chunk_y: std.atomic.Value(i32),
    /// Generation counter — incremented on each position update for change detection
    player_gen: std.atomic.Value(u32),

    // Thread-local state (only accessed by background thread)
    spiral: SpiralIterator,
    managed: PosSet,
    last_player: ChunkPos,
    last_gen: u32,
    /// Position that couldn't be submitted due to backpressure — retry next cycle
    stalled_pos: ?ChunkPos,

    // Configuration
    view_distance: u32,
    vertical_view_distance: u32,
    unload_distance: u32,

    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        pool: *ThreadPool,
        in_flight_terrain: *std.atomic.Value(u32),
        view_distance: u32,
        vertical_view_distance: u32,
        unload_distance: u32,
    ) !Self {
        var unload_requests = try SPSCQueue(ChunkPos).init(allocator, 1024);
        errdefer unload_requests.deinit();

        return Self{
            .allocator = allocator,
            .io = io,
            .running = std.atomic.Value(bool).init(false),
            .pool = pool,
            .in_flight_terrain = in_flight_terrain,
            .unload_requests = unload_requests,
            .player_chunk_x = std.atomic.Value(i32).init(0),
            .player_chunk_z = std.atomic.Value(i32).init(0),
            .player_chunk_y = std.atomic.Value(i32).init(0),
            .player_gen = std.atomic.Value(u32).init(0),
            .spiral = .{},
            .managed = PosSet.init(allocator),
            .last_player = ChunkPos{ .x = 0, .z = 0, .section_y = 0 },
            .last_gen = 0,
            .stalled_pos = null,
            .view_distance = view_distance,
            .vertical_view_distance = vertical_view_distance,
            .unload_distance = unload_distance,
        };
    }

    pub fn deinit(self: *Self) void {
        self.shutdown();
        self.managed.deinit();
        self.unload_requests.deinit();
        logger.info("ChunkLoadThread destroyed", .{});
    }

    pub fn start(self: *Self) !void {
        if (self.running.load(.acquire)) return;

        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, threadLoop, .{self});
        logger.info("ChunkLoadThread started (view={}, unload={}, vert={})", .{
            self.view_distance, self.unload_distance, self.vertical_view_distance,
        });
    }

    pub fn shutdown(self: *Self) void {
        if (!self.running.load(.acquire)) return;

        logger.info("ChunkLoadThread shutting down...", .{});
        self.running.store(false, .release);

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        logger.info("ChunkLoadThread shutdown complete", .{});
    }

    /// Update player position (called from main thread)
    pub fn updatePlayerPos(self: *Self, chunk_x: i32, chunk_z: i32, section_y: i32) void {
        self.player_chunk_x.store(chunk_x, .release);
        self.player_chunk_z.store(chunk_z, .release);
        self.player_chunk_y.store(section_y, .release);
        // Generation counter must be last (release) so reader sees position before gen
        _ = self.player_gen.fetchAdd(1, .release);
    }

    /// Read player position atomically from background thread
    fn readPlayerPos(self: *Self) struct { pos: ChunkPos, gen: u32 } {
        // Read generation first (acquire) to establish ordering
        const gen = self.player_gen.load(.acquire);
        const y = self.player_chunk_y.load(.acquire);
        const z = self.player_chunk_z.load(.acquire);
        const x = self.player_chunk_x.load(.acquire);
        return .{
            .pos = ChunkPos{ .x = x, .z = z, .section_y = y },
            .gen = gen,
        };
    }

    fn threadLoop(self: *Self) void {
        profiler.setThreadName("ChunkLoadThread");
        logger.debug("ChunkLoadThread started", .{});

        // Wait for first player position update before loading
        // Prevents loading chunks at (0,0,0) before actual player position is known
        while (self.running.load(.acquire)) {
            if (self.player_gen.load(.acquire) > 0) break;
            Io.Clock.Duration.sleep(.{
                .clock = .awake,
                .raw = .fromNanoseconds(1_000_000), // 1ms
            }, self.io) catch {};
        }

        // Initialize spiral with current view distance
        self.spiral.reset(self.view_distance, self.vertical_view_distance);

        // Read initial player position
        const initial = self.readPlayerPos();
        self.last_player = initial.pos;
        self.last_gen = initial.gen;

        while (self.running.load(.acquire)) {
            const zone = profiler.traceNamed("ChunkLoadCycle");
            defer zone.end();

            const player = self.readPlayerPos();

            // Check if player position changed
            if (player.gen != self.last_gen) {
                self.last_gen = player.gen;

                const pos_changed = !player.pos.eql(self.last_player);
                self.last_player = player.pos;

                if (pos_changed) {
                    // Reset spiral to new center
                    self.spiral.reset(self.view_distance, self.vertical_view_distance);
                    self.stalled_pos = null; // Stalled pos from old center is invalid

                    // Scan managed set for positions outside unload range
                    self.scanForUnloads(player.pos);
                }
            }

            // Continue spiral iteration — submit terrain tasks directly to pool
            const loads_produced = self.produceLoadRequests(player.pos);

            // Sleep when idle (spiral complete) or stalled (backpressure)
            if (loads_produced == 0) {
                Io.Clock.Duration.sleep(.{
                    .clock = .awake,
                    .raw = .fromNanoseconds(1_000_000), // 1ms
                }, self.io) catch {};
            }
        }

        logger.debug("ChunkLoadThread exiting", .{});
    }

    /// Scan managed positions for chunks that should be unloaded
    fn scanForUnloads(self: *Self, player_pos: ChunkPos) void {
        const zone = profiler.traceNamed("ScanForUnloads");
        defer zone.end();

        // Collect positions to unload (can't remove during iteration)
        var to_remove = std.ArrayListUnmanaged(ChunkPos){};
        defer to_remove.deinit(self.allocator);

        var iter = self.managed.iterator();
        while (iter.next()) |entry| {
            const pos = entry.key_ptr.*;

            const horizontally_distant = !pos.isWithinDistance(player_pos, self.unload_distance);
            const dy = @abs(pos.section_y - player_pos.section_y);
            const vertically_distant = dy > self.vertical_view_distance + 2;

            if (horizontally_distant or vertically_distant) {
                to_remove.append(self.allocator, pos) catch continue;
            }
        }

        var unloads_pushed: u32 = 0;
        for (to_remove.items) |pos| {
            if (!self.unload_requests.tryPush(pos)) {
                // Queue full — leave in managed so we retry next cycle.
                // Don't remove-then-re-add (put can fail under OOM, permanently losing the position).
                break;
            }
            _ = self.managed.remove(pos);
            unloads_pushed += 1;
        }

        if (unloads_pushed > 0) {
            profiler.plotInt("UnloadsPushed", @intCast(unloads_pushed));
        }
    }

    /// Iterate spiral and submit terrain tasks directly to worker pool
    fn produceLoadRequests(self: *Self, player_pos: ChunkPos) u32 {
        const zone = profiler.traceNamed("ProduceLoadRequests");
        defer zone.end();

        var loads_produced: u32 = 0;

        // Retry stalled position first (couldn't submit last cycle due to backpressure)
        if (self.stalled_pos) |stalled| {
            if (self.trySubmitTerrain(stalled)) {
                // Re-add to managed so it's tracked for unloading.
                // It was removed on the failed attempt (line ~305) to keep managed
                // in sync with actually-submitted tasks.
                self.managed.put(stalled, {}) catch {};
                self.stalled_pos = null;
                loads_produced += 1;
            } else {
                return 0; // Still stalled
            }
        }

        while (self.spiral.next()) |offset| {
            const pos = ChunkPos{
                .x = player_pos.x + offset.dx,
                .z = player_pos.z + offset.dz,
                .section_y = player_pos.section_y + offset.dy,
            };

            // Skip if already managed
            const gop = self.managed.getOrPut(pos) catch continue;
            if (gop.found_existing) continue;

            // Verify within view distance (spiral overshoots at corners)
            if (!pos.isWithinDistance(player_pos, self.view_distance)) {
                _ = self.managed.remove(pos);
                continue;
            }

            // Submit terrain task directly to worker pool
            if (!self.trySubmitTerrain(pos)) {
                // Backpressure or submit failure — save position for retry
                _ = self.managed.remove(pos);
                self.stalled_pos = pos;
                break;
            }

            loads_produced += 1;
            if (loads_produced >= LOADS_PER_CYCLE) break;
        }

        if (loads_produced > 0) {
            profiler.plotInt("LoadsPushed", @intCast(loads_produced));
        }

        return loads_produced;
    }

    /// Try to submit a terrain generation task to the worker pool.
    /// Zero allocation — position is embedded directly in the Task struct.
    /// Returns false if backpressure limit reached or submission failed.
    fn trySubmitTerrain(self: *Self, pos: ChunkPos) bool {
        // Backpressure: don't exceed max concurrent terrain tasks
        if (self.in_flight_terrain.load(.acquire) >= MAX_IN_FLIGHT) return false;

        // Increment BEFORE submit to prevent underflow race:
        // If we increment after, a worker could finish and fetchSub before our fetchAdd,
        // wrapping u32 to max and permanently stalling all terrain loading.
        _ = self.in_flight_terrain.fetchAdd(1, .release);

        // data=null signals terrain task to processTask — no heap allocation needed
        self.pool.submit(Task{
            .task_type = .generate_and_mesh,
            .data = null,
            .chunk_pos = pos,
            .chunk_task_kind = .generate,
        }) catch {
            _ = self.in_flight_terrain.fetchSub(1, .release);
            return false;
        };

        return true;
    }
};
