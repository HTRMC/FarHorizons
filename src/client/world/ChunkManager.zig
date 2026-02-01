/// ChunkManager - Manages chunk loading, unloading, and meshing
/// Coordinates between main thread and worker threads
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
const Vertex = renderer.Vertex;
const BlockModelShaper = renderer.block.BlockModelShaper;
const ModelLoader = renderer.block.ModelLoader;
const BlockstateLoader = renderer.block.BlockstateLoader;
const ChunkBufferManager = renderer.buffer.ChunkBufferManager;
const ChunkBufferConfig = renderer.buffer.ChunkBufferConfig;
const ChunkBufferAllocation = renderer.buffer.ChunkBufferAllocation;
const ChunkDrawCommand = RenderSystem.ChunkDrawCommand;
const StagingCopy = RenderSystem.StagingCopy;
const GPUDrivenTypes = renderer.GPUDrivenTypes;

const render_chunk = @import("RenderChunk.zig");
const RenderChunk = render_chunk.RenderChunk;
const ChunkMesh = render_chunk.ChunkMesh;
const ChunkState = render_chunk.ChunkState;
const CompletedMesh = render_chunk.CompletedMesh;
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

/// Task type for chunk operations (C2ME-style two-phase loading)
pub const ChunkTaskType = enum {
    /// Phase 1: Generate terrain only (no dependencies needed)
    generate_terrain,
    /// Phase 2: Generate mesh (requires neighbors to be generated/ready)
    generate_mesh,
    /// Remesh existing chunk (for block updates)
    remesh,
};

/// Task data for terrain generation (Phase 1 - no neighbors needed)
pub const TerrainTask = struct {
    pos: ChunkPos,
    render_chunk: *RenderChunk,
};

/// Task data for mesh generation (Phase 2 - neighbors captured on main thread when deps satisfied)
pub const MeshTask = struct {
    pos: ChunkPos,
    /// Chunk data to mesh (copied from RenderChunk on main thread)
    chunk: Chunk,
    /// Neighbor chunk data COPIES captured on main thread when dependencies were satisfied
    /// Using copies instead of pointers ensures data is valid even if original chunks are unloaded
    neighbors: [6]?Chunk,
    render_chunk: *RenderChunk,
    /// Whether this is a remesh (existing chunk) or initial mesh (newly generated)
    is_remesh: bool,
};

pub const ChunkTask = struct {
    pos: ChunkPos,
    task_type: ChunkTaskType,
    data: union {
        terrain: TerrainTask,
        mesh: MeshTask,
    },
};

pub const TerrainResult = struct {
    pos: ChunkPos,
    chunk: Chunk,
    render_chunk: *RenderChunk,
};

pub const ChunkConfig = struct {
    view_distance: u32 = 4,
    vertical_view_distance: u32 = 4,
    /// Hysteresis to prevent load/unload thrashing at view distance boundary
    unload_distance: u32 = 6,
    worker_count: u8 = 4,
    max_uploads_per_tick: u8 = 4,
    /// C2ME-style rate limiting: prevents frame spikes when entering new areas
    max_chunks_per_update: u16 = 32,
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

    const PosSet = std.HashMap(ChunkPos, void, ChunkPosContext, std.hash_map.default_max_load_percentage);

    allocator: std.mem.Allocator,
    io: Io,

    chunk_storage: ChunkStorage,

    /// Prevents duplicate load tasks for the same position
    pending_loads: PosSet,

    /// O(1) skip check in updateLoadQueue - tracks loaded + pending positions
    managed_positions: PosSet,

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
    draw_commands: std.ArrayListUnmanaged(ChunkDrawCommand) = .{},
    staging_copies: std.ArrayListUnmanaged(StagingCopy) = .{},

    /// Defers updateLoadQueue to once per frame to prevent cascading slowdowns
    load_queue_dirty: bool = false,

    /// Remembers position between frames; reset when player moves to new chunk
    chunk_load_iterator: SpiralIterator = .{},

    vertex_buffer_cache: std.ArrayListUnmanaged(vk.VkBuffer) = .{},
    index_buffer_cache: std.ArrayListUnmanaged(vk.VkBuffer) = .{},

    /// Protects neighbor chunk pointers during async meshing
    rcu: ?*Rcu = null,

    /// Eliminates ~2.4MB of allocations per chunk by reusing buffers
    worker_data: ?[]WorkerData = null,

    /// Completed terrain waiting for main thread to copy to RenderChunk
    completed_terrain: ThreadSafeQueue(TerrainResult) = undefined,

    /// Chunks with terrain generated, waiting for neighbors before meshing
    pending_mesh: PosSet = undefined,

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
            .pending_loads = PosSet.init(allocator),
            .managed_positions = PosSet.init(allocator),
            .completed_queue = ThreadSafeQueue(CompletedMesh).init(allocator),
            .completed_terrain = ThreadSafeQueue(TerrainResult).init(allocator),
            .pending_mesh = PosSet.init(allocator),
            .pool = try ThreadPool.init(allocator, config.worker_count, processTask),
            .player_chunk = ChunkPos{ .x = 0, .z = 0, .section_y = 0 },
            .config = config,
            .render_system = render_system,
            .texture_manager = texture_manager,
            .asset_directory = asset_directory,
        };

        return self;
    }

    pub fn start(self: *Self) !void {
        const buffer_mgr = try self.allocator.create(ChunkBufferManager);
        buffer_mgr.* = try ChunkBufferManager.init(
            self.allocator,
            self.render_system.getDevice(),
            self.render_system.getPhysicalDevice(),
            ChunkBufferConfig{
                .view_distance = self.config.view_distance,
                .vertical_view_distance = self.config.vertical_view_distance,
                // Uses single-buffer mode by default (1GB vertex, 512MB index)
                // Required for GPU-driven rendering where all geometry must be in one buffer
            },
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
        rcu_instance.* = Rcu.init(self.allocator, self.config.worker_count);
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

        self.chunk_load_iterator.reset(self.config.view_distance, self.config.vertical_view_distance);
        self.load_queue_dirty = true;
    }

    pub fn deinit(self: *Self) void {
        logger.info("Shutting down ChunkManager...", .{});

        self.pool.shutdown();

        // Drain any remaining tasks that weren't processed before shutdown
        // These contain ChunkTask allocations that would otherwise leak
        while (self.pool.task_queue.tryPop()) |task| {
            if (task.data) |data_ptr| {
                const task_data: *ChunkTask = @ptrCast(@alignCast(data_ptr));
                self.allocator.destroy(task_data);
            }
        }

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
            // Free buffer allocation if present
            if (self.buffer_manager) |buf_mgr| {
                if (chunk.getBufferAllocation()) |alloc| {
                    buf_mgr.free(alloc);
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

        self.pending_loads.deinit();
        self.managed_positions.deinit();
        self.pending_mesh.deinit();

        while (self.completed_terrain.tryPop()) |_| {}
        self.completed_terrain.deinit();

        while (self.completed_queue.tryPop()) |*mesh| {
            var m = mesh.*;
            m.deinit();
        }
        self.completed_queue.deinit();

        self.draw_commands.deinit(self.allocator);
        self.staging_copies.deinit(self.allocator);
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

        // Rescan from center (closest chunks first)
        self.chunk_load_iterator.reset(self.config.view_distance, self.config.vertical_view_distance);

        // Actual updateLoadQueue called once per frame in flushLoadQueue()
        self.load_queue_dirty = true;
    }

    /// Call once per frame after all ticks, not per tick
    pub fn flushLoadQueue(self: *Self) void {
        if (!self.load_queue_dirty) return;
        self.load_queue_dirty = false;
        self.updateLoadQueue();
    }

    pub fn beginFrame(self: *Self, frame_fence: vk.VkFence) void {
        if (self.buffer_manager) |buf_mgr| {
            buf_mgr.beginFrame(frame_fence) catch |err| {
                logger.warn("Failed to begin frame for buffer manager: {}", .{err});
            };
        }
        // Synchronize slot allocator's frame counter with buffer manager
        // This ensures deferred frees for both are processed at the same time
        self.render_system.advanceSlotAllocatorFrame();
    }

    fn processCompletedTerrain(self: *Self) void {
        const zone = profiler.traceNamed("ProcessCompletedTerrain");
        defer zone.end();

        var processed: u32 = 0;
        while (self.completed_terrain.tryPop()) |result| {
            if (self.chunk_storage.get(result.pos)) |render_chunk_ptr| {
                render_chunk_ptr.chunk = result.chunk;
                render_chunk_ptr.setState(.generated);
                self.pending_mesh.put(result.pos, {}) catch |err| {
                    logger.warn("Failed to queue chunk ({},{},{}) for mesh: {}", .{
                        result.pos.x, result.pos.z, result.pos.section_y, err,
                    });
                    continue;
                };
                processed += 1;
            }
            _ = self.pending_loads.remove(result.pos);
        }
        zone.setValue(processed);
    }

    /// Queue mesh tasks for chunks whose neighbors are generated/ready
    fn checkMeshDependencies(self: *Self) void {
        const zone = profiler.traceNamed("CheckMeshDependencies");
        defer zone.end();

        var ready_to_mesh: std.ArrayListUnmanaged(ChunkPos) = .{};
        defer ready_to_mesh.deinit(self.allocator);

        var iter = self.pending_mesh.iterator();
        while (iter.next()) |entry| {
            const pos = entry.key_ptr.*;
            if (self.canMesh(pos)) {
                ready_to_mesh.append(self.allocator, pos) catch continue;
            }
        }

        var queued: u32 = 0;
        for (ready_to_mesh.items) |pos| {
            _ = self.pending_mesh.remove(pos);
            self.queueMeshTask(pos);
            queued += 1;
        }
        zone.setValue(queued);
    }

    /// Neighbors must be generated/ready to have valid terrain data
    fn canMesh(self: *Self, pos: ChunkPos) bool {
        const offsets = [6]ChunkPos{
            .{ .x = 0, .z = 0, .section_y = -1 }, // down
            .{ .x = 0, .z = 0, .section_y = 1 }, // up
            .{ .x = 0, .z = -1, .section_y = 0 }, // north
            .{ .x = 0, .z = 1, .section_y = 0 }, // south
            .{ .x = -1, .z = 0, .section_y = 0 }, // west
            .{ .x = 1, .z = 0, .section_y = 0 }, // east
        };

        for (offsets) |offset| {
            const neighbor_pos = ChunkPos{
                .x = pos.x + offset.x,
                .z = pos.z + offset.z,
                .section_y = pos.section_y + offset.section_y,
            };

            if (self.chunk_storage.get(neighbor_pos)) |neighbor| {
                const state = neighbor.getState();
                if (state == .loading) {
                    return false;
                }
            }
            // Missing neighbors OK - mesh without them (edge chunks)
        }
        return true;
    }

    /// Called from main thread - captures neighbors when dependencies are satisfied
    fn queueMeshTask(self: *Self, pos: ChunkPos) void {
        const zone = profiler.traceNamed("QueueMeshTask");
        defer zone.end();

        const render_chunk_ptr = self.chunk_storage.get(pos) orelse return;

        render_chunk_ptr.setState(.meshing);

        const neighbors = self.getNeighborChunks(pos);

        const task_data = self.allocator.create(ChunkTask) catch return;
        task_data.* = ChunkTask{
            .pos = pos,
            .task_type = .generate_mesh,
            .data = .{ .mesh = MeshTask{
                .pos = pos,
                .chunk = render_chunk_ptr.chunk,
                .neighbors = neighbors,
                .render_chunk = render_chunk_ptr,
                .is_remesh = false,
            } },
        };

        self.pool.submit(Task{
            .task_type = .generate_and_mesh,
            .data = @ptrCast(task_data),
            .chunk_pos = pos,
            .chunk_task_kind = .generate,
        }) catch |submit_err| {
            self.allocator.destroy(task_data);
            render_chunk_ptr.setState(.generated);
            self.pending_mesh.put(pos, {}) catch |requeue_err| {
                logger.err("Double failure requeueing chunk ({},{},{}) after submit fail: submit={}, requeue={}", .{
                    pos.x, pos.z, pos.section_y, submit_err, requeue_err,
                });
            };
        };
    }

    /// Call once per frame from main thread after beginFrame
    pub fn tick(self: *Self) void {
        const zone = profiler.trace(@src());
        defer zone.end();

        // Tracy plots for monitoring chunk system health
        profiler.plotInt("LoadedChunks", @intCast(self.chunk_storage.count));
        profiler.plotInt("PendingLoads", @intCast(self.pending_loads.count()));
        profiler.plotInt("PendingMesh", @intCast(self.pending_mesh.count()));
        profiler.plotInt("TaskQueueLen", @intCast(self.pool.pendingTasks()));
        profiler.plotInt("CompletedTerrain", @intCast(self.completed_terrain.len()));
        profiler.plotInt("CompletedMesh", @intCast(self.completed_queue.len()));

        self.processCompletedTerrain();
        self.checkMeshDependencies();

        const buf_mgr = self.buffer_manager orelse return;

        var uploads: u8 = 0;
        while (uploads < self.config.max_uploads_per_tick) {
            const mesh_opt = self.completed_queue.tryPop();
            if (mesh_opt == null) break;

            var mesh = mesh_opt.?;

            // Skip chunks that moved out of view range while queued
            const dx = if (mesh.pos.x > self.player_chunk.x)
                mesh.pos.x - self.player_chunk.x
            else
                self.player_chunk.x - mesh.pos.x;
            const dz = if (mesh.pos.z > self.player_chunk.z)
                mesh.pos.z - self.player_chunk.z
            else
                self.player_chunk.z - mesh.pos.z;
            const dy = if (mesh.pos.section_y > self.player_chunk.section_y)
                mesh.pos.section_y - self.player_chunk.section_y
            else
                self.player_chunk.section_y - mesh.pos.section_y;

            const horizontal_dist = @max(dx, dz);
            const is_stale = horizontal_dist > self.config.unload_distance or
                dy > self.config.vertical_view_distance + 2;

            if (is_stale) {
                mesh.deinit();
                _ = self.pending_loads.remove(mesh.pos);
                continue;
            }

            if (self.chunk_storage.get(mesh.pos)) |render_chunk_ptr| {
                if (mesh.generated_chunk) |gen_chunk| {
                    render_chunk_ptr.chunk = gen_chunk;
                }

                const total_vertices = mesh.getTotalVertexCount();
                const total_indices = mesh.getTotalIndexCount();
                if (total_vertices == 0 or total_indices == 0) {
                    render_chunk_ptr.setState(.ready);
                    mesh.deinit();
                    _ = self.pending_loads.remove(mesh.pos);
                    continue;
                }

                var valid = true;
                for (0..RENDER_LAYER_COUNT) |i| {
                    const layer = &mesh.layers[i];
                    if (layer.vertices.len == 0) continue;

                    var max_index: u32 = 0;
                    for (layer.indices) |idx| {
                        if (idx > max_index) max_index = idx;
                    }
                    if (max_index >= layer.vertices.len) {
                        logger.err("Chunk ({},{},{}) layer {} has invalid index {} >= vertex count {}", .{
                            mesh.pos.x,
                            mesh.pos.z,
                            mesh.pos.section_y,
                            i,
                            max_index,
                            layer.vertices.len,
                        });
                        valid = false;
                        break;
                    }
                }
                if (!valid) {
                    mesh.deinit();
                    _ = self.pending_loads.remove(mesh.pos);
                    continue;
                }

                var layer_allocations: [RENDER_LAYER_COUNT]?ChunkBufferAllocation = .{ null, null, null };
                var allocation_failed = false;

                for (0..RENDER_LAYER_COUNT) |i| {
                    const layer = &mesh.layers[i];
                    if (layer.vertices.len == 0) continue;

                    layer_allocations[i] = buf_mgr.allocate(
                        @intCast(layer.vertices.len),
                        @intCast(layer.indices.len),
                    );
                    if (layer_allocations[i] == null) {
                        logger.warn("Failed to allocate buffer space for chunk layer {}", .{i});
                        allocation_failed = true;
                        break;
                    }
                }

                if (allocation_failed) {
                    for (layer_allocations) |alloc_opt| {
                        if (alloc_opt) |alloc| {
                            buf_mgr.free(alloc);
                        }
                    }
                    _ = self.pending_loads.remove(mesh.pos);
                    mesh.deinit();
                    continue;
                }

                var staging_failed = false;
                for (0..RENDER_LAYER_COUNT) |i| {
                    const layer = &mesh.layers[i];
                    const alloc_opt = layer_allocations[i];
                    if (alloc_opt == null) continue;
                    const allocation = alloc_opt.?;

                    const vertex_bytes = std.mem.sliceAsBytes(layer.vertices);
                    buf_mgr.stageVertices(allocation, vertex_bytes) catch |err| {
                        logger.warn("Failed to stage vertex data for layer {}: {}", .{ i, err });
                        staging_failed = true;
                        break;
                    };

                    const index_bytes = std.mem.sliceAsBytes(layer.indices);
                    buf_mgr.stageIndices(allocation, index_bytes) catch |err| {
                        logger.warn("Failed to stage index data for layer {}: {}", .{ i, err });
                        staging_failed = true;
                        break;
                    };
                }

                if (staging_failed) {
                    for (layer_allocations) |alloc_opt| {
                        if (alloc_opt) |alloc| {
                            buf_mgr.free(alloc);
                        }
                    }
                    _ = self.pending_loads.remove(mesh.pos);
                    mesh.deinit();
                    continue;
                }

                var layer_vertices: [RENDER_LAYER_COUNT][]const Vertex = undefined;
                var layer_indices: [RENDER_LAYER_COUNT][]const u32 = undefined;
                for (0..RENDER_LAYER_COUNT) |i| {
                    layer_vertices[i] = mesh.layers[i].vertices;
                    layer_indices[i] = mesh.layers[i].indices;
                }

                var chunk_mesh = ChunkMesh.init(
                    self.allocator,
                    layer_vertices,
                    layer_indices,
                ) catch {
                    logger.warn("Failed to create chunk mesh", .{});
                    for (layer_allocations) |alloc_opt| {
                        if (alloc_opt) |alloc| {
                            buf_mgr.free(alloc);
                        }
                    }
                    _ = self.pending_loads.remove(mesh.pos);
                    mesh.deinit();
                    continue;
                };

                for (0..RENDER_LAYER_COUNT) |i| {
                    if (layer_allocations[i]) |alloc| {
                        chunk_mesh.setLayerBufferAllocation(i, alloc);
                    }
                }

                const old_allocations = render_chunk_ptr.getBufferAllocations();
                for (old_allocations) |old_alloc_opt| {
                    if (old_alloc_opt) |old_alloc| {
                        buf_mgr.free(old_alloc);
                    }
                }

                render_chunk_ptr.setMesh(chunk_mesh);
                _ = self.pending_loads.remove(mesh.pos);

                // GPU-driven rendering: allocate slot if needed and queue metadata upload
                if (!render_chunk_ptr.hasGPUSlot()) {
                    render_chunk_ptr.gpu_slot = self.render_system.allocateChunkSlot();
                }
                if (render_chunk_ptr.hasGPUSlot()) {
                    self.pending_metadata_uploads.append(self.allocator, render_chunk_ptr) catch {};
                }

                uploads += 1;
            }

            mesh.deinit();
        }

        if (self.rcu) |rcu_instance| {
            _ = rcu_instance.tryAdvance();
        }
    }

    pub fn commitUploads(self: *Self, cmd_buffer: vk.VkCommandBuffer) bool {
        const buf_mgr = self.buffer_manager orelse return false;
        if (!buf_mgr.hasPendingUploads()) return false;
        buf_mgr.commitUploads(cmd_buffer);
        return true;
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

    /// Returns commands sorted by render layer for proper draw order
    pub fn getDrawCommands(self: *Self) []const ChunkDrawCommand {
        const zone = profiler.trace(@src());
        defer zone.end();

        self.draw_commands.clearRetainingCapacity();

        const vertex_size: u64 = 36;
        const index_size: u64 = 4;

        var iter = self.chunk_storage.iterator();
        while (iter.next()) |entry| {
            const chunk = entry.value_ptr.*;

            const state = chunk.getState();
            if (state != .ready and state != .dirty) continue;

            const m = chunk.mesh orelse continue;

            for (0..RENDER_LAYER_COUNT) |layer_idx| {
                const layer = &m.layers[layer_idx];
                if (layer.index_count == 0) continue;
                if (!layer.buffer_allocation.valid or !layer.uploaded) continue;

                const vertex_offset = layer.buffer_allocation.vertex_slice.offset;
                const index_offset = layer.buffer_allocation.index_slice.offset;

                if (vertex_offset % vertex_size != 0) {
                    logger.warn("Chunk ({},{},{}) layer {} has unaligned vertex offset: {}", .{
                        chunk.pos.x,
                        chunk.pos.z,
                        chunk.pos.section_y,
                        layer_idx,
                        vertex_offset,
                    });
                    continue;
                }
                if (index_offset % index_size != 0) {
                    logger.warn("Chunk ({},{},{}) layer {} has unaligned index offset: {}", .{
                        chunk.pos.x,
                        chunk.pos.z,
                        chunk.pos.section_y,
                        layer_idx,
                        index_offset,
                    });
                    continue;
                }

                self.draw_commands.append(self.allocator, ChunkDrawCommand{
                    .vertex_offset = vertex_offset,
                    .index_offset = index_offset,
                    .index_count = layer.index_count,
                    .vertex_arena = layer.buffer_allocation.vertex_slice.arena_index,
                    .index_arena = layer.buffer_allocation.index_slice.arena_index,
                    .render_layer = @intCast(layer_idx),
                }) catch continue;
            }
        }

        std.mem.sort(ChunkDrawCommand, self.draw_commands.items, {}, struct {
            fn lessThan(_: void, a: ChunkDrawCommand, b: ChunkDrawCommand) bool {
                if (a.render_layer != b.render_layer) return a.render_layer < b.render_layer;
                if (a.vertex_arena != b.vertex_arena) return a.vertex_arena < b.vertex_arena;
                return a.index_arena < b.index_arena;
            }
        }.lessThan);

        return self.draw_commands.items;
    }

    pub fn getVertexBuffer(self: *const Self) ?vk.VkBuffer {
        const buf_mgr = self.buffer_manager orelse return null;
        return buf_mgr.getPrimaryVertexBuffer();
    }

    pub fn getIndexBuffer(self: *const Self) ?vk.VkBuffer {
        const buf_mgr = self.buffer_manager orelse return null;
        return buf_mgr.getPrimaryIndexBuffer();
    }

    pub fn getVertexBufferForArena(self: *const Self, arena_index: u16) ?vk.VkBuffer {
        const buf_mgr = self.buffer_manager orelse return null;
        return buf_mgr.getVertexBuffer(arena_index);
    }

    pub fn getIndexBufferForArena(self: *const Self, arena_index: u16) ?vk.VkBuffer {
        const buf_mgr = self.buffer_manager orelse return null;
        return buf_mgr.getIndexBuffer(arena_index);
    }

    pub fn getVertexArenaCount(self: *const Self) usize {
        const buf_mgr = self.buffer_manager orelse return 0;
        return buf_mgr.getVertexArenaCount();
    }

    pub fn getAllVertexBuffers(self: *Self) []const vk.VkBuffer {
        const buf_mgr = self.buffer_manager orelse return &.{};
        const count = buf_mgr.getVertexArenaCount();

        self.vertex_buffer_cache.clearRetainingCapacity();
        for (0..count) |i| {
            if (buf_mgr.getVertexBuffer(@intCast(i))) |buf| {
                self.vertex_buffer_cache.append(self.allocator, buf) catch continue;
            }
        }
        return self.vertex_buffer_cache.items;
    }

    pub fn getAllIndexBuffers(self: *Self) []const vk.VkBuffer {
        const buf_mgr = self.buffer_manager orelse return &.{};
        const count = buf_mgr.getIndexArenaCount();

        self.index_buffer_cache.clearRetainingCapacity();
        for (0..count) |i| {
            if (buf_mgr.getIndexBuffer(@intCast(i))) |buf| {
                self.index_buffer_cache.append(self.allocator, buf) catch continue;
            }
        }
        return self.index_buffer_cache.items;
    }

    /// Returns the high water mark of GPU slots for GPU-driven rendering
    /// This is the maximum slot index ever allocated, ensuring compute shader
    /// iterates over all slots (freed slots have zeroed metadata and are skipped)
    pub fn getActiveChunkCount(self: *const Self) u32 {
        return self.render_system.getChunkSlotHighWaterMark();
    }

    pub fn getStagingCopies(self: *Self) []const StagingCopy {
        const buf_mgr = self.buffer_manager orelse return &.{};

        self.staging_copies.clearRetainingCapacity();

        const staging_buffer = buf_mgr.getStagingBuffer();
        const pending = buf_mgr.getPendingCopies();

        for (pending) |copy| {
            self.staging_copies.append(self.allocator, StagingCopy{
                .src_buffer = staging_buffer,
                .src_offset = copy.src_offset,
                .dst_buffer = copy.dst_buffer,
                .dst_offset = copy.dst_offset,
                .size = copy.size,
            }) catch continue;
        }

        return self.staging_copies.items;
    }

    pub fn clearStagingCopies(self: *Self) void {
        if (self.buffer_manager) |buf_mgr| {
            buf_mgr.clearPendingCopies();
        }
        self.staging_copies.clearRetainingCapacity();
    }

    pub fn getVisibleChunks(self: *Self) []*RenderChunk {
        var result = std.ArrayList(*RenderChunk).init(self.allocator);

        var iter = self.chunk_storage.iterator();
        while (iter.next()) |entry| {
            const chunk = entry.value_ptr.*;
            if (chunk.isReady()) {
                result.append(chunk) catch continue;
            }
        }

        return result.toOwnedSlice() catch &.{};
    }

    fn updateLoadQueue(self: *Self) void {
        const zone = profiler.trace(@src());
        defer zone.end();

        const max_per_update: u32 = @intCast(self.config.max_chunks_per_update);

        var chunks_queued: u32 = 0;
        var chunks_skipped: u32 = 0;
        var positions_scanned: u32 = 0;
        {
            const scan_zone = profiler.traceNamed("ScanForNewChunks");
            defer scan_zone.end();

            while (self.chunk_load_iterator.next()) |offset| {
                positions_scanned += 1;

                const pos = ChunkPos{
                    .x = self.player_chunk.x + offset.dx,
                    .z = self.player_chunk.z + offset.dz,
                    .section_y = self.player_chunk.section_y + offset.dy,
                };

                const gop = self.managed_positions.getOrPut(pos) catch continue;
                if (gop.found_existing) {
                    chunks_skipped += 1;
                    continue;
                }

                if (!pos.isWithinDistance(self.player_chunk, self.config.view_distance)) {
                    _ = self.managed_positions.remove(pos);
                    continue;
                }

                self.queueChunkLoad(pos);
                chunks_queued += 1;

                if (chunks_queued >= max_per_update) {
                    self.load_queue_dirty = true;
                    break;
                }
            }
        }

        profiler.plotInt("ChunksQueued", @intCast(chunks_queued));
        profiler.plotInt("ChunksSkipped", @intCast(chunks_skipped));
        profiler.plotInt("PositionsScanned", @intCast(positions_scanned));
        zone.setValue(chunks_queued);

        self.unloadDistantChunks();
    }

    fn queueChunkLoad(self: *Self, pos: ChunkPos) void {
        const zone = profiler.trace(@src());
        defer zone.end();

        self.pending_loads.put(pos, {}) catch return;

        const render_chunk_ptr = self.allocator.create(RenderChunk) catch return;
        render_chunk_ptr.* = RenderChunk.init(self.allocator, pos);

        const previous = self.chunk_storage.put(pos, render_chunk_ptr) catch {
            self.allocator.destroy(render_chunk_ptr);
            _ = self.pending_loads.remove(pos);
            return;
        };
        if (previous) |old_chunk| {
            if (self.buffer_manager) |buf_mgr| {
                // Free all layer allocations (solid, cutout, translucent)
                const allocations = old_chunk.getBufferAllocations();
                for (allocations) |alloc_opt| {
                    if (alloc_opt) |alloc| {
                        buf_mgr.free(alloc);
                    }
                }
            }
            // GPU-driven rendering: queue slot for clearing, then free it
            if (old_chunk.hasGPUSlot()) {
                self.pending_slot_clears.append(self.allocator, old_chunk.gpu_slot) catch {};
                self.render_system.freeChunkSlot(old_chunk.gpu_slot);
            }
            old_chunk.deinit();
            self.allocator.destroy(old_chunk);
        }

        const task_data = self.allocator.create(ChunkTask) catch {
            _ = self.chunk_storage.remove(pos);
            render_chunk_ptr.deinit();
            self.allocator.destroy(render_chunk_ptr);
            _ = self.pending_loads.remove(pos);
            return;
        };
        task_data.* = ChunkTask{
            .pos = pos,
            .task_type = .generate_terrain,
            .data = .{ .terrain = TerrainTask{
                .pos = pos,
                .render_chunk = render_chunk_ptr,
            } },
        };

        self.pool.submit(Task{
            .task_type = .generate_and_mesh,
            .data = @ptrCast(task_data),
            .chunk_pos = pos,
            .chunk_task_kind = .generate,
        }) catch {
            self.allocator.destroy(task_data);
            _ = self.chunk_storage.remove(pos);
            render_chunk_ptr.deinit();
            self.allocator.destroy(render_chunk_ptr);
            _ = self.pending_loads.remove(pos);
            return;
        };
    }

    /// Returns copies to ensure data remains valid during async mesh generation
    fn getNeighborChunks(self: *Self, pos: ChunkPos) [6]?Chunk {
        const zone = profiler.trace(@src());
        defer zone.end();

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

            if (self.chunk_storage.get(neighbor_pos)) |neighbor| {
                const state = neighbor.getState();
                if (state == .generated or state == .meshing or state == .ready or state == .dirty) {
                    neighbors[i] = neighbor.chunk;
                }
            }
        }

        return neighbors;
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

        self.queueChunkRemesh(chunk_pos, rchunk);

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
        if (self.chunk_storage.get(neighbor_pos)) |neighbor_chunk| {
            if (neighbor_chunk.getState() == .ready) {
                self.queueChunkRemesh(neighbor_pos, neighbor_chunk);
            }
        }
    }

    fn queueChunkRemesh(self: *Self, pos: ChunkPos, render_chunk_ptr: *RenderChunk) void {
        render_chunk_ptr.setState(.dirty);

        const neighbors = self.getNeighborChunks(pos);

        const task_data = self.allocator.create(ChunkTask) catch return;
        task_data.* = ChunkTask{
            .pos = pos,
            .task_type = .remesh,
            .data = .{ .mesh = MeshTask{
                .pos = pos,
                .chunk = render_chunk_ptr.chunk,
                .neighbors = neighbors,
                .render_chunk = render_chunk_ptr,
                .is_remesh = true,
            } },
        };

        self.pool.submit(Task{
            .task_type = .generate_and_mesh,
            .data = @ptrCast(task_data),
            .chunk_pos = pos,
            .chunk_task_kind = .remesh,
        }) catch {
            self.allocator.destroy(task_data);
            return;
        };
    }

    fn unloadDistantChunks(self: *Self) void {
        const zone = profiler.trace(@src());
        defer zone.end();

        var to_unload: std.ArrayListUnmanaged(ChunkPos) = .{};
        defer to_unload.deinit(self.allocator);

        {
            const scan_zone = profiler.traceNamed("ScanDistantChunks");
            defer scan_zone.end();

            var iter = self.chunk_storage.iterator();
            while (iter.next()) |entry| {
                const pos = entry.key_ptr.*;
                if (!pos.isWithinDistance(self.player_chunk, self.config.unload_distance)) {
                    to_unload.append(self.allocator, pos) catch continue;
                }
            }
        }

        {
            const unload_zone = profiler.traceNamed("UnloadChunks");
            defer unload_zone.end();
            unload_zone.setValue(to_unload.items.len);

            for (to_unload.items) |pos| {
                self.unloadChunk(pos);
            }
        }
    }

    /// Uses RCU to defer freeing until all workers have exited critical sections
    fn unloadChunk(self: *Self, pos: ChunkPos) void {
        const zone = profiler.trace(@src());
        defer zone.end();

        if (self.chunk_storage.remove(pos)) |render_chunk_ptr| {
            if (self.buffer_manager) |buf_mgr| {
                // Free all layer allocations (solid, cutout, translucent)
                const allocations = render_chunk_ptr.getBufferAllocations();
                for (allocations) |alloc_opt| {
                    if (alloc_opt) |alloc| {
                        buf_mgr.free(alloc);
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
        _ = self.pending_loads.remove(pos);
        _ = self.managed_positions.remove(pos);
    }

    fn processTask(ctx: *WorkerContext, task: Task) void {
        const zone = profiler.trace(@src());
        defer zone.end();

        if (task.task_type != .generate_and_mesh) return;

        const task_data_ptr = task.data orelse return;
        const task_data: *ChunkTask = @ptrCast(@alignCast(task_data_ptr));

        const worker_data: *WorkerData = @ptrCast(@alignCast(ctx.user_data orelse return));
        const self = worker_data.manager;
        const mesh_ctx = worker_data.mesh_context;

        defer self.allocator.destroy(task_data);

        switch (task_data.task_type) {
            .generate_terrain => {
                const terrain_task = task_data.data.terrain;

                var chunk: Chunk = undefined;
                if (self.terrain_generator) |terrain_gen| {
                    chunk = terrain_gen.generateChunk(
                        terrain_task.pos.x,
                        terrain_task.pos.section_y,
                        terrain_task.pos.z,
                    );
                } else {
                    chunk = Chunk.generateTestChunk();
                }

                self.completed_terrain.push(TerrainResult{
                    .pos = terrain_task.pos,
                    .chunk = chunk,
                    .render_chunk = terrain_task.render_chunk,
                }) catch |err| {
                    logger.warn("Failed to push completed terrain: {}", .{err});
                };
            },

            .generate_mesh, .remesh => {
                var mesh_task = task_data.data.mesh;

                const shaper = self.shared_model_shaper orelse return;

                var neighbor_ptrs: [6]?*const Chunk = .{ null, null, null, null, null, null };
                for (0..6) |i| {
                    if (mesh_task.neighbors[i] != null) {
                        neighbor_ptrs[i] = &(mesh_task.neighbors[i].?);
                    }
                }

                var mesh = mesh_ctx.generateMesh(
                    &mesh_task.chunk,
                    mesh_task.pos,
                    neighbor_ptrs,
                    shaper,
                    self.texture_manager,
                ) catch |err| {
                    logger.warn("Failed to generate mesh for chunk: {}", .{err});
                    return;
                };

                mesh.generated_chunk = null;

                self.completed_queue.push(mesh) catch |err| {
                    logger.warn("Failed to push completed mesh: {}", .{err});
                    mesh.deinit();
                };
            },
        }
    }
};
