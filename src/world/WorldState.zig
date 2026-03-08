const std = @import("std");
const types = @import("../renderer/vulkan/types.zig");
const FaceData = types.FaceData;
const LightEntry = types.LightEntry;
const LightMap = @import("LightMap.zig").LightMap;
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

pub const WorldType = enum(u8) {
    normal,
    debug,
};

pub const LAYER_COUNT = 3;
pub const RenderLayer = enum(u2) { solid, cutout, translucent };

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
    cobblestone,
    oak_log,
    oak_planks,
    bricks,
    bedrock,
    gold_ore,
    iron_ore,
    coal_ore,
    diamond_ore,
    sponge,
    pumice,
    wool,
    gold_block,
    iron_block,
    diamond_block,
    bookshelf,
    obsidian,
    oak_leaves,
};

pub const block_properties = struct {
    pub fn isOpaque(block: BlockType) bool {
        return switch (block) {
            .air, .glass, .water, .oak_leaves => false,
            .grass_block, .dirt, .stone, .glowstone, .sand, .snow, .gravel,
            .cobblestone, .oak_log, .oak_planks, .bricks, .bedrock,
            .gold_ore, .iron_ore, .coal_ore, .diamond_ore,
            .sponge, .pumice, .wool, .gold_block, .iron_block,
            .diamond_block, .bookshelf, .obsidian,
            => true,
        };
    }
    pub fn cullsSelf(block: BlockType) bool {
        return switch (block) {
            .air => false,
            .glass, .water => true,
            .oak_leaves => false,
            .grass_block, .dirt, .stone, .glowstone, .sand, .snow, .gravel,
            .cobblestone, .oak_log, .oak_planks, .bricks, .bedrock,
            .gold_ore, .iron_ore, .coal_ore, .diamond_ore,
            .sponge, .pumice, .wool, .gold_block, .iron_block,
            .diamond_block, .bookshelf, .obsidian,
            => true,
        };
    }
    pub fn isSolid(block: BlockType) bool {
        return block != .air and block != .water;
    }
    pub fn renderLayer(block: BlockType) RenderLayer {
        return switch (block) {
            .glass, .water => .translucent,
            .oak_leaves => .cutout,
            else => .solid,
        };
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
    layer_face_counts: [LAYER_COUNT][6]u32,
    total_face_count: u32,
    lights: []LightEntry,
    light_count: u32,

    /// Sum face counts across all layers for each normal direction.
    pub fn totalFaceCounts(self: ChunkMeshResult) [6]u32 {
        var out: [6]u32 = .{ 0, 0, 0, 0, 0, 0 };
        for (0..LAYER_COUNT) |l| {
            for (0..6) |n| out[n] += self.layer_face_counts[l][n];
        }
        return out;
    }
};

pub const ChunkLightResult = struct {
    lights: []LightEntry,
    light_count: u32,
    layer_face_counts: [LAYER_COUNT][6]u32,
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

/// Debug world: places one of each block type in a grid at y=0, stone floor at y=-1.
pub fn generateDebugChunk(chunk: *Chunk, key: ChunkKey) void {
    chunk.blocks = .{.air} ** BLOCKS_PER_CHUNK;

    const COLS = 6;
    const SPACING = 2;

    // Stone floor at y = -1
    if (key.cy == -1) {
        for (0..CHUNK_SIZE) |bz| {
            for (0..CHUNK_SIZE) |bx| {
                chunk.blocks[chunkIndex(bx, CHUNK_SIZE - 1, bz)] = .stone;
            }
        }
        return;
    }

    if (key.cy != 0) return;

    // Enumerate all non-air block types
    const fields = @typeInfo(BlockType).@"enum".fields;
    inline for (fields, 0..) |field, i| {
        const bt: BlockType = @enumFromInt(field.value);
        if (bt == .air) continue;

        const idx = i - 1; // skip air
        const col = idx % COLS;
        const row = idx / COLS;

        // World position of this block
        const wx: i32 = @intCast(col * SPACING);
        const wz: i32 = @intCast(row * SPACING);

        // Check if this block falls within this chunk
        const lx = wx - key.cx * CHUNK_SIZE;
        const lz = wz - key.cz * CHUNK_SIZE;

        if (lx >= 0 and lx < CHUNK_SIZE and lz >= 0 and lz < CHUNK_SIZE) {
            chunk.blocks[chunkIndex(@intCast(lx), 0, @intCast(lz))] = bt;
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

/// Build padded 34³ light volumes from center LightMap + 6 neighbor LightMaps.
fn buildPaddedLight(
    padded_sky: *[PADDED_BLOCKS]u8,
    padded_block: *[PADDED_BLOCKS][3]u8,
    light_map: ?*const LightMap,
    neighbor_lights: [6]?*const LightMap,
) void {
    // Default: full sky, no block light
    @memset(padded_sky, 255);
    @memset(padded_block, .{ 0, 0, 0 });

    const lm = light_map orelse return;

    // Copy center 32³
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |z| {
            for (0..CHUNK_SIZE) |x| {
                const ci = chunkIndex(x, y, z);
                const pi = paddedIndex(x + 1, y + 1, z + 1);
                padded_sky[pi] = lm.sky_light[ci];
                padded_block[pi] = lm.block_light[ci];
            }
        }
    }

    // Copy border from neighbor LightMaps (use current values even if dirty —
    // the mesh will be re-generated when the neighbor's light is recomputed)
    // +Z face (0): neighbor's z=0 → padded z=PADDED_SIZE-1
    if (neighbor_lights[0]) |n| {
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |x| {
                const ci = chunkIndex(x, y, 0);
                const pi = paddedIndex(x + 1, y + 1, PADDED_SIZE - 1);
                padded_sky[pi] = n.sky_light[ci];
                padded_block[pi] = n.block_light[ci];
            }
        }
    }
    // -Z face (1): neighbor's z=31 → padded z=0
    if (neighbor_lights[1]) |n| {
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |x| {
                const ci = chunkIndex(x, y, CHUNK_SIZE - 1);
                const pi = paddedIndex(x + 1, y + 1, 0);
                padded_sky[pi] = n.sky_light[ci];
                padded_block[pi] = n.block_light[ci];
            }
        }
    }
    // -X face (2): neighbor's x=31 → padded x=0
    if (neighbor_lights[2]) |n| {
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |z| {
                const ci = chunkIndex(CHUNK_SIZE - 1, y, z);
                const pi = paddedIndex(0, y + 1, z + 1);
                padded_sky[pi] = n.sky_light[ci];
                padded_block[pi] = n.block_light[ci];
            }
        }
    }
    // +X face (3): neighbor's x=0 → padded x=PADDED_SIZE-1
    if (neighbor_lights[3]) |n| {
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |z| {
                const ci = chunkIndex(0, y, z);
                const pi = paddedIndex(PADDED_SIZE - 1, y + 1, z + 1);
                padded_sky[pi] = n.sky_light[ci];
                padded_block[pi] = n.block_light[ci];
            }
        }
    }
    // +Y face (4): neighbor's y=0 → padded y=PADDED_SIZE-1
    if (neighbor_lights[4]) |n| {
        for (0..CHUNK_SIZE) |z| {
            for (0..CHUNK_SIZE) |x| {
                const ci = chunkIndex(x, 0, z);
                const pi = paddedIndex(x + 1, PADDED_SIZE - 1, z + 1);
                padded_sky[pi] = n.sky_light[ci];
                padded_block[pi] = n.block_light[ci];
            }
        }
    }
    // -Y face (5): neighbor's y=31 → padded y=0
    if (neighbor_lights[5]) |n| {
        for (0..CHUNK_SIZE) |z| {
            for (0..CHUNK_SIZE) |x| {
                const ci = chunkIndex(x, CHUNK_SIZE - 1, z);
                const pi = paddedIndex(x + 1, 0, z + 1);
                padded_sky[pi] = n.sky_light[ci];
                padded_block[pi] = n.block_light[ci];
            }
        }
    }
}

/// Pack sky and block light values into the 30-bit GPU format.
fn packLight(sky_val: u8, block_light_val: [3]u8) u32 {
    const s5: u32 = @as(u32, sky_val) >> 3;
    const br5: u32 = @as(u32, block_light_val[0]) >> 3;
    const bg5: u32 = @as(u32, block_light_val[1]) >> 3;
    const bb5: u32 = @as(u32, block_light_val[2]) >> 3;
    return (s5 << 0) | (s5 << 5) | (s5 << 10) | (br5 << 15) | (bg5 << 20) | (bb5 << 25);
}

/// Returns true if this chunk will produce zero mesh faces:
/// all blocks are opaque AND all 6 neighbor boundary faces are opaque.
pub fn isFullyHidden(chunk: *const Chunk, neighbors: [6]?*const Chunk) bool {
    // 1. Check all blocks in the chunk are opaque
    for (&chunk.blocks) |b| {
        if (!block_properties.isOpaque(b)) return false;
    }

    // 2. Check each neighbor's boundary face is fully opaque
    for (0..6) |face| {
        const n = neighbors[face] orelse return false;
        const nb = &n.blocks;

        switch (face) {
            0 => { // +Z: neighbor z=0
                for (0..CHUNK_SIZE) |y| {
                    for (0..CHUNK_SIZE) |x| {
                        if (!block_properties.isOpaque(nb[chunkIndex(x, y, 0)])) return false;
                    }
                }
            },
            1 => { // -Z: neighbor z=31
                for (0..CHUNK_SIZE) |y| {
                    for (0..CHUNK_SIZE) |x| {
                        if (!block_properties.isOpaque(nb[chunkIndex(x, y, CHUNK_SIZE - 1)])) return false;
                    }
                }
            },
            2 => { // -X: neighbor x=31
                for (0..CHUNK_SIZE) |y| {
                    for (0..CHUNK_SIZE) |z| {
                        if (!block_properties.isOpaque(nb[chunkIndex(CHUNK_SIZE - 1, y, z)])) return false;
                    }
                }
            },
            3 => { // +X: neighbor x=0
                for (0..CHUNK_SIZE) |y| {
                    for (0..CHUNK_SIZE) |z| {
                        if (!block_properties.isOpaque(nb[chunkIndex(0, y, z)])) return false;
                    }
                }
            },
            4 => { // +Y: neighbor y=0
                for (0..CHUNK_SIZE) |z| {
                    for (0..CHUNK_SIZE) |x| {
                        if (!block_properties.isOpaque(nb[chunkIndex(x, 0, z)])) return false;
                    }
                }
            },
            5 => { // -Y: neighbor y=31
                for (0..CHUNK_SIZE) |z| {
                    for (0..CHUNK_SIZE) |x| {
                        if (!block_properties.isOpaque(nb[chunkIndex(x, CHUNK_SIZE - 1, z)])) return false;
                    }
                }
            },
            else => unreachable,
        }
    }

    return true;
}

// --- Mesh generation ---

pub fn generateChunkMesh(
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    neighbors: [6]?*const Chunk,
    light_map: ?*const LightMap,
    neighbor_lights: [6]?*const LightMap,
) !ChunkMeshResult {
    const tz = tracy.zone(@src(), "generateChunkMesh");
    defer tz.end();

    var padded: [PADDED_BLOCKS]BlockType = undefined;
    buildPaddedBlocks(&padded, chunk, neighbors);

    var padded_sky: [PADDED_BLOCKS]u8 = undefined;
    var padded_block_light: [PADDED_BLOCKS][3]u8 = undefined;
    buildPaddedLight(&padded_sky, &padded_block_light, light_map, neighbor_lights);

    var layer_faces: [LAYER_COUNT][6]std.ArrayList(FaceData) = undefined;
    var layer_lights: [LAYER_COUNT][6]std.ArrayList(LightEntry) = undefined;
    for (0..LAYER_COUNT) |l| {
        for (0..6) |n| {
            layer_faces[l][n] = .empty;
            layer_lights[l][n] = .empty;
        }
    }
    errdefer for (0..LAYER_COUNT) |l| {
        for (0..6) |n| {
            layer_faces[l][n].deinit(allocator);
            layer_lights[l][n].deinit(allocator);
        }
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
                        .cobblestone => 9,
                        .oak_log => if (face == 4 or face == 5) @as(u8, 27) else 10,
                        .oak_planks => 11,
                        .bricks => 12,
                        .bedrock => 13,
                        .gold_ore => 14,
                        .iron_ore => 15,
                        .coal_ore => 16,
                        .diamond_ore => 17,
                        .sponge => 18,
                        .pumice => 19,
                        .wool => 20,
                        .gold_block => 21,
                        .iron_block => 22,
                        .diamond_block => 23,
                        .bookshelf => 24,
                        .obsidian => 25,
                        .oak_leaves => 26,
                    };

                    // Sample light from the padded light volume at the face neighbor position
                    const face_neighbor_idx: usize = @intCast(base + padded_face_deltas[face]);
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
                        // Sample light at each AO corner position for smooth per-corner light
                        for (0..4) |corner| {
                            const deltas = padded_ao_deltas[face][corner];
                            // Average the face neighbor + 3 AO neighbor light values
                            var sky_sum: u32 = @as(u32, padded_sky[face_neighbor_idx]);
                            var blk_sum: [3]u32 = .{
                                @as(u32, padded_block_light[face_neighbor_idx][0]),
                                @as(u32, padded_block_light[face_neighbor_idx][1]),
                                @as(u32, padded_block_light[face_neighbor_idx][2]),
                            };
                            var count: u32 = 1;

                            for (0..3) |s| {
                                const sample_idx: usize = @intCast(base + deltas[s]);
                                if (!block_properties.isOpaque(padded[sample_idx])) {
                                    sky_sum += @as(u32, padded_sky[sample_idx]);
                                    blk_sum[0] += @as(u32, padded_block_light[sample_idx][0]);
                                    blk_sum[1] += @as(u32, padded_block_light[sample_idx][1]);
                                    blk_sum[2] += @as(u32, padded_block_light[sample_idx][2]);
                                    count += 1;
                                }
                            }

                            const avg_sky: u8 = @intCast(sky_sum / count);
                            const avg_blk: [3]u8 = .{
                                @intCast(blk_sum[0] / count),
                                @intCast(blk_sum[1] / count),
                                @intCast(blk_sum[2] / count),
                            };
                            corner_packed[corner] = packLight(avg_sky, avg_blk);
                            corner_block_brightness[corner] = @intCast(@max(blk_sum[0] / count, @max(blk_sum[1] / count, blk_sum[2] / count)));
                        }
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

                    const layer = @intFromEnum(block_properties.renderLayer(block));
                    try layer_faces[layer][face].append(allocator, face_data);
                    try layer_lights[layer][face].append(allocator, .{ .corners = corner_packed });
                }
            }
        }
    }

    var layer_face_counts: [LAYER_COUNT][6]u32 = undefined;
    var total_face_count: u32 = 0;
    for (0..LAYER_COUNT) |l| {
        for (0..6) |n| {
            layer_face_counts[l][n] = @intCast(layer_faces[l][n].items.len);
            total_face_count += layer_face_counts[l][n];
        }
    }

    const faces = try allocator.alloc(FaceData, total_face_count);
    errdefer allocator.free(faces);
    const lights = try allocator.alloc(LightEntry, total_face_count);
    errdefer allocator.free(lights);

    var write_offset: usize = 0;
    for (0..LAYER_COUNT) |l| {
        for (0..6) |n| {
            const fitems = layer_faces[l][n].items;
            const litems = layer_lights[l][n].items;
            @memcpy(faces[write_offset..][0..fitems.len], fitems);
            @memcpy(lights[write_offset..][0..litems.len], litems);
            write_offset += fitems.len;
            layer_faces[l][n].deinit(allocator);
            layer_lights[l][n].deinit(allocator);
        }
    }

    return .{
        .faces = faces,
        .layer_face_counts = layer_face_counts,
        .total_face_count = total_face_count,
        .lights = lights,
        .light_count = total_face_count,
    };
}

pub fn generateChunkLightOnly(
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    neighbors: [6]?*const Chunk,
    light_map: ?*const LightMap,
    neighbor_lights: [6]?*const LightMap,
) !ChunkLightResult {
    const tz = tracy.zone(@src(), "generateChunkLightOnly");
    defer tz.end();

    var padded: [PADDED_BLOCKS]BlockType = undefined;
    buildPaddedBlocks(&padded, chunk, neighbors);

    var padded_sky: [PADDED_BLOCKS]u8 = undefined;
    var padded_block_light: [PADDED_BLOCKS][3]u8 = undefined;
    buildPaddedLight(&padded_sky, &padded_block_light, light_map, neighbor_lights);

    var layer_lights: [LAYER_COUNT][6]std.ArrayList(LightEntry) = undefined;
    for (0..LAYER_COUNT) |l| {
        for (0..6) |n| {
            layer_lights[l][n] = .empty;
        }
    }
    errdefer for (0..LAYER_COUNT) |l| {
        for (0..6) |n| {
            layer_lights[l][n].deinit(allocator);
        }
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

                    const face_neighbor_idx2: usize = @intCast(base + padded_face_deltas[face]);
                    var corner_packed: [4]u32 = undefined;

                    if (is_emitter) {
                        const br5: u32 = @as(u32, emits[0]) >> 3;
                        const bg5: u32 = @as(u32, emits[1]) >> 3;
                        const bb5: u32 = @as(u32, emits[2]) >> 3;
                        const emit_packed: u32 = (31 << 0) | (31 << 5) | (31 << 10) | (br5 << 15) | (bg5 << 20) | (bb5 << 25);
                        corner_packed = .{ emit_packed, emit_packed, emit_packed, emit_packed };
                    } else {
                        // Sample light at the face neighbor position
                        const face_sky = padded_sky[face_neighbor_idx2];
                        const face_blk = padded_block_light[face_neighbor_idx2];
                        const lp = packLight(face_sky, face_blk);
                        corner_packed = .{ lp, lp, lp, lp };
                    }

                    const layer = @intFromEnum(block_properties.renderLayer(block));
                    try layer_lights[layer][face].append(allocator, .{ .corners = corner_packed });
                }
            }
        }
    }

    var layer_face_counts: [LAYER_COUNT][6]u32 = undefined;
    var total_face_count: u32 = 0;
    for (0..LAYER_COUNT) |l| {
        for (0..6) |n| {
            layer_face_counts[l][n] = @intCast(layer_lights[l][n].items.len);
            total_face_count += layer_face_counts[l][n];
        }
    }

    const lights = try allocator.alloc(LightEntry, total_face_count);
    errdefer allocator.free(lights);

    var write_offset: usize = 0;
    for (0..LAYER_COUNT) |l| {
        for (0..6) |n| {
            const litems = layer_lights[l][n].items;
            @memcpy(lights[write_offset..][0..litems.len], litems);
            write_offset += litems.len;
            layer_lights[l][n].deinit(allocator);
        }
    }

    return .{
        .lights = lights,
        .light_count = total_face_count,
        .layer_face_counts = layer_face_counts,
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
const no_light_neighbors: [6]?*const LightMap = .{ null, null, null, null, null, null };

test "single block in air produces 6 faces" {
    var chunk = makeEmptyChunk();
    chunk.blocks[chunkIndex(5, 5, 5)] = .stone;

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_light_neighbors);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    try testing.expectEqual(@as(u32, 6), result.total_face_count);

    const fc = result.totalFaceCounts();
    for (0..6) |i| {
        try testing.expectEqual(@as(u32, 1), fc[i]);
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

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_light_neighbors);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    try testing.expectEqual(@as(u32, 10), result.total_face_count);

    const fc = result.totalFaceCounts();
    try testing.expectEqual(@as(u32, 1), fc[2]);
    try testing.expectEqual(@as(u32, 1), fc[3]);
    try testing.expectEqual(@as(u32, 2), fc[0]);
    try testing.expectEqual(@as(u32, 2), fc[1]);
    try testing.expectEqual(@as(u32, 2), fc[4]);
    try testing.expectEqual(@as(u32, 2), fc[5]);
}

test "face_counts sum equals total_face_count" {
    var chunk = makeEmptyChunk();
    for (3..7) |x| {
        for (3..6) |y| {
            chunk.blocks[chunkIndex(x, y, 4)] = .dirt;
        }
    }

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_light_neighbors);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    var sum: u32 = 0;
    const fc = result.totalFaceCounts();
    for (fc) |c| sum += c;
    try testing.expectEqual(sum, result.total_face_count);
    try testing.expectEqual(result.total_face_count, @as(u32, @intCast(result.faces.len)));
}

test "normal indices in faces match their group" {
    var chunk = makeEmptyChunk();
    chunk.blocks[chunkIndex(10, 10, 10)] = .grass_block;

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_light_neighbors);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    const fc = result.totalFaceCounts();
    var offset: usize = 0;
    for (0..6) |normal_idx| {
        const count = fc[normal_idx];
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

    const result0 = try generateChunkMesh(testing.allocator, &chunk0, neighbors0, null, no_light_neighbors);
    defer testing.allocator.free(result0.faces);
    defer testing.allocator.free(result0.lights);

    const result1 = try generateChunkMesh(testing.allocator, &chunk1, neighbors1, null, no_light_neighbors);
    defer testing.allocator.free(result1.faces);
    defer testing.allocator.free(result1.lights);

    try testing.expectEqual(@as(u32, 5), result0.total_face_count);
    try testing.expectEqual(@as(u32, 5), result1.total_face_count);

    const fc0 = result0.totalFaceCounts();
    const fc1 = result1.totalFaceCounts();
    try testing.expectEqual(@as(u32, 0), fc0[3]);
    try testing.expectEqual(@as(u32, 0), fc1[2]);
}

test "empty chunk produces no faces" {
    const chunk = makeEmptyChunk();
    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_light_neighbors);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    try testing.expectEqual(@as(u32, 0), result.total_face_count);
    try testing.expectEqual(@as(usize, 0), result.faces.len);
}

test "glass does not cull adjacent non-glass" {
    var chunk = makeEmptyChunk();
    chunk.blocks[chunkIndex(5, 5, 5)] = .stone;
    chunk.blocks[chunkIndex(6, 5, 5)] = .glass;

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_light_neighbors);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    try testing.expectEqual(@as(u32, 11), result.total_face_count);
}

test "glass-glass adjacency culls shared face" {
    var chunk = makeEmptyChunk();
    chunk.blocks[chunkIndex(5, 5, 5)] = .glass;
    chunk.blocks[chunkIndex(6, 5, 5)] = .glass;

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_light_neighbors);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    try testing.expectEqual(@as(u32, 10), result.total_face_count);
}

test "light count equals face count (1:1 mapping)" {
    var chunk = makeEmptyChunk();
    for (0..4) |x| {
        chunk.blocks[chunkIndex(x, 5, 5)] = .stone;
    }

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_light_neighbors);
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

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_light_neighbors);
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
    const fc = result.totalFaceCounts();
    var offset: usize = 0;
    for (0..6) |i| {
        const count = fc[i];
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

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_light_neighbors);
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

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_light_neighbors);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    const fc = result.totalFaceCounts();
    var offset: usize = 0;
    for (0..4) |i| {
        offset += fc[i];
    }
    var center_top: ?FaceData = null;
    for (offset..offset + fc[4]) |i| {
        const u = unpackFace(result.faces[i]);
        if (u.x == 5 and u.y == 5 and u.z == 5) {
            center_top = result.faces[i];
            break;
        }
    }

    const ao = unpackAo(center_top.?);
    // Center block's top face: no blocks above (y=6) → no occlusion
    for (ao) |level| {
        try testing.expectEqual(@as(u2, 0), level);
    }
}

test "AO: block in corner has maximum occlusion on enclosed corner" {
    var chunk = makeEmptyChunk();
    chunk.blocks[chunkIndex(5, 5, 5)] = .stone;
    chunk.blocks[chunkIndex(6, 5, 5)] = .stone;
    chunk.blocks[chunkIndex(5, 6, 5)] = .stone;
    chunk.blocks[chunkIndex(5, 5, 6)] = .stone;

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_light_neighbors);
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
