const std = @import("std");
const GpuVertex = @import("../renderer/vulkan/types.zig").GpuVertex;
const tracy = @import("../platform/tracy.zig");

pub const CHUNK_SIZE = 16;
pub const BLOCKS_PER_CHUNK = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE; // 4096
pub const VERTS_PER_BLOCK = 24;
pub const INDICES_PER_BLOCK = 36;
pub const CHUNK_VERTEX_COUNT = BLOCKS_PER_CHUNK * VERTS_PER_BLOCK; // 98304
pub const CHUNK_INDEX_COUNT = BLOCKS_PER_CHUNK * INDICES_PER_BLOCK; // 147456

pub const WORLD_CHUNKS_X = 8;
pub const WORLD_CHUNKS_Y = 2;
pub const WORLD_CHUNKS_Z = 8;
pub const WORLD_SIZE_X = WORLD_CHUNKS_X * CHUNK_SIZE; // 128
pub const WORLD_SIZE_Y = WORLD_CHUNKS_Y * CHUNK_SIZE; // 32
pub const WORLD_SIZE_Z = WORLD_CHUNKS_Z * CHUNK_SIZE; // 128
pub const TOTAL_WORLD_CHUNKS = WORLD_CHUNKS_X * WORLD_CHUNKS_Y * WORLD_CHUNKS_Z; // 128
pub const MAX_WORLD_VERTEX_COUNT = TOTAL_WORLD_CHUNKS * CHUNK_VERTEX_COUNT;
pub const MAX_WORLD_INDEX_COUNT = TOTAL_WORLD_CHUNKS * CHUNK_INDEX_COUNT;

// Per-face vertex template (unit cube centered at origin)
pub const face_vertices = [6][4]struct { px: f32, py: f32, pz: f32, u: f32, v: f32 }{
    // Front face (z = +0.5)
    .{
        .{ .px = -0.5, .py = -0.5, .pz = 0.5, .u = 0.0, .v = 1.0 },
        .{ .px = 0.5, .py = -0.5, .pz = 0.5, .u = 1.0, .v = 1.0 },
        .{ .px = 0.5, .py = 0.5, .pz = 0.5, .u = 1.0, .v = 0.0 },
        .{ .px = -0.5, .py = 0.5, .pz = 0.5, .u = 0.0, .v = 0.0 },
    },
    // Back face (z = -0.5)
    .{
        .{ .px = 0.5, .py = -0.5, .pz = -0.5, .u = 0.0, .v = 1.0 },
        .{ .px = -0.5, .py = -0.5, .pz = -0.5, .u = 1.0, .v = 1.0 },
        .{ .px = -0.5, .py = 0.5, .pz = -0.5, .u = 1.0, .v = 0.0 },
        .{ .px = 0.5, .py = 0.5, .pz = -0.5, .u = 0.0, .v = 0.0 },
    },
    // Left face (x = -0.5)
    .{
        .{ .px = -0.5, .py = -0.5, .pz = -0.5, .u = 0.0, .v = 1.0 },
        .{ .px = -0.5, .py = -0.5, .pz = 0.5, .u = 1.0, .v = 1.0 },
        .{ .px = -0.5, .py = 0.5, .pz = 0.5, .u = 1.0, .v = 0.0 },
        .{ .px = -0.5, .py = 0.5, .pz = -0.5, .u = 0.0, .v = 0.0 },
    },
    // Right face (x = +0.5)
    .{
        .{ .px = 0.5, .py = -0.5, .pz = 0.5, .u = 0.0, .v = 1.0 },
        .{ .px = 0.5, .py = -0.5, .pz = -0.5, .u = 1.0, .v = 1.0 },
        .{ .px = 0.5, .py = 0.5, .pz = -0.5, .u = 1.0, .v = 0.0 },
        .{ .px = 0.5, .py = 0.5, .pz = 0.5, .u = 0.0, .v = 0.0 },
    },
    // Top face (y = +0.5)
    .{
        .{ .px = -0.5, .py = 0.5, .pz = 0.5, .u = 0.0, .v = 1.0 },
        .{ .px = 0.5, .py = 0.5, .pz = 0.5, .u = 1.0, .v = 1.0 },
        .{ .px = 0.5, .py = 0.5, .pz = -0.5, .u = 1.0, .v = 0.0 },
        .{ .px = -0.5, .py = 0.5, .pz = -0.5, .u = 0.0, .v = 0.0 },
    },
    // Bottom face (y = -0.5)
    .{
        .{ .px = -0.5, .py = -0.5, .pz = -0.5, .u = 0.0, .v = 1.0 },
        .{ .px = 0.5, .py = -0.5, .pz = -0.5, .u = 1.0, .v = 1.0 },
        .{ .px = 0.5, .py = -0.5, .pz = 0.5, .u = 1.0, .v = 0.0 },
        .{ .px = -0.5, .py = -0.5, .pz = 0.5, .u = 0.0, .v = 0.0 },
    },
};

// Per-face index pattern (two triangles, 6 indices referencing 4 verts)
pub const face_index_pattern = [6]u32{ 0, 1, 2, 2, 3, 0 };

// Face neighbor offsets: for each face index, the (dx, dy, dz) to the adjacent block
// Matches face_vertices order: 0=+Z, 1=-Z, 2=-X, 3=+X, 4=+Y, 5=-Y
pub const face_neighbor_offsets = [6][3]i32{
    .{ 0, 0, 1 }, // front  (+Z)
    .{ 0, 0, -1 }, // back   (-Z)
    .{ -1, 0, 0 }, // left   (-X)
    .{ 1, 0, 0 }, // right  (+X)
    .{ 0, 1, 0 }, // top    (+Y)
    .{ 0, -1, 0 }, // bottom (-Y)
};

pub const BlockType = enum(u8) {
    air,
    glass,
};

pub const block_properties = struct {
    pub fn isOpaque(block: BlockType) bool {
        return switch (block) {
            .air => false,
            .glass => false,
        };
    }
    pub fn cullsSelf(block: BlockType) bool {
        return switch (block) {
            .air => false,
            .glass => true,
        };
    }
};

pub const Chunk = struct {
    blocks: [BLOCKS_PER_CHUNK]BlockType,
};

pub fn chunkIndex(x: usize, y: usize, z: usize) usize {
    return y * CHUNK_SIZE * CHUNK_SIZE + z * CHUNK_SIZE + x;
}

pub fn generateSphereWorld() [WORLD_CHUNKS_Y][WORLD_CHUNKS_Z][WORLD_CHUNKS_X]Chunk {
    @setEvalBranchQuota(100_000_000);
    const half_x = @as(f32, WORLD_SIZE_X) / 2.0;
    const half_y = @as(f32, WORLD_SIZE_Y) / 2.0;
    const half_z = @as(f32, WORLD_SIZE_Z) / 2.0;
    const radius_sq = 15.5 * 15.5;
    var world: [WORLD_CHUNKS_Y][WORLD_CHUNKS_Z][WORLD_CHUNKS_X]Chunk = undefined;

    for (0..WORLD_CHUNKS_Y) |cy| {
        for (0..WORLD_CHUNKS_Z) |cz| {
            for (0..WORLD_CHUNKS_X) |cx| {
                var blocks: [BLOCKS_PER_CHUNK]BlockType = .{.air} ** BLOCKS_PER_CHUNK;

                for (0..CHUNK_SIZE) |y| {
                    for (0..CHUNK_SIZE) |z| {
                        for (0..CHUNK_SIZE) |x| {
                            const wx: f32 = @as(f32, @floatFromInt(cx * CHUNK_SIZE + x)) - half_x;
                            const wy: f32 = @as(f32, @floatFromInt(cy * CHUNK_SIZE + y)) - half_y;
                            const wz: f32 = @as(f32, @floatFromInt(cz * CHUNK_SIZE + z)) - half_z;

                            // Check against all 16 sphere centers (4x4 grid)
                            var hit = false;
                            for (0..4) |gz| {
                                if (hit) break;
                                for (0..4) |gx| {
                                    const center_x = @as(f32, @floatFromInt(gx * 32 + 16)) - half_x;
                                    const center_z = @as(f32, @floatFromInt(gz * 32 + 16)) - half_z;
                                    const dx = wx - center_x;
                                    const dy = wy;
                                    const dz = wz - center_z;
                                    if (dx * dx + dy * dy + dz * dz <= radius_sq) {
                                        hit = true;
                                        break;
                                    }
                                }
                            }
                            if (hit) {
                                blocks[chunkIndex(x, y, z)] = .glass;
                            }
                        }
                    }
                }

                world[cy][cz][cx] = .{ .blocks = blocks };
            }
        }
    }

    return world;
}

pub fn generateWorldMesh(
    allocator: std.mem.Allocator,
    world: *const [WORLD_CHUNKS_Y][WORLD_CHUNKS_Z][WORLD_CHUNKS_X]Chunk,
) !struct { vertices: []GpuVertex, indices: []u32, vertex_count: u32, index_count: u32 } {
    const tz = tracy.zone(@src(), "generateWorldMesh");
    defer tz.end();

    const vertices = try allocator.alloc(GpuVertex, MAX_WORLD_VERTEX_COUNT);
    errdefer allocator.free(vertices);
    const indices = try allocator.alloc(u32, MAX_WORLD_INDEX_COUNT);
    errdefer allocator.free(indices);

    var vert_count: u32 = 0;
    var idx_count: u32 = 0;

    const half_world_x: f32 = @as(f32, WORLD_SIZE_X) / 2.0;
    const half_world_y: f32 = @as(f32, WORLD_SIZE_Y) / 2.0;
    const half_world_z: f32 = @as(f32, WORLD_SIZE_Z) / 2.0;

    for (0..WORLD_CHUNKS_Y) |cy| {
        for (0..WORLD_CHUNKS_Z) |cz| {
            for (0..WORLD_CHUNKS_X) |cx| {
                const chunk = &world[cy][cz][cx];

                for (0..CHUNK_SIZE) |by| {
                    for (0..CHUNK_SIZE) |bz| {
                        for (0..CHUNK_SIZE) |bx| {
                            const block = chunk.blocks[chunkIndex(bx, by, bz)];
                            if (block == .air) continue;

                            const world_x: f32 = @as(f32, @floatFromInt(cx * CHUNK_SIZE + bx)) - half_world_x;
                            const world_y: f32 = @as(f32, @floatFromInt(cy * CHUNK_SIZE + by)) - half_world_y;
                            const world_z: f32 = @as(f32, @floatFromInt(cz * CHUNK_SIZE + bz)) - half_world_z;

                            for (0..6) |face| {
                                const offset = face_neighbor_offsets[face];
                                const nx: i32 = @as(i32, @intCast(bx)) + offset[0];
                                const ny: i32 = @as(i32, @intCast(by)) + offset[1];
                                const nz: i32 = @as(i32, @intCast(bz)) + offset[2];

                                // Cross-chunk neighbor lookup
                                const neighbor = blk: {
                                    if (nx >= 0 and nx < CHUNK_SIZE and ny >= 0 and ny < CHUNK_SIZE and nz >= 0 and nz < CHUNK_SIZE) {
                                        // Within same chunk
                                        break :blk chunk.blocks[chunkIndex(@intCast(nx), @intCast(ny), @intCast(nz))];
                                    }

                                    // Compute neighbor chunk coordinates
                                    const ncx: i32 = @as(i32, @intCast(cx)) + if (nx < 0) @as(i32, -1) else if (nx >= CHUNK_SIZE) @as(i32, 1) else @as(i32, 0);
                                    const ncy: i32 = @as(i32, @intCast(cy)) + if (ny < 0) @as(i32, -1) else if (ny >= CHUNK_SIZE) @as(i32, 1) else @as(i32, 0);
                                    const ncz: i32 = @as(i32, @intCast(cz)) + if (nz < 0) @as(i32, -1) else if (nz >= CHUNK_SIZE) @as(i32, 1) else @as(i32, 0);

                                    // Out of world bounds → air (emit face)
                                    if (ncx < 0 or ncx >= WORLD_CHUNKS_X or ncy < 0 or ncy >= WORLD_CHUNKS_Y or ncz < 0 or ncz >= WORLD_CHUNKS_Z) {
                                        break :blk BlockType.air;
                                    }

                                    // Wrap local coordinate into neighbor chunk
                                    const lx: usize = @intCast(@mod(nx, @as(i32, CHUNK_SIZE)));
                                    const ly: usize = @intCast(@mod(ny, @as(i32, CHUNK_SIZE)));
                                    const lz: usize = @intCast(@mod(nz, @as(i32, CHUNK_SIZE)));
                                    break :blk world[@intCast(ncy)][@intCast(ncz)][@intCast(ncx)].blocks[chunkIndex(lx, ly, lz)];
                                };

                                if (block_properties.isOpaque(neighbor)) continue;
                                if (neighbor == block and block_properties.cullsSelf(block)) continue;

                                // Emit 4 vertices for this face
                                for (0..4) |v| {
                                    const fv = face_vertices[face][v];
                                    vertices[vert_count + @as(u32, @intCast(v))] = .{
                                        .px = fv.px + world_x,
                                        .py = fv.py + world_y,
                                        .pz = fv.pz + world_z,
                                        .u = fv.u,
                                        .v = fv.v,
                                        .tex_index = 0,
                                    };
                                }

                                // Emit 6 indices for this face
                                for (0..6) |i| {
                                    indices[idx_count + @as(u32, @intCast(i))] = vert_count + face_index_pattern[i];
                                }

                                vert_count += 4;
                                idx_count += 6;
                            }
                        }
                    }
                }
            }
        }
    }

    std.log.info("World mesh: {} indices ({} faces) out of max {}", .{ idx_count, idx_count / 6, MAX_WORLD_INDEX_COUNT });
    return .{ .vertices = vertices, .indices = indices, .vertex_count = vert_count, .index_count = idx_count };
}
