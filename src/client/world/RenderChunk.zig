/// RenderChunk - Per-chunk rendering data with mesh and GPU resources
const std = @import("std");
const shared = @import("Shared");
const renderer = @import("Renderer");
const volk = @import("volk");
const vk = volk.c;

const Chunk = shared.Chunk;
const ChunkPos = shared.ChunkPos;
const CompactVertex = renderer.CompactVertex;
const Logger = shared.Logger;
const ChunkBufferAllocation = renderer.buffer.ChunkBufferAllocation;
const RenderLayer = shared.RenderLayer;
const GPUDrivenTypes = renderer.GPUDrivenTypes;

/// Number of render layers (derived from enum at comptime)
pub const RENDER_LAYER_COUNT = @typeInfo(RenderLayer).@"enum".fields.len;

/// State of a chunk in the rendering pipeline (C2ME-style two-phase loading)
pub const ChunkState = enum(u8) {
    /// Chunk is queued for terrain generation (no dependencies)
    loading = 0,
    /// Terrain generated, waiting for mesh dependencies (neighbors must be generated/ready)
    generated = 1,
    /// Mesh task submitted, waiting for completion
    meshing = 2,
    /// Chunk is ready to render
    ready = 3,
    /// Chunk has been modified and needs remeshing
    dirty = 4,
    /// Chunk is being unloaded
    unloading = 5,
};

/// Callback type for chunk state transitions
pub const ChunkCallback = *const fn (chunk: *RenderChunk) void;

/// ChunkFuture - C2ME-style async status tracking with completion callbacks
/// Enables non-blocking state transitions and event-driven chunk management
pub const ChunkFuture = struct {
    const Self = @This();

    /// Atomic status for thread-safe access
    status: std.atomic.Value(u8),

    /// Callback when chunk becomes ready (mesh uploaded to GPU)
    on_ready: ?ChunkCallback = null,

    /// Callback when chunk is marked dirty (needs remesh)
    on_dirty: ?ChunkCallback = null,

    /// Callback when chunk is being unloaded
    on_unload: ?ChunkCallback = null,

    /// Back-reference to the owning RenderChunk
    owner: ?*RenderChunk = null,

    /// Create a new ChunkFuture in loading state
    pub fn init() Self {
        return .{
            .status = std.atomic.Value(u8).init(@intFromEnum(ChunkState.loading)),
        };
    }

    /// Get current status (thread-safe)
    pub fn getStatus(self: *const Self) ChunkState {
        return @enumFromInt(self.status.load(.acquire));
    }

    /// Set status and fire callbacks if applicable (call from main thread)
    pub fn setStatus(self: *Self, new_status: ChunkState) void {
        const old_status = self.status.swap(@intFromEnum(new_status), .acq_rel);

        // Fire callbacks based on transition
        if (self.owner) |chunk| {
            const old: ChunkState = @enumFromInt(old_status);

            // Transitioning TO ready state
            if (new_status == .ready and old != .ready) {
                if (self.on_ready) |callback| {
                    callback(chunk);
                }
            }

            // Transitioning TO dirty state
            if (new_status == .dirty and old != .dirty) {
                if (self.on_dirty) |callback| {
                    callback(chunk);
                }
            }

            // Transitioning TO unloading state
            if (new_status == .unloading and old != .unloading) {
                if (self.on_unload) |callback| {
                    callback(chunk);
                }
            }
        }
    }

    /// Atomically try to transition from expected state to new state
    /// Returns true if successful, false if current state didn't match expected
    pub fn tryTransition(self: *Self, expected: ChunkState, new_status: ChunkState) bool {
        const result = self.status.cmpxchgStrong(
            @intFromEnum(expected),
            @intFromEnum(new_status),
            .acq_rel,
            .acquire,
        );

        if (result == null) {
            // Transition succeeded, fire callbacks
            if (self.owner) |chunk| {
                if (new_status == .ready) {
                    if (self.on_ready) |callback| {
                        callback(chunk);
                    }
                } else if (new_status == .dirty) {
                    if (self.on_dirty) |callback| {
                        callback(chunk);
                    }
                } else if (new_status == .unloading) {
                    if (self.on_unload) |callback| {
                        callback(chunk);
                    }
                }
            }
            return true;
        }
        return false;
    }

    /// Register callback for when chunk becomes ready
    pub fn onReady(self: *Self, callback: ChunkCallback) void {
        self.on_ready = callback;
    }

    /// Register callback for when chunk needs remeshing
    pub fn onDirty(self: *Self, callback: ChunkCallback) void {
        self.on_dirty = callback;
    }

    /// Register callback for when chunk is unloaded
    pub fn onUnload(self: *Self, callback: ChunkCallback) void {
        self.on_unload = callback;
    }

    /// Check if chunk is in ready state (thread-safe)
    pub fn isReady(self: *const Self) bool {
        return self.getStatus() == .ready;
    }

    /// Check if chunk needs remeshing (thread-safe)
    pub fn isDirty(self: *const Self) bool {
        const status = self.getStatus();
        return status == .dirty;
    }

    /// Check if chunk is still loading (thread-safe)
    pub fn isLoading(self: *const Self) bool {
        const status = self.getStatus();
        return status == .loading or status == .meshing;
    }
};

/// Per-layer mesh data
pub const LayerMeshData = struct {
    vertices: []CompactVertex,
    indices: []u32,
    vertex_count: u32 = 0,
    index_count: u32 = 0,
    buffer_allocation: ChunkBufferAllocation = ChunkBufferAllocation.INVALID,
    uploaded: bool = false,

    pub const EMPTY = LayerMeshData{
        .vertices = &[_]CompactVertex{},
        .indices = &[_]u32{},
    };
};

/// GPU resources for a chunk mesh
pub const ChunkMesh = struct {
    const Self = @This();
    const logger = Logger.scoped(Self);

    /// Per-layer mesh data (solid, cutout, translucent)
    layers: [RENDER_LAYER_COUNT]LayerMeshData,

    /// Whether GPU resources have been allocated and uploaded
    uploaded: bool = false,

    allocator: std.mem.Allocator,

    /// Create a new ChunkMesh with per-layer vertex/index data
    pub fn init(
        allocator: std.mem.Allocator,
        layer_vertices: [RENDER_LAYER_COUNT][]const CompactVertex,
        layer_indices: [RENDER_LAYER_COUNT][]const u32,
    ) !Self {
        var layers: [RENDER_LAYER_COUNT]LayerMeshData = undefined;

        for (0..RENDER_LAYER_COUNT) |i| {
            const vertices = layer_vertices[i];
            const indices = layer_indices[i];

            if (vertices.len == 0) {
                layers[i] = .{
                    .vertices = &[_]CompactVertex{},
                    .indices = &[_]u32{},
                    .vertex_count = 0,
                    .index_count = 0,
                };
                continue;
            }

            const vertex_copy = try allocator.alloc(CompactVertex, vertices.len);
            errdefer allocator.free(vertex_copy);
            @memcpy(vertex_copy, vertices);

            const index_copy = try allocator.alloc(u32, indices.len);
            errdefer allocator.free(index_copy);
            @memcpy(index_copy, indices);

            layers[i] = .{
                .vertices = vertex_copy,
                .indices = index_copy,
                .vertex_count = @intCast(vertices.len),
                .index_count = @intCast(indices.len),
            };
        }

        return Self{
            .layers = layers,
            .allocator = allocator,
        };
    }

    /// Free CPU resources only (GPU resources freed via ChunkBufferManager)
    pub fn deinit(self: *Self) void {
        for (&self.layers) |*layer| {
            if (layer.vertices.len > 0) {
                self.allocator.free(layer.vertices);
            }
            if (layer.indices.len > 0) {
                self.allocator.free(layer.indices);
            }
        }
    }

    /// Set the buffer allocation for a specific layer
    pub fn setLayerBufferAllocation(self: *Self, layer: usize, allocation: ChunkBufferAllocation) void {
        self.layers[layer].buffer_allocation = allocation;
        self.layers[layer].uploaded = allocation.valid;
        // Check if all non-empty layers are uploaded
        self.uploaded = true;
        for (&self.layers) |*l| {
            if (l.index_count > 0 and !l.uploaded) {
                self.uploaded = false;
                break;
            }
        }
    }

    /// Legacy: Set buffer allocation for solid layer (backwards compat)
    pub fn setBufferAllocation(self: *Self, allocation: ChunkBufferAllocation) void {
        self.setLayerBufferAllocation(@intFromEnum(RenderLayer.solid), allocation);
    }

    /// Get the vertex buffer offset for vkCmdBindVertexBuffers (solid layer)
    pub fn getVertexOffset(self: *const Self) u64 {
        return self.layers[@intFromEnum(RenderLayer.solid)].buffer_allocation.vertex_slice.offset;
    }

    /// Get the index buffer offset for vkCmdBindIndexBuffer (solid layer)
    pub fn getIndexOffset(self: *const Self) u64 {
        return self.layers[@intFromEnum(RenderLayer.solid)].buffer_allocation.index_slice.offset;
    }

    /// Check if mesh is empty (no geometry in any layer)
    pub fn isEmpty(self: *const Self) bool {
        for (&self.layers) |*layer| {
            if (layer.index_count > 0) return false;
        }
        return true;
    }

    /// Check if mesh has valid buffer allocation (at least solid layer)
    pub fn hasValidAllocation(self: *const Self) bool {
        const solid = &self.layers[@intFromEnum(RenderLayer.solid)];
        return solid.buffer_allocation.valid and solid.uploaded;
    }

    /// Get total index count across all layers
    pub fn getTotalIndexCount(self: *const Self) u32 {
        var total: u32 = 0;
        for (&self.layers) |*layer| {
            total += layer.index_count;
        }
        return total;
    }

    /// Legacy: get index_count (returns solid layer count for backwards compat)
    pub fn getIndexCount(self: *const Self) u32 {
        return self.layers[@intFromEnum(RenderLayer.solid)].index_count;
    }

    /// Legacy: get vertex_count (returns solid layer count for backwards compat)
    pub fn getVertexCount(self: *const Self) u32 {
        return self.layers[@intFromEnum(RenderLayer.solid)].vertex_count;
    }
};

/// A chunk section with associated rendering data
pub const RenderChunk = struct {
    const Self = @This();

    /// Position in chunk coordinates
    pos: ChunkPos,

    /// The actual chunk data (block storage)
    chunk: Chunk,

    /// Baked mesh for rendering (null if not yet meshed)
    mesh: ?ChunkMesh = null,

    /// Async status tracking with completion callbacks (C2ME pattern)
    future: ChunkFuture,

    /// Allocator for mesh data
    allocator: std.mem.Allocator,

    /// GPU slot index for GPU-driven rendering metadata buffer
    gpu_slot: u32 = GPUDrivenTypes.SlotAllocator.INVALID_SLOT,

    /// Generation counter: incremented each time a mesh task is scheduled for this chunk.
    /// Used to discard stale mesh results when multiple meshes are in-flight concurrently.
    mesh_generation: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Backwards-compatible state getter (reads from future)
    pub fn getState(self: *const Self) ChunkState {
        return self.future.getStatus();
    }

    /// Backwards-compatible state setter (writes to future with callbacks)
    pub fn setState(self: *Self, new_state: ChunkState) void {
        self.future.setStatus(new_state);
    }

    /// Create a new RenderChunk at the given position
    pub fn init(allocator: std.mem.Allocator, pos: ChunkPos) Self {
        var self = Self{
            .pos = pos,
            .chunk = Chunk.init(),
            .future = ChunkFuture.init(),
            .allocator = allocator,
        };
        // Set back-reference for callbacks
        self.future.owner = &self;
        return self;
    }

    /// Create a RenderChunk with existing chunk data
    pub fn initWithChunk(allocator: std.mem.Allocator, pos: ChunkPos, chunk_data: Chunk) Self {
        var self = Self{
            .pos = pos,
            .chunk = chunk_data,
            .future = ChunkFuture.init(),
            .allocator = allocator,
        };
        self.future.owner = &self;
        self.future.setStatus(.dirty); // Needs meshing
        return self;
    }

    /// Free all resources
    /// Note: Buffer allocation should be freed via ChunkBufferManager before calling this
    pub fn deinit(self: *Self) void {
        if (self.mesh) |*mesh| {
            mesh.deinit();
        }
    }

    /// Get the buffer allocations for freeing via ChunkBufferManager
    /// Returns allocations for all layers that have valid data
    pub fn getBufferAllocations(self: *const Self) [RENDER_LAYER_COUNT]?ChunkBufferAllocation {
        var allocations: [RENDER_LAYER_COUNT]?ChunkBufferAllocation = .{ null, null, null };
        if (self.mesh) |mesh| {
            for (0..RENDER_LAYER_COUNT) |i| {
                if (mesh.layers[i].buffer_allocation.valid) {
                    allocations[i] = mesh.layers[i].buffer_allocation;
                }
            }
        }
        return allocations;
    }

    /// Legacy: Get the buffer allocation for solid layer
    pub fn getBufferAllocation(self: *const Self) ?ChunkBufferAllocation {
        if (self.mesh) |mesh| {
            const solid = &mesh.layers[@intFromEnum(RenderLayer.solid)];
            if (solid.buffer_allocation.valid) {
                return solid.buffer_allocation;
            }
        }
        return null;
    }

    /// Check if this chunk needs remeshing
    pub fn needsRemesh(self: *const Self) bool {
        return self.future.isDirty();
    }

    /// Check if this chunk is ready to render
    pub fn isReady(self: *const Self) bool {
        return self.future.isReady() and self.mesh != null;
    }

    /// Mark chunk as dirty (needs remeshing)
    /// Uses atomic CAS to only transition from ready -> dirty
    pub fn markDirty(self: *Self) void {
        _ = self.future.tryTransition(.ready, .dirty);
    }

    /// Set the mesh data (called from main thread after worker completes)
    /// This triggers the on_ready callback if registered
    pub fn setMesh(self: *Self, mesh: ChunkMesh) void {
        // Free old mesh if present
        // Note: GPU resources should be freed before calling this
        if (self.mesh) |*old_mesh| {
            old_mesh.deinit();
        }
        self.mesh = mesh;
        self.future.setStatus(.ready);
    }

    /// Get world offset for rendering
    pub fn getWorldOffset(self: *const Self) struct { x: f32, y: f32, z: f32 } {
        const block_pos = self.pos.getBlockPos();
        return .{
            .x = @floatFromInt(block_pos.x),
            .y = @floatFromInt(block_pos.y),
            .z = @floatFromInt(block_pos.z),
        };
    }

    /// Build GPU metadata for GPU-driven rendering
    /// Returns ChunkGPUData with world position, AABB bounds, and per-layer data
    pub fn buildGPUData(self: *const Self) GPUDrivenTypes.ChunkGPUData {
        const block_pos = self.pos.getBlockPos();
        const chunk_size: f32 = 16.0;

        // Chunk AABB in world coordinates
        const min_x: f32 = @floatFromInt(block_pos.x);
        const min_y: f32 = @floatFromInt(block_pos.y);
        const min_z: f32 = @floatFromInt(block_pos.z);

        var gpu_data = GPUDrivenTypes.ChunkGPUData{
            .world_pos = .{
                min_x + chunk_size * 0.5,
                min_y + chunk_size * 0.5,
                min_z + chunk_size * 0.5,
            },
            .aabb_min = .{ min_x, min_y, min_z },
            .aabb_max = .{
                min_x + chunk_size,
                min_y + chunk_size,
                min_z + chunk_size,
            },
            .layers = .{
                GPUDrivenTypes.LayerGPUData.EMPTY,
                GPUDrivenTypes.LayerGPUData.EMPTY,
                GPUDrivenTypes.LayerGPUData.EMPTY,
            },
        };

        // Fill in per-layer data from buffer allocations
        if (self.mesh) |mesh| {
            for (0..RENDER_LAYER_COUNT) |i| {
                const layer = &mesh.layers[i];
                if (layer.buffer_allocation.valid and layer.index_count > 0) {
                    const vertex_slice = layer.buffer_allocation.vertex_slice;
                    const index_slice = layer.buffer_allocation.index_slice;

                    gpu_data.layers[i] = .{
                        .vertex_offset = @truncate(vertex_slice.offset),
                        .index_offset = @truncate(index_slice.offset),
                        .index_count = layer.index_count,
                        .arena_indices = GPUDrivenTypes.LayerGPUData.pack(
                            vertex_slice.arena_index,
                            index_slice.arena_index,
                        ),
                    };
                }
            }
        }

        return gpu_data;
    }

    /// Check if this chunk has a valid GPU slot assigned
    pub fn hasGPUSlot(self: *const Self) bool {
        return self.gpu_slot != GPUDrivenTypes.SlotAllocator.INVALID_SLOT;
    }
};

/// Per-layer vertex/index data for completed mesh
pub const CompletedLayerData = struct {
    vertices: []CompactVertex,
    indices: []u32,

    pub const EMPTY = CompletedLayerData{
        .vertices = &[_]CompactVertex{},
        .indices = &[_]u32{},
    };
};

/// Result from async mesh generation
pub const CompletedMesh = struct {
    pos: ChunkPos,
    /// Per-layer mesh data (solid, cutout, translucent)
    layers: [RENDER_LAYER_COUNT]CompletedLayerData,
    allocator: std.mem.Allocator,
    /// Generated chunk data (for generation tasks, null for remesh tasks)
    /// Main thread will copy this to RenderChunk.chunk
    generated_chunk: ?Chunk = null,
    /// Mesh generation counter (matches RenderChunk.mesh_generation at scheduling time)
    mesh_generation: u32 = 0,

    pub fn deinit(self: *CompletedMesh) void {
        for (&self.layers) |*layer| {
            if (layer.vertices.len > 0) {
                self.allocator.free(layer.vertices);
            }
            if (layer.indices.len > 0) {
                self.allocator.free(layer.indices);
            }
        }
    }

    /// Get total vertex count across all layers
    pub fn getTotalVertexCount(self: *const CompletedMesh) usize {
        var total: usize = 0;
        for (&self.layers) |*layer| {
            total += layer.vertices.len;
        }
        return total;
    }

    /// Get total index count across all layers
    pub fn getTotalIndexCount(self: *const CompletedMesh) usize {
        var total: usize = 0;
        for (&self.layers) |*layer| {
            total += layer.indices.len;
        }
        return total;
    }
};
