/// ChunkMesher - Generates mesh data from chunk blocks
/// Designed to run on worker threads
const std = @import("std");
const shared = @import("Shared");
const renderer = @import("Renderer");

const Chunk = shared.Chunk;
const ChunkPos = shared.ChunkPos;
const BlockEntry = shared.BlockEntry;
const CHUNK_SIZE = shared.CHUNK_SIZE;
const VoxelDirection = shared.Direction;
const ChunkAccess = shared.ChunkAccess;
const Logger = shared.Logger;

const Vertex = renderer.Vertex;
const BlockModel = renderer.block.BlockModel;
const FaceBakery = renderer.block.FaceBakery;
const Direction = renderer.block.Direction;
const BlockModelShaper = renderer.block.BlockModelShaper;
const TextureManager = renderer.TextureManager;

const RenderChunk = @import("RenderChunk.zig");
const CompletedMesh = RenderChunk.CompletedMesh;

/// Mesh generation context for a single chunk
pub const ChunkMesher = struct {
    const Self = @This();
    const logger = Logger.init("ChunkMesher");

    /// Maximum faces per chunk (worst case: every block visible on all sides)
    const MAX_FACES_PER_CHUNK = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE * 6;

    allocator: std.mem.Allocator,

    /// Create a new mesher instance
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    /// Generate mesh for a chunk
    /// Returns owned vertex and index arrays that caller must free
    pub fn generateMesh(
        self: *Self,
        chunk: *const Chunk,
        pos: ChunkPos,
        neighbors: [6]?*const Chunk,
        block_model_shaper: *BlockModelShaper,
        texture_manager: *const TextureManager,
    ) !CompletedMesh {
        // Create chunk access for cross-chunk face culling
        var chunk_access = ChunkAccess.init(chunk);
        if (neighbors[0]) |n| chunk_access.setNeighbor(.down, n);
        if (neighbors[1]) |n| chunk_access.setNeighbor(.up, n);
        if (neighbors[2]) |n| chunk_access.setNeighbor(.north, n);
        if (neighbors[3]) |n| chunk_access.setNeighbor(.south, n);
        if (neighbors[4]) |n| chunk_access.setNeighbor(.west, n);
        if (neighbors[5]) |n| chunk_access.setNeighbor(.east, n);

        // Count non-air blocks to estimate buffer size
        var block_count: usize = 0;
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |z| {
                for (0..CHUNK_SIZE) |x| {
                    const entry = chunk.getBlockEntry(@intCast(x), @intCast(y), @intCast(z));
                    if (!entry.isAir()) block_count += 1;
                }
            }
        }

        // Estimate buffer size (worst case: 6 faces per block, 4 vertices per face)
        const max_faces = block_count * 6;
        const max_vertices = max_faces * 4;
        const max_indices = max_faces * 6;

        // Allocate working buffers
        const vertices = try self.allocator.alloc(Vertex, max_vertices);
        errdefer self.allocator.free(vertices);
        const indices = try self.allocator.alloc(u32, max_indices);
        errdefer self.allocator.free(indices);

        var vertex_idx: usize = 0;
        var index_idx: usize = 0;

        // Get world offset for this chunk
        const block_pos = pos.getBlockPos();
        const offset_x: f32 = @floatFromInt(block_pos.x);
        const offset_y: f32 = @floatFromInt(block_pos.y);
        const offset_z: f32 = @floatFromInt(block_pos.z);

        // Iterate through chunk and bake visible faces
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |z| {
                for (0..CHUNK_SIZE) |x| {
                    const entry = chunk.getBlockEntry(@intCast(x), @intCast(y), @intCast(z));
                    if (entry.isAir()) continue;

                    // Get the model for this block via blockstate system
                    const model = block_model_shaper.getModel(entry) catch continue;

                    // Get variant for rotation info
                    const variant = block_model_shaper.getVariant(entry) catch continue;

                    // Bake this block's faces
                    try self.bakeBlock(
                        model,
                        chunk,
                        &chunk_access,
                        @intCast(x),
                        @intCast(y),
                        @intCast(z),
                        offset_x,
                        offset_y,
                        offset_z,
                        texture_manager,
                        variant.x,
                        variant.y,
                        variant.uvlock,
                        vertices,
                        indices,
                        &vertex_idx,
                        &index_idx,
                    );
                }
            }
        }

        // Shrink buffers to actual size
        const final_vertices = try self.allocator.realloc(vertices, vertex_idx);
        const final_indices = try self.allocator.realloc(indices, index_idx);

        return CompletedMesh{
            .pos = pos,
            .vertices = final_vertices,
            .indices = final_indices,
            .allocator = self.allocator,
        };
    }

    /// Bake a single block's faces into the mesh buffers
    fn bakeBlock(
        self: *Self,
        model: *const BlockModel,
        chunk: *const Chunk,
        chunk_access: *const ChunkAccess,
        x: i32,
        y: i32,
        z: i32,
        offset_x: f32,
        offset_y: f32,
        offset_z: f32,
        texture_manager: *const TextureManager,
        model_rotation_x: i16,
        model_rotation_y: i16,
        uvlock: bool,
        vertices: []Vertex,
        indices: []u32,
        vertex_idx: *usize,
        index_idx: *usize,
    ) !void {
        _ = self;

        const elements = model.elements orelse return;

        // White color (texture provides color)
        const color = [3]f32{ 1.0, 1.0, 1.0 };

        const directions = [_]Direction{ .down, .up, .north, .south, .west, .east };

        for (elements) |*elem| {
            for (directions) |dir| {
                if (elem.faces.get(dir)) |face| {
                    // Only cull faces that have cullface specified
                    if (face.cullface) |cullface_dir| {
                        // Transform cullface direction by model rotation
                        const rotated_cullface = FaceBakery.rotateFaceDirection(cullface_dir, model_rotation_x, model_rotation_y);

                        // Convert to VoxelDirection for culling
                        const rotated_voxel_dir: VoxelDirection = @enumFromInt(@intFromEnum(rotated_cullface));

                        // Rotate element bounds by model rotation
                        const rotated_bounds = FaceBakery.rotateElementBounds(
                            elem.from,
                            elem.to,
                            model_rotation_x,
                            model_rotation_y,
                        );

                        // Use per-element face culling
                        if (!chunk.shouldRenderElementFace(
                            x,
                            y,
                            z,
                            rotated_voxel_dir,
                            rotated_bounds.from,
                            rotated_bounds.to,
                            chunk_access,
                        )) {
                            continue;
                        }
                    }

                    // Get texture index
                    const texture_index = texture_manager.getTextureIndex(face.texture) orelse 0;

                    // Bake the face into a quad
                    var quad = FaceBakery.bakeQuad(
                        elem.from,
                        elem.to,
                        face,
                        dir,
                        elem.rotation,
                        elem.shade,
                        elem.light_emission,
                        texture_index,
                    );

                    // Apply model-level rotation
                    FaceBakery.rotateQuad(&quad, model_rotation_x, model_rotation_y, uvlock);

                    // Local position offset within chunk
                    const local_x: f32 = @floatFromInt(x);
                    const local_y: f32 = @floatFromInt(y);
                    const local_z: f32 = @floatFromInt(z);

                    // Add vertices
                    const base_vertex: u32 = @intCast(vertex_idx.*);
                    for (0..4) |i| {
                        const pos = quad.position(@intCast(i));
                        const packed_uv = quad.packedUV(@intCast(i));
                        const u: f32 = @bitCast(@as(u32, @intCast(packed_uv >> 32)));
                        const v: f32 = @bitCast(@as(u32, @intCast(packed_uv & 0xFFFFFFFF)));
                        vertices[vertex_idx.*] = .{
                            .pos = .{
                                pos[0] - 0.5 + local_x + offset_x,
                                pos[1] - 0.5 + local_y + offset_y,
                                pos[2] - 0.5 + local_z + offset_z,
                            },
                            .color = color,
                            .uv = .{ u, v },
                            .tex_index = quad.texture_index,
                        };
                        vertex_idx.* += 1;
                    }

                    // Add indices for two triangles (CCW winding)
                    indices[index_idx.*] = base_vertex;
                    indices[index_idx.* + 1] = base_vertex + 1;
                    indices[index_idx.* + 2] = base_vertex + 2;
                    indices[index_idx.* + 3] = base_vertex + 2;
                    indices[index_idx.* + 4] = base_vertex + 3;
                    indices[index_idx.* + 5] = base_vertex;
                    index_idx.* += 6;
                }
            }
        }
    }
};

/// Per-worker meshing context (holds thread-local resources)
pub const WorkerMeshContext = struct {
    mesher: ChunkMesher,
    /// Per-worker allocator (could be thread-local arena)
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) WorkerMeshContext {
        return .{
            .mesher = ChunkMesher.init(allocator),
            .allocator = allocator,
        };
    }
};
