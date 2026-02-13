/// MeshSchedulerThread - Dedicated background thread for mesh scheduling
/// Decouples mesh dependency checking and task submission from the main thread.
/// The main thread only pushes positions to a lock-free queue; this thread does all
/// the work of checking chunk state, neighbor dependencies, CAS transitions, and pool submission.
///
/// Owns (thread-local, no synchronization needed):
/// - pending_mesh: PosSet for dedup
/// - pending_mesh_queue: ArrayList(ChunkPos) for FIFO order
/// - pending_mesh_head: read index
///
/// Communicates via:
/// - mesh_ready_queue: SPSCQueue(MeshRequest) — main thread produces, this thread consumes
/// - ChunkStorage.getAtomic() for safe cross-thread chunk reads
/// - RenderChunk.future.tryTransition() for atomic state CAS
/// - pool.submit() for task submission (mutex-protected)
/// - Atomic player position — main thread writes, this thread reads
const std = @import("std");
const Io = std.Io;
const shared = @import("Shared");

const Logger = shared.Logger;
const profiler = shared.profiler;
const ChunkPos = shared.ChunkPos;
const ChunkPosContext = shared.ChunkPosContext;

const chunk_storage = @import("ChunkStorage.zig");
const ChunkStorage = chunk_storage.ChunkStorage;

const tp = @import("ThreadPool.zig");
const ThreadPool = tp.ThreadPool;
const Task = tp.Task;

const SPSCQueue = @import("SPSCQueue.zig").SPSCQueue;

/// Request from main thread to schedule a mesh task
pub const MeshRequest = struct {
    pos: ChunkPos,
    /// true = remesh (CAS .dirty → .meshing), false = fresh mesh (CAS .generated → .meshing)
    is_remesh: bool,
};

/// Neighbor offsets: down, up, north, south, west, east
const NEIGHBOR_OFFSETS = [6]ChunkPos{
    .{ .x = 0, .z = 0, .section_y = -1 }, // down
    .{ .x = 0, .z = 0, .section_y = 1 }, // up
    .{ .x = 0, .z = -1, .section_y = 0 }, // north
    .{ .x = 0, .z = 1, .section_y = 0 }, // south
    .{ .x = -1, .z = 0, .section_y = 0 }, // west
    .{ .x = 1, .z = 0, .section_y = 0 }, // east
};

pub const MeshSchedulerThread = struct {
    const Self = @This();
    const logger = Logger.scoped(Self);

    const PosSet = std.HashMap(ChunkPos, void, ChunkPosContext, std.hash_map.default_max_load_percentage);

    allocator: std.mem.Allocator,
    io: Io,

    // Thread control
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool),

    // Input queue (main thread produces, this thread consumes)
    mesh_ready_queue: SPSCQueue(MeshRequest),

    // Direct pool submission (thread-safe via mutex)
    pool: *ThreadPool,

    // Read-only reference to chunk storage (uses getAtomic for safe reads)
    storage: *ChunkStorage,

    // Atomic player position (main thread writes, this thread reads)
    player_chunk_x: std.atomic.Value(i32),
    player_chunk_z: std.atomic.Value(i32),
    player_chunk_y: std.atomic.Value(i32),

    // View distance config (for neighbor dependency checks)
    view_distance: u32,
    vertical_view_distance: u32,

    // Thread-local state (only accessed by background thread)
    pending_mesh: PosSet,
    pending_mesh_queue: std.ArrayListUnmanaged(ChunkPos),
    pending_mesh_head: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        pool: *ThreadPool,
        storage: *ChunkStorage,
        view_distance: u32,
        vertical_view_distance: u32,
    ) !Self {
        var mesh_ready_queue = try SPSCQueue(MeshRequest).init(allocator, 8192);
        errdefer mesh_ready_queue.deinit();

        return Self{
            .allocator = allocator,
            .io = io,
            .running = std.atomic.Value(bool).init(false),
            .mesh_ready_queue = mesh_ready_queue,
            .pool = pool,
            .storage = storage,
            .player_chunk_x = std.atomic.Value(i32).init(0),
            .player_chunk_z = std.atomic.Value(i32).init(0),
            .player_chunk_y = std.atomic.Value(i32).init(0),
            .view_distance = view_distance,
            .vertical_view_distance = vertical_view_distance,
            .pending_mesh = PosSet.init(allocator),
            .pending_mesh_queue = .{},
            .pending_mesh_head = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.shutdown();
        self.pending_mesh.deinit();
        self.pending_mesh_queue.deinit(self.allocator);
        self.mesh_ready_queue.deinit();
        logger.info("MeshSchedulerThread destroyed", .{});
    }

    /// Update player position (called from main thread)
    pub fn updatePlayerPos(self: *Self, chunk_x: i32, chunk_z: i32, section_y: i32) void {
        self.player_chunk_x.store(chunk_x, .release);
        self.player_chunk_z.store(chunk_z, .release);
        self.player_chunk_y.store(section_y, .release);
    }

    fn readPlayerPos(self: *Self) ChunkPos {
        return ChunkPos{
            .x = self.player_chunk_x.load(.acquire),
            .z = self.player_chunk_z.load(.acquire),
            .section_y = self.player_chunk_y.load(.acquire),
        };
    }

    pub fn start(self: *Self) !void {
        if (self.running.load(.acquire)) return;

        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, threadLoop, .{self});
        logger.info("MeshSchedulerThread started", .{});
    }

    pub fn shutdown(self: *Self) void {
        if (!self.running.load(.acquire)) return;

        logger.info("MeshSchedulerThread shutting down...", .{});
        self.running.store(false, .release);

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        logger.info("MeshSchedulerThread shutdown complete", .{});
    }

    fn threadLoop(self: *Self) void {
        profiler.setThreadName("MeshScheduler");
        logger.debug("MeshSchedulerThread started", .{});

        while (self.running.load(.acquire)) {
            const zone = profiler.traceNamed("MeshScheduleCycle");
            defer zone.end();

            // 1. Drain mesh_ready_queue → add to pending_mesh + pending_mesh_queue
            const drained = self.drainReadyQueue();

            // 2. Process pending_mesh_queue (FIFO, no per-tick cap — not on render thread)
            const submitted = self.processPendingQueue();

            // 3. Rebuild queue if orphans exist (catches entries waiting for neighbors + silent append failures)
            self.rebuildQueueIfNeeded();

            // Sleep when idle
            if (drained == 0 and submitted == 0) {
                Io.Clock.Duration.sleep(.{
                    .clock = .awake,
                    .raw = .fromNanoseconds(1_000_000), // 1ms
                }, self.io) catch {};
            }
        }

        logger.debug("MeshSchedulerThread exiting", .{});
    }

    /// Drain all pending requests from the main thread's SPSC queue
    fn drainReadyQueue(self: *Self) u32 {
        var drained: u32 = 0;

        while (self.mesh_ready_queue.tryPop()) |request| {
            // Dedup: only add if not already pending
            self.pending_mesh.put(request.pos, {}) catch |err| {
                logger.warn("Failed to add chunk ({},{},{}) to pending_mesh: {}", .{
                    request.pos.x, request.pos.z, request.pos.section_y, err,
                });
                continue;
            };
            self.pending_mesh_queue.append(self.allocator, request.pos) catch {
                // Silent append failure — rebuildQueueIfNeeded will catch orphans
            };
            drained += 1;
        }

        return drained;
    }

    /// Check if all required neighbors are available in storage.
    /// A neighbor is "required" if it's within the player's view distance
    /// (neighbors outside view distance will never be loaded, so we don't wait for them).
    fn hasRequiredNeighbors(self: *Self, pos: ChunkPos, player: ChunkPos) bool {
        for (NEIGHBOR_OFFSETS) |offset| {
            const neighbor_pos = ChunkPos{
                .x = pos.x + offset.x,
                .z = pos.z + offset.z,
                .section_y = pos.section_y + offset.section_y,
            };

            // Skip neighbors outside view distance — they'll never be loaded
            if (!neighbor_pos.isWithinDistance(player, self.view_distance)) continue;

            // Skip neighbors outside vertical view distance
            const dy = @abs(neighbor_pos.section_y - player.section_y);
            if (dy > self.vertical_view_distance) continue;

            // Neighbor is within load range — check if it exists in storage
            if (self.storage.getAtomic(neighbor_pos) == null) return false;
        }
        return true;
    }

    /// Process the FIFO queue: check neighbors, chunk state, CAS, submit to pool
    fn processPendingQueue(self: *Self) u32 {
        const zone = profiler.traceNamed("MeshScheduleProcess");
        defer zone.end();

        const player = self.readPlayerPos();
        var submitted: u32 = 0;
        var deferred: u32 = 0;

        while (self.pending_mesh_head < self.pending_mesh_queue.items.len) {
            const pos = self.pending_mesh_queue.items[self.pending_mesh_head];
            self.pending_mesh_head += 1;

            // Skip stale entries (already processed or unloaded)
            if (!self.pending_mesh.contains(pos)) {
                continue;
            }

            // Get chunk via atomic read (safe cross-thread access)
            const chunk = self.storage.getAtomic(pos) orelse {
                // Chunk gone — remove from pending
                _ = self.pending_mesh.remove(pos);
                continue;
            };

            // Check neighbor dependencies: wait for all in-range neighbors to be loaded
            // This prevents meshing without neighbor data (causes uncculled boundary faces).
            // Entries left in pending_mesh will be retried via rebuildQueueIfNeeded.
            if (!self.hasRequiredNeighbors(pos, player)) {
                // Leave in pending_mesh — rebuildQueueIfNeeded picks it up after queue drains
                deferred += 1;
                continue;
            }

            // All neighbors available — remove from dedup set and proceed
            _ = self.pending_mesh.remove(pos);

            // Try state transition via CAS
            // Try fresh mesh first (.generated → .meshing), then remesh (.dirty → .meshing)
            const cas_succeeded = chunk.future.tryTransition(.generated, .meshing) or
                chunk.future.tryTransition(.dirty, .meshing);

            if (!cas_succeeded) {
                // State changed (chunk being meshed, unloaded, etc.) — skip
                continue;
            }

            // Increment mesh generation for stale result detection
            const gen = chunk.mesh_generation.fetchAdd(1, .acq_rel) +% 1;

            // Submit lightweight mesh task (data=null, workers capture neighbors via RCU)
            self.pool.submit(Task{
                .task_type = .generate_and_mesh,
                .data = null,
                .chunk_pos = pos,
                .chunk_task_kind = .mesh,
                .mesh_generation = gen,
            }) catch |err| {
                // Submission failed — revert state so chunk can be retried
                chunk.setState(.generated);
                logger.warn("Failed to submit mesh task for ({},{},{}): {}", .{
                    pos.x, pos.z, pos.section_y, err,
                });
                // Re-add to pending so it's retried
                self.pending_mesh.put(pos, {}) catch {};
                self.pending_mesh_queue.append(self.allocator, pos) catch {};
                continue;
            };

            submitted += 1;
        }

        // Compact queue when fully consumed
        if (self.pending_mesh_head >= self.pending_mesh_queue.items.len) {
            self.pending_mesh_queue.clearRetainingCapacity();
            self.pending_mesh_head = 0;
        } else if (self.pending_mesh_head > 4096) {
            // Too many consumed entries at front — shift remaining to reclaim memory
            const remaining = self.pending_mesh_queue.items.len - self.pending_mesh_head;
            std.mem.copyForwards(
                ChunkPos,
                self.pending_mesh_queue.items[0..remaining],
                self.pending_mesh_queue.items[self.pending_mesh_head..],
            );
            self.pending_mesh_queue.shrinkRetainingCapacity(remaining);
            self.pending_mesh_head = 0;
        }

        if (submitted > 0) {
            profiler.plotInt("MeshTasksSubmitted", @intCast(submitted));
        }
        if (deferred > 0) {
            profiler.plotInt("MeshDeferred", @intCast(deferred));
        }
        zone.setValue(submitted);

        return submitted;
    }

    /// Rebuild queue when entries are waiting for neighbors or from silent append failures.
    /// When the FIFO drains but pending_mesh has entries (waiting for neighbors or orphaned),
    /// rebuild the queue from the HashMap so they get retried.
    fn rebuildQueueIfNeeded(self: *Self) void {
        // Only rebuild when queue is fully drained but entries remain in pending_mesh
        if (self.pending_mesh_head < self.pending_mesh_queue.items.len) return;
        if (self.pending_mesh.count() == 0) return;

        self.pending_mesh_queue.clearRetainingCapacity();
        self.pending_mesh_head = 0;

        var iter = self.pending_mesh.iterator();
        while (iter.next()) |entry| {
            self.pending_mesh_queue.append(self.allocator, entry.key_ptr.*) catch {};
        }

        profiler.plotInt("MeshQueueRebuilt", @intCast(self.pending_mesh.count()));
    }
};
