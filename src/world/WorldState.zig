const std = @import("std");
const types = @import("../renderer/vulkan/types.zig");
const FaceData = types.FaceData;
const LightEntry = types.LightEntry;
const tracy = @import("../platform/tracy.zig");

pub const CHUNK_SIZE = 32;
pub const BLOCKS_PER_CHUNK = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE;
pub const MAX_FACES_PER_CHUNK = BLOCKS_PER_CHUNK * 6;

pub const face_vertices = [6][4]struct { px: f32, py: f32, pz: f32, u: f32, v: f32 }{
    .{
        .{ .px = 0.0, .py = 0.0, .pz = 1.0, .u = 0.0, .v = 1.0 },
        .{ .px = 1.0, .py = 0.0, .pz = 1.0, .u = 1.0, .v = 1.0 },
        .{ .px = 1.0, .py = 1.0, .pz = 1.0, .u = 1.0, .v = 0.0 },
        .{ .px = 0.0, .py = 1.0, .pz = 1.0, .u = 0.0, .v = 0.0 },
    },
    .{
        .{ .px = 1.0, .py = 0.0, .pz = 0.0, .u = 0.0, .v = 1.0 },
        .{ .px = 0.0, .py = 0.0, .pz = 0.0, .u = 1.0, .v = 1.0 },
        .{ .px = 0.0, .py = 1.0, .pz = 0.0, .u = 1.0, .v = 0.0 },
        .{ .px = 1.0, .py = 1.0, .pz = 0.0, .u = 0.0, .v = 0.0 },
    },
    .{
        .{ .px = 0.0, .py = 0.0, .pz = 0.0, .u = 0.0, .v = 1.0 },
        .{ .px = 0.0, .py = 0.0, .pz = 1.0, .u = 1.0, .v = 1.0 },
        .{ .px = 0.0, .py = 1.0, .pz = 1.0, .u = 1.0, .v = 0.0 },
        .{ .px = 0.0, .py = 1.0, .pz = 0.0, .u = 0.0, .v = 0.0 },
    },
    .{
        .{ .px = 1.0, .py = 0.0, .pz = 1.0, .u = 0.0, .v = 1.0 },
        .{ .px = 1.0, .py = 0.0, .pz = 0.0, .u = 1.0, .v = 1.0 },
        .{ .px = 1.0, .py = 1.0, .pz = 0.0, .u = 1.0, .v = 0.0 },
        .{ .px = 1.0, .py = 1.0, .pz = 1.0, .u = 0.0, .v = 0.0 },
    },
    .{
        .{ .px = 0.0, .py = 1.0, .pz = 1.0, .u = 0.0, .v = 1.0 },
        .{ .px = 1.0, .py = 1.0, .pz = 1.0, .u = 1.0, .v = 1.0 },
        .{ .px = 1.0, .py = 1.0, .pz = 0.0, .u = 1.0, .v = 0.0 },
        .{ .px = 0.0, .py = 1.0, .pz = 0.0, .u = 0.0, .v = 0.0 },
    },
    .{
        .{ .px = 0.0, .py = 0.0, .pz = 0.0, .u = 0.0, .v = 1.0 },
        .{ .px = 1.0, .py = 0.0, .pz = 0.0, .u = 1.0, .v = 1.0 },
        .{ .px = 1.0, .py = 0.0, .pz = 1.0, .u = 1.0, .v = 0.0 },
        .{ .px = 0.0, .py = 0.0, .pz = 1.0, .u = 0.0, .v = 0.0 },
    },
};

pub const face_index_pattern = [6]u32{ 0, 1, 2, 2, 3, 0 };

pub const face_neighbor_offsets = [6][3]i32{
    .{ 0, 0, 1 },
    .{ 0, 0, -1 },
    .{ -1, 0, 0 },
    .{ 1, 0, 0 },
    .{ 0, 1, 0 },
    .{ 0, -1, 0 },
};

pub const BlockType = enum(u8) {
    air,
    glass,
    grass_block,
    dirt,
    stone,
    glowstone,
    sand,
    snow,
    water,
    gravel,
};

pub const block_properties = struct {
    pub fn isOpaque(block: BlockType) bool {
        return switch (block) {
            .air => false,
            .glass => false,
            .water => false,
            .grass_block, .dirt, .stone, .glowstone, .sand, .snow, .gravel => true,
        };
    }
    pub fn cullsSelf(block: BlockType) bool {
        return switch (block) {
            .air => false,
            .glass, .water => true,
            .grass_block, .dirt, .stone, .glowstone, .sand, .snow, .gravel => true,
        };
    }
    pub fn isSolid(block: BlockType) bool {
        return block != .air and block != .water;
    }
    pub fn emittedLight(block: BlockType) [3]u8 {
        return switch (block) {
            .glowstone => .{ 255, 200, 100 },
            else => .{ 0, 0, 0 },
        };
    }
};

// --- Core types ---

pub const Chunk = struct {
    blocks: [BLOCKS_PER_CHUNK]BlockType,
};

pub const ChunkKey = struct {
    cx: i32,
    cy: i32,
    cz: i32,

    pub fn eql(a: ChunkKey, b: ChunkKey) bool {
        return a.cx == b.cx and a.cy == b.cy and a.cz == b.cz;
    }

    pub fn fromWorldPos(wx: i32, wy: i32, wz: i32) ChunkKey {
        return .{
            .cx = @divFloor(wx, @as(i32, CHUNK_SIZE)),
            .cy = @divFloor(wy, @as(i32, CHUNK_SIZE)),
            .cz = @divFloor(wz, @as(i32, CHUNK_SIZE)),
        };
    }

    /// World-space origin of this chunk (block coordinates of corner 0,0,0).
    pub fn position(self: ChunkKey) [3]i32 {
        return .{
            self.cx * CHUNK_SIZE,
            self.cy * CHUNK_SIZE,
            self.cz * CHUNK_SIZE,
        };
    }

    /// World-space origin scaled by voxel size (for GPU chunk data).
    pub fn positionScaled(self: ChunkKey, voxel_size: u32) [3]i32 {
        const vs: i32 = @intCast(voxel_size);
        return .{
            self.cx * CHUNK_SIZE * vs,
            self.cy * CHUNK_SIZE * vs,
            self.cz * CHUNK_SIZE * vs,
        };
    }
};

pub const ChunkMeshResult = struct {
    faces: []FaceData,
    face_counts: [6]u32,
    total_face_count: u32,
    lights: []LightEntry,
    light_count: u32,
};

pub const ChunkLightResult = struct {
    lights: []LightEntry,
    light_count: u32,
    face_counts: [6]u32,
    total_face_count: u32,
};

pub const AffectedChunks = struct {
    keys: [7]ChunkKey,
    count: u8,
};

// --- Utility ---

pub fn chunkIndex(x: usize, y: usize, z: usize) usize {
    return y * CHUNK_SIZE * CHUNK_SIZE + z * CHUNK_SIZE + x;
}

// --- Terrain generation ---

/// Generate flat terrain into a chunk based on its key.
/// Grass at wy=0, dirt at wy=-1..-2, stone at wy=-3..-7, air elsewhere.
pub fn generateFlatChunk(chunk: *Chunk, key: ChunkKey) void {
    chunk.blocks = .{.air} ** BLOCKS_PER_CHUNK;

    for (0..CHUNK_SIZE) |by| {
        const wy: i32 = key.cy * CHUNK_SIZE + @as(i32, @intCast(by));

        const block_type: BlockType = if (wy == 0)
            .grass_block
        else if (wy >= -2 and wy <= -1)
            .dirt
        else if (wy >= -7 and wy <= -3)
            .stone
        else
            .air;

        if (block_type == .air) continue;

        for (0..CHUNK_SIZE) |bz| {
            for (0..CHUNK_SIZE) |bx| {
                chunk.blocks[chunkIndex(bx, by, bz)] = block_type;
            }
        }
    }
}

// --- Neighbor block lookup ---

/// Get a block at local coordinates that may extend into neighbor chunks.
/// For single-axis out-of-bounds, reads from the corresponding face neighbor.
/// For multi-axis out-of-bounds (diagonal), returns .air.
///
/// Face neighbor mapping:
///   0: +Z, 1: -Z, 2: -X, 3: +X, 4: +Y, 5: -Y
fn getNeighborBlock(
    chunk: *const Chunk,
    neighbors: [6]?*const Chunk,
    lx: i32,
    ly: i32,
    lz: i32,
) BlockType {
    // Fast path: within current chunk
    if (lx >= 0 and lx < CHUNK_SIZE and ly >= 0 and ly < CHUNK_SIZE and lz >= 0 and lz < CHUNK_SIZE) {
        return chunk.blocks[chunkIndex(@intCast(lx), @intCast(ly), @intCast(lz))];
    }

    // Count how many axes are out of bounds
    const x_out = lx < 0 or lx >= CHUNK_SIZE;
    const y_out = ly < 0 or ly >= CHUNK_SIZE;
    const z_out = lz < 0 or lz >= CHUNK_SIZE;

    const out_count = @as(u32, @intFromBool(x_out)) + @intFromBool(y_out) + @intFromBool(z_out);
    if (out_count != 1) return .air;

    // Determine which face neighbor to use
    const face_idx: usize = if (lx < 0)
        2 // -X
    else if (lx >= CHUNK_SIZE)
        3 // +X
    else if (ly < 0)
        5 // -Y
    else if (ly >= CHUNK_SIZE)
        4 // +Y
    else if (lz < 0)
        1 // -Z
    else
        0; // +Z

    const neighbor = neighbors[face_idx] orelse return .air;

    const nlx: usize = @intCast(@mod(lx, @as(i32, CHUNK_SIZE)));
    const nly: usize = @intCast(@mod(ly, @as(i32, CHUNK_SIZE)));
    const nlz: usize = @intCast(@mod(lz, @as(i32, CHUNK_SIZE)));

    return neighbor.blocks[chunkIndex(nlx, nly, nlz)];
}

// --- AO computation ---

const ao_offsets = computeAoOffsets();

fn computeAoOffsets() [6][4][3][3]i32 {
    var result: [6][4][3][3]i32 = undefined;

    for (0..6) |face| {
        const normal = face_neighbor_offsets[face];

        for (0..4) |corner| {
            const vert = face_vertices[face][corner];
            const pos = [3]f32{ vert.px, vert.py, vert.pz };

            var tang: [2]usize = undefined;
            var ti: usize = 0;
            for (0..3) |axis| {
                if (normal[axis] == 0) {
                    tang[ti] = axis;
                    ti += 1;
                }
            }

            var edge1 = [3]i32{ 0, 0, 0 };
            var edge2 = [3]i32{ 0, 0, 0 };
            edge1[tang[0]] = if (pos[tang[0]] == 0.0) -1 else 1;
            edge2[tang[1]] = if (pos[tang[1]] == 0.0) -1 else 1;

            result[face][corner][0] = .{
                normal[0] + edge1[0],
                normal[1] + edge1[1],
                normal[2] + edge1[2],
            };
            result[face][corner][1] = .{
                normal[0] + edge2[0],
                normal[1] + edge2[1],
                normal[2] + edge2[2],
            };
            result[face][corner][2] = .{
                normal[0] + edge1[0] + edge2[0],
                normal[1] + edge1[1] + edge2[1],
                normal[2] + edge1[2] + edge2[2],
            };
        }
    }

    return result;
}

// --- Padded block lookup (eliminates per-block neighbor branching) ---

const PADDED_SIZE = CHUNK_SIZE + 2;
const PADDED_BLOCKS = PADDED_SIZE * PADDED_SIZE * PADDED_SIZE;

fn paddedIndex(x: usize, y: usize, z: usize) usize {
    return y * PADDED_SIZE * PADDED_SIZE + z * PADDED_SIZE + x;
}

/// Comptime padded-index offsets for the 6 face neighbors.
const padded_face_deltas = computePaddedFaceDeltas();

fn computePaddedFaceDeltas() [6]i32 {
    var result: [6]i32 = undefined;
    for (0..6) |f| {
        const fno = face_neighbor_offsets[f];
        result[f] = fno[1] * @as(i32, PADDED_SIZE * PADDED_SIZE) + fno[2] * @as(i32, PADDED_SIZE) + fno[0];
    }
    return result;
}

/// Comptime padded-index offsets for AO corner samples.
const padded_ao_deltas = computePaddedAoDeltas();

fn computePaddedAoDeltas() [6][4][3]i32 {
    var result: [6][4][3]i32 = undefined;
    for (0..6) |face| {
        for (0..4) |corner| {
            for (0..3) |sample| {
                const off = ao_offsets[face][corner][sample];
                result[face][corner][sample] = off[1] * @as(i32, PADDED_SIZE * PADDED_SIZE) + off[2] * @as(i32, PADDED_SIZE) + off[0];
            }
        }
    }
    return result;
}

/// Build a 34³ padded block array: center 32³ from chunk, 1-block border from neighbors, .air elsewhere.
fn buildPaddedBlocks(padded: *[PADDED_BLOCKS]BlockType, chunk: *const Chunk, neighbors: [6]?*const Chunk) void {
    @memset(padded, .air);

    // Copy center 32³ — row by row (x-axis contiguous in memory)
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |z| {
            @memcpy(
                padded[paddedIndex(1, y + 1, z + 1)..][0..CHUNK_SIZE],
                chunk.blocks[chunkIndex(0, y, z)..][0..CHUNK_SIZE],
            );
        }
    }

    // +Z face (0): neighbor's z=0 slice → padded z=PADDED_SIZE-1
    if (neighbors[0]) |n| {
        for (0..CHUNK_SIZE) |y| {
            @memcpy(
                padded[paddedIndex(1, y + 1, PADDED_SIZE - 1)..][0..CHUNK_SIZE],
                n.blocks[chunkIndex(0, y, 0)..][0..CHUNK_SIZE],
            );
        }
    }
    // -Z face (1): neighbor's z=31 slice → padded z=0
    if (neighbors[1]) |n| {
        for (0..CHUNK_SIZE) |y| {
            @memcpy(
                padded[paddedIndex(1, y + 1, 0)..][0..CHUNK_SIZE],
                n.blocks[chunkIndex(0, y, CHUNK_SIZE - 1)..][0..CHUNK_SIZE],
            );
        }
    }
    // -X face (2): neighbor's x=31 → padded x=0
    if (neighbors[2]) |n| {
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |z| {
                padded[paddedIndex(0, y + 1, z + 1)] = n.blocks[chunkIndex(CHUNK_SIZE - 1, y, z)];
            }
        }
    }
    // +X face (3): neighbor's x=0 → padded x=PADDED_SIZE-1
    if (neighbors[3]) |n| {
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |z| {
                padded[paddedIndex(PADDED_SIZE - 1, y + 1, z + 1)] = n.blocks[chunkIndex(0, y, z)];
            }
        }
    }
    // +Y face (4): neighbor's y=0 → padded y=PADDED_SIZE-1
    if (neighbors[4]) |n| {
        for (0..CHUNK_SIZE) |z| {
            @memcpy(
                padded[paddedIndex(1, PADDED_SIZE - 1, z + 1)..][0..CHUNK_SIZE],
                n.blocks[chunkIndex(0, 0, z)..][0..CHUNK_SIZE],
            );
        }
    }
    // -Y face (5): neighbor's y=31 → padded y=0
    if (neighbors[5]) |n| {
        for (0..CHUNK_SIZE) |z| {
            @memcpy(
                padded[paddedIndex(1, 0, z + 1)..][0..CHUNK_SIZE],
                n.blocks[chunkIndex(0, CHUNK_SIZE - 1, z)..][0..CHUNK_SIZE],
            );
        }
    }
}

// --- Mesh generation ---

pub fn generateChunkMesh(
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    neighbors: [6]?*const Chunk,
) !ChunkMeshResult {
    const tz = tracy.zone(@src(), "generateChunkMesh");
    defer tz.end();

    var padded: [PADDED_BLOCKS]BlockType = undefined;
    buildPaddedBlocks(&padded, chunk, neighbors);

    var normal_faces: [6]std.ArrayList(FaceData) = undefined;
    var normal_lights: [6]std.ArrayList(LightEntry) = undefined;
    for (0..6) |i| {
        normal_faces[i] = .empty;
        normal_lights[i] = .empty;
    }
    errdefer for (0..6) |i| {
        normal_faces[i].deinit(allocator);
        normal_lights[i].deinit(allocator);
    };

    for (0..CHUNK_SIZE) |by| {
        for (0..CHUNK_SIZE) |bz| {
            for (0..CHUNK_SIZE) |bx| {
                const base: i32 = @intCast(paddedIndex(bx + 1, by + 1, bz + 1));
                const block = padded[@intCast(base)];
                if (block == .air) continue;

                const emits = block_properties.emittedLight(block);
                const is_emitter = emits[0] > 0 or emits[1] > 0 or emits[2] > 0;

                for (0..6) |face| {
                    const neighbor = padded[@intCast(base + padded_face_deltas[face])];

                    if (block_properties.isOpaque(neighbor)) continue;
                    if (neighbor == block and block_properties.cullsSelf(block)) continue;

                    const tex_index: u8 = switch (block) {
                        .air => unreachable,
                        .glass => 0,
                        .grass_block => 1,
                        .dirt => 2,
                        .stone => 3,
                        .glowstone => 4,
                        .sand => 5,
                        .snow => 6,
                        .water => 7,
                        .gravel => 8,
                    };

                    var corner_packed: [4]u32 = undefined;
                    var corner_block_brightness: [4]u8 = .{ 0, 0, 0, 0 };

                    if (is_emitter) {
                        const br5: u32 = @as(u32, emits[0]) >> 3;
                        const bg5: u32 = @as(u32, emits[1]) >> 3;
                        const bb5: u32 = @as(u32, emits[2]) >> 3;
                        const emit_packed: u32 = (31 << 0) | (31 << 5) | (31 << 10) | (br5 << 15) | (bg5 << 20) | (bb5 << 25);
                        corner_packed = .{ emit_packed, emit_packed, emit_packed, emit_packed };
                        corner_block_brightness = .{ 255, 255, 255, 255 };
                    } else {
                        // No light map — full sky brightness
                        const full_sky: u32 = 31 | (31 << 5) | (31 << 10);
                        corner_packed = .{ full_sky, full_sky, full_sky, full_sky };
                    }

                    var ao: [4]u2 = undefined;
                    if (is_emitter) {
                        ao = .{ 0, 0, 0, 0 };
                    } else {
                        for (0..4) |corner| {
                            const deltas = padded_ao_deltas[face][corner];
                            const s1 = block_properties.isOpaque(padded[@intCast(base + deltas[0])]);
                            const s2 = block_properties.isOpaque(padded[@intCast(base + deltas[1])]);
                            const diag = if (s1 and s2)
                                true
                            else
                                block_properties.isOpaque(padded[@intCast(base + deltas[2])]);
                            const raw_ao: u3 = @as(u3, @intFromBool(s1)) + @intFromBool(s2) + @intFromBool(diag);

                            const reduction: u3 = @intCast(@min(@as(u32, 3), @as(u32, corner_block_brightness[corner]) / 64));
                            ao[corner] = @intCast(raw_ao -| reduction);
                        }
                    }

                    const face_data = types.packFaceData(
                        @intCast(bx),
                        @intCast(by),
                        @intCast(bz),
                        tex_index,
                        @intCast(face),
                        0,
                        ao,
                    );

                    try normal_faces[face].append(allocator, face_data);
                    try normal_lights[face].append(allocator, .{ .corners = corner_packed });
                }
            }
        }
    }

    var face_counts: [6]u32 = undefined;
    var total_face_count: u32 = 0;
    for (0..6) |i| {
        face_counts[i] = @intCast(normal_faces[i].items.len);
        total_face_count += face_counts[i];
    }

    const faces = try allocator.alloc(FaceData, total_face_count);
    errdefer allocator.free(faces);
    const lights = try allocator.alloc(LightEntry, total_face_count);
    errdefer allocator.free(lights);

    var write_offset: usize = 0;
    for (0..6) |i| {
        const fitems = normal_faces[i].items;
        const litems = normal_lights[i].items;
        @memcpy(faces[write_offset..][0..fitems.len], fitems);
        @memcpy(lights[write_offset..][0..litems.len], litems);
        write_offset += fitems.len;
        normal_faces[i].deinit(allocator);
        normal_lights[i].deinit(allocator);
    }

    return .{
        .faces = faces,
        .face_counts = face_counts,
        .total_face_count = total_face_count,
        .lights = lights,
        .light_count = total_face_count,
    };
}

pub fn generateChunkLightOnly(
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    neighbors: [6]?*const Chunk,
) !ChunkLightResult {
    const tz = tracy.zone(@src(), "generateChunkLightOnly");
    defer tz.end();

    var padded: [PADDED_BLOCKS]BlockType = undefined;
    buildPaddedBlocks(&padded, chunk, neighbors);

    var normal_lights: [6]std.ArrayList(LightEntry) = undefined;
    for (0..6) |i| {
        normal_lights[i] = .empty;
    }
    errdefer for (0..6) |i| {
        normal_lights[i].deinit(allocator);
    };

    for (0..CHUNK_SIZE) |by| {
        for (0..CHUNK_SIZE) |bz| {
            for (0..CHUNK_SIZE) |bx| {
                const base: i32 = @intCast(paddedIndex(bx + 1, by + 1, bz + 1));
                const block = padded[@intCast(base)];
                if (block == .air) continue;

                const emits = block_properties.emittedLight(block);
                const is_emitter = emits[0] > 0 or emits[1] > 0 or emits[2] > 0;

                for (0..6) |face| {
                    const neighbor_block = padded[@intCast(base + padded_face_deltas[face])];

                    if (block_properties.isOpaque(neighbor_block)) continue;
                    if (neighbor_block == block and block_properties.cullsSelf(block)) continue;

                    var corner_packed: [4]u32 = undefined;

                    if (is_emitter) {
                        const br5: u32 = @as(u32, emits[0]) >> 3;
                        const bg5: u32 = @as(u32, emits[1]) >> 3;
                        const bb5: u32 = @as(u32, emits[2]) >> 3;
                        const emit_packed: u32 = (31 << 0) | (31 << 5) | (31 << 10) | (br5 << 15) | (bg5 << 20) | (bb5 << 25);
                        corner_packed = .{ emit_packed, emit_packed, emit_packed, emit_packed };
                    } else {
                        // No light map — full sky brightness
                        const full_sky: u32 = 31 | (31 << 5) | (31 << 10);
                        corner_packed = .{ full_sky, full_sky, full_sky, full_sky };
                    }

                    try normal_lights[face].append(allocator, .{ .corners = corner_packed });
                }
            }
        }
    }

    var face_counts: [6]u32 = undefined;
    var total_face_count: u32 = 0;
    for (0..6) |i| {
        face_counts[i] = @intCast(normal_lights[i].items.len);
        total_face_count += face_counts[i];
    }

    const lights = try allocator.alloc(LightEntry, total_face_count);
    errdefer allocator.free(lights);

    var write_offset: usize = 0;
    for (0..6) |i| {
        const litems = normal_lights[i].items;
        @memcpy(lights[write_offset..][0..litems.len], litems);
        write_offset += litems.len;
        normal_lights[i].deinit(allocator);
    }

    return .{
        .lights = lights,
        .light_count = total_face_count,
        .face_counts = face_counts,
        .total_face_count = total_face_count,
    };
}

// --- Affected chunks ---

/// Returns the chunk keys affected by a block change at world coordinates.
/// Includes the primary chunk and up to 6 adjacent chunks if the block
/// is within 1 block of a chunk boundary.
pub fn affectedChunks(wx: i32, wy: i32, wz: i32) AffectedChunks {
    const cs: i32 = CHUNK_SIZE;
    const base_cx = @divFloor(wx, cs);
    const base_cy = @divFloor(wy, cs);
    const base_cz = @divFloor(wz, cs);

    var result = AffectedChunks{
        .keys = undefined,
        .count = 0,
    };

    result.keys[0] = .{ .cx = base_cx, .cy = base_cy, .cz = base_cz };
    result.count = 1;

    const lx = @mod(wx, cs);
    const ly = @mod(wy, cs);
    const lz = @mod(wz, cs);

    if (lx <= 1) {
        result.keys[result.count] = .{ .cx = base_cx - 1, .cy = base_cy, .cz = base_cz };
        result.count += 1;
    }
    if (lx >= cs - 2) {
        result.keys[result.count] = .{ .cx = base_cx + 1, .cy = base_cy, .cz = base_cz };
        result.count += 1;
    }

    if (ly <= 1) {
        result.keys[result.count] = .{ .cx = base_cx, .cy = base_cy - 1, .cz = base_cz };
        result.count += 1;
    }
    if (ly >= cs - 2) {
        result.keys[result.count] = .{ .cx = base_cx, .cy = base_cy + 1, .cz = base_cz };
        result.count += 1;
    }

    if (lz <= 1) {
        result.keys[result.count] = .{ .cx = base_cx, .cy = base_cy, .cz = base_cz - 1 };
        result.count += 1;
    }
    if (lz >= cs - 2) {
        result.keys[result.count] = .{ .cx = base_cx, .cy = base_cy, .cz = base_cz + 1 };
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

fn makeEmptyChunk() Chunk {
    return .{ .blocks = .{.air} ** BLOCKS_PER_CHUNK };
}

const no_neighbors: [6]?*const Chunk = .{ null, null, null, null, null, null };

test "single block in air produces 6 faces" {
    var chunk = makeEmptyChunk();
    chunk.blocks[chunkIndex(5, 5, 5)] = .stone;

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    try testing.expectEqual(@as(u32, 6), result.total_face_count);

    for (0..6) |i| {
        try testing.expectEqual(@as(u32, 1), result.face_counts[i]);
    }

    for (result.faces) |face| {
        const u = unpackFace(face);
        try testing.expectEqual(@as(u5, 5), u.x);
        try testing.expectEqual(@as(u5, 5), u.y);
        try testing.expectEqual(@as(u5, 5), u.z);
        try testing.expectEqual(@as(u8, 3), u.tex_index);
    }
}

test "two adjacent blocks share face - culled" {
    var chunk = makeEmptyChunk();
    chunk.blocks[chunkIndex(5, 5, 5)] = .stone;
    chunk.blocks[chunkIndex(6, 5, 5)] = .stone;

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    try testing.expectEqual(@as(u32, 10), result.total_face_count);

    try testing.expectEqual(@as(u32, 1), result.face_counts[2]);
    try testing.expectEqual(@as(u32, 1), result.face_counts[3]);
    try testing.expectEqual(@as(u32, 2), result.face_counts[0]);
    try testing.expectEqual(@as(u32, 2), result.face_counts[1]);
    try testing.expectEqual(@as(u32, 2), result.face_counts[4]);
    try testing.expectEqual(@as(u32, 2), result.face_counts[5]);
}

test "face_counts sum equals total_face_count" {
    var chunk = makeEmptyChunk();
    for (3..7) |x| {
        for (3..6) |y| {
            chunk.blocks[chunkIndex(x, y, 4)] = .dirt;
        }
    }

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    var sum: u32 = 0;
    for (result.face_counts) |fc| sum += fc;
    try testing.expectEqual(sum, result.total_face_count);
    try testing.expectEqual(result.total_face_count, @as(u32, @intCast(result.faces.len)));
}

test "normal indices in faces match their group" {
    var chunk = makeEmptyChunk();
    chunk.blocks[chunkIndex(10, 10, 10)] = .grass_block;

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

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
    var chunk0 = makeEmptyChunk();
    var chunk1 = makeEmptyChunk();
    chunk0.blocks[chunkIndex(CHUNK_SIZE - 1, 5, 5)] = .stone;
    chunk1.blocks[chunkIndex(0, 5, 5)] = .stone;

    // chunk0 has chunk1 as its +X neighbor (face 3)
    var neighbors0 = no_neighbors;
    neighbors0[3] = &chunk1;
    // chunk1 has chunk0 as its -X neighbor (face 2)
    var neighbors1 = no_neighbors;
    neighbors1[2] = &chunk0;

    const result0 = try generateChunkMesh(testing.allocator, &chunk0, neighbors0);
    defer testing.allocator.free(result0.faces);
    defer testing.allocator.free(result0.lights);

    const result1 = try generateChunkMesh(testing.allocator, &chunk1, neighbors1);
    defer testing.allocator.free(result1.faces);
    defer testing.allocator.free(result1.lights);

    try testing.expectEqual(@as(u32, 5), result0.total_face_count);
    try testing.expectEqual(@as(u32, 5), result1.total_face_count);

    try testing.expectEqual(@as(u32, 0), result0.face_counts[3]);
    try testing.expectEqual(@as(u32, 0), result1.face_counts[2]);
}

test "empty chunk produces no faces" {
    const chunk = makeEmptyChunk();
    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    try testing.expectEqual(@as(u32, 0), result.total_face_count);
    try testing.expectEqual(@as(usize, 0), result.faces.len);
}

test "glass does not cull adjacent non-glass" {
    var chunk = makeEmptyChunk();
    chunk.blocks[chunkIndex(5, 5, 5)] = .stone;
    chunk.blocks[chunkIndex(6, 5, 5)] = .glass;

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    try testing.expectEqual(@as(u32, 11), result.total_face_count);
}

test "glass-glass adjacency culls shared face" {
    var chunk = makeEmptyChunk();
    chunk.blocks[chunkIndex(5, 5, 5)] = .glass;
    chunk.blocks[chunkIndex(6, 5, 5)] = .glass;

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    try testing.expectEqual(@as(u32, 10), result.total_face_count);
}

test "light count equals face count (1:1 mapping)" {
    var chunk = makeEmptyChunk();
    for (0..4) |x| {
        chunk.blocks[chunkIndex(x, 5, 5)] = .stone;
    }

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    try testing.expectEqual(result.total_face_count, result.light_count);
    try testing.expectEqual(result.faces.len, result.lights.len);
}

test "ChunkKey.position returns correct world-space origin" {
    const pos0 = (ChunkKey{ .cx = 0, .cy = 0, .cz = 0 }).position();
    try testing.expectEqual(@as(i32, 0), pos0[0]);
    try testing.expectEqual(@as(i32, 0), pos0[1]);
    try testing.expectEqual(@as(i32, 0), pos0[2]);

    const pos1 = (ChunkKey{ .cx = 2, .cy = -1, .cz = 3 }).position();
    try testing.expectEqual(@as(i32, 64), pos1[0]);
    try testing.expectEqual(@as(i32, -32), pos1[1]);
    try testing.expectEqual(@as(i32, 96), pos1[2]);
}

test "ChunkKey.fromWorldPos handles negative coords" {
    const k0 = ChunkKey.fromWorldPos(0, 0, 0);
    try testing.expectEqual(@as(i32, 0), k0.cx);
    try testing.expectEqual(@as(i32, 0), k0.cy);
    try testing.expectEqual(@as(i32, 0), k0.cz);

    const k1 = ChunkKey.fromWorldPos(-1, -1, -1);
    try testing.expectEqual(@as(i32, -1), k1.cx);
    try testing.expectEqual(@as(i32, -1), k1.cy);
    try testing.expectEqual(@as(i32, -1), k1.cz);

    const k2 = ChunkKey.fromWorldPos(31, 32, -32);
    try testing.expectEqual(@as(i32, 0), k2.cx);
    try testing.expectEqual(@as(i32, 1), k2.cy);
    try testing.expectEqual(@as(i32, -1), k2.cz);
}

test "world boundary blocks have all outer faces" {
    var chunk = makeEmptyChunk();
    chunk.blocks[chunkIndex(0, 0, 0)] = .stone;

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    try testing.expectEqual(@as(u32, 6), result.total_face_count);
}

fn unpackAo(fd: FaceData) [4]u2 {
    return .{
        @intCast(fd.word1 & 0x3),
        @intCast((fd.word1 >> 2) & 0x3),
        @intCast((fd.word1 >> 4) & 0x3),
        @intCast((fd.word1 >> 6) & 0x3),
    };
}

fn findFaceByNormal(result: ChunkMeshResult, normal: u3) ?FaceData {
    var offset: usize = 0;
    for (0..6) |i| {
        const count = result.face_counts[i];
        if (i == normal) {
            if (count > 0) return result.faces[offset];
            return null;
        }
        offset += count;
    }
    return null;
}

test "AO: single block in air has no occlusion" {
    var chunk = makeEmptyChunk();
    chunk.blocks[chunkIndex(5, 5, 5)] = .stone;

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    for (result.faces) |face| {
        try testing.expectEqual([4]u2{ 0, 0, 0, 0 }, unpackAo(face));
    }
}

test "AO: block on flat surface has correct top face AO" {
    var chunk = makeEmptyChunk();
    for (4..7) |x| {
        for (4..7) |z| {
            chunk.blocks[chunkIndex(x, 5, z)] = .stone;
        }
    }

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    var offset: usize = 0;
    for (0..4) |i| {
        offset += result.face_counts[i];
    }
    var center_top: ?FaceData = null;
    for (offset..offset + result.face_counts[4]) |i| {
        const u = unpackFace(result.faces[i]);
        if (u.x == 5 and u.y == 5 and u.z == 5) {
            center_top = result.faces[i];
            break;
        }
    }

    const ao = unpackAo(center_top.?);
    for (ao) |level| {
        try testing.expectEqual(@as(u2, 3), level);
    }
}

test "AO: block in corner has maximum occlusion on enclosed corner" {
    var chunk = makeEmptyChunk();
    chunk.blocks[chunkIndex(5, 5, 5)] = .stone;
    chunk.blocks[chunkIndex(6, 5, 5)] = .stone;
    chunk.blocks[chunkIndex(5, 6, 5)] = .stone;
    chunk.blocks[chunkIndex(5, 5, 6)] = .stone;

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    var found_nonzero = false;
    for (result.faces) |face| {
        const ao = unpackAo(face);
        for (ao) |level| {
            if (level > 0) {
                found_nonzero = true;
                break;
            }
        }
        if (found_nonzero) break;
    }
    try testing.expect(found_nonzero);
}

test "AO: comptime offset table sanity" {
    for (0..6) |face| {
        const normal = face_neighbor_offsets[face];
        for (0..4) |corner| {
            for (0..3) |sample| {
                const off = ao_offsets[face][corner][sample];
                for (0..3) |axis| {
                    try testing.expect(off[axis] >= -1 and off[axis] <= 1);
                }
                for (0..3) |axis| {
                    if (normal[axis] != 0) {
                        try testing.expectEqual(normal[axis], off[axis]);
                    }
                }
            }
        }
    }
}

test "affectedChunks: center of chunk returns only self" {
    const result = affectedChunks(16, 16, 16);
    try testing.expectEqual(@as(u8, 1), result.count);
    try testing.expectEqual(@as(i32, 0), result.keys[0].cx);
    try testing.expectEqual(@as(i32, 0), result.keys[0].cy);
    try testing.expectEqual(@as(i32, 0), result.keys[0].cz);
}

test "affectedChunks: edge of chunk returns neighbor" {
    // Block at (0, 16, 16) is at lx=0 in chunk (0,0,0), so neighbor (-1,0,0) is affected
    const result = affectedChunks(0, 16, 16);
    try testing.expect(result.count >= 2);
}

test "generateFlatChunk: grass at wy=0" {
    var chunk: Chunk = undefined;
    generateFlatChunk(&chunk, .{ .cx = 0, .cy = 0, .cz = 0 });
    // wy=0 is at by=0 in chunk cy=0
    try testing.expectEqual(BlockType.grass_block, chunk.blocks[chunkIndex(0, 0, 0)]);
    // wy=1 should be air
    try testing.expectEqual(BlockType.air, chunk.blocks[chunkIndex(0, 1, 0)]);
}
