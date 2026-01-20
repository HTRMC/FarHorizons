/// ChunkManager - Manages chunk loading, unloading, and meshing
/// Coordinates between main thread and worker threads
const std = @import("std");
const Io = std.Io;
const shared = @import("Shared");
const renderer = @import("Renderer");
const volk = @import("volk");
const vk = volk.c;

const Logger = shared.Logger;
const Vec3 = shared.Vec3;
const Chunk = shared.Chunk;
const ChunkPos = shared.ChunkPos;
const ChunkPosContext = shared.ChunkPosContext;
const CHUNK_SIZE = shared.CHUNK_SIZE;
const TerrainGenerator = shared.TerrainGenerator;
const Rcu = shared.Rcu;

const RenderSystem = renderer.RenderSystem;
const TextureManager = renderer.TextureManager;
const Vertex = renderer.Vertex;
const BlockModelShaper = renderer.block.BlockModelShaper;
const ModelLoader = renderer.block.ModelLoader;
const BlockstateLoader = renderer.block.BlockstateLoader;
const ChunkBufferManager = renderer.buffer.ChunkBufferManager;
const ChunkBufferConfig = renderer.buffer.ChunkBufferConfig;
const ChunkDrawCommand = RenderSystem.ChunkDrawCommand;
const StagingCopy = RenderSystem.StagingCopy;

const render_chunk = @import("RenderChunk.zig");
const RenderChunk = render_chunk.RenderChunk;
const ChunkMesh = render_chunk.ChunkMesh;
const ChunkState = render_chunk.ChunkState;
const CompletedMesh = render_chunk.CompletedMesh;

const thread_pool = @import("ThreadPool.zig");
const ThreadPool = thread_pool.ThreadPool;
const ThreadSafeQueue = thread_pool.ThreadSafeQueue;
const Task = thread_pool.Task;
const WorkerContext = thread_pool.WorkerContext;

const chunk_mesher = @import("ChunkMesher.zig");
const ChunkMesher = chunk_mesher.ChunkMesher;
const WorkerMeshContext = chunk_mesher.WorkerMeshContext;

/// Task data for chunk generation/meshing
pub const ChunkTask = struct {
    pos: ChunkPos,
    chunk: Chunk,
    neighbors: [6]?*const Chunk,
};

/// Configuration for chunk loading
pub const ChunkConfig = struct {
    /// Horizontal view distance in chunks
    view_distance: u8 = 4,
    /// Vertical view distance in chunk sections
    vertical_view_distance: u8 = 4,
    /// Distance at which to unload chunks (hysteresis)
    unload_distance: u8 = 6,
    /// Number of worker threads
    worker_count: u8 = 4,
    /// Maximum chunk uploads per frame
    max_uploads_per_tick: u8 = 4,
};

pub const ChunkManager = struct {
    const Self = @This();
    const logger = Logger.scoped(Self);

    /// HashMap for loaded chunks
    const ChunkMap = std.HashMap(ChunkPos, *RenderChunk, ChunkPosContext, std.hash_map.default_max_load_percentage);
    /// HashSet for pending positions
    const PosSet = std.HashMap(ChunkPos, void, ChunkPosContext, std.hash_map.default_max_load_percentage);

    allocator: std.mem.Allocator,
    io: Io,

    /// Currently loaded chunks
    loaded_chunks: ChunkMap,

    /// Positions queued for loading (prevents duplicate tasks)
    pending_loads: PosSet,

    /// Completed meshes ready for GPU upload
    completed_queue: ThreadSafeQueue(CompletedMesh),

    /// Thread pool for async operations
    pool: ThreadPool,

    /// Current player chunk position
    player_chunk: ChunkPos,

    /// Configuration
    config: ChunkConfig,

    /// Reference to render system for GPU uploads
    render_system: *RenderSystem,

    /// Shared texture manager reference (read-only, thread-safe)
    texture_manager: *TextureManager,

    /// Asset directory for model loading
    asset_directory: []const u8,

    /// Per-worker block model shapers (one per worker for thread safety)
    worker_model_shapers: []?*BlockModelShaper,
    worker_model_loaders: []?*ModelLoader,
    worker_blockstate_loaders: []?*BlockstateLoader,

    /// Buffer manager for GPU buffer arena allocation
    buffer_manager: ?*ChunkBufferManager = null,

    /// Terrain generator for procedural chunk generation
    terrain_generator: ?*TerrainGenerator = null,

    /// Reusable draw commands list
    draw_commands: std.ArrayListUnmanaged(ChunkDrawCommand) = .{},

    /// Reusable staging copies list
    staging_copies: std.ArrayListUnmanaged(StagingCopy) = .{},

    /// Cached vertex buffer list for multi-arena rendering
    vertex_buffer_cache: std.ArrayListUnmanaged(vk.VkBuffer) = .{},

    /// Cached index buffer list for multi-arena rendering
    index_buffer_cache: std.ArrayListUnmanaged(vk.VkBuffer) = .{},

    /// RCU for safe concurrent chunk access
    /// Protects neighbor chunk pointers during meshing
    rcu: ?*Rcu = null,

    /// Initialize the chunk manager
    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        render_system: *RenderSystem,
        texture_manager: *TextureManager,
        asset_directory: []const u8,
        config: ChunkConfig,
    ) !Self {
        logger.info("Initializing ChunkManager with view distance {}", .{config.view_distance});

        var self = Self{
            .allocator = allocator,
            .io = io,
            .loaded_chunks = ChunkMap.init(allocator),
            .pending_loads = PosSet.init(allocator),
            .completed_queue = ThreadSafeQueue(CompletedMesh).init(allocator),
            .pool = try ThreadPool.init(allocator, config.worker_count, processTask),
            .player_chunk = ChunkPos{ .x = 0, .z = 0, .section_y = 0 },
            .config = config,
            .render_system = render_system,
            .texture_manager = texture_manager,
            .asset_directory = asset_directory,
            .worker_model_shapers = try allocator.alloc(?*BlockModelShaper, config.worker_count),
            .worker_model_loaders = try allocator.alloc(?*ModelLoader, config.worker_count),
            .worker_blockstate_loaders = try allocator.alloc(?*BlockstateLoader, config.worker_count),
        };

        // Initialize per-worker model loading systems
        for (0..config.worker_count) |i| {
            self.worker_model_loaders[i] = null;
            self.worker_blockstate_loaders[i] = null;
            self.worker_model_shapers[i] = null;
        }

        return self;
    }

    /// Start the worker threads
    pub fn start(self: *Self) !void {
        // Initialize buffer manager for GPU buffer arena allocation
        const buffer_mgr = try self.allocator.create(ChunkBufferManager);
        buffer_mgr.* = try ChunkBufferManager.init(
            self.allocator,
            self.render_system.getDevice(),
            self.render_system.getPhysicalDevice(),
            ChunkBufferConfig{
                .view_distance = self.config.view_distance,
                .vertical_view_distance = self.config.vertical_view_distance,
            },
        );
        self.buffer_manager = buffer_mgr;

        // Initialize per-worker resources
        for (0..self.config.worker_count) |i| {
            // Create model loader for this worker
            const model_loader = try self.allocator.create(ModelLoader);
            model_loader.* = ModelLoader.init(self.allocator, self.io, self.asset_directory);
            self.worker_model_loaders[i] = model_loader;

            // Create blockstate loader for this worker
            const blockstate_loader = try self.allocator.create(BlockstateLoader);
            blockstate_loader.* = BlockstateLoader.init(self.allocator, self.io, self.asset_directory);
            self.worker_blockstate_loaders[i] = blockstate_loader;

            // Create block model shaper for this worker
            const shaper = try self.allocator.create(BlockModelShaper);
            shaper.* = BlockModelShaper.init(
                self.allocator,
                model_loader,
                blockstate_loader,
                self.texture_manager,
            );
            self.worker_model_shapers[i] = shaper;
        }

        // Initialize RCU for safe concurrent chunk access
        const rcu_instance = try self.allocator.create(Rcu);
        rcu_instance.* = Rcu.init(self.allocator, self.config.worker_count);
        self.rcu = rcu_instance;
        logger.info("RCU initialized for {} worker threads", .{self.config.worker_count});

        // Initialize terrain generator
        const terrain_gen = try self.allocator.create(TerrainGenerator);
        terrain_gen.* = TerrainGenerator.init(12345) orelse {
            logger.err("Failed to initialize terrain generator", .{});
            self.allocator.destroy(terrain_gen);
            return error.TerrainGeneratorInitFailed;
        };
        self.terrain_generator = terrain_gen;
        logger.info("Terrain generator initialized with seed 12345", .{});

        // Start pool first (this initializes contexts)
        try self.pool.start();

        // Set user data AFTER start() since it re-initializes contexts
        for (0..self.config.worker_count) |i| {
            self.pool.setWorkerData(i, @ptrCast(self));
        }

        logger.info("ChunkManager started with {} workers", .{self.config.worker_count});
    }

    /// Shutdown and cleanup
    pub fn deinit(self: *Self) void {
        logger.info("Shutting down ChunkManager...", .{});

        // Shutdown thread pool
        self.pool.shutdown();
        self.pool.deinit();

        // Synchronize RCU and free deferred items
        // This must happen after pool shutdown to ensure all workers have exited
        if (self.rcu) |rcu_instance| {
            logger.info("Synchronizing RCU before cleanup...", .{});
            rcu_instance.synchronize();
            rcu_instance.deinit();
            self.allocator.destroy(rcu_instance);
            self.rcu = null;
        }

        // Free per-worker resources
        for (0..self.config.worker_count) |i| {
            if (self.worker_model_shapers[i]) |shaper| {
                shaper.deinit();
                self.allocator.destroy(shaper);
            }
            if (self.worker_blockstate_loaders[i]) |loader| {
                loader.deinit();
                self.allocator.destroy(loader);
            }
            if (self.worker_model_loaders[i]) |loader| {
                loader.deinit();
                self.allocator.destroy(loader);
            }
        }
        self.allocator.free(self.worker_model_shapers);
        self.allocator.free(self.worker_model_loaders);
        self.allocator.free(self.worker_blockstate_loaders);

        // Free loaded chunks (and their buffer allocations)
        var iter = self.loaded_chunks.iterator();
        while (iter.next()) |entry| {
            const chunk = entry.value_ptr.*;
            // Free buffer allocation if present
            if (self.buffer_manager) |buf_mgr| {
                if (chunk.getBufferAllocation()) |alloc| {
                    buf_mgr.free(alloc);
                }
            }
            chunk.deinit();
            self.allocator.destroy(chunk);
        }
        self.loaded_chunks.deinit();

        // Free pending queues
        self.pending_loads.deinit();

        // Free completed meshes that weren't processed
        while (self.completed_queue.tryPop()) |*mesh| {
            var m = mesh.*;
            m.deinit();
        }
        self.completed_queue.deinit();

        // Free draw commands, staging copies, and buffer caches
        self.draw_commands.deinit(self.allocator);
        self.staging_copies.deinit(self.allocator);
        self.vertex_buffer_cache.deinit(self.allocator);
        self.index_buffer_cache.deinit(self.allocator);

        // Free buffer manager
        if (self.buffer_manager) |buf_mgr| {
            buf_mgr.deinit();
            self.allocator.destroy(buf_mgr);
        }

        // Free terrain generator
        if (self.terrain_generator) |terrain_gen| {
            terrain_gen.deinit();
            self.allocator.destroy(terrain_gen);
        }

        logger.info("ChunkManager shutdown complete", .{});
    }

    /// Update player position and queue chunks for loading/unloading
    pub fn updatePlayerPosition(self: *Self, position: Vec3) void {
        const new_chunk = ChunkPos.fromWorldPos(position.x, position.y, position.z);

        // Only update if player moved to a new chunk
        if (new_chunk.eql(self.player_chunk)) return;

        self.player_chunk = new_chunk;
        self.updateLoadQueue();
    }

    /// Begin a new frame - call this before tick() with the current frame fence
    /// This ensures staging buffer synchronization
    pub fn beginFrame(self: *Self, frame_fence: vk.VkFence) void {
        if (self.buffer_manager) |buf_mgr| {
            buf_mgr.beginFrame(frame_fence) catch |err| {
                logger.warn("Failed to begin frame for buffer manager: {}", .{err});
            };
        }
    }

    /// Process completed meshes and update chunks
    /// Call this once per frame from the main thread (after beginFrame)
    pub fn tick(self: *Self) void {
        const buf_mgr = self.buffer_manager orelse return;

        // Process completed meshes (limit per frame to avoid stalls)
        var uploads: u8 = 0;
        while (uploads < self.config.max_uploads_per_tick) {
            const mesh_opt = self.completed_queue.tryPop();
            if (mesh_opt == null) break;

            var mesh = mesh_opt.?;

            // Find the corresponding render chunk
            if (self.loaded_chunks.get(mesh.pos)) |render_chunk_ptr| {
                // Skip empty meshes
                if (mesh.vertices.len == 0 or mesh.indices.len == 0) {
                    mesh.deinit();
                    _ = self.pending_loads.remove(mesh.pos);
                    continue;
                }

                // Validate indices are within vertex bounds
                var max_index: u32 = 0;
                for (mesh.indices) |idx| {
                    if (idx > max_index) max_index = idx;
                }
                if (max_index >= mesh.vertices.len) {
                    logger.err("Chunk ({},{},{}) has invalid index {} >= vertex count {}", .{
                        mesh.pos.x,
                        mesh.pos.z,
                        mesh.pos.section_y,
                        max_index,
                        mesh.vertices.len,
                    });
                    mesh.deinit();
                    _ = self.pending_loads.remove(mesh.pos);
                    continue;
                }

                // Allocate buffer space from arena
                const allocation = buf_mgr.allocate(
                    @intCast(mesh.vertices.len),
                    @intCast(mesh.indices.len),
                ) orelse {
                    logger.warn("Failed to allocate buffer space for chunk", .{});
                    mesh.deinit();
                    continue;
                };

                // Stage vertex data
                const vertex_bytes = std.mem.sliceAsBytes(mesh.vertices);
                buf_mgr.stageVertices(allocation, vertex_bytes) catch |err| {
                    logger.warn("Failed to stage vertex data: {}", .{err});
                    buf_mgr.free(allocation);
                    mesh.deinit();
                    continue;
                };

                // Stage index data
                const index_bytes = std.mem.sliceAsBytes(mesh.indices);
                buf_mgr.stageIndices(allocation, index_bytes) catch |err| {
                    logger.warn("Failed to stage index data: {}", .{err});
                    buf_mgr.free(allocation);
                    mesh.deinit();
                    continue;
                };

                // Create ChunkMesh with the allocation
                var chunk_mesh = ChunkMesh.init(
                    self.allocator,
                    mesh.vertices,
                    mesh.indices,
                ) catch {
                    logger.warn("Failed to create chunk mesh", .{});
                    buf_mgr.free(allocation);
                    mesh.deinit();
                    continue;
                };
                chunk_mesh.setBufferAllocation(allocation);

                // Free OLD buffer allocation BEFORE swapping (atomic swap pattern)
                if (render_chunk_ptr.getBufferAllocation()) |old_alloc| {
                    buf_mgr.free(old_alloc);
                }

                // Store mesh in render chunk (this frees old mesh CPU data)
                render_chunk_ptr.setMesh(chunk_mesh);

                // Remove from pending
                _ = self.pending_loads.remove(mesh.pos);

                uploads += 1;
            }

            // Free the completed mesh data (ChunkMesh made a copy)
            mesh.deinit();
        }

        // Advance RCU epoch to free deferred chunk deletions
        // This allows chunks that were unloaded in previous frames to be freed
        // once all workers have exited their critical sections
        if (self.rcu) |rcu_instance| {
            _ = rcu_instance.tryAdvance();
        }
    }

    /// Commit staged uploads to GPU (call before rendering)
    /// Returns true if there were uploads to commit
    pub fn commitUploads(self: *Self, cmd_buffer: vk.VkCommandBuffer) bool {
        const buf_mgr = self.buffer_manager orelse return false;
        if (!buf_mgr.hasPendingUploads()) return false;
        buf_mgr.commitUploads(cmd_buffer);
        return true;
    }

    /// Get draw commands for all ready chunks
    pub fn getDrawCommands(self: *Self) []const ChunkDrawCommand {
        self.draw_commands.clearRetainingCapacity();

        var iter = self.loaded_chunks.iterator();
        while (iter.next()) |entry| {
            const chunk = entry.value_ptr.*;
            
            // Render chunks that are ready OR dirty (dirty = rebuilding, till has old mesh)
            if (chunk.state != .ready and chunk.state != .dirty) continue;

            const m = chunk.mesh orelse continue;
            if (!m.hasValidAllocation()) continue;

            const vertex_offset = m.getVertexOffset();
            const index_offset = m.getIndexOffset();

            // Sanity checks - offsets should be aligned
            const vertex_size: u64 = 36; // sizeof(Vertex)
            const index_size: u64 = 4; // sizeof(u32)

            if (vertex_offset % vertex_size != 0) {
                logger.warn("Chunk ({},{},{}) has unaligned vertex offset: {}", .{ chunk.pos.x, chunk.pos.z, chunk.pos.section_y, vertex_offset });
                continue;
            }
            if (index_offset % index_size != 0) {
                logger.warn("Chunk ({},{},{}) has unaligned index offset: {}", .{ chunk.pos.x, chunk.pos.z, chunk.pos.section_y, index_offset });
                continue;
            }

            self.draw_commands.append(self.allocator, ChunkDrawCommand{
                .vertex_offset = vertex_offset,
                .index_offset = index_offset,
                .index_count = m.index_count,
                .vertex_arena = m.buffer_allocation.vertex_slice.arena_index,
                .index_arena = m.buffer_allocation.index_slice.arena_index,
            }) catch continue;
        }

        return self.draw_commands.items;
    }

    /// Get the primary vertex buffer for rendering (arena 0)
    /// For multi-buffer rendering, use getVertexBufferForArena()
    pub fn getVertexBuffer(self: *const Self) ?vk.VkBuffer {
        const buf_mgr = self.buffer_manager orelse return null;
        return buf_mgr.getPrimaryVertexBuffer();
    }

    /// Get the primary index buffer for rendering (arena 0)
    /// For multi-buffer rendering, use getIndexBufferForArena()
    pub fn getIndexBuffer(self: *const Self) ?vk.VkBuffer {
        const buf_mgr = self.buffer_manager orelse return null;
        return buf_mgr.getPrimaryIndexBuffer();
    }

    /// Get a vertex buffer for a specific arena index
    pub fn getVertexBufferForArena(self: *const Self, arena_index: u16) ?vk.VkBuffer {
        const buf_mgr = self.buffer_manager orelse return null;
        return buf_mgr.getVertexBuffer(arena_index);
    }

    /// Get an index buffer for a specific arena index
    pub fn getIndexBufferForArena(self: *const Self, arena_index: u16) ?vk.VkBuffer {
        const buf_mgr = self.buffer_manager orelse return null;
        return buf_mgr.getIndexBuffer(arena_index);
    }

    /// Get the number of vertex buffer arenas
    pub fn getVertexArenaCount(self: *const Self) usize {
        const buf_mgr = self.buffer_manager orelse return 0;
        return buf_mgr.getVertexArenaCount();
    }

    /// Get all vertex buffers for multi-arena rendering
    /// Returns a slice of VkBuffers, one per arena
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

    /// Get all index buffers for multi-arena rendering
    /// Returns a slice of VkBuffers, one per arena
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

    /// Get pending staging copies for GPU upload
    /// Call this after tick() and before drawFrameMultiChunk()
    pub fn getStagingCopies(self: *Self) []const StagingCopy {
        const buf_mgr = self.buffer_manager orelse return &.{};

        // Build staging copies from pending copies
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

    /// Clear pending staging copies after they've been committed
    pub fn clearStagingCopies(self: *Self) void {
        if (self.buffer_manager) |buf_mgr| {
            buf_mgr.clearPendingCopies();
        }
        self.staging_copies.clearRetainingCapacity();
    }

    /// Get all chunks ready for rendering
    pub fn getVisibleChunks(self: *Self) []*RenderChunk {
        var result = std.ArrayList(*RenderChunk).init(self.allocator);

        var iter = self.loaded_chunks.iterator();
        while (iter.next()) |entry| {
            const chunk = entry.value_ptr.*;
            if (chunk.isReady()) {
                result.append(chunk) catch continue;
            }
        }

        return result.toOwnedSlice() catch &.{};
    }

    /// Queue chunks for loading based on player position
    fn updateLoadQueue(self: *Self) void {
        const view_dist: i32 = @intCast(self.config.view_distance);
        const vert_dist: i32 = @intCast(self.config.vertical_view_distance);

        // Queue chunks within view distance
        var dx: i32 = -view_dist;
        while (dx <= view_dist) : (dx += 1) {
            var dz: i32 = -view_dist;
            while (dz <= view_dist) : (dz += 1) {
                var dy: i32 = -vert_dist;
                while (dy <= vert_dist) : (dy += 1) {
                    const pos = ChunkPos{
                        .x = self.player_chunk.x + dx,
                        .z = self.player_chunk.z + dz,
                        .section_y = self.player_chunk.section_y + dy,
                    };

                    // Skip if already loaded or pending
                    if (self.loaded_chunks.contains(pos)) continue;
                    if (self.pending_loads.contains(pos)) continue;

                    // Check distance
                    if (!pos.isWithinDistance(self.player_chunk, self.config.view_distance)) continue;

                    // Queue for loading
                    self.queueChunkLoad(pos);
                }
            }
        }

        // Unload distant chunks
        self.unloadDistantChunks();
    }

    /// Queue a chunk position for loading
    fn queueChunkLoad(self: *Self, pos: ChunkPos) void {
        // Mark as pending
        self.pending_loads.put(pos, {}) catch return;

        // Create render chunk placeholder
        const render_chunk_ptr = self.allocator.create(RenderChunk) catch return;
        render_chunk_ptr.* = RenderChunk.init(self.allocator, pos);
        self.loaded_chunks.put(pos, render_chunk_ptr) catch {
            self.allocator.destroy(render_chunk_ptr);
            _ = self.pending_loads.remove(pos);
            return;
        };

        // Generate chunk data using terrain generator
        if (self.terrain_generator) |terrain_gen| {
            render_chunk_ptr.chunk = terrain_gen.generateChunk(pos.x, pos.section_y, pos.z);
        } else {
            // Fallback to test chunk if terrain generator unavailable
            render_chunk_ptr.chunk = Chunk.generateTestChunk();
        }
        render_chunk_ptr.state = .meshing;

        // Create task data
        const task_data = self.allocator.create(ChunkTask) catch return;
        task_data.* = ChunkTask{
            .pos = pos,
            .chunk = render_chunk_ptr.chunk,
            .neighbors = self.getNeighborChunks(pos),
        };

        // Submit to thread pool
        self.pool.submit(Task{
            .task_type = .generate_and_mesh,
            .data = @ptrCast(task_data),
        }) catch {
            self.allocator.destroy(task_data);
            return;
        };
    }

    /// Get neighbor chunk data for face culling
    fn getNeighborChunks(self: *Self, pos: ChunkPos) [6]?*const Chunk {
        var neighbors: [6]?*const Chunk = .{ null, null, null, null, null, null };

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

            if (self.loaded_chunks.get(neighbor_pos)) |neighbor| {
                if (neighbor.state == .ready) {
                    neighbors[i] = &neighbor.chunk;
                }
            }
        }

        return neighbors;
    }

    // ========== Block Access Methods ==========

    /// Get block entry at world position
    /// Returns null if chunk is not loaded or not ready (for rendering)
    pub fn getBlockAt(self: *Self, world_x: i32, world_y: i32, world_z: i32) ?shared.BlockEntry {
        const chunk_pos = ChunkPos.fromBlockPos(world_x, world_y, world_z);

        const rchunk = self.loaded_chunks.get(chunk_pos) orelse return null;
        if (rchunk.state != .ready) return null;

        // Convert to local coordinates (0-15)
        const local_x: u32 = @intCast(@mod(world_x, CHUNK_SIZE));
        const local_y: u32 = @intCast(@mod(world_y, CHUNK_SIZE));
        const local_z: u32 = @intCast(@mod(world_z, CHUNK_SIZE));

        return rchunk.chunk.getBlockEntry(local_x, local_y, local_z);
    }

    /// Get block entry at world position regardless of chunk state
    /// Used for collision - block data is valid even during remeshing
    /// Returns null only if chunk is completely unloaded
    pub fn getBlockAtForCollision(self: *Self, world_x: i32, world_y: i32, world_z: i32) ?shared.BlockEntry {
        const chunk_pos = ChunkPos.fromBlockPos(world_x, world_y, world_z);

        const rchunk = self.loaded_chunks.get(chunk_pos) orelse return null;
        // Don't check state - block data is always valid once chunk is loaded

        // Convert to local coordinates (0-15)
        const local_x: u32 = @intCast(@mod(world_x, CHUNK_SIZE));
        const local_y: u32 = @intCast(@mod(world_y, CHUNK_SIZE));
        const local_z: u32 = @intCast(@mod(world_z, CHUNK_SIZE));

        return rchunk.chunk.getBlockEntry(local_x, local_y, local_z);
    }

    /// Set block entry at world position
    /// Returns true if successful, false if chunk is not loaded
    pub fn setBlockAt(self: *Self, world_x: i32, world_y: i32, world_z: i32, entry: shared.BlockEntry) bool {
        const chunk_pos = ChunkPos.fromBlockPos(world_x, world_y, world_z);

        const rchunk = self.loaded_chunks.get(chunk_pos) orelse return false;

        // Convert to local coordinates (0-15)
        const local_x: u32 = @intCast(@mod(world_x, CHUNK_SIZE));
        const local_y: u32 = @intCast(@mod(world_y, CHUNK_SIZE));
        const local_z: u32 = @intCast(@mod(world_z, CHUNK_SIZE));

        rchunk.chunk.setBlockEntry(local_x, local_y, local_z, entry);

        // Mark chunk for re-meshing
        self.queueChunkRemesh(chunk_pos, rchunk);

        // Also remesh neighbors if block is on chunk boundary
        if (local_x == 0) self.remeshNeighborIfLoaded(chunk_pos.x - 1, chunk_pos.z, chunk_pos.section_y);
        if (local_x == CHUNK_SIZE - 1) self.remeshNeighborIfLoaded(chunk_pos.x + 1, chunk_pos.z, chunk_pos.section_y);
        if (local_y == 0) self.remeshNeighborIfLoaded(chunk_pos.x, chunk_pos.z, chunk_pos.section_y - 1);
        if (local_y == CHUNK_SIZE - 1) self.remeshNeighborIfLoaded(chunk_pos.x, chunk_pos.z, chunk_pos.section_y + 1);
        if (local_z == 0) self.remeshNeighborIfLoaded(chunk_pos.x, chunk_pos.z - 1, chunk_pos.section_y);
        if (local_z == CHUNK_SIZE - 1) self.remeshNeighborIfLoaded(chunk_pos.x, chunk_pos.z + 1, chunk_pos.section_y);

        return true;
    }

    /// Check if a block at world position is solid (for collision/raycasting)
    /// Uses collision-safe block access that works during chunk remeshing
    pub fn isBlockSolid(self: *Self, world_x: i32, world_y: i32, world_z: i32) bool {
        const entry = self.getBlockAtForCollision(world_x, world_y, world_z) orelse return false;
        return !entry.isAir() and entry.isSolid();
    }

    /// Get the collision shape for a block at world position
    /// Returns VoxelShape.EMPTY for air or out-of-bounds positions
    /// Like Minecraft's BlockState.getCollisionShape()
    pub fn getCollisionShape(self: *Self, world_x: i32, world_y: i32, world_z: i32) shared.VoxelShape {
        const entry = self.getBlockAtForCollision(world_x, world_y, world_z) orelse return shared.voxel_shape.EMPTY;
        if (entry.isAir()) return shared.voxel_shape.EMPTY;
        // Get the shape from the block registry
        return shared.block.getShape(entry.id, entry.state).*;
    }

    /// Helper to remesh a neighbor chunk if loaded
    fn remeshNeighborIfLoaded(self: *Self, chunk_x: i32, chunk_z: i32, section_y: i32) void {
        const neighbor_pos = ChunkPos{ .x = chunk_x, .z = chunk_z, .section_y = section_y };
        if (self.loaded_chunks.get(neighbor_pos)) |neighbor_chunk| {
            if (neighbor_chunk.state == .ready) {
                self.queueChunkRemesh(neighbor_pos, neighbor_chunk);
            }
        }
    }

    /// Queue a chunk for re-meshing
    fn queueChunkRemesh(self: *Self, pos: ChunkPos, render_chunk_ptr: *RenderChunk) void {
        // Don't clear mesh - keep rendering old mesh until new one arrives
        // Mark as dirty as we know a rebuild is pending
        render_chunk_ptr.state = .dirty;

        // Create task data
        const task_data = self.allocator.create(ChunkTask) catch return;
        task_data.* = ChunkTask{
            .pos = pos,
            .chunk = render_chunk_ptr.chunk,
            .neighbors = self.getNeighborChunks(pos),
        };

        // Submit to thread pool
        self.pool.submit(Task{
            .task_type = .generate_and_mesh,
            .data = @ptrCast(task_data),
        }) catch {
            self.allocator.destroy(task_data);
            return;
        };
    }

    /// Unload chunks beyond unload distance
    fn unloadDistantChunks(self: *Self) void {
        var to_unload: std.ArrayListUnmanaged(ChunkPos) = .{};
        defer to_unload.deinit(self.allocator);

        var iter = self.loaded_chunks.iterator();
        while (iter.next()) |entry| {
            const pos = entry.key_ptr.*;
            if (!pos.isWithinDistance(self.player_chunk, self.config.unload_distance)) {
                to_unload.append(self.allocator, pos) catch continue;
            }
        }

        for (to_unload.items) |pos| {
            self.unloadChunk(pos);
        }
    }

    /// Unload a single chunk
    /// Uses RCU to defer freeing until all workers have exited their critical sections
    fn unloadChunk(self: *Self, pos: ChunkPos) void {
        if (self.loaded_chunks.fetchRemove(pos)) |kv| {
            const render_chunk_ptr = kv.value;

            // Free buffer allocation immediately - workers don't access GPU buffers
            if (self.buffer_manager) |buf_mgr| {
                if (render_chunk_ptr.getBufferAllocation()) |alloc| {
                    buf_mgr.free(alloc);
                }
            }

            // Defer freeing the RenderChunk itself via RCU
            // Workers might still be accessing this chunk's data as a neighbor
            const rcu_instance = self.rcu orelse {
                @panic("RCU must be initialized before unloading chunks - this indicates a bug in initialization order");
            };

            // Create closure data for deferred free
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
    }

    /// Worker task processing callback
    fn processTask(ctx: *WorkerContext, task: Task) void {
        if (task.task_type != .generate_and_mesh) return;

        const task_data_ptr = task.data orelse return;
        const task_data: *ChunkTask = @ptrCast(@alignCast(task_data_ptr));

        // Get per-worker resources
        const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return));

        // Defer cleanup of task data
        defer self.allocator.destroy(task_data);

        const shaper = self.worker_model_shapers[ctx.id] orelse return;

        // Enter RCU read-side critical section
        // This protects neighbor chunk pointers from being freed while we're using them
        const rcu_instance = self.rcu orelse {
            logger.warn("RCU not initialized, skipping mesh generation", .{});
            return;
        };
        _ = rcu_instance.readLock(@intCast(ctx.id));
        defer rcu_instance.readUnlock(@intCast(ctx.id));

        // Create mesher
        var mesher = ChunkMesher.init(self.allocator);

        // Generate mesh (neighbor access is now protected by RCU)
        const mesh = mesher.generateMesh(
            &task_data.chunk,
            task_data.pos,
            task_data.neighbors,
            shaper,
            self.texture_manager,
        ) catch |err| {
            logger.warn("Failed to generate mesh for chunk: {}", .{err});
            return;
        };

        // Push to completed queue
        self.completed_queue.push(mesh) catch |err| {
            logger.warn("Failed to push completed mesh: {}", .{err});
            var m = mesh;
            m.deinit();
        };
    }
};
