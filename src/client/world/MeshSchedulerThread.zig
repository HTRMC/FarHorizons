/// MeshSchedulerThread - Dedicated background thread for mesh scheduling
/// Decouples mesh dependency checking and task submission from the main thread.
/// The main thread only pushes positions to a lock-free queue; this thread does all
/// the work of checking chunk state, CAS transitions, and pool submission.
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

    // Thread-local state (only accessed by background thread)
    pending_mesh: PosSet,
    pending_mesh_queue: std.ArrayListUnmanaged(ChunkPos),
    pending_mesh_head: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        pool: *ThreadPool,
        storage: *ChunkStorage,
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
            self.pending_mesh_queue.append(self.allocator, request.pos) catch {};
            drained += 1;
        }

        return drained;
    }

    /// Process the FIFO queue: check chunk state, CAS, submit to pool.
    /// No neighbor dependency checks — chunks are meshed immediately when terrain
    /// completes. Boundary artifacts are fixed by queueNeighborRemeshes on the main thread.
    fn processPendingQueue(self: *Self) u32 {
        const zone = profiler.traceNamed("MeshScheduleProcess");
        defer zone.end();

        var submitted: u32 = 0;

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

            // Remove from dedup set and proceed
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
        zone.setValue(submitted);

        return submitted;
    }
};
