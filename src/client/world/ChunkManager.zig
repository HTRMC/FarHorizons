/// ChunkManager - Manages chunk loading, unloading, and meshing
/// Coordinates between main thread and worker threads
const std = @import("std");
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

const RenderSystem = renderer.RenderSystem;
const TextureManager = renderer.TextureManager;
const Vertex = renderer.Vertex;
const BlockModelShaper = renderer.block.BlockModelShaper;
const ModelLoader = renderer.block.ModelLoader;
const BlockstateLoader = renderer.block.BlockstateLoader;
const ChunkBufferManager = renderer.buffer.ChunkBufferManager;
const ChunkBufferConfig = renderer.buffer.ChunkBufferConfig;
const ChunkDrawCommand = RenderSystem.ChunkDrawCommand;

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
    const logger = Logger.init("ChunkManager");

    /// HashMap for loaded chunks
    const ChunkMap = std.HashMap(ChunkPos, *RenderChunk, ChunkPosContext, std.hash_map.default_max_load_percentage);
    /// HashSet for pending positions
    const PosSet = std.HashMap(ChunkPos, void, ChunkPosContext, std.hash_map.default_max_load_percentage);

    allocator: std.mem.Allocator,

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

    /// Reusable draw commands list
    draw_commands: std.ArrayListUnmanaged(ChunkDrawCommand) = .{},

    /// Initialize the chunk manager
    pub fn init(
        allocator: std.mem.Allocator,
        render_system: *RenderSystem,
        texture_manager: *TextureManager,
        asset_directory: []const u8,
        config: ChunkConfig,
    ) !Self {
        logger.info("Initializing ChunkManager with view distance {}", .{config.view_distance});

        var self = Self{
            .allocator = allocator,
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
            ChunkBufferConfig{}, // Use defaults
        );
        self.buffer_manager = buffer_mgr;

        // Initialize per-worker resources
        for (0..self.config.worker_count) |i| {
            // Create model loader for this worker
            const model_loader = try self.allocator.create(ModelLoader);
            model_loader.* = ModelLoader.init(self.allocator, self.asset_directory);
            self.worker_model_loaders[i] = model_loader;

            // Create blockstate loader for this worker
            const blockstate_loader = try self.allocator.create(BlockstateLoader);
            blockstate_loader.* = BlockstateLoader.init(self.allocator, self.asset_directory);
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

        // Free draw commands
        self.draw_commands.deinit(self.allocator);

        // Free buffer manager
        if (self.buffer_manager) |buf_mgr| {
            buf_mgr.deinit();
            self.allocator.destroy(buf_mgr);
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

    /// Process completed meshes and update chunks
    /// Call this once per frame from the main thread
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

                // Store mesh in render chunk
                render_chunk_ptr.setMesh(chunk_mesh);

                // Remove from pending
                _ = self.pending_loads.remove(mesh.pos);

                uploads += 1;
            }

            // Free the completed mesh data (ChunkMesh made a copy)
            mesh.deinit();
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
            if (!chunk.isReady()) continue;

            const m = chunk.mesh orelse continue;
            if (!m.hasValidAllocation()) continue;

            self.draw_commands.append(self.allocator, ChunkDrawCommand{
                .vertex_offset = m.getVertexOffset(),
                .index_offset = m.getIndexOffset(),
                .index_count = m.index_count,
            }) catch continue;
        }

        return self.draw_commands.items;
    }

    /// Get the vertex buffer for rendering
    pub fn getVertexBuffer(self: *const Self) ?vk.VkBuffer {
        const buf_mgr = self.buffer_manager orelse return null;
        return buf_mgr.getVertexBuffer();
    }

    /// Get the index buffer for rendering
    pub fn getIndexBuffer(self: *const Self) ?vk.VkBuffer {
        const buf_mgr = self.buffer_manager orelse return null;
        return buf_mgr.getIndexBuffer();
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

        // Generate chunk data (using test pattern for now)
        render_chunk_ptr.chunk = Chunk.generateTestChunk();
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
    fn unloadChunk(self: *Self, pos: ChunkPos) void {
        if (self.loaded_chunks.fetchRemove(pos)) |kv| {
            const chunk = kv.value;
            // Free buffer allocation if present
            if (self.buffer_manager) |buf_mgr| {
                if (chunk.getBufferAllocation()) |alloc| {
                    buf_mgr.free(alloc);
                }
            }
            chunk.deinit();
            self.allocator.destroy(chunk);
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

        // Create mesher
        var mesher = ChunkMesher.init(self.allocator);

        // Generate mesh
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
