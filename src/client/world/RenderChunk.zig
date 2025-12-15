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

/// GPU resources for a chunk mesh
pub const ChunkMesh = struct {
    const Self = @This();
    const logger = Logger.init("ChunkMesh");

    /// CPU-side vertex data (kept for potential remeshing)
    vertices: []Vertex,
    /// CPU-side index data
    indices: []u32,

    /// Buffer allocation in the shared chunk buffer arena
    buffer_allocation: ChunkBufferAllocation = ChunkBufferAllocation.INVALID,

    /// Number of vertices
    vertex_count: u32 = 0,
    /// Number of indices to draw
    index_count: u32 = 0,

    /// Whether GPU resources have been allocated and uploaded
    uploaded: bool = false,

    allocator: std.mem.Allocator,

    /// Create a new ChunkMesh with the given vertex/index data
    pub fn init(allocator: std.mem.Allocator, vertices: []const Vertex, indices: []const u32) !Self {
        const vertex_copy = try allocator.alloc(Vertex, vertices.len);
        errdefer allocator.free(vertex_copy);
        @memcpy(vertex_copy, vertices);

        const index_copy = try allocator.alloc(u32, indices.len);
        errdefer allocator.free(index_copy);
        @memcpy(index_copy, indices);

        return Self{
            .vertices = vertex_copy,
            .indices = index_copy,
            .vertex_count = @intCast(vertices.len),
            .index_count = @intCast(indices.len),
            .allocator = allocator,
        };
    }

    /// Free CPU resources only (GPU resources freed via ChunkBufferManager)
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.vertices);
        self.allocator.free(self.indices);
    }

    /// Set the buffer allocation (from ChunkBufferManager)
    pub fn setBufferAllocation(self: *Self, allocation: ChunkBufferAllocation) void {
        self.buffer_allocation = allocation;
        self.uploaded = allocation.valid;
    }

    /// Get the vertex buffer offset for vkCmdBindVertexBuffers
    pub fn getVertexOffset(self: *const Self) u64 {
        return self.buffer_allocation.vertex_slice.offset;
    }

    /// Get the index buffer offset for vkCmdBindIndexBuffer
    pub fn getIndexOffset(self: *const Self) u64 {
        return self.buffer_allocation.index_slice.offset;
    }

    /// Check if mesh is empty (no geometry)
    pub fn isEmpty(self: *const Self) bool {
        return self.index_count == 0;
    }

    /// Check if mesh has valid buffer allocation
    pub fn hasValidAllocation(self: *const Self) bool {
        return self.buffer_allocation.valid and self.uploaded;
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

    /// Get the buffer allocation for freeing via ChunkBufferManager
    pub fn getBufferAllocation(self: *const Self) ?ChunkBufferAllocation {
        if (self.mesh) |mesh| {
            if (mesh.buffer_allocation.valid) {
                return mesh.buffer_allocation;
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
            old_mesh.allocator.free(old_mesh.vertices);
            old_mesh.allocator.free(old_mesh.indices);
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

/// Result from async mesh generation
pub const CompletedMesh = struct {
    pos: ChunkPos,
    vertices: []Vertex,
    indices: []u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CompletedMesh) void {
        self.allocator.free(self.vertices);
        self.allocator.free(self.indices);
    }
};
