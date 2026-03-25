const std = @import("std");
const types = @import("../renderer/vulkan/types.zig");
const FaceData = types.FaceData;
const LightEntry = types.LightEntry;
const LightMapMod = @import("LightMap.zig");
const LightMap = LightMapMod.LightMap;
const tracy = @import("../platform/tracy.zig");
pub const BlockModelLoader = @import("BlockModelLoader.zig");
pub const BlockModelRegistry = BlockModelLoader.BlockModelRegistry;
pub const BlockState = @import("BlockState.zig");

pub const CHUNK_SIZE = 32;
pub const BLOCKS_PER_CHUNK = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE;
pub const MAX_FACES_PER_CHUNK = BLOCKS_PER_CHUNK * 6;

pub const FaceVertex = struct { px: f32, py: f32, pz: f32, u: f32, v: f32 };
pub const face_vertices = [6][4]FaceVertex{
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

/// All 27 offsets in a 3x3x3 cube (including self at index 13).
pub const neighbor_offsets_27: [27][3]i32 = blk: {
    var result: [27][3]i32 = undefined;
    var i: usize = 0;
    for ([_]i32{ -1, 0, 1 }) |dx| {
        for ([_]i32{ -1, 0, 1 }) |dy| {
            for ([_]i32{ -1, 0, 1 }) |dz| {
                result[i] = .{ dx, dy, dz };
                i += 1;
            }
        }
    }
    break :blk result;
};

/// Bit index for a neighbor at offset (dx,dy,dz) in the 27-chunk bitmask.
pub fn neighborBitIndex(dx: i32, dy: i32, dz: i32) u5 {
    return @intCast(@as(u32, @intCast(dx + 1)) * 9 + @as(u32, @intCast(dy + 1)) * 3 + @as(u32, @intCast(dz + 1)));
}

// --- Water face models (same as cube faces but top at 14/16) ---
// Models 6-11 mirror faces 0-5 with py clamped to WATER_HEIGHT.
pub const WATER_HEIGHT: f32 = 14.0 / 16.0;
pub const water_face_vertices: [6][4]FaceVertex = blk: {
    var result = face_vertices;
    for (&result) |*face| {
        for (face) |*vert| {
            if (vert.py == 1.0) vert.py = WATER_HEIGHT;
        }
    }
    break :blk result;
};

// --- Extra quad models for shaped blocks (slabs, stairs) ---
// Models 0-5 are standard full-cube faces from face_vertices.
// Models 6-11 are water faces from water_face_vertices.
pub const WATER_MODEL_BASE: u9 = 6;
pub const EXTRA_MODEL_BASE: u32 = 12;
// Models 6+ are partial quads for shaped blocks.
pub const ExtraQuadModel = struct {
    corners: [4][3]f32,
    uvs: [4][2]f32,
    normal: [3]f32,
};

/// Face definition for shaped blocks: which model to use and which face bucket it belongs to.
pub const ShapeFace = struct {
    model_index: u16, // index into combined model array (0-5 = standard, 6-11 = water, 12+ = extra)
    face_bucket: u3, // which direction bucket (0=+Z, 1=-Z, 2=-X, 3=+X, 4=+Y, 5=-Y)
    always_emit: bool, // true for internal faces (slab top at y=0.5, step risers)
    face_bitmap: u16, // 4x4 bitmap of THIS quad's coverage area on the face boundary
};

// --- Model registry (loaded at runtime from JSON) ---
var registry: ?*const BlockModelRegistry = null;

pub fn setRegistry(reg: *const BlockModelRegistry) void {
    registry = reg;
}

pub fn getRegistry() *const BlockModelRegistry {
    return registry.?;
}

pub fn totalModelCount() u32 {
    return getRegistry().totalModelCount();
}

/// Get the face list for a shaped block by StateId.
/// Returns slice of ShapeFace describing all quads to emit.
pub fn getShapeFaces(state: BlockState.StateId) []const ShapeFace {
    return getRegistry().state_shape_faces[state];
}

/// Get per-face texture indices for a shaped block by StateId.
pub fn getShapedTexIndices(state: BlockState.StateId) []const u8 {
    return getRegistry().state_face_tex_indices[state];
}

/// Get the 4x4 occlusion bitmap for a block on the given face.
/// Full opaque blocks = 0xFFFF. Solid shaped blocks use registry bitmaps.
/// Transparent/non-solid blocks = 0 (don't occlude).
pub fn getOcclusionBitmap(state: StateId, face: usize) u16 {
    if (state == 0) return 0; // air
    if (BlockState.isOpaque(state)) return 0xFFFF;
    if (BlockState.isSolidShaped(state)) {
        if (registry) |reg| {
            return reg.state_face_bitmaps[state][face];
        }
        return 0;
    }
    return 0;
}

/// Minecraft-style VoxelShape face culling: should this block's face be culled
/// given the neighbor block on that side?
/// Compares 4x4 bitmaps: cull if the neighbor covers every cell this block exposes.
/// face: 0=+Z, 1=-Z, 2=-X, 3=+X, 4=+Y, 5=-Y
pub fn shouldCullFace(state: StateId, face: usize, neighbor: StateId) bool {
    const neighbor_bmp = getOcclusionBitmap(neighbor, oppositeFace(face));
    if (neighbor_bmp == 0) return false;
    if (neighbor_bmp == 0xFFFF) return true;
    const this_bmp = getOcclusionBitmap(state, face);
    if (this_bmp == 0) return false;
    return (this_bmp & ~neighbor_bmp) == 0;
}

/// Per-quad face culling for shaped blocks: checks if the neighbor covers
/// this individual quad's area (using the quad's own face_bitmap).
pub fn shouldCullShapeFace(sf: ShapeFace, neighbor: StateId) bool {
    const neighbor_bmp = getOcclusionBitmap(neighbor, oppositeFace(sf.face_bucket));
    if (neighbor_bmp == 0) return false;
    if (neighbor_bmp == 0xFFFF) return true;
    if (sf.face_bitmap == 0) return false;
    return (sf.face_bitmap & ~neighbor_bmp) == 0;
}

/// Opposite face direction: 0<->1, 2<->3, 4<->5
pub fn oppositeFace(face: usize) usize {
    return face ^ 1;
}

pub const WorldType = enum(u8) {
    normal,
    debug,
};

pub const LAYER_COUNT = @import("BlockTypes.zig").LAYER_COUNT;
pub const RenderLayer = @import("BlockTypes.zig").RenderLayer;

// --- Core types ---

pub const StateId = BlockState.StateId;
pub const PaletteBlocks = @import("../allocators/PaletteStorage.zig").PaletteStorage(StateId, BLOCKS_PER_CHUNK);

pub const Chunk = struct {
    blocks: PaletteBlocks,
    mutex: std.Io.Mutex = .init,
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
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

    pub fn position(self: ChunkKey) [3]i32 {
        return .{
            self.cx * CHUNK_SIZE,
            self.cy * CHUNK_SIZE,
            self.cz * CHUNK_SIZE,
        };
    }

};

pub const ChunkMeshResult = struct {
    faces: []FaceData,
    layer_face_counts: [LAYER_COUNT][6]u32,
    total_face_count: u32,
    lights: []LightEntry,
    light_count: u32,

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

pub fn generateFlatChunk(chunk: *Chunk, key: ChunkKey) void {
    chunk.blocks.fillUniform(BlockState.defaultState(.air));

    for (0..CHUNK_SIZE) |by| {
        const wy: i32 = key.cy * CHUNK_SIZE + @as(i32, @intCast(by));

        const state: StateId = if (wy == 0)
            BlockState.defaultState(.grass_block)
        else if (wy >= -2 and wy <= -1)
            BlockState.defaultState(.dirt)
        else if (wy >= -7 and wy <= -3)
            BlockState.defaultState(.stone)
        else
            BlockState.defaultState(.air);

        if (state == BlockState.defaultState(.air)) continue;

        for (0..CHUNK_SIZE) |bz| {
            for (0..CHUNK_SIZE) |bx| {
                chunk.blocks.set(chunkIndex(bx, by, bz), state);
            }
        }
    }
}

pub fn generateDebugChunk(chunk: *Chunk, key: ChunkKey) void {
    chunk.blocks.fillUniform(BlockState.defaultState(.air));

    const COLS = 6;
    const SPACING = 2;

    if (key.cy == -1) {
        for (0..CHUNK_SIZE) |bz| {
            for (0..CHUNK_SIZE) |bx| {
                chunk.blocks.set(chunkIndex(bx, CHUNK_SIZE - 1, bz), BlockState.defaultState(.stone));
            }
        }
        return;
    }

    if (key.cy != 0) return;

    for (0..BlockState.TOTAL_STATES) |si| {
        if (si == 0) continue;
        const idx = si - 1;
        const col = idx % COLS;
        const row = idx / COLS;

        const wx: i32 = @intCast(col * SPACING);
        const wz: i32 = @intCast(row * SPACING);

        const lx = wx - key.cx * CHUNK_SIZE;
        const lz = wz - key.cz * CHUNK_SIZE;

        if (lx >= 0 and lx < CHUNK_SIZE and lz >= 0 and lz < CHUNK_SIZE) {
            chunk.blocks.set(chunkIndex(@intCast(lx), 0, @intCast(lz)), @intCast(si));
        }
    }
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

const padded_face_deltas = computePaddedFaceDeltas();

fn computePaddedFaceDeltas() [6]i32 {
    var result: [6]i32 = undefined;
    for (0..6) |f| {
        const fno = face_neighbor_offsets[f];
        result[f] = fno[1] * @as(i32, PADDED_SIZE * PADDED_SIZE) + fno[2] * @as(i32, PADDED_SIZE) + fno[0];
    }
    return result;
}

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

const TrilinearSample = struct {
    dx: i8,
    dy: i8,
    dz: i8,
    delta: i32, // flat padded index offset (for block state lookups)
    weight: u16,
};

const trilinear_light_samples = computeTrilinearLightSamples();

fn computeTrilinearLightSamples() [6][4][4]TrilinearSample {
    @setEvalBranchQuota(10000);
    var result: [6][4][4]TrilinearSample = undefined;
    for (0..6) |face| {
        const normal = face_neighbor_offsets[face];
        for (0..4) |corner| {
            const vert = face_vertices[face][corner];

            const light_pos = [3]f32{
                vert.px + @as(f32, @floatFromInt(normal[0])) * 0.5 - 0.5,
                vert.py + @as(f32, @floatFromInt(normal[1])) * 0.5 - 0.5,
                vert.pz + @as(f32, @floatFromInt(normal[2])) * 0.5 - 0.5,
            };
            const start = [3]i32{
                @intFromFloat(@floor(light_pos[0])),
                @intFromFloat(@floor(light_pos[1])),
                @intFromFloat(@floor(light_pos[2])),
            };
            const interp = [3]f32{
                light_pos[0] - @as(f32, @floatFromInt(start[0])),
                light_pos[1] - @as(f32, @floatFromInt(start[1])),
                light_pos[2] - @as(f32, @floatFromInt(start[2])),
            };

            var si: usize = 0;
            for (0..2) |dxi| {
                const dx: i32 = @intCast(dxi);
                for (0..2) |dyi| {
                    const dy: i32 = @intCast(dyi);
                    for (0..2) |dzi| {
                        const dz: i32 = @intCast(dzi);
                        var w: f32 = 1.0;
                        w *= if (dx == 0) (1.0 - interp[0]) else interp[0];
                        w *= if (dy == 0) (1.0 - interp[1]) else interp[1];
                        w *= if (dz == 0) (1.0 - interp[2]) else interp[2];

                        const iw: u16 = @intFromFloat(w * 256.0);
                        if (iw > 0) {
                            const sx = start[0] + dx;
                            const sy = start[1] + dy;
                            const sz = start[2] + dz;
                            result[face][corner][si] = .{
                                .dx = @intCast(sx),
                                .dy = @intCast(sy),
                                .dz = @intCast(sz),
                                .delta = sy * @as(i32, PADDED_SIZE * PADDED_SIZE) + sz * @as(i32, PADDED_SIZE) + sx,
                                .weight = iw,
                            };
                            si += 1;
                        }
                    }
                }
            }
            while (si < 4) : (si += 1) {
                result[face][corner][si] = .{ .dx = 0, .dy = 0, .dz = 0, .delta = 0, .weight = 0 };
            }
        }
    }
    return result;
}

/// Build a 34^3 padded state array: center 32^3 from chunk, 1-block border from neighbors, air (0) elsewhere.
fn buildPaddedStates(padded: *[PADDED_BLOCKS]StateId, chunk: *const Chunk, neighbors: [6]?*const Chunk) void {
    @memset(padded, 0);

    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |z| {
            const dst = padded[paddedIndex(1, y + 1, z + 1)..][0..CHUNK_SIZE];
            chunk.blocks.getRange(dst, @intCast(chunkIndex(0, y, z)));
        }
    }

    if (neighbors[0]) |n| {
        for (0..CHUNK_SIZE) |y| {
            const dst = padded[paddedIndex(1, y + 1, PADDED_SIZE - 1)..][0..CHUNK_SIZE];
            n.blocks.getRange(dst, @intCast(chunkIndex(0, y, 0)));
        }
    }
    if (neighbors[1]) |n| {
        for (0..CHUNK_SIZE) |y| {
            const dst = padded[paddedIndex(1, y + 1, 0)..][0..CHUNK_SIZE];
            n.blocks.getRange(dst, @intCast(chunkIndex(0, y, CHUNK_SIZE - 1)));
        }
    }
    if (neighbors[2]) |n| {
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |z| {
                padded[paddedIndex(0, y + 1, z + 1)] = n.blocks.get(chunkIndex(CHUNK_SIZE - 1, y, z));
            }
        }
    }
    if (neighbors[3]) |n| {
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |z| {
                padded[paddedIndex(PADDED_SIZE - 1, y + 1, z + 1)] = n.blocks.get(chunkIndex(0, y, z));
            }
        }
    }
    if (neighbors[4]) |n| {
        for (0..CHUNK_SIZE) |z| {
            const dst = padded[paddedIndex(1, PADDED_SIZE - 1, z + 1)..][0..CHUNK_SIZE];
            n.blocks.getRange(dst, @intCast(chunkIndex(0, 0, z)));
        }
    }
    if (neighbors[5]) |n| {
        for (0..CHUNK_SIZE) |z| {
            const dst = padded[paddedIndex(1, 0, z + 1)..][0..CHUNK_SIZE];
            n.blocks.getRange(dst, @intCast(chunkIndex(0, CHUNK_SIZE - 1, z)));
        }
    }

    // Fill 12 edges and 8 corners by clamping to nearest face-filled position.
    const S = PADDED_SIZE - 1;
    const bounds = [2]usize{ 0, S };
    for (bounds) |py| {
        for (bounds) |pz| {
            const cy = if (py == 0) @as(usize, 1) else S - 1;
            const cz = if (pz == 0) @as(usize, 1) else S - 1;
            for (1..S) |px| {
                padded[paddedIndex(px, py, pz)] = padded[paddedIndex(px, cy, cz)];
            }
        }
    }
    for (bounds) |px| {
        for (bounds) |pz| {
            const cx = if (px == 0) @as(usize, 1) else S - 1;
            const cz = if (pz == 0) @as(usize, 1) else S - 1;
            for (1..S) |py| {
                padded[paddedIndex(px, py, pz)] = padded[paddedIndex(cx, py, cz)];
            }
        }
    }
    for (bounds) |px| {
        for (bounds) |py| {
            const cx = if (px == 0) @as(usize, 1) else S - 1;
            const cy = if (py == 0) @as(usize, 1) else S - 1;
            for (1..S) |pz| {
                padded[paddedIndex(px, py, pz)] = padded[paddedIndex(cx, cy, pz)];
            }
        }
    }
    for (bounds) |px| {
        for (bounds) |py| {
            for (bounds) |pz| {
                const cx = if (px == 0) @as(usize, 1) else S - 1;
                const cy = if (py == 0) @as(usize, 1) else S - 1;
                const cz = if (pz == 0) @as(usize, 1) else S - 1;
                padded[paddedIndex(px, py, pz)] = padded[paddedIndex(cx, cy, cz)];
            }
        }
    }
}

/// Visibility bitmask arrays for sparse mesh iteration.
/// Each u32 packs one bit per X position in a (Y, Z) column.
const ColumnMask = [CHUNK_SIZE][CHUNK_SIZE]u32;

const VisibilityMasks = struct {
    /// Bit set if block at (x,y,z) is non-air
    has_block: ColumnMask,
    /// Bit set if block is a simple full cube (not shaped, not self-culling)
    is_simple: ColumnMask,
    /// Per-face: bit set if the neighbor in that direction is fully opaque
    neighbor_opaque: [6]ColumnMask,
};

fn buildVisibilityMasks(padded: *const [PADDED_BLOCKS]StateId) VisibilityMasks {
    var masks: VisibilityMasks = undefined;

    // First pass: build has_block, is_simple, and opaque_col (for X-axis face shifts)
    var opaque_col: ColumnMask = undefined;
    for (0..CHUNK_SIZE) |by| {
        for (0..CHUNK_SIZE) |bz| {
            var block_bits: u32 = 0;
            var simple_bits: u32 = 0;
            var opaque_bits: u32 = 0;
            for (0..CHUNK_SIZE) |bx| {
                const state = padded[paddedIndex(bx + 1, by + 1, bz + 1)];
                const bit: u32 = @as(u32, 1) << @intCast(bx);
                if (state != 0) {
                    block_bits |= bit;
                    if (!BlockState.isShaped(state) and !BlockState.cullsSelf(state)) {
                        simple_bits |= bit;
                    }
                }
                if (BlockState.isOpaque(state)) {
                    opaque_bits |= bit;
                }
            }
            masks.has_block[by][bz] = block_bits;
            masks.is_simple[by][bz] = simple_bits;
            opaque_col[by][bz] = opaque_bits;
        }
    }

    // Build neighbor_opaque for each face.
    // Face 2 (-X): neighbor at bx-1. Shift opaque left, fill bit 0 from padded x=0.
    // Face 3 (+X): neighbor at bx+1. Shift opaque right, fill bit 31 from padded x=33.
    for (0..CHUNK_SIZE) |by| {
        for (0..CHUNK_SIZE) |bz| {
            // -X boundary bit (padded x=0)
            const lo_bit: u32 = @intFromBool(BlockState.isOpaque(padded[paddedIndex(0, by + 1, bz + 1)]));
            masks.neighbor_opaque[2][by][bz] = (opaque_col[by][bz] << 1) | lo_bit;
            // +X boundary bit (padded x=33)
            const hi_bit: u32 = @intFromBool(BlockState.isOpaque(padded[paddedIndex(PADDED_SIZE - 1, by + 1, bz + 1)]));
            masks.neighbor_opaque[3][by][bz] = (opaque_col[by][bz] >> 1) | (hi_bit << (CHUNK_SIZE - 1));
        }
    }

    // Face 0 (+Z): neighbor at bz+1. Use opaque_col[by][bz+1], boundary from padded z=33.
    // Face 1 (-Z): neighbor at bz-1. Use opaque_col[by][bz-1], boundary from padded z=0.
    for (0..CHUNK_SIZE) |by| {
        for (0..CHUNK_SIZE) |bz| {
            if (bz < CHUNK_SIZE - 1) {
                masks.neighbor_opaque[0][by][bz] = opaque_col[by][bz + 1];
            } else {
                // bz=31: neighbor is in +Z padded boundary (z=33)
                var bits: u32 = 0;
                for (0..CHUNK_SIZE) |bx| {
                    if (BlockState.isOpaque(padded[paddedIndex(bx + 1, by + 1, PADDED_SIZE - 1)])) {
                        bits |= @as(u32, 1) << @intCast(bx);
                    }
                }
                masks.neighbor_opaque[0][by][bz] = bits;
            }
            if (bz > 0) {
                masks.neighbor_opaque[1][by][bz] = opaque_col[by][bz - 1];
            } else {
                var bits: u32 = 0;
                for (0..CHUNK_SIZE) |bx| {
                    if (BlockState.isOpaque(padded[paddedIndex(bx + 1, by + 1, 0)])) {
                        bits |= @as(u32, 1) << @intCast(bx);
                    }
                }
                masks.neighbor_opaque[1][by][bz] = bits;
            }
        }
    }

    // Face 4 (+Y): neighbor at by+1. Use opaque_col[by+1][bz], boundary from padded y=33.
    // Face 5 (-Y): neighbor at by-1. Use opaque_col[by-1][bz], boundary from padded y=0.
    for (0..CHUNK_SIZE) |by| {
        for (0..CHUNK_SIZE) |bz| {
            if (by < CHUNK_SIZE - 1) {
                masks.neighbor_opaque[4][by][bz] = opaque_col[by + 1][bz];
            } else {
                var bits: u32 = 0;
                for (0..CHUNK_SIZE) |bx| {
                    if (BlockState.isOpaque(padded[paddedIndex(bx + 1, PADDED_SIZE - 1, bz + 1)])) {
                        bits |= @as(u32, 1) << @intCast(bx);
                    }
                }
                masks.neighbor_opaque[4][by][bz] = bits;
            }
            if (by > 0) {
                masks.neighbor_opaque[5][by][bz] = opaque_col[by - 1][bz];
            } else {
                var bits: u32 = 0;
                for (0..CHUNK_SIZE) |bx| {
                    if (BlockState.isOpaque(padded[paddedIndex(bx + 1, 0, bz + 1)])) {
                        bits |= @as(u32, 1) << @intCast(bx);
                    }
                }
                masks.neighbor_opaque[5][by][bz] = bits;
            }
        }
    }

    return masks;
}

/// SIMD light vector: [br, bg, bb, _, sr, sg, sb, _]
/// Block light RGB in [0..2], sky light (replicated to RGB) in [4..6].
/// u16 to avoid overflow in directional darkening arithmetic.
const LightVector = @Vector(8, u16);

const LIGHT_ZERO: LightVector = @splat(0);

fn lightVectorFrom(block: [3]u8, sky: u8) LightVector {
    return .{ block[0], block[1], block[2], 0, sky, sky, sky, 0 };
}

fn packLight(v: LightVector) u32 {
    return (@as(u32, @intCast(v[4])) >> 3) << 0 | // sky r
        (@as(u32, @intCast(v[5])) >> 3) << 5 | // sky g
        (@as(u32, @intCast(v[6])) >> 3) << 10 | // sky b
        (@as(u32, @intCast(v[0])) >> 3) << 15 | // block r
        (@as(u32, @intCast(v[1])) >> 3) << 20 | // block g
        (@as(u32, @intCast(v[2])) >> 3) << 25; // block b
}

fn lightBlockBrightness(v: LightVector) u8 {
    return @max(@as(u8, @intCast(v[0])), @max(@as(u8, @intCast(v[1])), @as(u8, @intCast(v[2]))));
}

/// Read light at a padded-space position, like Cubyz's getLightAt.
/// Returns a LightVector for SIMD operations. Interior positions read from
/// the chunk's own LightMap (locked by caller). Border positions read directly
/// from the neighbor's LightMap via RCU-safe atomic get(). Returns LIGHT_ZERO
/// if the neighbor doesn't exist.
inline fn getLightAt(
    px: i32,
    py: i32,
    pz: i32,
    light_map: ?*const LightMap,
    neighbor_lights: [6]?*const LightMap,
) LightVector {
    const S = @as(i32, CHUNK_SIZE);
    const cx = px - 1;
    const cy = py - 1;
    const cz = pz - 1;

    if (cx >= 0 and cx < S and cy >= 0 and cy < S and cz >= 0 and cz < S) {
        const lm = light_map orelse return LIGHT_ZERO;
        const ci = chunkIndex(@intCast(cx), @intCast(cy), @intCast(cz));
        return lightVectorFrom(lm.block_light.get(ci), lm.sky_light.get(ci));
    }

    const face: ?usize = if (cx < 0 and cy >= 0 and cy < S and cz >= 0 and cz < S)
        @as(usize, 2)
    else if (cx >= S and cy >= 0 and cy < S and cz >= 0 and cz < S)
        @as(usize, 3)
    else if (cy < 0 and cx >= 0 and cx < S and cz >= 0 and cz < S)
        @as(usize, 5)
    else if (cy >= S and cx >= 0 and cx < S and cz >= 0 and cz < S)
        @as(usize, 4)
    else if (cz < 0 and cx >= 0 and cx < S and cy >= 0 and cy < S)
        @as(usize, 1)
    else if (cz >= S and cx >= 0 and cx < S and cy >= 0 and cy < S)
        @as(usize, 0)
    else
        null;

    const f = face orelse {
        const lm = light_map orelse return LIGHT_ZERO;
        const ci = chunkIndex(
            @intCast(std.math.clamp(cx, 0, S - 1)),
            @intCast(std.math.clamp(cy, 0, S - 1)),
            @intCast(std.math.clamp(cz, 0, S - 1)),
        );
        return lightVectorFrom(lm.block_light.get(ci), lm.sky_light.get(ci));
    };

    const lm = neighbor_lights[f] orelse return LIGHT_ZERO;
    const lx: usize = @intCast(if (f == 2) S - 1 else if (f == 3) @as(i32, 0) else cx);
    const ly: usize = @intCast(if (f == 5) S - 1 else if (f == 4) @as(i32, 0) else cy);
    const lz: usize = @intCast(if (f == 1) S - 1 else if (f == 0) @as(i32, 0) else cz);
    const ci = chunkIndex(lx, ly, lz);
    return lightVectorFrom(lm.block_light.get(ci), lm.sky_light.get(ci));
}

fn sampleTrilinearLight(
    bx: usize,
    by: usize,
    bz: usize,
    face: usize,
    corner: usize,
    padded: *const [PADDED_BLOCKS]StateId,
    light_map: ?*const LightMap,
    neighbor_lights: [6]?*const LightMap,
) LightVector {
    const samples = trilinear_light_samples[face][corner];
    const face_normal = face_neighbor_offsets[face];
    const base: i32 = @intCast(paddedIndex(bx + 1, by + 1, bz + 1));
    const base_px: i32 = @intCast(bx + 1);
    const base_py: i32 = @intCast(by + 1);
    const base_pz: i32 = @intCast(bz + 1);
    var light_sum: @Vector(8, u32) = @splat(0);
    var total_weight: u32 = 0;

    for (0..4) |s| {
        const sample = samples[s];
        if (sample.weight == 0) continue;
        const sample_idx: usize = @intCast(base + sample.delta);
        if (BlockState.isOpaque(padded[sample_idx])) continue;
        const w: u32 = sample.weight;
        total_weight += w;

        const spx = base_px + sample.dx;
        const spy = base_py + sample.dy;
        const spz = base_pz + sample.dz;
        var light_val = getLightAt(spx, spy, spz, light_map, neighbor_lights);

        // Directional darkening — single SIMD operation on all channels
        const next_val = getLightAt(spx + face_normal[0], spy + face_normal[1], spz + face_normal[2], light_map, neighbor_lights);
        const diff = @min(@as(LightVector, @splat(8)), light_val -| next_val);
        light_val -|= diff * @as(LightVector, @splat(5)) / @as(LightVector, @splat(2));

        const wide: @Vector(8, u32) = light_val;
        light_sum += wide * @as(@Vector(8, u32), @splat(w));
    }

    if (total_weight == 0) {
        return getLightAt(base_px + face_normal[0], base_py + face_normal[1], base_pz + face_normal[2], light_map, neighbor_lights);
    }

    return @intCast(light_sum / @as(@Vector(8, u32), @splat(total_weight)));
}

pub fn isFullyHidden(chunk: *const Chunk, neighbors: [6]?*const Chunk) bool {
    for (chunk.blocks.palette[0..chunk.blocks.palette_len]) |s| {
        if (!BlockState.isOpaque(s)) return false;
    }

    for (0..6) |face| {
        const n = neighbors[face] orelse return false;

        switch (face) {
            0 => {
                for (0..CHUNK_SIZE) |y| {
                    for (0..CHUNK_SIZE) |x| {
                        if (!BlockState.isOpaque(n.blocks.get(chunkIndex(x, y, 0)))) return false;
                    }
                }
            },
            1 => {
                for (0..CHUNK_SIZE) |y| {
                    for (0..CHUNK_SIZE) |x| {
                        if (!BlockState.isOpaque(n.blocks.get(chunkIndex(x, y, CHUNK_SIZE - 1)))) return false;
                    }
                }
            },
            2 => {
                for (0..CHUNK_SIZE) |y| {
                    for (0..CHUNK_SIZE) |z| {
                        if (!BlockState.isOpaque(n.blocks.get(chunkIndex(CHUNK_SIZE - 1, y, z)))) return false;
                    }
                }
            },
            3 => {
                for (0..CHUNK_SIZE) |y| {
                    for (0..CHUNK_SIZE) |z| {
                        if (!BlockState.isOpaque(n.blocks.get(chunkIndex(0, y, z)))) return false;
                    }
                }
            },
            4 => {
                for (0..CHUNK_SIZE) |z| {
                    for (0..CHUNK_SIZE) |x| {
                        if (!BlockState.isOpaque(n.blocks.get(chunkIndex(x, 0, z)))) return false;
                    }
                }
            },
            5 => {
                for (0..CHUNK_SIZE) |z| {
                    for (0..CHUNK_SIZE) |x| {
                        if (!BlockState.isOpaque(n.blocks.get(chunkIndex(x, CHUNK_SIZE - 1, z)))) return false;
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

    var padded: [PADDED_BLOCKS]StateId = undefined;
    buildPaddedStates(&padded, chunk, neighbors);
    const vis = buildVisibilityMasks(&padded);

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
            var remaining = vis.has_block[by][bz];
            while (remaining != 0) {
                const bx: usize = @intCast(@ctz(remaining));
                remaining &= remaining - 1; // clear lowest set bit

                const base: i32 = @intCast(paddedIndex(bx + 1, by + 1, bz + 1));
                const state_id = padded[@intCast(base)];
                const layer = @intFromEnum(BlockState.renderLayer(state_id));

                if (BlockState.isShaped(state_id)) {
                    const shape_faces = getShapeFaces(state_id);
                    const tex_indices = getShapedTexIndices(state_id);
                    for (shape_faces, 0..) |sf, sf_idx| {
                        if (!sf.always_emit) {
                            const neighbor = padded[@intCast(base + padded_face_deltas[sf.face_bucket])];
                            if (shouldCullShapeFace(sf, neighbor)) continue;
                        }
                        const face: usize = sf.face_bucket;
                        var corner_packed: [4]u32 = undefined;
                        var corner_block_brightness: [4]u8 = .{ 0, 0, 0, 0 };
                        for (0..4) |corner| {
                            const result = sampleTrilinearLight(bx, by, bz, face, corner, &padded, light_map, neighbor_lights);
                            corner_packed[corner] = packLight(result);
                            corner_block_brightness[corner] = lightBlockBrightness(result);
                        }
                        var ao: [4]u2 = undefined;
                        for (0..4) |corner| {
                            const deltas = padded_ao_deltas[face][corner];
                            const s1 = BlockState.isOpaque(padded[@intCast(base + deltas[0])]);
                            const s2 = BlockState.isOpaque(padded[@intCast(base + deltas[1])]);
                            const diag = if (s1 and s2)
                                true
                            else
                                BlockState.isOpaque(padded[@intCast(base + deltas[2])]);
                            const raw_ao: u3 = @as(u3, @intFromBool(s1)) + @intFromBool(s2) + @intFromBool(diag);
                            const reduction: u3 = @intCast(@min(@as(u32, 3), @as(u32, corner_block_brightness[corner]) / 64));
                            ao[corner] = @intCast(raw_ao -| reduction);
                        }
                        const shaped_tex: u8 = tex_indices[sf_idx];
                        const face_data = types.packFaceData(
                            @intCast(bx),
                            @intCast(by),
                            @intCast(bz),
                            shaped_tex,
                            sf.model_index,
                            ao,
                        );
                        try layer_faces[layer][face].append(allocator, face_data);
                        try layer_lights[layer][face].append(allocator, .{ .corners = corner_packed });
                    }
                    continue;
                }

                const emits = BlockState.emittedLight(state_id);
                const is_emitter = emits[0] > 0 or emits[1] > 0 or emits[2] > 0;

                const is_water = BlockState.getBlock(state_id) == .water;
                const water_lowered = is_water and
                    BlockState.getBlock(padded[@intCast(base + padded_face_deltas[4])]) != .water;

                const bx_bit: u32 = @as(u32, 1) << @intCast(bx);
                for (0..6) |face| {
                    // Fast cull: if neighbor is fully opaque, skip without shouldCullFace
                    if (vis.neighbor_opaque[face][by][bz] & bx_bit != 0) {
                        // Simple blocks with opaque neighbors are always culled
                        if (vis.is_simple[by][bz] & bx_bit != 0) continue;
                    }

                    const neighbor = padded[@intCast(base + padded_face_deltas[face])];
                    if (shouldCullFace(state_id, face, neighbor)) continue;
                    if (neighbor == state_id and BlockState.cullsSelf(state_id)) continue;

                    const tex = BlockState.blockTexIndices(state_id);
                    const tex_index: u8 = @intCast(if (face == 4 or face == 5) tex.top else tex.side);

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
                        for (0..4) |corner| {
                            const result = sampleTrilinearLight(bx, by, bz, face, corner, &padded, light_map, neighbor_lights);
                            corner_packed[corner] = packLight(result);
                            corner_block_brightness[corner] = lightBlockBrightness(result);
                        }
                    }

                    var ao: [4]u2 = undefined;
                    if (is_emitter) {
                        ao = .{ 0, 0, 0, 0 };
                    } else {
                        for (0..4) |corner| {
                            const deltas = padded_ao_deltas[face][corner];
                            const s1 = BlockState.isOpaque(padded[@intCast(base + deltas[0])]);
                            const s2 = BlockState.isOpaque(padded[@intCast(base + deltas[1])]);
                            const diag = if (s1 and s2)
                                true
                            else
                                BlockState.isOpaque(padded[@intCast(base + deltas[2])]);
                            const raw_ao: u3 = @as(u3, @intFromBool(s1)) + @intFromBool(s2) + @intFromBool(diag);

                            const reduction: u3 = @intCast(@min(@as(u32, 3), @as(u32, corner_block_brightness[corner]) / 64));
                            ao[corner] = @intCast(raw_ao -| reduction);
                        }
                    }

                    const model_index: u16 = if (water_lowered)
                        WATER_MODEL_BASE + @as(u9, @intCast(face))
                    else
                        @intCast(face);
                    const face_data = types.packFaceData(
                        @intCast(bx),
                        @intCast(by),
                        @intCast(bz),
                        tex_index,
                        model_index,
                        ao,
                    );

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

    var padded: [PADDED_BLOCKS]StateId = undefined;
    buildPaddedStates(&padded, chunk, neighbors);
    const vis = buildVisibilityMasks(&padded);

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
            var remaining = vis.has_block[by][bz];
            while (remaining != 0) {
                const bx: usize = @intCast(@ctz(remaining));
                remaining &= remaining - 1;

                const base: i32 = @intCast(paddedIndex(bx + 1, by + 1, bz + 1));
                const state_id = padded[@intCast(base)];
                const layer = @intFromEnum(BlockState.renderLayer(state_id));

                if (BlockState.isShaped(state_id)) {
                    const shape_faces = getShapeFaces(state_id);
                    for (shape_faces) |sf| {
                        if (!sf.always_emit) {
                            const neighbor = padded[@intCast(base + padded_face_deltas[sf.face_bucket])];
                            if (shouldCullShapeFace(sf, neighbor)) continue;
                        }
                        const face: usize = sf.face_bucket;
                        var corner_packed: [4]u32 = undefined;
                        for (0..4) |corner| {
                            const result = sampleTrilinearLight(bx, by, bz, face, corner, &padded, light_map, neighbor_lights);
                            corner_packed[corner] = packLight(result);
                        }
                        try layer_lights[layer][face].append(allocator, .{ .corners = corner_packed });
                    }
                    continue;
                }

                const emits = BlockState.emittedLight(state_id);
                const is_emitter = emits[0] > 0 or emits[1] > 0 or emits[2] > 0;

                const bx_bit: u32 = @as(u32, 1) << @intCast(bx);
                for (0..6) |face| {
                    if (vis.neighbor_opaque[face][by][bz] & bx_bit != 0) {
                        if (vis.is_simple[by][bz] & bx_bit != 0) continue;
                    }

                    const neighbor = padded[@intCast(base + padded_face_deltas[face])];
                    if (shouldCullFace(state_id, face, neighbor)) continue;
                    if (neighbor == state_id and BlockState.cullsSelf(state_id)) continue;

                    var corner_packed: [4]u32 = undefined;

                    if (is_emitter) {
                        const br5: u32 = @as(u32, emits[0]) >> 3;
                        const bg5: u32 = @as(u32, emits[1]) >> 3;
                        const bb5: u32 = @as(u32, emits[2]) >> 3;
                        const emit_packed: u32 = (31 << 0) | (31 << 5) | (31 << 10) | (br5 << 15) | (bg5 << 20) | (bb5 << 25);
                        corner_packed = .{ emit_packed, emit_packed, emit_packed, emit_packed };
                    } else {
                        for (0..4) |corner| {
                            const result = sampleTrilinearLight(bx, by, bz, face, corner, &padded, light_map, neighbor_lights);
                            corner_packed[corner] = packLight(result);
                        }
                    }

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

pub fn affectedChunks(wx: i32, wy: i32, wz: i32) AffectedChunks {
    const cs: i32 = CHUNK_SIZE;
    const base_cx = @divFloor(wx, cs);
    const base_cy = @divFloor(wy, cs);
    const base_cz = @divFloor(wz, cs);

    var result = AffectedChunks{
        .keys = std.mem.zeroes([7]ChunkKey),
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
    return .{ .blocks = PaletteBlocks.init(testing.allocator) };
}

const no_neighbors: [6]?*const Chunk = .{ null, null, null, null, null, null };
const no_neighbor_lights: [6]?*const LightMap = .{ null, null, null, null, null, null };
const no_light_neighbors: [6]?*const LightMap = .{ null, null, null, null, null, null };

test "single block in air produces 6 faces" {
    var chunk = makeEmptyChunk();
    defer chunk.blocks.deinit();
    chunk.blocks.set(chunkIndex(5, 5, 5), BlockState.defaultState(.stone));

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_neighbor_lights);
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
    defer chunk.blocks.deinit();
    chunk.blocks.set(chunkIndex(5, 5, 5), BlockState.defaultState(.stone));
    chunk.blocks.set(chunkIndex(6, 5, 5), BlockState.defaultState(.stone));

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_neighbor_lights);
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
    defer chunk.blocks.deinit();
    for (3..7) |x| {
        for (3..6) |y| {
            chunk.blocks.set(chunkIndex(x, y, 4), BlockState.defaultState(.dirt));
        }
    }

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_neighbor_lights);
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
    defer chunk.blocks.deinit();
    chunk.blocks.set(chunkIndex(10, 10, 10), BlockState.defaultState(.grass_block));

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_neighbor_lights);
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
    defer chunk0.blocks.deinit();
    var chunk1 = makeEmptyChunk();
    defer chunk1.blocks.deinit();
    chunk0.blocks.set(chunkIndex(CHUNK_SIZE - 1, 5, 5), BlockState.defaultState(.stone));
    chunk1.blocks.set(chunkIndex(0, 5, 5), BlockState.defaultState(.stone));

    var neighbors0 = no_neighbors;
    neighbors0[3] = &chunk1;
    var neighbors1 = no_neighbors;
    neighbors1[2] = &chunk0;

    const result0 = try generateChunkMesh(testing.allocator, &chunk0, neighbors0, null, no_neighbor_lights);
    defer testing.allocator.free(result0.faces);
    defer testing.allocator.free(result0.lights);

    const result1 = try generateChunkMesh(testing.allocator, &chunk1, neighbors1, null, no_neighbor_lights);
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
    var chunk = makeEmptyChunk();
    defer chunk.blocks.deinit();
    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_neighbor_lights);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    try testing.expectEqual(@as(u32, 0), result.total_face_count);
    try testing.expectEqual(@as(usize, 0), result.faces.len);
}

test "glass does not cull adjacent non-glass" {
    var chunk = makeEmptyChunk();
    defer chunk.blocks.deinit();
    chunk.blocks.set(chunkIndex(5, 5, 5), BlockState.defaultState(.stone));
    chunk.blocks.set(chunkIndex(6, 5, 5), BlockState.defaultState(.glass));

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_neighbor_lights);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    try testing.expectEqual(@as(u32, 11), result.total_face_count);
}

test "glass-glass adjacency culls shared face" {
    var chunk = makeEmptyChunk();
    defer chunk.blocks.deinit();
    chunk.blocks.set(chunkIndex(5, 5, 5), BlockState.defaultState(.glass));
    chunk.blocks.set(chunkIndex(6, 5, 5), BlockState.defaultState(.glass));

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_neighbor_lights);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    try testing.expectEqual(@as(u32, 10), result.total_face_count);
}

test "light count equals face count (1:1 mapping)" {
    var chunk = makeEmptyChunk();
    defer chunk.blocks.deinit();
    for (0..4) |x| {
        chunk.blocks.set(chunkIndex(x, 5, 5), BlockState.defaultState(.stone));
    }

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_neighbor_lights);
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
    defer chunk.blocks.deinit();
    chunk.blocks.set(chunkIndex(0, 0, 0), BlockState.defaultState(.stone));

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_neighbor_lights);
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
    defer chunk.blocks.deinit();
    chunk.blocks.set(chunkIndex(5, 5, 5), BlockState.defaultState(.stone));

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_neighbor_lights);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    for (result.faces) |face| {
        try testing.expectEqual([4]u2{ 0, 0, 0, 0 }, unpackAo(face));
    }
}

test "AO: block on flat surface has correct top face AO" {
    var chunk = makeEmptyChunk();
    defer chunk.blocks.deinit();
    for (4..7) |x| {
        for (4..7) |z| {
            chunk.blocks.set(chunkIndex(x, 5, z), BlockState.defaultState(.stone));
        }
    }

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_neighbor_lights);
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
    for (ao) |level| {
        try testing.expectEqual(@as(u2, 0), level);
    }
}

test "AO: block in corner has maximum occlusion on enclosed corner" {
    var chunk = makeEmptyChunk();
    defer chunk.blocks.deinit();
    chunk.blocks.set(chunkIndex(5, 5, 5), BlockState.defaultState(.stone));
    chunk.blocks.set(chunkIndex(6, 5, 5), BlockState.defaultState(.stone));
    chunk.blocks.set(chunkIndex(5, 6, 5), BlockState.defaultState(.stone));
    chunk.blocks.set(chunkIndex(5, 5, 6), BlockState.defaultState(.stone));

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_neighbor_lights);
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
    const result = affectedChunks(0, 16, 16);
    try testing.expect(result.count >= 2);
}

test "generateFlatChunk: grass at wy=0" {
    var chunk: Chunk = .{ .blocks = PaletteBlocks.init(testing.allocator) };
    defer chunk.blocks.deinit();
    generateFlatChunk(&chunk, .{ .cx = 0, .cy = 0, .cz = 0 });
    try testing.expectEqual(BlockState.defaultState(.grass_block), chunk.blocks.get(chunkIndex(0, 0, 0)));
    try testing.expectEqual(@as(StateId, 0), chunk.blocks.get(chunkIndex(0, 1, 0)));
}

test "oppositeFace: correct pairs" {
    try testing.expectEqual(@as(usize, 1), oppositeFace(0));
    try testing.expectEqual(@as(usize, 0), oppositeFace(1));
    try testing.expectEqual(@as(usize, 3), oppositeFace(2));
    try testing.expectEqual(@as(usize, 2), oppositeFace(3));
    try testing.expectEqual(@as(usize, 5), oppositeFace(4));
    try testing.expectEqual(@as(usize, 4), oppositeFace(5));
}

test "oppositeFace: double opposite is identity" {
    for (0..6) |f| {
        try testing.expectEqual(f, oppositeFace(oppositeFace(f)));
    }
}

test "getOcclusionBitmap: air is zero" {
    for (0..6) |f| {
        try testing.expectEqual(@as(u16, 0), getOcclusionBitmap(0, f));
    }
}

test "getOcclusionBitmap: opaque blocks are full" {
    const opaque_blocks = [_]StateId{
        BlockState.defaultState(.stone),
        BlockState.defaultState(.dirt),
        BlockState.defaultState(.grass_block),
        BlockState.defaultState(.cobblestone),
        BlockState.defaultState(.oak_planks),
        BlockState.defaultState(.bedrock),
    };
    for (opaque_blocks) |state| {
        for (0..6) |f| {
            try testing.expectEqual(@as(u16, 0xFFFF), getOcclusionBitmap(state, f));
        }
    }
}

test "getOcclusionBitmap: transparent blocks are zero" {
    try testing.expectEqual(@as(u16, 0), getOcclusionBitmap(BlockState.defaultState(.glass), 0));
    try testing.expectEqual(@as(u16, 0), getOcclusionBitmap(BlockState.defaultState(.water), 0));
    try testing.expectEqual(@as(u16, 0), getOcclusionBitmap(BlockState.defaultState(.oak_leaves), 0));
}

test "getOcclusionBitmap: non-solid shaped blocks are zero" {
    try testing.expectEqual(@as(u16, 0), getOcclusionBitmap(BlockState.defaultState(.torch), 0));
    try testing.expectEqual(@as(u16, 0), getOcclusionBitmap(BlockState.defaultState(.ladder), 0));
}

test "shouldCullFace: opaque next to air shows face" {
    try testing.expect(!shouldCullFace(BlockState.defaultState(.stone), 0, 0));
}

test "shouldCullFace: opaque next to opaque hides face" {
    const stone = BlockState.defaultState(.stone);
    try testing.expect(shouldCullFace(stone, 0, stone));
}

test "shouldCullFace: opaque next to glass shows face" {
    try testing.expect(!shouldCullFace(BlockState.defaultState(.stone), 0, BlockState.defaultState(.glass)));
}

test "shouldCullFace: glass next to opaque hides face" {
    try testing.expect(shouldCullFace(BlockState.defaultState(.glass), 0, BlockState.defaultState(.stone)));
}

test "shouldCullFace: glass next to partial shows face" {
    try testing.expect(!shouldCullFace(BlockState.defaultState(.glass), 0, BlockState.defaultState(.oak_slab)));
}

test "shouldCullFace: opaque next to slab shows face (no registry)" {
    try testing.expect(!shouldCullFace(BlockState.defaultState(.stone), 0, BlockState.defaultState(.oak_slab)));
}

test "shouldCullFace: slab next to torch shows face" {
    try testing.expect(!shouldCullFace(BlockState.defaultState(.oak_slab), 0, BlockState.defaultState(.torch)));
}

test "shouldCullFace: slab top face next to air shows" {
    try testing.expect(!shouldCullFace(BlockState.defaultState(.oak_slab), 4, 0));
}

test "bitmap culling logic: slab-vs-slab covers shared area" {
    const slab_side: u16 = 0x00FF;
    const full_face: u16 = 0xFFFF;

    try testing.expect((slab_side & ~full_face) == 0);
    try testing.expect((full_face & ~slab_side) != 0);
    try testing.expect((slab_side & ~slab_side) == 0);
    try testing.expect((slab_side & ~@as(u16, 0)) != 0);
}

test "bitmap culling logic: stairs partial faces" {
    const stairs_west: u16 = 0x33FF;
    const full_face: u16 = 0xFFFF;
    const slab_side: u16 = 0x00FF;

    try testing.expect((stairs_west & ~full_face) == 0);
    try testing.expect((full_face & ~stairs_west) != 0);
    try testing.expect((stairs_west & ~slab_side) != 0);
    try testing.expect((slab_side & ~stairs_west) == 0);
}

// ============================================================
// Benchmarks
// ============================================================

fn printBenchResult(comptime name: []const u8, samples: []const u64, face_count: ?u32) void {
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    var total_ns: u64 = 0;
    for (samples) |s| {
        total_ns += s;
        if (s < min_ns) min_ns = s;
        if (s > max_ns) max_ns = s;
    }
    const avg = total_ns / samples.len;
    if (face_count) |fc| {
        std.debug.print("\n  {s}: min={d}us avg={d}us max={d}us (n={d}) faces={d}\n", .{ name, min_ns / 1000, avg / 1000, max_ns / 1000, samples.len, fc });
    } else {
        std.debug.print("\n  {s}: min={d}us avg={d}us max={d}us (n={d})\n", .{ name, min_ns / 1000, avg / 1000, max_ns / 1000, samples.len });
    }
}

/// Bottom 16 layers stone, layer 16 dirt, layer 17 grass, rest air.
fn makeSurfaceChunk() Chunk {
    var chunk: Chunk = .{ .blocks = PaletteBlocks.init(testing.allocator) };
    for (0..CHUNK_SIZE) |x| {
        for (0..CHUNK_SIZE) |z| {
            for (0..16) |y| {
                chunk.blocks.set(chunkIndex(x, y, z), BlockState.defaultState(.stone));
            }
            chunk.blocks.set(chunkIndex(x, 16, z), BlockState.defaultState(.dirt));
            chunk.blocks.set(chunkIndex(x, 17, z), BlockState.defaultState(.grass_block));
        }
    }
    return chunk;
}

/// Alternating stone/air — worst-case face count.
fn makeCheckerboardChunk() Chunk {
    var chunk: Chunk = .{ .blocks = PaletteBlocks.init(testing.allocator) };
    for (0..CHUNK_SIZE) |x| {
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |z| {
                if ((x + y + z) % 2 == 0) {
                    chunk.blocks.set(chunkIndex(x, y, z), BlockState.defaultState(.stone));
                }
            }
        }
    }
    return chunk;
}

test "bench: generateChunkMesh surface (with AO)" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const ITERS = 10;
    var samples: [ITERS]u64 = undefined;
    var chunk = makeSurfaceChunk();
    defer chunk.blocks.deinit();
    var face_count: u32 = 0;

    for (&samples) |*sample| {
        const start = std.Io.Clock.now(.awake, io);
        const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_neighbor_lights);
        sample.* = @intCast(start.durationTo(std.Io.Clock.now(.awake, io)).nanoseconds);
        face_count = result.total_face_count;
        testing.allocator.free(result.faces);
        testing.allocator.free(result.lights);
    }

    printBenchResult("generateChunkMesh surface (with AO)", &samples, face_count);
}

test "bench: generateChunkMesh checkerboard (worst case)" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const ITERS = 10;
    var samples: [ITERS]u64 = undefined;
    var chunk = makeCheckerboardChunk();
    defer chunk.blocks.deinit();
    var face_count: u32 = 0;

    for (&samples) |*sample| {
        const start = std.Io.Clock.now(.awake, io);
        const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_neighbor_lights);
        sample.* = @intCast(start.durationTo(std.Io.Clock.now(.awake, io)).nanoseconds);
        face_count = result.total_face_count;
        testing.allocator.free(result.faces);
        testing.allocator.free(result.lights);
    }

    printBenchResult("generateChunkMesh checkerboard (worst case)", &samples, face_count);
}

test "bench: generateChunkMesh empty (baseline)" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const ITERS = 10;
    var samples: [ITERS]u64 = undefined;
    var chunk = makeEmptyChunk();
    defer chunk.blocks.deinit();

    for (&samples) |*sample| {
        const start = std.Io.Clock.now(.awake, io);
        const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_neighbor_lights);
        sample.* = @intCast(start.durationTo(std.Io.Clock.now(.awake, io)).nanoseconds);
        testing.allocator.free(result.faces);
        testing.allocator.free(result.lights);
    }

    printBenchResult("generateChunkMesh empty (baseline)", &samples, 0);
}
