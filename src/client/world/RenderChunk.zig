/// RenderChunk - Per-chunk rendering data with mesh and GPU resources
const std = @import("std");
const shared = @import("Shared");
const renderer = @import("Renderer");
const volk = @import("volk");
const vk = volk.c;

const Chunk = shared.Chunk;
const ChunkPos = shared.ChunkPos;
const Vertex = renderer.Vertex;
const Logger = shared.Logger;
const ChunkBufferAllocation = renderer.buffer.ChunkBufferAllocation;
const RenderLayer = shared.RenderLayer;

/// Number of render layers (derived from enum at comptime)
pub const RENDER_LAYER_COUNT = @typeInfo(RenderLayer).@"enum".fields.len;

/// State of a chunk in the rendering pipeline
pub const ChunkState = enum {
    /// Chunk is queued for generation/loading
    loading,
    /// Chunk data exists, mesh is being baked
    meshing,
    /// Chunk is ready to render
    ready,
    /// Chunk has been modified and needs remeshing
    dirty,
    /// Chunk is being unloaded
    unloading,
};

/// Per-layer mesh data
pub const LayerMeshData = struct {
    vertices: []Vertex,
    indices: []u32,
    vertex_count: u32 = 0,
    index_count: u32 = 0,
    buffer_allocation: ChunkBufferAllocation = ChunkBufferAllocation.INVALID,
    uploaded: bool = false,

    pub const EMPTY = LayerMeshData{
        .vertices = &[_]Vertex{},
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
        layer_vertices: [RENDER_LAYER_COUNT][]const Vertex,
        layer_indices: [RENDER_LAYER_COUNT][]const u32,
    ) !Self {
        var layers: [RENDER_LAYER_COUNT]LayerMeshData = undefined;

        for (0..RENDER_LAYER_COUNT) |i| {
            const vertices = layer_vertices[i];
            const indices = layer_indices[i];

            if (vertices.len == 0) {
                layers[i] = .{
                    .vertices = &[_]Vertex{},
                    .indices = &[_]u32{},
                    .vertex_count = 0,
                    .index_count = 0,
                };
                continue;
            }

            const vertex_copy = try allocator.alloc(Vertex, vertices.len);
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

    /// Current state in the rendering pipeline
    state: ChunkState = .loading,

    /// Allocator for mesh data
    allocator: std.mem.Allocator,

    /// Create a new RenderChunk at the given position
    pub fn init(allocator: std.mem.Allocator, pos: ChunkPos) Self {
        return Self{
            .pos = pos,
            .chunk = Chunk.init(),
            .allocator = allocator,
        };
    }

    /// Create a RenderChunk with existing chunk data
    pub fn initWithChunk(allocator: std.mem.Allocator, pos: ChunkPos, chunk: Chunk) Self {
        return Self{
            .pos = pos,
            .chunk = chunk,
            .state = .dirty, // Needs meshing
            .allocator = allocator,
        };
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
        return self.state == .dirty;
    }

    /// Check if this chunk is ready to render
    pub fn isReady(self: *const Self) bool {
        return self.state == .ready and self.mesh != null;
    }

    /// Mark chunk as dirty (needs remeshing)
    pub fn markDirty(self: *Self) void {
        if (self.state == .ready) {
            self.state = .dirty;
        }
    }

    /// Set the mesh data (called from main thread after worker completes)
    pub fn setMesh(self: *Self, mesh: ChunkMesh) void {
        // Free old mesh if present
        // Note: GPU resources should be freed before calling this
        if (self.mesh) |*old_mesh| {
            old_mesh.deinit();
        }
        self.mesh = mesh;
        self.state = .ready;
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
};

/// Per-layer vertex/index data for completed mesh
pub const CompletedLayerData = struct {
    vertices: []Vertex,
    indices: []u32,

    pub const EMPTY = CompletedLayerData{
        .vertices = &[_]Vertex{},
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
