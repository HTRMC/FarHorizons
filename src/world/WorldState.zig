const std = @import("std");
const types = @import("../renderer/vulkan/types.zig");
const FaceData = types.FaceData;
const LightEntry = types.LightEntry;
const tracy = @import("../platform/tracy.zig");

pub const CHUNK_SIZE = 32;
pub const BLOCKS_PER_CHUNK = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE; // 32768
pub const MAX_FACES_PER_CHUNK = BLOCKS_PER_CHUNK * 6; // 196608

pub const WORLD_CHUNKS_X = 4;
pub const WORLD_CHUNKS_Y = 1;
pub const WORLD_CHUNKS_Z = 4;
pub const WORLD_SIZE_X = WORLD_CHUNKS_X * CHUNK_SIZE; // 128
pub const WORLD_SIZE_Y = WORLD_CHUNKS_Y * CHUNK_SIZE; // 32
pub const WORLD_SIZE_Z = WORLD_CHUNKS_Z * CHUNK_SIZE; // 128
pub const TOTAL_WORLD_CHUNKS = WORLD_CHUNKS_X * WORLD_CHUNKS_Y * WORLD_CHUNKS_Z; // 16

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

pub const ChunkCoord = struct {
    cx: u8,
    cy: u8,
    cz: u8,

    pub fn flatIndex(self: ChunkCoord) usize {
        return @as(usize, self.cy) * WORLD_CHUNKS_Z * WORLD_CHUNKS_X +
            @as(usize, self.cz) * WORLD_CHUNKS_X +
            @as(usize, self.cx);
    }

    pub fn eql(a: ChunkCoord, b: ChunkCoord) bool {
        return a.cx == b.cx and a.cy == b.cy and a.cz == b.cz;
    }

    pub fn position(self: ChunkCoord) [3]i32 {
        return .{
            @as(i32, @intCast(self.cx)) * CHUNK_SIZE - @as(i32, WORLD_SIZE_X / 2),
            @as(i32, @intCast(self.cy)) * CHUNK_SIZE - @as(i32, WORLD_SIZE_Y / 2),
            @as(i32, @intCast(self.cz)) * CHUNK_SIZE - @as(i32, WORLD_SIZE_Z / 2),
        };
    }
};

pub const ChunkMeshResult = struct {
    faces: []FaceData,
    face_counts: [6]u32, // per-normal count
    total_face_count: u32,
    lights: []LightEntry,
    light_count: u32,
};

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

/// Generate mesh data for a single chunk. Faces are grouped by normal direction
/// and packed into FaceData with deduplicated light entries.
pub fn generateChunkMesh(
    allocator: std.mem.Allocator,
    world: *const World,
    coord: ChunkCoord,
) !ChunkMeshResult {
    const tz = tracy.zone(@src(), "generateChunkMesh");
    defer tz.end();

    const cx: usize = coord.cx;
    const cy: usize = coord.cy;
    const cz: usize = coord.cz;
    const chunk = &world[cy][cz][cx];

    // Per-normal face lists: collect faces grouped by normal index
    var normal_faces: [6]std.ArrayList(FaceData) = undefined;
    for (0..6) |i| {
        normal_faces[i] = .empty;
    }
    errdefer for (0..6) |i| {
        normal_faces[i].deinit(allocator);
    };

    // Light deduplication map: [4]u32 corner pattern -> light index
    var light_map = std.AutoHashMap([4]u32, u6).init(allocator);
    defer light_map.deinit();

    var light_list: std.ArrayList(LightEntry) = .empty;
    errdefer light_list.deinit(allocator);

    const face_light_values = [6]f32{ 0.6, 0.6, 0.8, 0.8, 1.0, 0.5 };

    for (0..CHUNK_SIZE) |by| {
        for (0..CHUNK_SIZE) |bz| {
            for (0..CHUNK_SIZE) |bx| {
                const block = chunk.blocks[chunkIndex(bx, by, bz)];
                if (block == .air) continue;

                for (0..6) |face| {
                    const fno = face_neighbor_offsets[face];
                    const nx: i32 = @as(i32, @intCast(bx)) + fno[0];
                    const ny: i32 = @as(i32, @intCast(by)) + fno[1];
                    const nz: i32 = @as(i32, @intCast(bz)) + fno[2];

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

                    const tex_index: u8 = switch (block) {
                        .air => unreachable,
                        .glass => 0,
                        .grass_block => 1,
                        .dirt => 2,
                        .stone => 3,
                    };

                    // Pack light: all 4 corners get the same value (no AO yet)
                    const light_byte: u32 = @intFromFloat(@floor(face_light_values[face] * 255.0));
                    const packed_light: u32 = light_byte | (light_byte << 8) | (light_byte << 16);
                    const corner_pattern = [4]u32{ packed_light, packed_light, packed_light, packed_light };

                    // Deduplicate light entry
                    const light_index: u6 = blk2: {
                        if (light_map.get(corner_pattern)) |idx| {
                            break :blk2 idx;
                        }
                        const idx: u6 = @intCast(light_list.items.len);
                        try light_list.append(allocator, .{ .corners = corner_pattern });
                        try light_map.put(corner_pattern, idx);
                        break :blk2 idx;
                    };

                    const face_data = types.packFaceData(
                        @intCast(bx),
                        @intCast(by),
                        @intCast(bz),
                        tex_index,
                        @intCast(face),
                        light_index,
                    );

                    try normal_faces[face].append(allocator, face_data);
                }
            }
        }
    }

    // Compute per-normal face counts
    var face_counts: [6]u32 = undefined;
    var total_face_count: u32 = 0;
    for (0..6) |i| {
        face_counts[i] = @intCast(normal_faces[i].items.len);
        total_face_count += face_counts[i];
    }

    // Concatenate all faces sorted by normal into a single slice
    const faces = try allocator.alloc(FaceData, total_face_count);
    errdefer allocator.free(faces);

    var write_offset: usize = 0;
    for (0..6) |i| {
        const items = normal_faces[i].items;
        @memcpy(faces[write_offset..][0..items.len], items);
        write_offset += items.len;
        normal_faces[i].deinit(allocator);
    }

    const lights = try light_list.toOwnedSlice(allocator);

    return .{
        .faces = faces,
        .face_counts = face_counts,
        .total_face_count = total_face_count,
        .lights = lights,
        .light_count = @intCast(lights.len),
    };
}

pub const AffectedChunks = struct {
    coords: [7]ChunkCoord,
    count: u8,
};

/// Return the chunk coord(s) affected by a world-space block change.
/// Modifying a block on a chunk boundary can affect the neighbor chunk's mesh
/// (face culling changes), so we return up to 4 coords (the chunk itself +
/// up to 3 neighbors when the block is in a corner).
pub fn affectedChunks(wx: i32, wy: i32, wz: i32) AffectedChunks {
    const vx = wx + @as(i32, WORLD_SIZE_X / 2);
    const vy = wy + @as(i32, WORLD_SIZE_Y / 2);
    const vz = wz + @as(i32, WORLD_SIZE_Z / 2);

    if (vx < 0 or vx >= WORLD_SIZE_X or vy < 0 or vy >= WORLD_SIZE_Y or vz < 0 or vz >= WORLD_SIZE_Z) {
        return .{ .coords = undefined, .count = 0 };
    }

    const uvx: usize = @intCast(vx);
    const uvy: usize = @intCast(vy);
    const uvz: usize = @intCast(vz);

    const base_cx: u8 = @intCast(uvx / CHUNK_SIZE);
    const base_cy: u8 = @intCast(uvy / CHUNK_SIZE);
    const base_cz: u8 = @intCast(uvz / CHUNK_SIZE);

    var result = AffectedChunks{
        .coords = undefined,
        .count = 0,
    };

    // Always include the chunk containing the block
    result.coords[0] = .{ .cx = base_cx, .cy = base_cy, .cz = base_cz };
    result.count = 1;

    // Check if block is on a chunk boundary and add neighbor chunks
    const lx = uvx % CHUNK_SIZE;
    const ly = uvy % CHUNK_SIZE;
    const lz = uvz % CHUNK_SIZE;

    if (lx == 0 and base_cx > 0) {
        result.coords[result.count] = .{ .cx = base_cx - 1, .cy = base_cy, .cz = base_cz };
        result.count += 1;
    } else if (lx == CHUNK_SIZE - 1 and base_cx + 1 < WORLD_CHUNKS_X) {
        result.coords[result.count] = .{ .cx = base_cx + 1, .cy = base_cy, .cz = base_cz };
        result.count += 1;
    }

    if (ly == 0 and base_cy > 0) {
        result.coords[result.count] = .{ .cx = base_cx, .cy = base_cy - 1, .cz = base_cz };
        result.count += 1;
    } else if (ly == CHUNK_SIZE - 1 and base_cy + 1 < WORLD_CHUNKS_Y) {
        result.coords[result.count] = .{ .cx = base_cx, .cy = base_cy + 1, .cz = base_cz };
        result.count += 1;
    }

    if (lz == 0 and base_cz > 0) {
        result.coords[result.count] = .{ .cx = base_cx, .cy = base_cy, .cz = base_cz - 1 };
        result.count += 1;
    } else if (lz == CHUNK_SIZE - 1 and base_cz + 1 < WORLD_CHUNKS_Z) {
        result.coords[result.count] = .{ .cx = base_cx, .cy = base_cy, .cz = base_cz + 1 };
        result.count += 1;
    }

    return result;
}

// --- Tests ---

const testing = std.testing;

fn unpackFace(fd: FaceData) struct { x: u5, y: u5, z: u5, tex_index: u8, normal_index: u3, light_index: u6 } {
    return .{
        .x = @intCast(fd.word0 & 0x1F),
        .y = @intCast((fd.word0 >> 5) & 0x1F),
        .z = @intCast((fd.word0 >> 10) & 0x1F),
        .tex_index = @intCast((fd.word0 >> 15) & 0xFF),
        .normal_index = @intCast((fd.word0 >> 23) & 0x7),
        .light_index = @intCast((fd.word0 >> 26) & 0x3F),
    };
}

fn makeEmptyWorld() World {
    var world: World = undefined;
    for (0..WORLD_CHUNKS_Y) |cy| {
        for (0..WORLD_CHUNKS_Z) |cz| {
            for (0..WORLD_CHUNKS_X) |cx| {
                world[cy][cz][cx] = .{ .blocks = .{.air} ** BLOCKS_PER_CHUNK };
            }
        }
    }
    return world;
}

test "single block in air produces 6 faces" {
    var world = makeEmptyWorld();
    // Place a single stone block at local (5,5,5) in chunk (0,0,0)
    world[0][0][0].blocks[chunkIndex(5, 5, 5)] = .stone;

    const result = try generateChunkMesh(testing.allocator, &world, .{ .cx = 0, .cy = 0, .cz = 0 });
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    try testing.expectEqual(@as(u32, 6), result.total_face_count);

    // Each normal direction should have exactly 1 face
    for (0..6) |i| {
        try testing.expectEqual(@as(u32, 1), result.face_counts[i]);
    }

    // All faces should reference position (5,5,5)
    for (result.faces) |face| {
        const u = unpackFace(face);
        try testing.expectEqual(@as(u5, 5), u.x);
        try testing.expectEqual(@as(u5, 5), u.y);
        try testing.expectEqual(@as(u5, 5), u.z);
        try testing.expectEqual(@as(u8, 3), u.tex_index); // stone = 3
    }
}

test "two adjacent blocks share face - culled" {
    var world = makeEmptyWorld();
    // Two stone blocks adjacent in X
    world[0][0][0].blocks[chunkIndex(5, 5, 5)] = .stone;
    world[0][0][0].blocks[chunkIndex(6, 5, 5)] = .stone;

    const result = try generateChunkMesh(testing.allocator, &world, .{ .cx = 0, .cy = 0, .cz = 0 });
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    // 2 blocks * 6 faces - 2 shared faces = 10
    try testing.expectEqual(@as(u32, 10), result.total_face_count);

    // The shared face: block(5)'s +X face (normal 3) and block(6)'s -X face (normal 2) should be culled
    // So normal 2 (-X) should have 1 face (block 5's -X), normal 3 (+X) should have 1 face (block 6's +X)
    try testing.expectEqual(@as(u32, 1), result.face_counts[2]); // -X: only block 5
    try testing.expectEqual(@as(u32, 1), result.face_counts[3]); // +X: only block 6
    // +Z, -Z, +Y, -Y each have 2 faces (one per block)
    try testing.expectEqual(@as(u32, 2), result.face_counts[0]); // +Z
    try testing.expectEqual(@as(u32, 2), result.face_counts[1]); // -Z
    try testing.expectEqual(@as(u32, 2), result.face_counts[4]); // +Y
    try testing.expectEqual(@as(u32, 2), result.face_counts[5]); // -Y
}

test "face_counts sum equals total_face_count" {
    var world = makeEmptyWorld();
    // Place a small cluster
    for (3..7) |x| {
        for (3..6) |y| {
            world[0][0][0].blocks[chunkIndex(x, y, 4)] = .dirt;
        }
    }

    const result = try generateChunkMesh(testing.allocator, &world, .{ .cx = 0, .cy = 0, .cz = 0 });
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    var sum: u32 = 0;
    for (result.face_counts) |fc| sum += fc;
    try testing.expectEqual(sum, result.total_face_count);
    try testing.expectEqual(result.total_face_count, @as(u32, @intCast(result.faces.len)));
}

test "normal indices in faces match their group" {
    var world = makeEmptyWorld();
    world[0][0][0].blocks[chunkIndex(10, 10, 10)] = .grass_block;

    const result = try generateChunkMesh(testing.allocator, &world, .{ .cx = 0, .cy = 0, .cz = 0 });
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    // Faces are concatenated by normal group: first face_counts[0] faces have normal 0, etc.
    var offset: usize = 0;
    for (0..6) |normal_idx| {
        const count = result.face_counts[normal_idx];
        for (offset..offset + count) |i| {
            const u = unpackFace(result.faces[i]);
            try testing.expectEqual(@as(u3, @intCast(normal_idx)), u.normal_index);
        }
        offset += count;
    }
}

test "cross-chunk boundary face culling" {
    var world = makeEmptyWorld();
    // Place blocks on both sides of the chunk boundary in X
    // Chunk (0,0,0) block at local x=31 (rightmost)
    world[0][0][0].blocks[chunkIndex(CHUNK_SIZE - 1, 5, 5)] = .stone;
    // Chunk (1,0,0) block at local x=0 (leftmost)
    world[0][0][1].blocks[chunkIndex(0, 5, 5)] = .stone;

    const result0 = try generateChunkMesh(testing.allocator, &world, .{ .cx = 0, .cy = 0, .cz = 0 });
    defer testing.allocator.free(result0.faces);
    defer testing.allocator.free(result0.lights);

    const result1 = try generateChunkMesh(testing.allocator, &world, .{ .cx = 1, .cy = 0, .cz = 0 });
    defer testing.allocator.free(result1.faces);
    defer testing.allocator.free(result1.lights);

    // Each block should have 5 faces (shared +X/-X face culled)
    try testing.expectEqual(@as(u32, 5), result0.total_face_count);
    try testing.expectEqual(@as(u32, 5), result1.total_face_count);

    // Chunk 0's +X face (normal 3) should be 0 (culled by adjacent block in chunk 1)
    try testing.expectEqual(@as(u32, 0), result0.face_counts[3]);
    // Chunk 1's -X face (normal 2) should be 0 (culled by adjacent block in chunk 0)
    try testing.expectEqual(@as(u32, 0), result1.face_counts[2]);
}

test "empty chunk produces no faces" {
    var world = makeEmptyWorld();
    const result = try generateChunkMesh(testing.allocator, &world, .{ .cx = 0, .cy = 0, .cz = 0 });
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    try testing.expectEqual(@as(u32, 0), result.total_face_count);
    try testing.expectEqual(@as(usize, 0), result.faces.len);
}

test "glass does not cull adjacent non-glass" {
    var world = makeEmptyWorld();
    // Glass next to stone: stone face should be visible (glass is not opaque)
    world[0][0][0].blocks[chunkIndex(5, 5, 5)] = .stone;
    world[0][0][0].blocks[chunkIndex(6, 5, 5)] = .glass;

    const result = try generateChunkMesh(testing.allocator, &world, .{ .cx = 0, .cy = 0, .cz = 0 });
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    // Stone has 6 faces (glass doesn't cull it since glass is not opaque)
    // Glass has 5 faces (stone IS opaque, so glass's -X face facing stone is culled)
    try testing.expectEqual(@as(u32, 11), result.total_face_count);
}

test "glass-glass adjacency culls shared face" {
    var world = makeEmptyWorld();
    world[0][0][0].blocks[chunkIndex(5, 5, 5)] = .glass;
    world[0][0][0].blocks[chunkIndex(6, 5, 5)] = .glass;

    const result = try generateChunkMesh(testing.allocator, &world, .{ .cx = 0, .cy = 0, .cz = 0 });
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    // Glass-glass: cullsSelf is true, so shared faces culled → 10 faces
    try testing.expectEqual(@as(u32, 10), result.total_face_count);
}

test "light deduplication works" {
    var world = makeEmptyWorld();
    // Multiple blocks with the same face direction should share light entries
    for (0..4) |x| {
        world[0][0][0].blocks[chunkIndex(x, 5, 5)] = .stone;
    }

    const result = try generateChunkMesh(testing.allocator, &world, .{ .cx = 0, .cy = 0, .cz = 0 });
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    // With no AO, all faces of the same normal direction have the same light.
    // There are 6 unique face directions = 6 unique light values.
    // But some face directions share the same light value:
    //   +Z/-Z both use 0.6, -X/+X both use 0.8
    // So unique light entries should be: 0.6, 0.8, 1.0, 0.5 = 4
    try testing.expectEqual(@as(u32, 4), result.light_count);
}

test "ChunkCoord.position returns correct world-space origin" {
    // Chunk (0,0,0) should map to (-WORLD_SIZE_X/2, -WORLD_SIZE_Y/2, -WORLD_SIZE_Z/2)
    const pos0 = (ChunkCoord{ .cx = 0, .cy = 0, .cz = 0 }).position();
    try testing.expectEqual(@as(i32, -64), pos0[0]);
    try testing.expectEqual(@as(i32, -16), pos0[1]);
    try testing.expectEqual(@as(i32, -64), pos0[2]);

    // Chunk (2,0,2) should be at (0, -16, 0)
    const pos2 = (ChunkCoord{ .cx = 2, .cy = 0, .cz = 2 }).position();
    try testing.expectEqual(@as(i32, 0), pos2[0]);
    try testing.expectEqual(@as(i32, -16), pos2[1]);
    try testing.expectEqual(@as(i32, 0), pos2[2]);
}

test "world boundary blocks have all outer faces" {
    var world = makeEmptyWorld();
    // Place block at corner (0,0,0) of chunk (0,0,0) — world boundary on 3 sides
    world[0][0][0].blocks[chunkIndex(0, 0, 0)] = .stone;

    const result = try generateChunkMesh(testing.allocator, &world, .{ .cx = 0, .cy = 0, .cz = 0 });
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    // All 6 faces should be present (all neighbors are air - either in-chunk or world boundary)
    try testing.expectEqual(@as(u32, 6), result.total_face_count);
}
