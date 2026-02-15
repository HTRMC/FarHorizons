/// ChunkManager - Manages chunk loading, unloading, and meshing
/// Coordinates between main thread and worker threads
///
/// Main thread (minimal): processCompletedTerrain, drainUnloadRequests, processReadyUploads
/// MeshSchedulerThread: owns pending_mesh state, CAS transitions, submits mesh tasks
/// Workers: terrain generation + mesh generation (RCU-protected neighbor capture)
const std = @import("std");
const Io = std.Io;
const shared = @import("Shared");
const renderer = @import("Renderer");
const volk = @import("volk");
const vk = volk.c;

const Logger = shared.Logger;
const profiler = shared.profiler;
const Vec3 = shared.Vec3;
const Chunk = shared.Chunk;
const ChunkPos = shared.ChunkPos;
const ChunkPosContext = shared.ChunkPosContext;
const CHUNK_SIZE = shared.CHUNK_SIZE;
const TerrainGenerator = shared.TerrainGenerator;
const Rcu = shared.Rcu;
const BlockEntry = shared.BlockEntry;

const RenderSystem = renderer.RenderSystem;
const TextureManager = renderer.TextureManager;
const BlockModelShaper = renderer.block.BlockModelShaper;
const ModelLoader = renderer.block.ModelLoader;
const BlockstateLoader = renderer.block.BlockstateLoader;
const ChunkBufferManager = renderer.buffer.ChunkBufferManager;
const ChunkBufferConfig = renderer.buffer.ChunkBufferConfig;
const ChunkBufferAllocation = renderer.buffer.ChunkBufferAllocation;
const GPUDrivenTypes = renderer.GPUDrivenTypes;

const render_chunk = @import("RenderChunk.zig");
const RenderChunk = render_chunk.RenderChunk;
const ChunkMesh = render_chunk.ChunkMesh;
const ChunkState = render_chunk.ChunkState;
const CompletedMesh = render_chunk.CompletedMesh;
const CompletedLayerData = render_chunk.CompletedLayerData;
const RENDER_LAYER_COUNT = render_chunk.RENDER_LAYER_COUNT;

const thread_pool = @import("ThreadPool.zig");
const ThreadPool = thread_pool.ThreadPool;
const ThreadSafeQueue = thread_pool.ThreadSafeQueue;
const Task = thread_pool.Task;
const WorkerContext = thread_pool.WorkerContext;

const chunk_mesher = @import("ChunkMesher.zig");
const ChunkMesher = chunk_mesher.ChunkMesher;
const WorkerMeshContext = chunk_mesher.WorkerMeshContext;

const chunk_storage = @import("ChunkStorage.zig");
const ChunkStorage = chunk_storage.ChunkStorage;

const upload_thread = @import("UploadThread.zig");
const UploadThread = upload_thread.UploadThread;
const UploadResult = upload_thread.UploadResult;

const chunk_load_thread = @import("ChunkLoadThread.zig");
const ChunkLoadThread = chunk_load_thread.ChunkLoadThread;

const mesh_scheduler_thread = @import("MeshSchedulerThread.zig");
const MeshSchedulerThread = mesh_scheduler_thread.MeshSchedulerThread;
const MeshRequest = mesh_scheduler_thread.MeshRequest;

pub const TerrainResult = struct {
    pos: ChunkPos,
    chunk: Chunk,
};

pub const ChunkConfig = struct {
    view_distance: u32 = 4,
    vertical_view_distance: u32 = 4,
    /// Hysteresis to prevent load/unload thrashing at view distance boundary
    unload_distance: u32 = 6,
    worker_count: u8 = 4,
    max_uploads_per_tick: u8 = 4,
};

/// C2ME-style stateful spiral iterator for chunk positions
/// Generates positions in a spiral pattern from center outward (closest chunks first)
/// Remembers state between calls to avoid rescanning already-processed positions
///
/// Spiral pattern (2D view, numbers show iteration order):
///     20 21 22 23 24
///     19  6  7  8  9
///     18  5  0  1 10
///     17  4  3  2 11
///     16 15 14 13 12
///
/// Based on C2ME's SpiralIterator.java
pub const SpiralIterator = struct {
    const Self = @This();

    /// Spiral directions: right, down, left, up (matching C2ME)
    const Direction = enum(u2) { right = 0, down = 1, left = 2, up = 3 };

    pub const Offset = struct { dx: i32, dz: i32, dy: i32 };

    x: i32 = 0,
    z: i32 = 0,
    /// Current Y layer being iterated at this X/Z position
    y: i32 = 0,

    /// Spiral arm length (increases every 2 direction changes)
    span_total: u32 = 1,
    /// Progress along current arm
    span_progress: u32 = 0,
    /// Arms completed at current length (0 or 1, resets when span_total increases)
    span_count: u2 = 0,
    direction: Direction = .right,

    view_dist: i32 = 0,
    vert_dist: i32 = 0,

    /// First call returns origin without stepping
    need_step: bool = false,

    pub fn reset(self: *Self, view_distance: u32, vertical_view_distance: u32) void {
        self.x = 0;
        self.z = 0;
        self.y = -@as(i32, @intCast(vertical_view_distance));
        self.span_total = 1;
        self.span_progress = 0;
        self.span_count = 0;
        self.direction = .right;
        self.view_dist = @intCast(view_distance);
        self.vert_dist = @intCast(vertical_view_distance);
        self.need_step = true;
    }

    /// Spiral ends at corner (radius, radius)
    fn hasNextXZ(self: *const Self) bool {
        return self.x != self.view_dist or self.z != self.view_dist;
    }

    pub fn next(self: *Self) ?Offset {
        if (self.y > self.vert_dist) {
            if (!self.hasNextXZ()) {
                return null;
            }
            self.y = -self.vert_dist;
            self.stepSpiral();
        }

        const result = Offset{ .dx = self.x, .dz = self.z, .dy = self.y };
        self.y += 1;

        return result;
    }

    fn stepSpiral(self: *Self) void {
        if (self.need_step) {
            switch (self.direction) {
                .right => self.x += 1,
                .down => self.z -= 1,
                .left => self.x -= 1,
                .up => self.z += 1,
            }

            self.span_progress += 1;
            if (self.span_progress >= self.span_total) {
                self.span_progress = 0;
                self.span_count += 1;
                if (self.span_count >= 2) {
                    self.span_total += 1;
                    self.span_count = 0;
                }
                self.direction = @enumFromInt((@intFromEnum(self.direction) +% 1) & 0x3);
            }
        }
        self.need_step = true;
    }

    pub fn isComplete(self: *const Self) bool {
        return self.y > self.vert_dist and !self.hasNextXZ();
    }
};

/// Eliminates per-chunk allocations by reusing pre-allocated buffers per worker
pub const WorkerData = struct {
    manager: *ChunkManager,
    mesh_context: *WorkerMeshContext,
};

pub const ChunkManager = struct {
    const Self = @This();
    const logger = Logger.scoped(Self);

    allocator: std.mem.Allocator,
    io: Io,

    chunk_storage: ChunkStorage,

    completed_queue: ThreadSafeQueue(CompletedMesh),
    pool: ThreadPool,
    player_chunk: ChunkPos,
    config: ChunkConfig,
    render_system: *RenderSystem,
    /// Read-only after init, safe for worker threads
    texture_manager: *TextureManager,
    asset_directory: []const u8,

    /// Pre-warmed and read-only after init for thread safety
    shared_model_shaper: ?*BlockModelShaper = null,
    shared_model_loader: ?*ModelLoader = null,
    shared_blockstate_loader: ?*BlockstateLoader = null,

    buffer_manager: ?*ChunkBufferManager = null,
    terrain_generator: ?*TerrainGenerator = null,

    /// Dedicated upload thread for GPU staging (AAA pattern)
    upload_thread: ?*UploadThread = null,

    /// Dedicated thread for chunk load/unload decisions (C2ME-style)
    load_thread: ?*ChunkLoadThread = null,

    /// Dedicated thread for mesh scheduling (decoupled from render thread)
    mesh_scheduler: ?*MeshSchedulerThread = null,

    /// Backpressure counter for terrain tasks submitted by ChunkLoadThread
    /// Incremented by load thread, decremented by worker threads after terrain generation
    in_flight_terrain: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    vertex_buffer_cache: std.ArrayListUnmanaged(vk.VkBuffer) = .{},
    index_buffer_cache: std.ArrayListUnmanaged(vk.VkBuffer) = .{},
    /// Cached arena version to avoid rebuilding buffer lists every frame
    cached_arena_version: u32 = 0,

    /// Protects neighbor chunk pointers during async meshing
    rcu: ?*Rcu = null,

    /// Eliminates ~2.4MB of allocations per chunk by reusing buffers
    worker_data: ?[]WorkerData = null,

    /// Completed terrain waiting for main thread to copy to RenderChunk
    completed_terrain: ThreadSafeQueue(TerrainResult) = undefined,

    /// Chunks needing GPU metadata upload (GPU-driven rendering)
    pending_metadata_uploads: std.ArrayListUnmanaged(*RenderChunk) = .{},

    /// GPU slots needing to be zeroed (freed chunks - Voxy-style invalidation)
    pending_slot_clears: std.ArrayListUnmanaged(u32) = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        render_system: *RenderSystem,
        texture_manager: *TextureManager,
        asset_directory: []const u8,
        config: ChunkConfig,
    ) !Self {
        logger.info("Initializing ChunkManager with view distance {}", .{config.view_distance});

        const storage = try ChunkStorage.init(allocator, config.unload_distance, config.vertical_view_distance);

        const self = Self{
            .allocator = allocator,
            .io = io,
            .chunk_storage = storage,
            .completed_queue = ThreadSafeQueue(CompletedMesh).init(allocator, io),
            .completed_terrain = ThreadSafeQueue(TerrainResult).init(allocator, io),
            .pool = try ThreadPool.init(allocator, io, config.worker_count, processTask),
            .player_chunk = ChunkPos{ .x = 0, .z = 0, .section_y = 0 },
            .config = config,
            .render_system = render_system,
            .texture_manager = texture_manager,
            .asset_directory = asset_directory,
        };

        return self;
    }

    pub fn start(self: *Self) !void {
        const rs = self.render_system;

        // Configure buffer sharing mode for dedicated transfer queue
        const queue_family_indices: ?[]const u32 = if (rs.hasDedicatedTransfer())
            &[_]u32{ rs.getGraphicsFamily(), rs.getTransferFamily() }
        else
            null;

        const buffer_mgr = try self.allocator.create(ChunkBufferManager);
        buffer_mgr.* = try ChunkBufferManager.init(
            self.allocator,
            rs.getDevice(),
            rs.getPhysicalDevice(),
            ChunkBufferConfig{
                .view_distance = self.config.view_distance,
                .vertical_view_distance = self.config.vertical_view_distance,
                // Uses single-buffer mode by default (1GB vertex, 512MB index)
                // Required for GPU-driven rendering where all geometry must be in one buffer
                .sharing_mode = if (rs.hasDedicatedTransfer())
                    vk.VK_SHARING_MODE_CONCURRENT
                else
                    vk.VK_SHARING_MODE_EXCLUSIVE,
                .queue_family_indices = queue_family_indices,
            },
            self.io,
        );
        self.buffer_manager = buffer_mgr;

        const model_loader = try self.allocator.create(ModelLoader);
        model_loader.* = ModelLoader.init(self.allocator, self.io, self.asset_directory);
        self.shared_model_loader = model_loader;

        const blockstate_loader = try self.allocator.create(BlockstateLoader);
        blockstate_loader.* = BlockstateLoader.init(self.allocator, self.io, self.asset_directory);
        self.shared_blockstate_loader = blockstate_loader;

        const shaper = try self.allocator.create(BlockModelShaper);
        shaper.* = BlockModelShaper.init(
            self.allocator,
            model_loader,
            blockstate_loader,
            self.texture_manager,
        );
        self.shared_model_shaper = shaper;

        for (1..256) |id| {
            _ = shaper.getModel(BlockEntry.simple(@intCast(id))) catch {};
        }
        logger.info("Model cache pre-warmed", .{});

        const rcu_instance = try self.allocator.create(Rcu);
        rcu_instance.* = Rcu.init(self.allocator, self.config.worker_count, self.io);
        self.rcu = rcu_instance;
        logger.info("RCU initialized for {} worker threads", .{self.config.worker_count});

        const terrain_gen = try self.allocator.create(TerrainGenerator);
        terrain_gen.* = TerrainGenerator.init(.{ .seed = 12345 }) orelse {
            logger.err("Failed to initialize terrain generator", .{});
            self.allocator.destroy(terrain_gen);
            return error.TerrainGeneratorInitFailed;
        };
        self.terrain_generator = terrain_gen;
        logger.info("Terrain generator initialized with ridged terrain", .{});

        try self.pool.start();

        // Each worker gets ~3.6MB of pre-allocated buffers reused across all chunks
        const worker_count = self.config.worker_count;
        self.worker_data = try self.allocator.alloc(WorkerData, worker_count);

        for (0..worker_count) |i| {
            const mesh_ctx = try self.allocator.create(WorkerMeshContext);
            mesh_ctx.* = try WorkerMeshContext.init(self.allocator);

            self.worker_data.?[i] = WorkerData{
                .manager = self,
                .mesh_context = mesh_ctx,
            };

            self.pool.setWorkerData(i, @ptrCast(&self.worker_data.?[i]));
        }

        const total_buffer_mb = @as(f32, @floatFromInt(worker_count)) * 3.6;
        logger.info("ChunkManager started with {} workers (~{d:.1}MB thread-local buffers)", .{ worker_count, total_buffer_mb });

        // Initialize and start the upload thread (AAA pattern)
        // Upload thread OWNS its own staging ring and does all buffer allocations/frees
        // Upload thread prepares command buffers, main thread submits (thread-safe)
        if (self.buffer_manager) |buf_mgr| {
            const ut = try self.allocator.create(UploadThread);
            ut.* = try UploadThread.init(
                self.allocator,
                self.io,
                rs.getDevice(),
                rs.getPhysicalDevice(),
                rs.getTransferFamily(), // Use transfer queue family for upload command pool
                buf_mgr,
                &self.completed_queue,
                self.config.view_distance,
                self.config.vertical_view_distance,
                self.config.unload_distance,
                .{}, // Use default config (0.5ms budget)
            );
            try ut.start();
            self.upload_thread = ut;

            // Register upload timeline with RenderSystem for cross-queue synchronization
            rs.setUploadTimeline(ut.upload_timeline);

            if (rs.hasDedicatedTransfer()) {
                logger.info("Upload thread started with dedicated transfer queue (family {})", .{rs.getTransferFamily()});
            } else {
                logger.info("Upload thread started on graphics queue (0.5ms time budget)", .{});
            }
        }

        // Initialize and start the mesh scheduler thread
        // Owns pending_mesh state, CAS transitions, and pool submission for mesh tasks
        {
            const ms = try self.allocator.create(MeshSchedulerThread);
            ms.* = try MeshSchedulerThread.init(
                self.allocator,
                self.io,
                &self.pool,
                &self.chunk_storage,
                self.config.view_distance,
                self.config.vertical_view_distance,
            );
            try ms.start();
            self.mesh_scheduler = ms;
        }

        // Initialize and start the chunk load thread (C2ME-style)
        // Load thread submits terrain tasks directly to the pool (no SPSC intermediary)
        {
            const lt = try self.allocator.create(ChunkLoadThread);
            lt.* = try ChunkLoadThread.init(
                self.allocator,
                self.io,
                &self.pool,
                &self.in_flight_terrain,
                self.config.view_distance,
                self.config.vertical_view_distance,
                self.config.unload_distance,
            );
            try lt.start();
            self.load_thread = lt;
        }
    }

    pub fn deinit(self: *Self) void {
        logger.info("Shutting down ChunkManager...", .{});

        // Shutdown load thread first (it writes to load/unload request queues)
        if (self.load_thread) |lt| {
            lt.deinit();
            self.allocator.destroy(lt);
            self.load_thread = null;
        }

        // Shutdown mesh scheduler (it reads storage and submits to pool)
        if (self.mesh_scheduler) |ms| {
            ms.deinit();
            self.allocator.destroy(ms);
            self.mesh_scheduler = null;
        }

        // Shutdown upload thread (it reads from completed_queue)
        if (self.upload_thread) |ut| {
            ut.deinit();
            self.allocator.destroy(ut);
            self.upload_thread = null;
        }

        self.pool.shutdown();

        // All tasks now use data=null (terrain and mesh), no ChunkTask allocations to drain
        while (self.pool.task_queue.tryPop()) |_| {}

        self.pool.deinit();

        if (self.worker_data) |workers| {
            for (workers) |*wd| {
                wd.mesh_context.deinit();
                self.allocator.destroy(wd.mesh_context);
            }
            self.allocator.free(workers);
            self.worker_data = null;
        }

        // Must happen after pool shutdown to ensure all workers have exited
        if (self.rcu) |rcu_instance| {
            logger.info("Synchronizing RCU before cleanup...", .{});
            rcu_instance.synchronize();
            rcu_instance.deinit();
            self.allocator.destroy(rcu_instance);
            self.rcu = null;
        }

        if (self.shared_model_shaper) |shaper| {
            shaper.deinit();
            self.allocator.destroy(shaper);
        }
        if (self.shared_blockstate_loader) |loader| {
            loader.deinit();
            self.allocator.destroy(loader);
        }
        if (self.shared_model_loader) |loader| {
            loader.deinit();
            self.allocator.destroy(loader);
        }

        var iter = self.chunk_storage.iterator();
        while (iter.next()) |entry| {
            const chunk = entry.value_ptr.*;
            // Free all layer allocations (solid, cutout, translucent)
            if (self.buffer_manager) |buf_mgr| {
                const allocations = chunk.getBufferAllocations();
                for (allocations) |alloc_opt| {
                    if (alloc_opt) |alloc| {
                        buf_mgr.free(alloc);
                    }
                }
            }
            // Free GPU slot if present
            if (chunk.hasGPUSlot()) {
                self.render_system.freeChunkSlot(chunk.gpu_slot);
            }
            chunk.deinit();
            self.allocator.destroy(chunk);
        }
        self.chunk_storage.deinit();

        while (self.completed_terrain.tryPop()) |_| {}
        self.completed_terrain.deinit();

        while (self.completed_queue.tryPop()) |*mesh| {
            var m = mesh.*;
            m.deinit();
        }
        self.completed_queue.deinit();

        self.vertex_buffer_cache.deinit(self.allocator);
        self.index_buffer_cache.deinit(self.allocator);
        self.pending_metadata_uploads.deinit(self.allocator);
        self.pending_slot_clears.deinit(self.allocator);

        if (self.buffer_manager) |buf_mgr| {
            buf_mgr.deinit();
            self.allocator.destroy(buf_mgr);
        }

        if (self.terrain_generator) |terrain_gen| {
            terrain_gen.deinit();
            self.allocator.destroy(terrain_gen);
        }

        logger.info("ChunkManager shutdown complete", .{});
    }

    pub fn updatePlayerPosition(self: *Self, position: Vec3) void {
        const zone = profiler.trace(@src());
        defer zone.end();

        const new_chunk = ChunkPos.fromWorldPos(position.x, position.y, position.z);

        if (new_chunk.eql(self.player_chunk)) return;

        self.player_chunk = new_chunk;

        // Ensures closest chunks are always processed first, even as player moves
        self.pool.updateCameraPos(new_chunk.x, new_chunk.z, new_chunk.section_y);

        // Update upload thread for staleness checks
        if (self.upload_thread) |ut| {
            ut.updatePlayerPos(new_chunk.x, new_chunk.z, new_chunk.section_y);
        }

        // Notify background load thread of new player position (C2ME-style)
        if (self.load_thread) |lt| {
            lt.updatePlayerPos(new_chunk.x, new_chunk.z, new_chunk.section_y);
        }

        // Notify mesh scheduler of new player position (for neighbor dependency checks)
        if (self.mesh_scheduler) |ms| {
            ms.updatePlayerPos(new_chunk.x, new_chunk.z, new_chunk.section_y);
        }
    }

    pub fn beginFrame(self: *Self) void {
        // Synchronize slot allocator's frame counter
        self.render_system.advanceSlotAllocatorFrame();
    }

    /// Capped per tick to avoid frame spikes when workers produce terrain results faster than
    /// the main thread can create RenderChunks (~5μs each × 512 = ~2.5ms budget)
    const MAX_TERRAIN_PER_TICK: u32 = 512;

    fn processCompletedTerrain(self: *Self) void {
        const zone = profiler.traceNamed("ProcessCompletedTerrain");
        defer zone.end();

        const ms = self.mesh_scheduler orelse return;

        var processed: u32 = 0;
        var discarded: u32 = 0;
        while (processed < MAX_TERRAIN_PER_TICK) {
            const result = self.completed_terrain.tryPop() orelse break;

            // Discard stale terrain results for positions outside unload range.
            // This prevents orphaned chunks: if the load thread already removed this position
            // from its managed set (via scanForUnloads), creating it here would leave it
            // with no owner — never unloaded, never re-loaded.
            {
                const horizontally_distant = !result.pos.isWithinDistance(self.player_chunk, self.config.unload_distance);
                const dy = @abs(result.pos.section_y - self.player_chunk.section_y);
                const vertically_distant = dy > self.config.vertical_view_distance + 2;
                if (horizontally_distant or vertically_distant) {
                    discarded += 1;
                    continue;
                }
            }

            // If chunk already exists in storage (e.g. rapid unload/reload), update terrain data
            if (self.chunk_storage.get(result.pos)) |render_chunk_ptr| {
                render_chunk_ptr.chunk = result.chunk;
                render_chunk_ptr.setState(.generated);
                // Push to mesh scheduler (SPSC: main thread → scheduler thread)
                _ = ms.mesh_ready_queue.tryPush(MeshRequest{
                    .pos = result.pos,
                    .is_remesh = false,
                });
                // Remesh neighbors that were meshed without this chunk's data
                self.queueNeighborRemeshes(result.pos);
                processed += 1;
                continue;
            }

            // Chunk not in storage yet — create RenderChunk lazily
            // Stale results were already filtered above; remaining results are in range.
            const render_chunk_ptr = self.allocator.create(RenderChunk) catch continue;
            render_chunk_ptr.* = RenderChunk.init(self.allocator, result.pos);
            render_chunk_ptr.chunk = result.chunk;
            render_chunk_ptr.setState(.generated);

            const previous = self.chunk_storage.put(result.pos, render_chunk_ptr) catch {
                render_chunk_ptr.deinit();
                self.allocator.destroy(render_chunk_ptr);
                continue;
            };

            // Handle ring buffer collision (different position mapped to same slot)
            if (previous) |old_chunk| {
                // Scheduler handles stale entries via getAtomic → null (no pending_mesh cleanup needed)

                if (self.upload_thread) |ut| {
                    const allocations = old_chunk.getBufferAllocations();
                    for (allocations) |alloc_opt| {
                        if (alloc_opt) |alloc| {
                            ut.queueFree(alloc);
                        }
                    }
                }
                if (old_chunk.hasGPUSlot()) {
                    self.pending_slot_clears.append(self.allocator, old_chunk.gpu_slot) catch {};
                    self.render_system.freeChunkSlot(old_chunk.gpu_slot);
                }
                old_chunk.deinit();
                self.allocator.destroy(old_chunk);
            }

            // Push to mesh scheduler (SPSC: main thread → scheduler thread)
            _ = ms.mesh_ready_queue.tryPush(MeshRequest{
                .pos = result.pos,
                .is_remesh = false,
            });
            // Remesh neighbors that were meshed without this chunk's data
            self.queueNeighborRemeshes(result.pos);
            processed += 1;
        }
        if (discarded > 0) {
            profiler.plotInt("TerrainDiscarded", @intCast(discarded));
        }
        zone.setValue(processed);
    }

    /// Call once per frame from main thread after beginFrame
    /// AAA pattern: minimal work - no allocations, no uploads, no waits
    /// Mesh scheduling is fully off-thread (MeshSchedulerThread)
    pub fn tick(self: *Self) void {
        const zone = profiler.trace(@src());
        defer zone.end();

        // Tracy plots for monitoring chunk system health
        profiler.plotInt("LoadedChunks", @intCast(self.chunk_storage.count));
        profiler.plotInt("InFlightTerrain", @intCast(self.in_flight_terrain.load(.acquire)));
        profiler.plotInt("TaskQueueLen", @intCast(self.pool.pendingTasks()));
        profiler.plotInt("CompletedTerrain", @intCast(self.completed_terrain.len()));
        profiler.plotInt("CompletedMesh", @intCast(self.completed_queue.len()));

        // Plot upload thread stats
        if (self.upload_thread) |ut| {
            profiler.plotInt("UploadQueueDepth", @intCast(ut.getOutputQueueDepth()));
        }

        // Process terrain results BEFORE unloads to prevent orphaned chunks:
        // If we unload first, a terrain result for that position could re-create the chunk
        // after unload, leaving it orphaned (not in load thread's managed set → never unloaded again).
        self.processCompletedTerrain();

        // C2ME-style: apply unload decisions from background thread
        // Runs after terrain so newly-created chunks that are out of range get unloaded immediately.
        self.drainUnloadRequests();

        // Mesh scheduling is now handled by MeshSchedulerThread (no checkMeshDependencies)

        // AAA pattern: main thread submits prepared batches to transfer queue (thread-safe queue access)
        if (self.upload_thread) |ut| {
            const result = ut.submitPreparedBatches(self.render_system.getTransferQueue());
            if (result.count > 0) {
                self.render_system.setLastUploadTimelineValue(result.max_timeline);
                profiler.plotInt("BatchesSubmitted", @intCast(result.count));
            }
        }

        // AAA pattern: process ready uploads from upload thread (non-blocking)
        self.processReadyUploads();

        // RCU advancement (already opportunistic via tryAdvance)
        if (self.rcu) |rcu_instance| {
            _ = rcu_instance.tryAdvance();
        }
    }

    /// Process ready uploads from the upload thread (non-blocking)
    /// Only applies uploads that are ready - no waiting, no allocations
    /// AAA pattern: uses vkGetSemaphoreCounterValue (never waits) to check GPU completion
    /// AAA pattern: queues frees to upload thread instead of freeing directly
    /// Capped per tick to prevent frame spikes when many uploads complete at once
    const MAX_UPLOADS_PER_TICK: u32 = 256;

    fn processReadyUploads(self: *Self) void {
        const zone = profiler.traceNamed("ProcessReadyUploads");
        defer zone.end();

        const ut = self.upload_thread orelse return;
        if (ut.output_queue.isEmpty()) return; // no work, skip syscall

        const device = self.render_system.getDevice();
        const vkGetSemaphoreCounterValue = vk.vkGetSemaphoreCounterValue orelse return;

        // Single timeline query per frame
        var completed: u64 = 0;
        if (vkGetSemaphoreCounterValue(device, ut.upload_timeline, &completed) != vk.VK_SUCCESS) return;

        var processed: u32 = 0;
        var stale_discarded: u32 = 0;

        // Process uploads with completed timeline values (AAA pattern: never wait)
        while (processed < MAX_UPLOADS_PER_TICK) {
            const result_ptr = ut.output_queue.peek() orelse break;
            // timeline_value 0 = no GPU work, always ready
            if (result_ptr.upload_timeline_value > completed) break;

            // Timeline value is reached, pop and process
            const result = ut.output_queue.tryPop() orelse break;
            // Check if chunk still exists (might have been unloaded while uploading)
            const render_chunk_ptr = self.chunk_storage.get(result.pos) orelse {
                // Chunk was unloaded, clean up the result
                if (result.valid) {
                    var mesh = result.mesh;
                    // Queue GPU allocations for freeing (AAA: never touch buffer_manager from main thread)
                    for (0..RENDER_LAYER_COUNT) |i| {
                        if (mesh.layers[i].buffer_allocation.valid) {
                            ut.queueFree(mesh.layers[i].buffer_allocation);
                        }
                    }
                    mesh.deinit();
                }
                continue;
            };

            // State guard: only apply mesh to chunks still in .meshing state
            // Prevents stale mesh from being applied to a chunk that was recycled or re-queued
            const current_state = render_chunk_ptr.getState();
            if (current_state != .meshing) {
                if (result.valid) {
                    var mesh = result.mesh;
                    for (0..RENDER_LAYER_COUNT) |i| {
                        if (mesh.layers[i].buffer_allocation.valid) {
                            ut.queueFree(mesh.layers[i].buffer_allocation);
                        }
                    }
                    mesh.deinit();
                }
                stale_discarded += 1;
                continue;
            }

            // Generation guard: only apply if this result matches the current mesh generation
            // Prevents stale mesh from an earlier scheduling being applied over a newer one
            if (result.mesh_generation != render_chunk_ptr.mesh_generation.load(.acquire)) {
                if (result.valid) {
                    var mesh = result.mesh;
                    for (0..RENDER_LAYER_COUNT) |i| {
                        if (mesh.layers[i].buffer_allocation.valid) {
                            ut.queueFree(mesh.layers[i].buffer_allocation);
                        }
                    }
                    mesh.deinit();
                }
                stale_discarded += 1;
                continue;
            }

            // Handle invalid/empty results (empty meshes)
            if (!result.valid) {
                render_chunk_ptr.setState(.ready);
                continue;
            }

            // Queue old mesh allocations for freeing (AAA: never touch buffer_manager from main thread)
            const old_allocations = render_chunk_ptr.getBufferAllocations();
            for (old_allocations) |old_alloc_opt| {
                if (old_alloc_opt) |old_alloc| {
                    ut.queueFree(old_alloc);
                }
            }

            // Apply the new mesh
            render_chunk_ptr.setMesh(result.mesh);

            // GPU-driven rendering: allocate slot if needed and queue metadata upload
            if (!render_chunk_ptr.hasGPUSlot()) {
                render_chunk_ptr.gpu_slot = self.render_system.allocateChunkSlot();
            }
            if (render_chunk_ptr.hasGPUSlot()) {
                self.pending_metadata_uploads.append(self.allocator, render_chunk_ptr) catch {};
            }

            processed += 1;
        }

        if (processed > 0) {
            profiler.plotInt("UploadsApplied", @intCast(processed));
        }
        if (stale_discarded > 0) {
            profiler.plotInt("StaleUploadsDiscarded", @intCast(stale_discarded));
        }
    }

    /// Commit pending GPU metadata uploads for GPU-driven rendering
    /// Also clears metadata for freed slots (Voxy-style invalidation)
    pub fn commitMetadataUploads(self: *Self, cmd_buffer: vk.VkCommandBuffer) void {
        // First, clear metadata for freed slots (upload zeroed data)
        // This ensures compute shader skips these slots (all indexCount == 0)
        for (self.pending_slot_clears.items) |slot| {
            self.render_system.uploadChunkMetadata(slot, GPUDrivenTypes.ChunkGPUData.EMPTY, cmd_buffer) catch |err| {
                logger.warn("Failed to clear chunk metadata slot {}: {}", .{ slot, err });
            };
        }
        self.pending_slot_clears.clearRetainingCapacity();

        // Then upload actual metadata for new/updated chunks
        for (self.pending_metadata_uploads.items) |chunk| {
            if (chunk.hasGPUSlot() and chunk.mesh != null) {
                const gpu_data = chunk.buildGPUData();
                self.render_system.uploadChunkMetadata(chunk.gpu_slot, gpu_data, cmd_buffer) catch |err| {
                    logger.warn("Failed to upload chunk metadata: {}", .{err});
                };
            }
        }
        self.pending_metadata_uploads.clearRetainingCapacity();
    }

    pub fn getVertexBuffer(self: *const Self) ?vk.VkBuffer {
        const buf_mgr = self.buffer_manager orelse return null;
        return buf_mgr.getPrimaryVertexBuffer();
    }

    pub fn getIndexBuffer(self: *const Self) ?vk.VkBuffer {
        const buf_mgr = self.buffer_manager orelse return null;
        return buf_mgr.getPrimaryIndexBuffer();
    }

    pub fn getVertexArenaCount(self: *const Self) usize {
        const buf_mgr = self.buffer_manager orelse return 0;
        return buf_mgr.getVertexArenaCount();
    }

    pub fn getAllVertexBuffers(self: *Self) []const vk.VkBuffer {
        self.refreshBufferCachesIfNeeded();
        return self.vertex_buffer_cache.items;
    }

    pub fn getAllIndexBuffers(self: *Self) []const vk.VkBuffer {
        self.refreshBufferCachesIfNeeded();
        return self.index_buffer_cache.items;
    }

    /// Refreshes buffer caches only when arena version changes (new arenas added)
    /// This eliminates per-frame allocations in getAllVertexBuffers/getAllIndexBuffers
    fn refreshBufferCachesIfNeeded(self: *Self) void {
        const buf_mgr = self.buffer_manager orelse return;
        const current_version = buf_mgr.getArenaVersion();

        // Only rebuild if arenas have changed
        if (current_version == self.cached_arena_version and
            self.vertex_buffer_cache.items.len > 0)
        {
            return;
        }

        self.cached_arena_version = current_version;

        // Rebuild vertex buffer cache
        const vertex_count = buf_mgr.getVertexArenaCount();
        self.vertex_buffer_cache.clearRetainingCapacity();
        for (0..vertex_count) |i| {
            if (buf_mgr.getVertexBuffer(@intCast(i))) |buf| {
                self.vertex_buffer_cache.append(self.allocator, buf) catch {
                    logger.err("Failed to cache vertex buffer {}, rendering may be incomplete", .{i});
                    continue;
                };
            }
        }

        // Rebuild index buffer cache
        const index_count = buf_mgr.getIndexArenaCount();
        self.index_buffer_cache.clearRetainingCapacity();
        for (0..index_count) |i| {
            if (buf_mgr.getIndexBuffer(@intCast(i))) |buf| {
                self.index_buffer_cache.append(self.allocator, buf) catch {
                    logger.err("Failed to cache index buffer {}, rendering may be incomplete", .{i});
                    continue;
                };
            }
        }
    }

    /// Returns the high water mark of GPU slots for GPU-driven rendering
    /// This is the maximum slot index ever allocated, ensuring compute shader
    /// iterates over all slots (freed slots have zeroed metadata and are skipped)
    pub fn getActiveChunkCount(self: *const Self) u32 {
        return self.render_system.getChunkSlotHighWaterMark();
    }

    /// Drain unload requests from the background ChunkLoadThread
    /// Capped per tick to avoid frame spikes on boundary crossings (~900+ unloads at once)
    const MAX_UNLOADS_PER_TICK: u32 = 128;

    fn drainUnloadRequests(self: *Self) void {
        const zone = profiler.traceNamed("DrainUnloadRequests");
        defer zone.end();

        const lt = self.load_thread orelse return;
        var unloaded: u32 = 0;

        while (unloaded < MAX_UNLOADS_PER_TICK) {
            const pos = lt.unload_requests.tryPop() orelse break;
            self.unloadChunk(pos);
            unloaded += 1;
        }

        if (unloaded > 0) {
            profiler.plotInt("ChunksUnloaded", @intCast(unloaded));
        }
        zone.setValue(unloaded);
    }

    pub fn getBlockAt(self: *Self, world_x: i32, world_y: i32, world_z: i32) ?shared.BlockEntry {
        const chunk_pos = ChunkPos.fromBlockPos(world_x, world_y, world_z);

        const rchunk = self.chunk_storage.get(chunk_pos) orelse return null;
        if (rchunk.getState() != .ready) return null;

        const local_x: u32 = @intCast(@mod(world_x, CHUNK_SIZE));
        const local_y: u32 = @intCast(@mod(world_y, CHUNK_SIZE));
        const local_z: u32 = @intCast(@mod(world_z, CHUNK_SIZE));

        return rchunk.chunk.getBlockEntry(local_x, local_y, local_z);
    }

    /// For collision - block data is valid even during remeshing
    pub fn getBlockAtForCollision(self: *Self, world_x: i32, world_y: i32, world_z: i32) ?shared.BlockEntry {
        const chunk_pos = ChunkPos.fromBlockPos(world_x, world_y, world_z);

        const rchunk = self.chunk_storage.get(chunk_pos) orelse return null;
        if (rchunk.getState() == .loading) return null;

        const local_x: u32 = @intCast(@mod(world_x, CHUNK_SIZE));
        const local_y: u32 = @intCast(@mod(world_y, CHUNK_SIZE));
        const local_z: u32 = @intCast(@mod(world_z, CHUNK_SIZE));

        return rchunk.chunk.getBlockEntry(local_x, local_y, local_z);
    }

    pub fn setBlockAt(self: *Self, world_x: i32, world_y: i32, world_z: i32, entry: shared.BlockEntry) bool {
        const chunk_pos = ChunkPos.fromBlockPos(world_x, world_y, world_z);

        const rchunk = self.chunk_storage.get(chunk_pos) orelse return false;

        const local_x: u32 = @intCast(@mod(world_x, CHUNK_SIZE));
        const local_y: u32 = @intCast(@mod(world_y, CHUNK_SIZE));
        const local_z: u32 = @intCast(@mod(world_z, CHUNK_SIZE));

        rchunk.chunk.setBlockEntry(local_x, local_y, local_z, entry);

        self.queueChunkRemesh(chunk_pos);

        if (local_x == 0) self.remeshNeighborIfLoaded(chunk_pos.x - 1, chunk_pos.z, chunk_pos.section_y);
        if (local_x == CHUNK_SIZE - 1) self.remeshNeighborIfLoaded(chunk_pos.x + 1, chunk_pos.z, chunk_pos.section_y);
        if (local_y == 0) self.remeshNeighborIfLoaded(chunk_pos.x, chunk_pos.z, chunk_pos.section_y - 1);
        if (local_y == CHUNK_SIZE - 1) self.remeshNeighborIfLoaded(chunk_pos.x, chunk_pos.z, chunk_pos.section_y + 1);
        if (local_z == 0) self.remeshNeighborIfLoaded(chunk_pos.x, chunk_pos.z - 1, chunk_pos.section_y);
        if (local_z == CHUNK_SIZE - 1) self.remeshNeighborIfLoaded(chunk_pos.x, chunk_pos.z + 1, chunk_pos.section_y);

        return true;
    }

    pub fn isBlockSolid(self: *Self, world_x: i32, world_y: i32, world_z: i32) bool {
        const entry = self.getBlockAtForCollision(world_x, world_y, world_z) orelse return false;
        return !entry.isAir() and entry.isSolid();
    }

    pub fn getCollisionShape(self: *Self, world_x: i32, world_y: i32, world_z: i32) shared.VoxelShape {
        const entry = self.getBlockAtForCollision(world_x, world_y, world_z) orelse return shared.voxel_shape.EMPTY;
        if (entry.isAir()) return shared.voxel_shape.EMPTY;
        return shared.block.getShape(entry.id, entry.state).*;
    }

    fn remeshNeighborIfLoaded(self: *Self, chunk_x: i32, chunk_z: i32, section_y: i32) void {
        const neighbor_pos = ChunkPos{ .x = chunk_x, .z = chunk_z, .section_y = section_y };
        const neighbor_chunk = self.chunk_storage.get(neighbor_pos) orelse return;
        const state = neighbor_chunk.getState();
        // Also remesh .meshing chunks: the in-flight worker may have already captured
        // neighbors before this chunk was in storage. Setting .dirty causes the stale
        // result to be discarded (state/generation guards) and a fresh mesh scheduled.
        if (state == .ready or state == .meshing) {
            self.queueChunkRemesh(neighbor_pos);
        }
    }

    /// When a chunk's terrain data arrives, remesh all 6 neighbors already in .ready state.
    /// They may have been meshed without this chunk's data, causing uncculled boundary faces.
    fn queueNeighborRemeshes(self: *Self, pos: ChunkPos) void {
        self.remeshNeighborIfLoaded(pos.x, pos.z, pos.section_y - 1); // down
        self.remeshNeighborIfLoaded(pos.x, pos.z, pos.section_y + 1); // up
        self.remeshNeighborIfLoaded(pos.x, pos.z - 1, pos.section_y); // north
        self.remeshNeighborIfLoaded(pos.x, pos.z + 1, pos.section_y); // south
        self.remeshNeighborIfLoaded(pos.x - 1, pos.z, pos.section_y); // west
        self.remeshNeighborIfLoaded(pos.x + 1, pos.z, pos.section_y); // east
    }

    /// Queue a chunk for remeshing via the mesh scheduler thread.
    /// Sets state to .dirty and pushes a MeshRequest to the scheduler's SPSC queue.
    /// Zero allocations on the main thread — scheduler + workers handle everything.
    fn queueChunkRemesh(self: *Self, pos: ChunkPos) void {
        const render_chunk_ptr = self.chunk_storage.get(pos) orelse return;
        render_chunk_ptr.setState(.dirty);

        if (self.mesh_scheduler) |ms| {
            _ = ms.mesh_ready_queue.tryPush(MeshRequest{
                .pos = pos,
                .is_remesh = true,
            });
        }
    }

    /// Uses RCU to defer freeing until all workers have exited critical sections
    fn unloadChunk(self: *Self, pos: ChunkPos) void {
        const zone = profiler.trace(@src());
        defer zone.end();

        if (self.chunk_storage.remove(pos)) |render_chunk_ptr| {
            // Queue allocations for freeing (AAA: never touch buffer_manager from main thread)
            if (self.upload_thread) |ut| {
                const allocations = render_chunk_ptr.getBufferAllocations();
                for (allocations) |alloc_opt| {
                    if (alloc_opt) |alloc| {
                        ut.queueFree(alloc);
                    }
                }
            }

            // GPU-driven rendering: queue slot for clearing, then free it
            // This ensures the GPU metadata is zeroed so compute shader skips it (Voxy-style)
            if (render_chunk_ptr.hasGPUSlot()) {
                self.pending_slot_clears.append(self.allocator, render_chunk_ptr.gpu_slot) catch {};
                self.render_system.freeChunkSlot(render_chunk_ptr.gpu_slot);
                render_chunk_ptr.gpu_slot = GPUDrivenTypes.SlotAllocator.INVALID_SLOT;
            }

            const rcu_instance = self.rcu orelse {
                @panic("RCU must be initialized before unloading chunks");
            };

            const DeferredChunkFree = struct {
                chunk: *RenderChunk,
                allocator: std.mem.Allocator,

                fn free(self_ptr: *anyopaque) void {
                    const data: *@This() = @ptrCast(@alignCast(self_ptr));
                    data.chunk.deinit();
                    data.allocator.destroy(data.chunk);
                    data.allocator.destroy(data);
                }
            };

            const deferred = self.allocator.create(DeferredChunkFree) catch {
                @panic("Failed to allocate RCU deferred free - out of memory");
            };
            deferred.* = .{
                .chunk = render_chunk_ptr,
                .allocator = self.allocator,
            };

            rcu_instance.retire(@ptrCast(deferred), DeferredChunkFree.free);
        }
        // No pending_mesh cleanup needed — scheduler handles stale entries via getAtomic → null
    }

    fn processTask(ctx: *WorkerContext, task: Task) void {
        const zone = profiler.trace(@src());
        defer zone.end();

        if (task.task_type != .generate_and_mesh) return;

        const worker_data: *WorkerData = @ptrCast(@alignCast(ctx.user_data orelse return));
        const self = worker_data.manager;

        if (task.data != null) return; // No legacy ChunkTask data expected

        // Mesh task — capture neighbors via RCU + getAtomic (zero-alloc on main thread)
        if (task.chunk_task_kind == .mesh) {
            self.processMeshTask(ctx, task);
            return;
        }

        // Terrain task — position embedded in Task struct, zero heap allocation
        var chunk: Chunk = undefined;
        if (self.terrain_generator) |terrain_gen| {
            chunk = terrain_gen.generateChunk(
                task.chunk_pos.x,
                task.chunk_pos.section_y,
                task.chunk_pos.z,
            );
        } else {
            chunk = Chunk.generateTestChunk();
        }

        self.completed_terrain.push(TerrainResult{
            .pos = task.chunk_pos,
            .chunk = chunk,
        }) catch |err| {
            logger.warn("Failed to push completed terrain: {}", .{err});
        };

        // Release backpressure so load thread can submit more tasks
        _ = self.in_flight_terrain.fetchSub(1, .release);
    }

    /// Worker-side mesh task processing: captures chunk + neighbors via RCU + getAtomic
    /// No main-thread allocation needed — the 57KB neighbor copies happen on the worker thread
    fn processMeshTask(self: *Self, ctx: *WorkerContext, task: Task) void {
        const mesh_zone = profiler.traceNamed("ProcessMeshTask");
        defer mesh_zone.end();

        const worker_data: *WorkerData = @ptrCast(@alignCast(ctx.user_data orelse return));
        const mesh_ctx = worker_data.mesh_context;
        const shaper = self.shared_model_shaper orelse return;
        const rcu_instance = self.rcu orelse return;
        const pos = task.chunk_pos;
        const gen = task.mesh_generation;

        // RCU read-side critical section protects against chunk being freed during copy
        _ = rcu_instance.readLock(@intCast(ctx.id));

        // Get the chunk via atomic read
        const render_chunk_ptr = self.chunk_storage.getAtomic(pos) orelse {
            rcu_instance.readUnlock(@intCast(ctx.id));
            // Chunk was unloaded — push empty result so state machine isn't stuck
            self.pushEmptyMeshResult(pos, gen);
            return;
        };

        // Verify chunk is still in .meshing state (could have been recycled)
        if (render_chunk_ptr.getState() != .meshing) {
            rcu_instance.readUnlock(@intCast(ctx.id));
            self.pushEmptyMeshResult(pos, gen);
            return;
        }

        // Copy chunk data (8KB) under RCU protection
        const chunk_copy = render_chunk_ptr.chunk;

        // Copy neighbor data (up to 48KB total) via getAtomic
        var neighbors: [6]?Chunk = .{ null, null, null, null, null, null };
        const offsets = [6]ChunkPos{
            .{ .x = 0, .z = 0, .section_y = -1 }, // down
            .{ .x = 0, .z = 0, .section_y = 1 }, // up
            .{ .x = 0, .z = -1, .section_y = 0 }, // north
            .{ .x = 0, .z = 1, .section_y = 0 }, // south
            .{ .x = -1, .z = 0, .section_y = 0 }, // west
            .{ .x = 1, .z = 0, .section_y = 0 }, // east
        };

        for (0..6) |i| {
            const neighbor_pos = ChunkPos{
                .x = pos.x + offsets[i].x,
                .z = pos.z + offsets[i].z,
                .section_y = pos.section_y + offsets[i].section_y,
            };

            if (self.chunk_storage.getAtomic(neighbor_pos)) |neighbor| {
                const state = neighbor.getState();
                if (state == .generated or state == .meshing or state == .ready or state == .dirty) {
                    neighbors[i] = neighbor.chunk;
                }
            }
        }

        // Exit RCU critical section — all data has been copied to stack
        rcu_instance.readUnlock(@intCast(ctx.id));

        // Generate mesh from local copies (outside RCU section)
        var neighbor_ptrs: [6]?*const Chunk = .{ null, null, null, null, null, null };
        for (0..6) |i| {
            if (neighbors[i] != null) {
                neighbor_ptrs[i] = &(neighbors[i].?);
            }
        }

        var mesh = mesh_ctx.generateMesh(
            &chunk_copy,
            pos,
            neighbor_ptrs,
            shaper,
            self.texture_manager,
        ) catch |err| {
            logger.warn("Failed to generate mesh for chunk ({},{},{}): {}", .{ pos.x, pos.z, pos.section_y, err });
            self.pushEmptyMeshResult(pos, gen);
            return;
        };

        mesh.generated_chunk = null;
        mesh.mesh_generation = gen;

        self.completed_queue.push(mesh) catch |err| {
            logger.warn("Failed to push completed mesh: {}", .{err});
            mesh.deinit();
            self.pushEmptyMeshResult(pos, gen);
        };
    }

    /// Push an empty CompletedMesh so the chunk transitions out of .meshing
    fn pushEmptyMeshResult(self: *Self, pos: ChunkPos, gen: u32) void {
        self.completed_queue.push(CompletedMesh{
            .pos = pos,
            .layers = .{ CompletedLayerData.EMPTY, CompletedLayerData.EMPTY, CompletedLayerData.EMPTY },
            .allocator = self.allocator,
            .mesh_generation = gen,
        }) catch {};
    }
};
