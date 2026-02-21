const std = @import("std");
const types = @import("../renderer/vulkan/types.zig");
const GpuVertex = types.GpuVertex;
const DrawCommand = types.DrawCommand;
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

// Persistent GPU buffer capacities (practical upper bound, not theoretical max)
pub const MESH_BUFFER_MAX_VERTICES = 2 * 1024 * 1024; // 2M verts (~56 MB)
pub const MESH_BUFFER_MAX_INDICES = 3 * 1024 * 1024; // 3M indices (~12 MB)

// Per-face vertex template (unit cube with min corner at origin)
pub const face_vertices = [6][4]struct { px: f32, py: f32, pz: f32, u: f32, v: f32 }{
    // Front face (z = 1)
    .{
        .{ .px = 0.0, .py = 0.0, .pz = 1.0, .u = 0.0, .v = 1.0 },
        .{ .px = 1.0, .py = 0.0, .pz = 1.0, .u = 1.0, .v = 1.0 },
        .{ .px = 1.0, .py = 1.0, .pz = 1.0, .u = 1.0, .v = 0.0 },
        .{ .px = 0.0, .py = 1.0, .pz = 1.0, .u = 0.0, .v = 0.0 },
    },
    // Back face (z = 0)
    .{
        .{ .px = 1.0, .py = 0.0, .pz = 0.0, .u = 0.0, .v = 1.0 },
        .{ .px = 0.0, .py = 0.0, .pz = 0.0, .u = 1.0, .v = 1.0 },
        .{ .px = 0.0, .py = 1.0, .pz = 0.0, .u = 1.0, .v = 0.0 },
        .{ .px = 1.0, .py = 1.0, .pz = 0.0, .u = 0.0, .v = 0.0 },
    },
    // Left face (x = 0)
    .{
        .{ .px = 0.0, .py = 0.0, .pz = 0.0, .u = 0.0, .v = 1.0 },
        .{ .px = 0.0, .py = 0.0, .pz = 1.0, .u = 1.0, .v = 1.0 },
        .{ .px = 0.0, .py = 1.0, .pz = 1.0, .u = 1.0, .v = 0.0 },
        .{ .px = 0.0, .py = 1.0, .pz = 0.0, .u = 0.0, .v = 0.0 },
    },
    // Right face (x = 1)
    .{
        .{ .px = 1.0, .py = 0.0, .pz = 1.0, .u = 0.0, .v = 1.0 },
        .{ .px = 1.0, .py = 0.0, .pz = 0.0, .u = 1.0, .v = 1.0 },
        .{ .px = 1.0, .py = 1.0, .pz = 0.0, .u = 1.0, .v = 0.0 },
        .{ .px = 1.0, .py = 1.0, .pz = 1.0, .u = 0.0, .v = 0.0 },
    },
    // Top face (y = 1)
    .{
        .{ .px = 0.0, .py = 1.0, .pz = 1.0, .u = 0.0, .v = 1.0 },
        .{ .px = 1.0, .py = 1.0, .pz = 1.0, .u = 1.0, .v = 1.0 },
        .{ .px = 1.0, .py = 1.0, .pz = 0.0, .u = 1.0, .v = 0.0 },
        .{ .px = 0.0, .py = 1.0, .pz = 0.0, .u = 0.0, .v = 0.0 },
    },
    // Bottom face (y = 0)
    .{
        .{ .px = 0.0, .py = 0.0, .pz = 0.0, .u = 0.0, .v = 1.0 },
        .{ .px = 1.0, .py = 0.0, .pz = 0.0, .u = 1.0, .v = 1.0 },
        .{ .px = 1.0, .py = 0.0, .pz = 1.0, .u = 1.0, .v = 0.0 },
        .{ .px = 0.0, .py = 0.0, .pz = 1.0, .u = 0.0, .v = 0.0 },
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
    grass_block,
    dirt,
    stone,
};

pub const block_properties = struct {
    pub fn isOpaque(block: BlockType) bool {
        return switch (block) {
            .air => false,
            .glass => false,
            .grass_block, .dirt, .stone => true,
        };
    }
    pub fn cullsSelf(block: BlockType) bool {
        return switch (block) {
            .air => false,
            .glass => true,
            .grass_block, .dirt, .stone => true,
        };
    }
    pub fn isSolid(block: BlockType) bool {
        return block != .air;
    }
};

pub const Chunk = struct {
    blocks: [BLOCKS_PER_CHUNK]BlockType,
};

pub const World = [WORLD_CHUNKS_Y][WORLD_CHUNKS_Z][WORLD_CHUNKS_X]Chunk;

pub fn chunkIndex(x: usize, y: usize, z: usize) usize {
    return y * CHUNK_SIZE * CHUNK_SIZE + z * CHUNK_SIZE + x;
}

pub fn setBlock(world: *World, wx: i32, wy: i32, wz: i32, block: BlockType) void {
    const vx = wx + @as(i32, WORLD_SIZE_X / 2);
    const vy = wy + @as(i32, WORLD_SIZE_Y / 2);
    const vz = wz + @as(i32, WORLD_SIZE_Z / 2);

    if (vx < 0 or vx >= WORLD_SIZE_X or vy < 0 or vy >= WORLD_SIZE_Y or vz < 0 or vz >= WORLD_SIZE_Z) return;

    const uvx: usize = @intCast(vx);
    const uvy: usize = @intCast(vy);
    const uvz: usize = @intCast(vz);

    world[uvy / CHUNK_SIZE][uvz / CHUNK_SIZE][uvx / CHUNK_SIZE]
        .blocks[chunkIndex(uvx % CHUNK_SIZE, uvy % CHUNK_SIZE, uvz % CHUNK_SIZE)] = block;
}

pub fn getBlock(world: *const World, wx: i32, wy: i32, wz: i32) BlockType {
    // World-to-voxel: vx = wx + 64, vy = wy + 16, vz = wz + 64
    const vx = wx + @as(i32, WORLD_SIZE_X / 2);
    const vy = wy + @as(i32, WORLD_SIZE_Y / 2);
    const vz = wz + @as(i32, WORLD_SIZE_Z / 2);

    if (vx < 0 or vx >= WORLD_SIZE_X or vy < 0 or vy >= WORLD_SIZE_Y or vz < 0 or vz >= WORLD_SIZE_Z) {
        return .air;
    }

    const uvx: usize = @intCast(vx);
    const uvy: usize = @intCast(vy);
    const uvz: usize = @intCast(vz);

    const cx = uvx / CHUNK_SIZE;
    const cy = uvy / CHUNK_SIZE;
    const cz = uvz / CHUNK_SIZE;
    const lx = uvx % CHUNK_SIZE;
    const ly = uvy % CHUNK_SIZE;
    const lz = uvz % CHUNK_SIZE;

    return world[cy][cz][cx].blocks[chunkIndex(lx, ly, lz)];
}

pub fn generateSphereWorld(out: *World) void {
    const half_y: i32 = WORLD_SIZE_Y / 2;

    // Flat terrain: surface at world Y=0
    //   Y=0: grass, Y=-1..-2: dirt, Y=-3..-7: stone
    for (0..WORLD_CHUNKS_Y) |cy| {
        for (0..WORLD_CHUNKS_Z) |cz| {
            for (0..WORLD_CHUNKS_X) |cx| {
                var blocks: [BLOCKS_PER_CHUNK]BlockType = .{.air} ** BLOCKS_PER_CHUNK;

                for (0..CHUNK_SIZE) |y| {
                    const wy: i32 = @as(i32, @intCast(cy * CHUNK_SIZE + y)) - half_y;

                    const block_type: BlockType = if (wy == 0)
                        .grass_block
                    else if (wy >= -2 and wy <= -1)
                        .dirt
                    else if (wy >= -7 and wy <= -3)
                        .stone
                    else
                        .air;

                    if (block_type == .air) continue;

                    for (0..CHUNK_SIZE) |z| {
                        for (0..CHUNK_SIZE) |x| {
                            blocks[chunkIndex(x, y, z)] = block_type;
                        }
                    }
                }

                out[cy][cz][cx] = .{ .blocks = blocks };
            }
        }
    }
}

pub const MeshResult = struct {
    vertices: []GpuVertex,
    indices: []u32,
    vertex_count: u32,
    index_count: u32,
    chunk_positions: [][4]f32,
    draw_commands: []DrawCommand,
    draw_count: u32,
};

pub fn generateWorldMesh(
    allocator: std.mem.Allocator,
    world: *const World,
) !MeshResult {
    const tz = tracy.zone(@src(), "generateWorldMesh");
    defer tz.end();

    const vertices = try allocator.alloc(GpuVertex, MAX_WORLD_VERTEX_COUNT);
    errdefer allocator.free(vertices);
    const indices = try allocator.alloc(u32, MAX_WORLD_INDEX_COUNT);
    errdefer allocator.free(indices);
    var chunk_positions = try allocator.alloc([4]f32, TOTAL_WORLD_CHUNKS);
    errdefer allocator.free(chunk_positions);
    var draw_commands = try allocator.alloc(DrawCommand, TOTAL_WORLD_CHUNKS);
    errdefer allocator.free(draw_commands);

    var vert_count: u32 = 0;
    var idx_count: u32 = 0;
    var draw_count: u32 = 0;

    for (0..WORLD_CHUNKS_Y) |cy| {
        for (0..WORLD_CHUNKS_Z) |cz| {
            for (0..WORLD_CHUNKS_X) |cx| {
                const chunk = &world[cy][cz][cx];

                const chunk_first_index = idx_count;

                for (0..CHUNK_SIZE) |by| {
                    for (0..CHUNK_SIZE) |bz| {
                        for (0..CHUNK_SIZE) |bx| {
                            const block = chunk.blocks[chunkIndex(bx, by, bz)];
                            if (block == .air) continue;

                            const local_x: f32 = @floatFromInt(bx);
                            const local_y: f32 = @floatFromInt(by);
                            const local_z: f32 = @floatFromInt(bz);

                            for (0..6) |face| {
                                const offset = face_neighbor_offsets[face];
                                const nx: i32 = @as(i32, @intCast(bx)) + offset[0];
                                const ny: i32 = @as(i32, @intCast(by)) + offset[1];
                                const nz: i32 = @as(i32, @intCast(bz)) + offset[2];

                                // Cross-chunk neighbor lookup
                                const neighbor = blk: {
                                    if (nx >= 0 and nx < CHUNK_SIZE and ny >= 0 and ny < CHUNK_SIZE and nz >= 0 and nz < CHUNK_SIZE) {
                                        break :blk chunk.blocks[chunkIndex(@intCast(nx), @intCast(ny), @intCast(nz))];
                                    }

                                    const ncx: i32 = @as(i32, @intCast(cx)) + if (nx < 0) @as(i32, -1) else if (nx >= CHUNK_SIZE) @as(i32, 1) else @as(i32, 0);
                                    const ncy: i32 = @as(i32, @intCast(cy)) + if (ny < 0) @as(i32, -1) else if (ny >= CHUNK_SIZE) @as(i32, 1) else @as(i32, 0);
                                    const ncz: i32 = @as(i32, @intCast(cz)) + if (nz < 0) @as(i32, -1) else if (nz >= CHUNK_SIZE) @as(i32, 1) else @as(i32, 0);

                                    if (ncx < 0 or ncx >= WORLD_CHUNKS_X or ncy < 0 or ncy >= WORLD_CHUNKS_Y or ncz < 0 or ncz >= WORLD_CHUNKS_Z) {
                                        break :blk BlockType.air;
                                    }

                                    const lx: usize = @intCast(@mod(nx, @as(i32, CHUNK_SIZE)));
                                    const ly: usize = @intCast(@mod(ny, @as(i32, CHUNK_SIZE)));
                                    const lz: usize = @intCast(@mod(nz, @as(i32, CHUNK_SIZE)));
                                    break :blk world[@intCast(ncy)][@intCast(ncz)][@intCast(ncx)].blocks[chunkIndex(lx, ly, lz)];
                                };

                                if (block_properties.isOpaque(neighbor)) continue;
                                if (neighbor == block and block_properties.cullsSelf(block)) continue;

                                const tex_index: u32 = switch (block) {
                                    .air => unreachable,
                                    .glass => 0,
                                    .grass_block => 1,
                                    .dirt => 2,
                                    .stone => 3,
                                };
                                const face_light = [6]f32{ 0.6, 0.6, 0.8, 0.8, 1.0, 0.5 };
                                for (0..4) |v| {
                                    const fv = face_vertices[face][v];
                                    vertices[vert_count + @as(u32, @intCast(v))] = .{
                                        .px = fv.px + local_x,
                                        .py = fv.py + local_y,
                                        .pz = fv.pz + local_z,
                                        .u = fv.u,
                                        .v = fv.v,
                                        .tex_index = tex_index,
                                        .light = face_light[face],
                                    };
                                }

                                for (0..6) |i| {
                                    indices[idx_count + @as(u32, @intCast(i))] = vert_count + face_index_pattern[i];
                                }

                                vert_count += 4;
                                idx_count += 6;
                            }
                        }
                    }
                }

                const chunk_index_count = idx_count - chunk_first_index;
                if (chunk_index_count > 0) {
                    chunk_positions[draw_count] = .{
                        @as(f32, @floatFromInt(cx)) - @as(f32, WORLD_CHUNKS_X) / 2.0,
                        @as(f32, @floatFromInt(cy)) - @as(f32, WORLD_CHUNKS_Y) / 2.0,
                        @as(f32, @floatFromInt(cz)) - @as(f32, WORLD_CHUNKS_Z) / 2.0,
                        0.0,
                    };
                    draw_commands[draw_count] = .{
                        .index_count = chunk_index_count,
                        .instance_count = 1,
                        .first_index = chunk_first_index,
                        .vertex_offset = 0,
                        .first_instance = 0,
                    };
                    draw_count += 1;
                }
            }
        }
    }

    return .{
        .vertices = vertices,
        .indices = indices,
        .vertex_count = vert_count,
        .index_count = idx_count,
        .chunk_positions = chunk_positions,
        .draw_commands = draw_commands,
        .draw_count = draw_count,
    };
}
