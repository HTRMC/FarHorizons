const std = @import("std");
const types = @import("../renderer/vulkan/types.zig");
const FaceData = types.FaceData;
const LightEntry = types.LightEntry;
const LightMapMod = @import("LightMap.zig");
const LightMap = LightMapMod.LightMap;
const LightBorderSnapshot = LightMapMod.LightBorderSnapshot;
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

// --- Extra quad models for shaped blocks (slabs, stairs) ---
// Models 0-5 are standard full-cube faces from face_vertices.
// Models 6+ are partial quads for shaped blocks.
pub const ExtraQuadModel = struct {
    corners: [4][3]f32,
    uvs: [4][2]f32,
    normal: [3]f32,
};

/// Face definition for shaped blocks: which model to use and which face bucket it belongs to.
pub const ShapeFace = struct {
    model_index: u9, // index into combined model array (0-5 = standard, 6+ = extra)
    face_bucket: u3, // which direction bucket (0=+Z, 1=-Z, 2=-X, 3=+X, 4=+Y, 5=-Y)
    always_emit: bool, // true for internal faces (slab top at y=0.5, step risers)
};

// Helper to build a quad with 4 corners, UVs, and a normal
fn quad(c0: [3]f32, c1: [3]f32, c2: [3]f32, c3: [3]f32, uv0: [2]f32, uv1: [2]f32, uv2: [2]f32, uv3: [2]f32, normal: [3]f32) ExtraQuadModel {
    return .{ .corners = .{ c0, c1, c2, c3 }, .uvs = .{ uv0, uv1, uv2, uv3 }, .normal = normal };
}

pub const EXTRA_MODEL_COUNT = 30;

// Bottom slab: models 6-10
// 6: slab top (+Y at y=0.5)
// 7: slab +Z side (y: 0→0.5)
// 8: slab -Z side (y: 0→0.5)
// 9: slab -X side (y: 0→0.5)
// 10: slab +X side (y: 0→0.5)
//
// Top slab: models 11-15
// 11: slab bottom (-Y at y=0.5)
// 12: slab +Z side (y: 0.5→1)
// 13: slab -Z side (y: 0.5→1)
// 14: slab -X side (y: 0.5→1)
// 15: slab +X side (y: 0.5→1)
//
// Stairs south (step toward +Z, back at -Z): models 16-20
// 16: top back (+Y at y=1, z: 0→0.5)
// 17: step top (+Y at y=0.5, z: 0.5→1)
// 18: step riser (+Z at z=0.5, y: 0.5→1)
// 19: left upper back (-X, z: 0→0.5, y: 0.5→1)
// 20: right upper back (+X, z: 0→0.5, y: 0.5→1)
//
// Stairs north (step toward -Z, back at +Z): models 21-25
// Stairs east (step toward +X, back at -X): models 26-30
// Stairs west (step toward -X, back at +X): models 31-35

pub const extra_quad_models = [EXTRA_MODEL_COUNT]ExtraQuadModel{
    // --- Bottom slab models (6-10) ---
    // 6: slab top (+Y at y=0.5)
    quad(.{ 0, 0.5, 1 }, .{ 1, 0.5, 1 }, .{ 1, 0.5, 0 }, .{ 0, 0.5, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 }, .{ 0, 1, 0 }),
    // 7: slab +Z side half-height (y: 0→0.5)
    quad(.{ 0, 0, 1 }, .{ 1, 0, 1 }, .{ 1, 0.5, 1 }, .{ 0, 0.5, 1 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0.5 }, .{ 0, 0.5 }, .{ 0, 0, 1 }),
    // 8: slab -Z side half-height (y: 0→0.5)
    quad(.{ 1, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0.5, 0 }, .{ 1, 0.5, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0.5 }, .{ 0, 0.5 }, .{ 0, 0, -1 }),
    // 9: slab -X side half-height (y: 0→0.5)
    quad(.{ 0, 0, 0 }, .{ 0, 0, 1 }, .{ 0, 0.5, 1 }, .{ 0, 0.5, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0.5 }, .{ 0, 0.5 }, .{ -1, 0, 0 }),
    // 10: slab +X side half-height (y: 0→0.5)
    quad(.{ 1, 0, 1 }, .{ 1, 0, 0 }, .{ 1, 0.5, 0 }, .{ 1, 0.5, 1 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0.5 }, .{ 0, 0.5 }, .{ 1, 0, 0 }),

    // --- Top slab models (11-15) ---
    // 11: slab bottom (-Y at y=0.5)
    quad(.{ 0, 0.5, 0 }, .{ 1, 0.5, 0 }, .{ 1, 0.5, 1 }, .{ 0, 0.5, 1 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 }, .{ 0, -1, 0 }),
    // 12: slab +Z side upper half (y: 0.5→1)
    quad(.{ 0, 0.5, 1 }, .{ 1, 0.5, 1 }, .{ 1, 1, 1 }, .{ 0, 1, 1 }, .{ 0, 0.5 }, .{ 1, 0.5 }, .{ 1, 0 }, .{ 0, 0 }, .{ 0, 0, 1 }),
    // 13: slab -Z side upper half (y: 0.5→1)
    quad(.{ 1, 0.5, 0 }, .{ 0, 0.5, 0 }, .{ 0, 1, 0 }, .{ 1, 1, 0 }, .{ 0, 0.5 }, .{ 1, 0.5 }, .{ 1, 0 }, .{ 0, 0 }, .{ 0, 0, -1 }),
    // 14: slab -X side upper half (y: 0.5→1)
    quad(.{ 0, 0.5, 0 }, .{ 0, 0.5, 1 }, .{ 0, 1, 1 }, .{ 0, 1, 0 }, .{ 0, 0.5 }, .{ 1, 0.5 }, .{ 1, 0 }, .{ 0, 0 }, .{ -1, 0, 0 }),
    // 15: slab +X side upper half (y: 0.5→1)
    quad(.{ 1, 0.5, 1 }, .{ 1, 0.5, 0 }, .{ 1, 1, 0 }, .{ 1, 1, 1 }, .{ 0, 0.5 }, .{ 1, 0.5 }, .{ 1, 0 }, .{ 0, 0 }, .{ 1, 0, 0 }),

    // --- Stairs south models (step toward +Z, back at -Z) (16-20) ---
    // 16: top back (+Y at y=1, z: 0→0.5) — half-depth top
    quad(.{ 0, 1, 0.5 }, .{ 1, 1, 0.5 }, .{ 1, 1, 0 }, .{ 0, 1, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0.5 }, .{ 0, 0.5 }, .{ 0, 1, 0 }),
    // 17: step top (+Y at y=0.5, z: 0.5→1) — half-depth step
    quad(.{ 0, 0.5, 1 }, .{ 1, 0.5, 1 }, .{ 1, 0.5, 0.5 }, .{ 0, 0.5, 0.5 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0.5 }, .{ 0, 0.5 }, .{ 0, 1, 0 }),
    // 18: step riser (+Z at z=0.5, y: 0.5→1) — inner vertical face
    quad(.{ 0, 0.5, 0.5 }, .{ 1, 0.5, 0.5 }, .{ 1, 1, 0.5 }, .{ 0, 1, 0.5 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0.5 }, .{ 0, 0.5 }, .{ 0, 0, 1 }),
    // 19: left upper back (-X, z: 0→0.5, y: 0.5→1)
    quad(.{ 0, 0.5, 0 }, .{ 0, 0.5, 0.5 }, .{ 0, 1, 0.5 }, .{ 0, 1, 0 }, .{ 0, 1 }, .{ 0.5, 1 }, .{ 0.5, 0.5 }, .{ 0, 0.5 }, .{ -1, 0, 0 }),
    // 20: right upper back (+X, z: 0→0.5, y: 0.5→1)
    quad(.{ 1, 0.5, 0.5 }, .{ 1, 0.5, 0 }, .{ 1, 1, 0 }, .{ 1, 1, 0.5 }, .{ 0, 1 }, .{ 0.5, 1 }, .{ 0.5, 0.5 }, .{ 0, 0.5 }, .{ 1, 0, 0 }),

    // --- Stairs north models (step toward -Z, back at +Z) (21-25) ---
    // 21: top back (+Y at y=1, z: 0.5→1)
    quad(.{ 0, 1, 1 }, .{ 1, 1, 1 }, .{ 1, 1, 0.5 }, .{ 0, 1, 0.5 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0.5 }, .{ 0, 0.5 }, .{ 0, 1, 0 }),
    // 22: step top (+Y at y=0.5, z: 0→0.5)
    quad(.{ 0, 0.5, 0.5 }, .{ 1, 0.5, 0.5 }, .{ 1, 0.5, 0 }, .{ 0, 0.5, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0.5 }, .{ 0, 0.5 }, .{ 0, 1, 0 }),
    // 23: step riser (-Z at z=0.5, y: 0.5→1)
    quad(.{ 1, 0.5, 0.5 }, .{ 0, 0.5, 0.5 }, .{ 0, 1, 0.5 }, .{ 1, 1, 0.5 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0.5 }, .{ 0, 0.5 }, .{ 0, 0, -1 }),
    // 24: left upper back (-X, z: 0.5→1, y: 0.5→1)
    quad(.{ 0, 0.5, 0.5 }, .{ 0, 0.5, 1 }, .{ 0, 1, 1 }, .{ 0, 1, 0.5 }, .{ 0.5, 1 }, .{ 1, 1 }, .{ 1, 0.5 }, .{ 0.5, 0.5 }, .{ -1, 0, 0 }),
    // 25: right upper back (+X, z: 0.5→1, y: 0.5→1)
    quad(.{ 1, 0.5, 1 }, .{ 1, 0.5, 0.5 }, .{ 1, 1, 0.5 }, .{ 1, 1, 1 }, .{ 0.5, 1 }, .{ 1, 1 }, .{ 1, 0.5 }, .{ 0.5, 0.5 }, .{ 1, 0, 0 }),

    // --- Stairs east models (step toward +X, back at -X) (26-30) ---
    // 26: top back (+Y at y=1, x: 0→0.5)
    quad(.{ 0, 1, 1 }, .{ 0.5, 1, 1 }, .{ 0.5, 1, 0 }, .{ 0, 1, 0 }, .{ 0, 1 }, .{ 0.5, 1 }, .{ 0.5, 0 }, .{ 0, 0 }, .{ 0, 1, 0 }),
    // 27: step top (+Y at y=0.5, x: 0.5→1)
    quad(.{ 0.5, 0.5, 1 }, .{ 1, 0.5, 1 }, .{ 1, 0.5, 0 }, .{ 0.5, 0.5, 0 }, .{ 0.5, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0.5, 0 }, .{ 0, 1, 0 }),
    // 28: step riser (+X at x=0.5, y: 0.5→1)
    quad(.{ 0.5, 0.5, 1 }, .{ 0.5, 0.5, 0 }, .{ 0.5, 1, 0 }, .{ 0.5, 1, 1 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0.5 }, .{ 0, 0.5 }, .{ 1, 0, 0 }),
    // 29: front upper back (-Z, x: 0→0.5, y: 0.5→1)
    quad(.{ 0.5, 0.5, 0 }, .{ 0, 0.5, 0 }, .{ 0, 1, 0 }, .{ 0.5, 1, 0 }, .{ 0, 1 }, .{ 0.5, 1 }, .{ 0.5, 0.5 }, .{ 0, 0.5 }, .{ 0, 0, -1 }),
    // 30: back upper back (+Z, x: 0→0.5, y: 0.5→1)
    quad(.{ 0, 0.5, 1 }, .{ 0.5, 0.5, 1 }, .{ 0.5, 1, 1 }, .{ 0, 1, 1 }, .{ 0, 1 }, .{ 0.5, 1 }, .{ 0.5, 0.5 }, .{ 0, 0.5 }, .{ 0, 0, 1 }),

    // --- Stairs west models (step toward -X, back at +X) (31-35) ---
    // 31: top back (+Y at y=1, x: 0.5→1)
    quad(.{ 0.5, 1, 1 }, .{ 1, 1, 1 }, .{ 1, 1, 0 }, .{ 0.5, 1, 0 }, .{ 0.5, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0.5, 0 }, .{ 0, 1, 0 }),
    // 32: step top (+Y at y=0.5, x: 0→0.5)
    quad(.{ 0, 0.5, 1 }, .{ 0.5, 0.5, 1 }, .{ 0.5, 0.5, 0 }, .{ 0, 0.5, 0 }, .{ 0, 1 }, .{ 0.5, 1 }, .{ 0.5, 0 }, .{ 0, 0 }, .{ 0, 1, 0 }),
    // 33: step riser (-X at x=0.5, y: 0.5→1)
    quad(.{ 0.5, 0.5, 0 }, .{ 0.5, 0.5, 1 }, .{ 0.5, 1, 1 }, .{ 0.5, 1, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0.5 }, .{ 0, 0.5 }, .{ -1, 0, 0 }),
    // 34: front upper back (-Z, x: 0.5→1, y: 0.5→1)
    quad(.{ 1, 0.5, 0 }, .{ 0.5, 0.5, 0 }, .{ 0.5, 1, 0 }, .{ 1, 1, 0 }, .{ 0.5, 1 }, .{ 1, 1 }, .{ 1, 0.5 }, .{ 0.5, 0.5 }, .{ 0, 0, -1 }),
    // 35: back upper back (+Z, x: 0.5→1, y: 0.5→1)
    quad(.{ 0.5, 0.5, 1 }, .{ 1, 0.5, 1 }, .{ 1, 1, 1 }, .{ 0.5, 1, 1 }, .{ 0.5, 1 }, .{ 1, 1 }, .{ 1, 0.5 }, .{ 0.5, 0.5 }, .{ 0, 0, 1 }),
};

pub const TOTAL_MODEL_COUNT = 6 + EXTRA_MODEL_COUNT;

/// Get the face list for a shaped block.
/// Returns slice of ShapeFace describing all quads to emit.
pub fn getShapeFaces(block: BlockType) []const ShapeFace {
    return switch (block) {
        .oak_slab_bottom => &bottom_slab_faces,
        .oak_slab_top => &top_slab_faces,
        .oak_stairs_south => &stairs_south_faces,
        .oak_stairs_north => &stairs_north_faces,
        .oak_stairs_east => &stairs_east_faces,
        .oak_stairs_west => &stairs_west_faces,
        else => &.{},
    };
}

const bottom_slab_faces = [_]ShapeFace{
    .{ .model_index = 6, .face_bucket = 4, .always_emit = true }, // top at y=0.5 (always visible)
    .{ .model_index = 5, .face_bucket = 5, .always_emit = false }, // bottom (standard -Y)
    .{ .model_index = 7, .face_bucket = 0, .always_emit = false }, // +Z half-height
    .{ .model_index = 8, .face_bucket = 1, .always_emit = false }, // -Z half-height
    .{ .model_index = 9, .face_bucket = 2, .always_emit = false }, // -X half-height
    .{ .model_index = 10, .face_bucket = 3, .always_emit = false }, // +X half-height
};

const top_slab_faces = [_]ShapeFace{
    .{ .model_index = 4, .face_bucket = 4, .always_emit = false }, // top (standard +Y)
    .{ .model_index = 11, .face_bucket = 5, .always_emit = true }, // bottom at y=0.5 (always visible)
    .{ .model_index = 12, .face_bucket = 0, .always_emit = false }, // +Z upper half
    .{ .model_index = 13, .face_bucket = 1, .always_emit = false }, // -Z upper half
    .{ .model_index = 14, .face_bucket = 2, .always_emit = false }, // -X upper half
    .{ .model_index = 15, .face_bucket = 3, .always_emit = false }, // +X upper half
};

// South stair: step faces +Z, back wall at -Z
// Lower half = full slab, upper half = back portion (z: 0→0.5)
const stairs_south_faces = [_]ShapeFace{
    // Bottom slab portion
    .{ .model_index = 5, .face_bucket = 5, .always_emit = false }, // bottom -Y
    .{ .model_index = 7, .face_bucket = 0, .always_emit = false }, // +Z front half-height
    .{ .model_index = 9, .face_bucket = 2, .always_emit = false }, // -X lower half
    .{ .model_index = 10, .face_bucket = 3, .always_emit = false }, // +X lower half
    // Upper back portion
    .{ .model_index = 1, .face_bucket = 1, .always_emit = false }, // -Z back full-height
    .{ .model_index = 16, .face_bucket = 4, .always_emit = false }, // top back at y=1
    .{ .model_index = 17, .face_bucket = 4, .always_emit = true }, // step top at y=0.5 (internal)
    .{ .model_index = 18, .face_bucket = 0, .always_emit = true }, // step riser (internal)
    .{ .model_index = 19, .face_bucket = 2, .always_emit = false }, // -X upper back
    .{ .model_index = 20, .face_bucket = 3, .always_emit = false }, // +X upper back
};

const stairs_north_faces = [_]ShapeFace{
    .{ .model_index = 5, .face_bucket = 5, .always_emit = false },
    .{ .model_index = 8, .face_bucket = 1, .always_emit = false }, // -Z front half-height
    .{ .model_index = 9, .face_bucket = 2, .always_emit = false },
    .{ .model_index = 10, .face_bucket = 3, .always_emit = false },
    .{ .model_index = 0, .face_bucket = 0, .always_emit = false }, // +Z back full-height
    .{ .model_index = 21, .face_bucket = 4, .always_emit = false },
    .{ .model_index = 22, .face_bucket = 4, .always_emit = true },
    .{ .model_index = 23, .face_bucket = 1, .always_emit = true },
    .{ .model_index = 24, .face_bucket = 2, .always_emit = false },
    .{ .model_index = 25, .face_bucket = 3, .always_emit = false },
};

const stairs_east_faces = [_]ShapeFace{
    .{ .model_index = 5, .face_bucket = 5, .always_emit = false },
    .{ .model_index = 10, .face_bucket = 3, .always_emit = false }, // +X front half-height
    .{ .model_index = 7, .face_bucket = 0, .always_emit = false }, // +Z lower half
    .{ .model_index = 8, .face_bucket = 1, .always_emit = false }, // -Z lower half
    .{ .model_index = 2, .face_bucket = 2, .always_emit = false }, // -X back full-height
    .{ .model_index = 26, .face_bucket = 4, .always_emit = false },
    .{ .model_index = 27, .face_bucket = 4, .always_emit = true },
    .{ .model_index = 28, .face_bucket = 3, .always_emit = true },
    .{ .model_index = 29, .face_bucket = 1, .always_emit = false },
    .{ .model_index = 30, .face_bucket = 0, .always_emit = false },
};

const stairs_west_faces = [_]ShapeFace{
    .{ .model_index = 5, .face_bucket = 5, .always_emit = false },
    .{ .model_index = 9, .face_bucket = 2, .always_emit = false }, // -X front half-height
    .{ .model_index = 7, .face_bucket = 0, .always_emit = false }, // +Z lower half
    .{ .model_index = 8, .face_bucket = 1, .always_emit = false }, // -Z lower half
    .{ .model_index = 3, .face_bucket = 3, .always_emit = false }, // +X back full-height
    .{ .model_index = 31, .face_bucket = 4, .always_emit = false },
    .{ .model_index = 32, .face_bucket = 4, .always_emit = true },
    .{ .model_index = 33, .face_bucket = 2, .always_emit = true },
    .{ .model_index = 34, .face_bucket = 1, .always_emit = false },
    .{ .model_index = 35, .face_bucket = 0, .always_emit = false },
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
    oak_slab_bottom,
    oak_slab_top,
    oak_stairs_south,
    oak_stairs_north,
    oak_stairs_east,
    oak_stairs_west,

    pub fn isShapedBlock(self: BlockType) bool {
        return switch (self) {
            .oak_slab_bottom, .oak_slab_top,
            .oak_stairs_south, .oak_stairs_north, .oak_stairs_east, .oak_stairs_west,
            => true,
            else => false,
        };
    }
};

pub const block_properties = struct {
    pub fn isOpaque(block: BlockType) bool {
        return switch (block) {
            .air, .glass, .water, .oak_leaves,
            .oak_slab_bottom, .oak_slab_top,
            .oak_stairs_south, .oak_stairs_north, .oak_stairs_east, .oak_stairs_west,
            => false,
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
            .oak_slab_bottom, .oak_slab_top,
            .oak_stairs_south, .oak_stairs_north, .oak_stairs_east, .oak_stairs_west,
            => false,
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

/// Comptime trilinear light sample offsets and weights per face/corner.
/// Derived from Cubyz getCornerLight: lightPos = vertex + normal*0.5 - 0.5,
/// then trilinear interpolation over 8 surrounding blocks.
/// For axis-aligned faces, collapses to 4 samples with equal weight (64/256 each).
const TrilinearSample = struct {
    delta: i32,
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

            // lightPos = vertex + normal * 0.5 - 0.5 (per axis)
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
                                .delta = sy * @as(i32, PADDED_SIZE * PADDED_SIZE) + sz * @as(i32, PADDED_SIZE) + sx,
                                .weight = iw,
                            };
                            si += 1;
                        }
                    }
                }
            }
            while (si < 4) : (si += 1) {
                result[face][corner][si] = .{ .delta = 0, .weight = 0 };
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

/// Build padded 34³ light volumes from center LightMap + 6 neighbor border snapshots.
fn buildPaddedLight(
    padded_sky: *[PADDED_BLOCKS]u8,
    padded_block: *[PADDED_BLOCKS][3]u8,
    light_map: ?*const LightMap,
    neighbor_borders: [6]LightBorderSnapshot,
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
                padded_sky[pi] = lm.sky_light.get(ci);
                padded_block[pi] = lm.block_light.get(ci);
            }
        }
    }

    // Copy border from neighbor snapshots (already copied under brief locks)
    // +Z face (0): border_idx = y * CS + x
    if (neighbor_borders[0].valid) {
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |x| {
                const bi = y * CHUNK_SIZE + x;
                const pi = paddedIndex(x + 1, y + 1, PADDED_SIZE - 1);
                padded_sky[pi] = neighbor_borders[0].sky[bi];
                padded_block[pi] = neighbor_borders[0].block[bi];
            }
        }
    }
    // -Z face (1): border_idx = y * CS + x
    if (neighbor_borders[1].valid) {
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |x| {
                const bi = y * CHUNK_SIZE + x;
                const pi = paddedIndex(x + 1, y + 1, 0);
                padded_sky[pi] = neighbor_borders[1].sky[bi];
                padded_block[pi] = neighbor_borders[1].block[bi];
            }
        }
    }
    // -X face (2): border_idx = y * CS + z
    if (neighbor_borders[2].valid) {
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |z| {
                const bi = y * CHUNK_SIZE + z;
                const pi = paddedIndex(0, y + 1, z + 1);
                padded_sky[pi] = neighbor_borders[2].sky[bi];
                padded_block[pi] = neighbor_borders[2].block[bi];
            }
        }
    }
    // +X face (3): border_idx = y * CS + z
    if (neighbor_borders[3].valid) {
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |z| {
                const bi = y * CHUNK_SIZE + z;
                const pi = paddedIndex(PADDED_SIZE - 1, y + 1, z + 1);
                padded_sky[pi] = neighbor_borders[3].sky[bi];
                padded_block[pi] = neighbor_borders[3].block[bi];
            }
        }
    }
    // +Y face (4): border_idx = z * CS + x
    if (neighbor_borders[4].valid) {
        for (0..CHUNK_SIZE) |z| {
            for (0..CHUNK_SIZE) |x| {
                const bi = z * CHUNK_SIZE + x;
                const pi = paddedIndex(x + 1, PADDED_SIZE - 1, z + 1);
                padded_sky[pi] = neighbor_borders[4].sky[bi];
                padded_block[pi] = neighbor_borders[4].block[bi];
            }
        }
    }
    // -Y face (5): border_idx = z * CS + x
    if (neighbor_borders[5].valid) {
        for (0..CHUNK_SIZE) |z| {
            for (0..CHUNK_SIZE) |x| {
                const bi = z * CHUNK_SIZE + x;
                const pi = paddedIndex(x + 1, 0, z + 1);
                padded_sky[pi] = neighbor_borders[5].sky[bi];
                padded_block[pi] = neighbor_borders[5].block[bi];
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

/// Trilinear light sampling for one corner of a face quad.
/// Samples 4 surrounding block positions with precomputed weights (Cubyz-style).
const TrilinearLightResult = struct { sky: u8, block: [3]u8 };

fn sampleTrilinearLight(
    base: i32,
    face: usize,
    corner: usize,
    padded: *const [PADDED_BLOCKS]BlockType,
    padded_sky: *const [PADDED_BLOCKS]u8,
    padded_block_light: *const [PADDED_BLOCKS][3]u8,
) TrilinearLightResult {
    const samples = trilinear_light_samples[face][corner];
    const face_delta = padded_face_deltas[face];
    var sky_sum: u32 = 0;
    var blk_sum: [3]u32 = .{ 0, 0, 0 };
    var total_weight: u32 = 0;

    for (0..4) |s| {
        const sample = samples[s];
        if (sample.weight == 0) continue;
        const sample_idx: usize = @intCast(base + sample.delta);
        // Skip opaque samples — AO already handles corner darkening
        if (block_properties.isOpaque(padded[sample_idx])) continue;
        const w: u32 = sample.weight;
        total_weight += w;

        // Per-sample directional shadow: compare light at sample with one
        // step further in normal direction; darken if facing away from light.
        var sky_val: u8 = padded_sky[sample_idx];
        var blk_val: [3]u8 = padded_block_light[sample_idx];
        const next_signed: i32 = @as(i32, @intCast(sample_idx)) + face_delta;
        if (next_signed >= 0 and next_signed < PADDED_BLOCKS) {
            const next_idx: usize = @intCast(next_signed);
            const sky_diff: u8 = @min(8, sky_val -| padded_sky[next_idx]);
            sky_val -|= sky_diff * 5 / 2;
            const next_blk = padded_block_light[next_idx];
            inline for (0..3) |ch| {
                const blk_diff: u8 = @min(8, blk_val[ch] -| next_blk[ch]);
                blk_val[ch] -|= blk_diff * 5 / 2;
            }
        }

        sky_sum += @as(u32, sky_val) * w;
        blk_sum[0] += @as(u32, blk_val[0]) * w;
        blk_sum[1] += @as(u32, blk_val[1]) * w;
        blk_sum[2] += @as(u32, blk_val[2]) * w;
    }

    // If all samples were opaque, fall back to face neighbor light
    if (total_weight == 0) {
        const face_idx: usize = @intCast(base + face_delta);
        return .{
            .sky = padded_sky[face_idx],
            .block = padded_block_light[face_idx],
        };
    }

    return .{
        .sky = @intCast(sky_sum / total_weight),
        .block = .{
            @intCast(blk_sum[0] / total_weight),
            @intCast(blk_sum[1] / total_weight),
            @intCast(blk_sum[2] / total_weight),
        },
    };
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
    neighbor_borders: [6]LightBorderSnapshot,
) !ChunkMeshResult {
    const tz = tracy.zone(@src(), "generateChunkMesh");
    defer tz.end();

    var padded: [PADDED_BLOCKS]BlockType = undefined;
    buildPaddedBlocks(&padded, chunk, neighbors);

    var padded_sky: [PADDED_BLOCKS]u8 = undefined;
    var padded_block_light: [PADDED_BLOCKS][3]u8 = undefined;
    buildPaddedLight(&padded_sky, &padded_block_light, light_map, neighbor_borders);

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

                const layer = @intFromEnum(block_properties.renderLayer(block));

                if (block.isShapedBlock()) {
                    // Shaped block: emit partial quads
                    const shape_faces = getShapeFaces(block);
                    for (shape_faces) |sf| {
                        if (!sf.always_emit) {
                            const neighbor = padded[@intCast(base + padded_face_deltas[sf.face_bucket])];
                            if (block_properties.isOpaque(neighbor)) continue;
                        }
                        const face: usize = sf.face_bucket;
                        // Light/AO uses the face bucket direction
                        var corner_packed: [4]u32 = undefined;
                        var corner_block_brightness: [4]u8 = .{ 0, 0, 0, 0 };
                        for (0..4) |corner| {
                            const result = sampleTrilinearLight(base, face, corner, &padded, &padded_sky, &padded_block_light);
                            corner_packed[corner] = packLight(result.sky, result.block);
                            corner_block_brightness[corner] = @max(result.block[0], @max(result.block[1], result.block[2]));
                        }
                        var ao: [4]u2 = undefined;
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
                        const face_data = types.packFaceData(
                            @intCast(bx),
                            @intCast(by),
                            @intCast(bz),
                            11, // oak_planks texture
                            sf.model_index,
                            ao,
                        );
                        try layer_faces[layer][face].append(allocator, face_data);
                        try layer_lights[layer][face].append(allocator, .{ .corners = corner_packed });
                    }
                    continue;
                }

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
                        .oak_slab_bottom, .oak_slab_top,
                        .oak_stairs_south, .oak_stairs_north, .oak_stairs_east, .oak_stairs_west,
                        => unreachable, // handled above
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
                        for (0..4) |corner| {
                            const result = sampleTrilinearLight(base, face, corner, &padded, &padded_sky, &padded_block_light);
                            corner_packed[corner] = packLight(result.sky, result.block);
                            corner_block_brightness[corner] = @max(result.block[0], @max(result.block[1], result.block[2]));
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
    neighbor_borders: [6]LightBorderSnapshot,
) !ChunkLightResult {
    const tz = tracy.zone(@src(), "generateChunkLightOnly");
    defer tz.end();

    var padded: [PADDED_BLOCKS]BlockType = undefined;
    buildPaddedBlocks(&padded, chunk, neighbors);

    var padded_sky: [PADDED_BLOCKS]u8 = undefined;
    var padded_block_light: [PADDED_BLOCKS][3]u8 = undefined;
    buildPaddedLight(&padded_sky, &padded_block_light, light_map, neighbor_borders);

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

                const layer = @intFromEnum(block_properties.renderLayer(block));

                if (block.isShapedBlock()) {
                    const shape_faces = getShapeFaces(block);
                    for (shape_faces) |sf| {
                        if (!sf.always_emit) {
                            const neighbor = padded[@intCast(base + padded_face_deltas[sf.face_bucket])];
                            if (block_properties.isOpaque(neighbor)) continue;
                        }
                        const face: usize = sf.face_bucket;
                        var corner_packed: [4]u32 = undefined;
                        for (0..4) |corner| {
                            const result = sampleTrilinearLight(base, face, corner, &padded, &padded_sky, &padded_block_light);
                            corner_packed[corner] = packLight(result.sky, result.block);
                        }
                        try layer_lights[layer][face].append(allocator, .{ .corners = corner_packed });
                    }
                    continue;
                }

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
                        for (0..4) |corner| {
                            const result = sampleTrilinearLight(base, face, corner, &padded, &padded_sky, &padded_block_light);
                            corner_packed[corner] = packLight(result.sky, result.block);
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
const no_borders: [6]LightBorderSnapshot = .{LightBorderSnapshot.empty} ** 6;

test "single block in air produces 6 faces" {
    var chunk = makeEmptyChunk();
    chunk.blocks[chunkIndex(5, 5, 5)] = .stone;

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_borders);
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

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_borders);
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

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_borders);
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

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_borders);
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

    const result0 = try generateChunkMesh(testing.allocator, &chunk0, neighbors0, null, no_borders);
    defer testing.allocator.free(result0.faces);
    defer testing.allocator.free(result0.lights);

    const result1 = try generateChunkMesh(testing.allocator, &chunk1, neighbors1, null, no_borders);
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
    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_borders);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    try testing.expectEqual(@as(u32, 0), result.total_face_count);
    try testing.expectEqual(@as(usize, 0), result.faces.len);
}

test "glass does not cull adjacent non-glass" {
    var chunk = makeEmptyChunk();
    chunk.blocks[chunkIndex(5, 5, 5)] = .stone;
    chunk.blocks[chunkIndex(6, 5, 5)] = .glass;

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_borders);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    try testing.expectEqual(@as(u32, 11), result.total_face_count);
}

test "glass-glass adjacency culls shared face" {
    var chunk = makeEmptyChunk();
    chunk.blocks[chunkIndex(5, 5, 5)] = .glass;
    chunk.blocks[chunkIndex(6, 5, 5)] = .glass;

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_borders);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    try testing.expectEqual(@as(u32, 10), result.total_face_count);
}

test "light count equals face count (1:1 mapping)" {
    var chunk = makeEmptyChunk();
    for (0..4) |x| {
        chunk.blocks[chunkIndex(x, 5, 5)] = .stone;
    }

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_borders);
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

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_borders);
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

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_borders);
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

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_borders);
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

    const result = try generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_borders);
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
