const std = @import("std");
const types = @import("../renderer/vulkan/types.zig");
const FaceData = types.FaceData;
const LightEntry = types.LightEntry;
const LightMapMod = @import("LightMap.zig");
const LightMap = LightMapMod.LightMap;
const LightBorderSnapshot = LightMapMod.LightBorderSnapshot;
const tracy = @import("../platform/tracy.zig");
pub const BlockModelLoader = @import("BlockModelLoader.zig");
pub const BlockModelRegistry = BlockModelLoader.BlockModelRegistry;

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
    model_index: u9, // index into combined model array (0-5 = standard, 6+ = extra)
    face_bucket: u3, // which direction bucket (0=+Z, 1=-Z, 2=-X, 3=+X, 4=+Y, 5=-Y)
    always_emit: bool, // true for internal faces (slab top at y=0.5, step risers)
    face_bitmap: u16, // 4×4 bitmap of THIS quad's coverage area on the face boundary
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

/// Get the face list for a shaped block.
/// Returns slice of ShapeFace describing all quads to emit.
pub fn getShapeFaces(block: BlockType) []const ShapeFace {
    return getRegistry().block_shape_faces[@intFromEnum(block)];
}

/// Get per-face texture indices for a shaped block.
pub fn getShapedTexIndices(block: BlockType) []const u8 {
    return getRegistry().block_face_tex_indices[@intFromEnum(block)];
}

/// Get the 4×4 occlusion bitmap for a block on the given face.
/// Full opaque blocks = 0xFFFF. Solid shaped blocks use registry bitmaps.
/// Transparent/non-solid blocks = 0 (don't occlude).
pub fn getOcclusionBitmap(block: BlockType, face: usize) u16 {
    if (block == .air) return 0;
    if (block_properties.isOpaque(block)) return 0xFFFF;
    if (block_properties.isSolidShaped(block)) {
        if (registry) |reg| {
            return reg.block_face_bitmaps[@intFromEnum(block)][face];
        }
        return 0;
    }
    return 0;
}

/// Minecraft-style VoxelShape face culling: should this block's face be culled
/// given the neighbor block on that side?
/// Compares 4×4 bitmaps: cull if the neighbor covers every cell this block exposes.
/// face: 0=+Z, 1=-Z, 2=-X, 3=+X, 4=+Y, 5=-Y
pub fn shouldCullFace(block: BlockType, face: usize, neighbor: BlockType) bool {
    const neighbor_bmp = getOcclusionBitmap(neighbor, oppositeFace(face));
    if (neighbor_bmp == 0) return false;
    // Fast path: neighbor fully covers the face → always cull (matches Minecraft's
    // `occluder == Shapes.block()` check that fires before the shape comparison)
    if (neighbor_bmp == 0xFFFF) return true;
    // If this block has no occlusion bitmap, it doesn't participate in partial
    // face culling — always render. Matches Minecraft's `shape == Shapes.empty() → true`.
    const this_bmp = getOcclusionBitmap(block, face);
    if (this_bmp == 0) return false;
    // Partial check: cull if neighbor covers all cells this block exposes
    return (this_bmp & ~neighbor_bmp) == 0;
}

/// Per-quad face culling for shaped blocks: checks if the neighbor covers
/// this individual quad's area (using the quad's own face_bitmap).
pub fn shouldCullShapeFace(sf: ShapeFace, neighbor: BlockType) bool {
    const neighbor_bmp = getOcclusionBitmap(neighbor, oppositeFace(sf.face_bucket));
    if (neighbor_bmp == 0) return false;
    if (neighbor_bmp == 0xFFFF) return true;
    if (sf.face_bitmap == 0) return false;
    return (sf.face_bitmap & ~neighbor_bmp) == 0;
}

/// Opposite face direction: 0↔1, 2↔3, 4↔5
pub fn oppositeFace(face: usize) usize {
    return face ^ 1;
}

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
    oak_slab_double,
    oak_stairs_south,
    oak_stairs_north,
    oak_stairs_east,
    oak_stairs_west,
    torch,
    torch_wall_south,
    torch_wall_north,
    torch_wall_east,
    torch_wall_west,
    ladder_south,
    ladder_north,
    ladder_east,
    ladder_west,
    // Oak door: 16 variants = 4 facing × 2 halves × 2 open states (left hinge only)
    oak_door_bottom_east,
    oak_door_bottom_east_open,
    oak_door_bottom_south,
    oak_door_bottom_south_open,
    oak_door_bottom_west,
    oak_door_bottom_west_open,
    oak_door_bottom_north,
    oak_door_bottom_north_open,
    oak_door_top_east,
    oak_door_top_east_open,
    oak_door_top_south,
    oak_door_top_south_open,
    oak_door_top_west,
    oak_door_top_west_open,
    oak_door_top_north,
    oak_door_top_north_open,
    // Oak fence: 16 variants for connection combinations (N/S/E/W bitmask)
    oak_fence_post,
    oak_fence_n,
    oak_fence_s,
    oak_fence_e,
    oak_fence_w,
    oak_fence_ns,
    oak_fence_ne,
    oak_fence_nw,
    oak_fence_se,
    oak_fence_sw,
    oak_fence_ew,
    oak_fence_nse,
    oak_fence_nsw,
    oak_fence_new,
    oak_fence_sew,
    oak_fence_nsew,

    pub fn isShapedBlock(self: BlockType) bool {
        return switch (self) {
            .oak_slab_bottom, .oak_slab_top,
            .oak_stairs_south, .oak_stairs_north, .oak_stairs_east, .oak_stairs_west,
            .torch, .torch_wall_south, .torch_wall_north, .torch_wall_east, .torch_wall_west,
            .ladder_south, .ladder_north, .ladder_east, .ladder_west,
            .oak_door_bottom_east, .oak_door_bottom_east_open,
            .oak_door_bottom_south, .oak_door_bottom_south_open,
            .oak_door_bottom_west, .oak_door_bottom_west_open,
            .oak_door_bottom_north, .oak_door_bottom_north_open,
            .oak_door_top_east, .oak_door_top_east_open,
            .oak_door_top_south, .oak_door_top_south_open,
            .oak_door_top_west, .oak_door_top_west_open,
            .oak_door_top_north, .oak_door_top_north_open,
            .oak_fence_post, .oak_fence_n, .oak_fence_s, .oak_fence_e, .oak_fence_w,
            .oak_fence_ns, .oak_fence_ne, .oak_fence_nw, .oak_fence_se, .oak_fence_sw, .oak_fence_ew,
            .oak_fence_nse, .oak_fence_nsw, .oak_fence_new, .oak_fence_sew, .oak_fence_nsew,
            => true,
            else => false,
        };
    }

    pub fn isFence(self: BlockType) bool {
        return switch (self) {
            .oak_fence_post, .oak_fence_n, .oak_fence_s, .oak_fence_e, .oak_fence_w,
            .oak_fence_ns, .oak_fence_ne, .oak_fence_nw, .oak_fence_se, .oak_fence_sw, .oak_fence_ew,
            .oak_fence_nse, .oak_fence_nsw, .oak_fence_new, .oak_fence_sew, .oak_fence_nsew,
            => true,
            else => false,
        };
    }

    /// Whether a block can connect to a fence (fences + solid opaque blocks).
    pub fn connectsToFence(self: BlockType) bool {
        return self.isFence() or (block_properties.isSolid(self) and block_properties.isOpaque(self));
    }

    /// Calculate the correct fence variant based on which neighbors are connectable.
    /// Flags: n=bit0, s=bit1, e=bit2, w=bit3.
    pub fn fenceFromConnections(n: bool, s: bool, e: bool, w: bool) BlockType {
        const idx: u4 = (@as(u4, @intFromBool(n))) |
            (@as(u4, @intFromBool(s)) << 1) |
            (@as(u4, @intFromBool(e)) << 2) |
            (@as(u4, @intFromBool(w)) << 3);
        return fence_variant_table[idx];
    }

    const fence_variant_table = [16]BlockType{
        .oak_fence_post, // 0000
        .oak_fence_n, // 0001
        .oak_fence_s, // 0010
        .oak_fence_ns, // 0011
        .oak_fence_e, // 0100
        .oak_fence_ne, // 0101
        .oak_fence_se, // 0110
        .oak_fence_nse, // 0111
        .oak_fence_w, // 1000
        .oak_fence_nw, // 1001
        .oak_fence_sw, // 1010
        .oak_fence_nsw, // 1011
        .oak_fence_ew, // 1100
        .oak_fence_new, // 1101
        .oak_fence_sew, // 1110
        .oak_fence_nsew, // 1111
    };

    pub fn isDoor(self: BlockType) bool {
        return switch (self) {
            .oak_door_bottom_east, .oak_door_bottom_east_open,
            .oak_door_bottom_south, .oak_door_bottom_south_open,
            .oak_door_bottom_west, .oak_door_bottom_west_open,
            .oak_door_bottom_north, .oak_door_bottom_north_open,
            .oak_door_top_east, .oak_door_top_east_open,
            .oak_door_top_south, .oak_door_top_south_open,
            .oak_door_top_west, .oak_door_top_west_open,
            .oak_door_top_north, .oak_door_top_north_open,
            => true,
            else => false,
        };
    }

    pub fn isDoorBottom(self: BlockType) bool {
        return switch (self) {
            .oak_door_bottom_east, .oak_door_bottom_east_open,
            .oak_door_bottom_south, .oak_door_bottom_south_open,
            .oak_door_bottom_west, .oak_door_bottom_west_open,
            .oak_door_bottom_north, .oak_door_bottom_north_open,
            => true,
            else => false,
        };
    }

    pub fn isDoorOpen(self: BlockType) bool {
        return switch (self) {
            .oak_door_bottom_east_open, .oak_door_bottom_south_open,
            .oak_door_bottom_west_open, .oak_door_bottom_north_open,
            .oak_door_top_east_open, .oak_door_top_south_open,
            .oak_door_top_west_open, .oak_door_top_north_open,
            => true,
            else => false,
        };
    }

    /// Toggle a door block between open and closed states.
    pub fn toggleDoor(self: BlockType) BlockType {
        return switch (self) {
            .oak_door_bottom_east => .oak_door_bottom_east_open,
            .oak_door_bottom_east_open => .oak_door_bottom_east,
            .oak_door_bottom_south => .oak_door_bottom_south_open,
            .oak_door_bottom_south_open => .oak_door_bottom_south,
            .oak_door_bottom_west => .oak_door_bottom_west_open,
            .oak_door_bottom_west_open => .oak_door_bottom_west,
            .oak_door_bottom_north => .oak_door_bottom_north_open,
            .oak_door_bottom_north_open => .oak_door_bottom_north,
            .oak_door_top_east => .oak_door_top_east_open,
            .oak_door_top_east_open => .oak_door_top_east,
            .oak_door_top_south => .oak_door_top_south_open,
            .oak_door_top_south_open => .oak_door_top_south,
            .oak_door_top_west => .oak_door_top_west_open,
            .oak_door_top_west_open => .oak_door_top_west,
            .oak_door_top_north => .oak_door_top_north_open,
            .oak_door_top_north_open => .oak_door_top_north,
            else => self,
        };
    }

    /// Get the corresponding top variant for a bottom door block.
    pub fn doorBottomToTop(self: BlockType) BlockType {
        return switch (self) {
            .oak_door_bottom_east => .oak_door_top_east,
            .oak_door_bottom_east_open => .oak_door_top_east_open,
            .oak_door_bottom_south => .oak_door_top_south,
            .oak_door_bottom_south_open => .oak_door_top_south_open,
            .oak_door_bottom_west => .oak_door_top_west,
            .oak_door_bottom_west_open => .oak_door_top_west_open,
            .oak_door_bottom_north => .oak_door_top_north,
            .oak_door_bottom_north_open => .oak_door_top_north_open,
            else => self,
        };
    }
};

pub const block_properties = struct {
    pub fn isOpaque(block: BlockType) bool {
        return switch (block) {
            .air, .glass, .water, .oak_leaves,
            .oak_slab_bottom, .oak_slab_top,
            .oak_stairs_south, .oak_stairs_north, .oak_stairs_east, .oak_stairs_west,
            .torch, .torch_wall_south, .torch_wall_north, .torch_wall_east, .torch_wall_west,
            .ladder_south, .ladder_north, .ladder_east, .ladder_west,
            .oak_door_bottom_east, .oak_door_bottom_east_open,
            .oak_door_bottom_south, .oak_door_bottom_south_open,
            .oak_door_bottom_west, .oak_door_bottom_west_open,
            .oak_door_bottom_north, .oak_door_bottom_north_open,
            .oak_door_top_east, .oak_door_top_east_open,
            .oak_door_top_south, .oak_door_top_south_open,
            .oak_door_top_west, .oak_door_top_west_open,
            .oak_door_top_north, .oak_door_top_north_open,
            .oak_fence_post, .oak_fence_n, .oak_fence_s, .oak_fence_e, .oak_fence_w,
            .oak_fence_ns, .oak_fence_ne, .oak_fence_nw, .oak_fence_se, .oak_fence_sw, .oak_fence_ew,
            .oak_fence_nse, .oak_fence_nsw, .oak_fence_new, .oak_fence_sew, .oak_fence_nsew,
            => false,
            .grass_block, .dirt, .stone, .glowstone, .sand, .snow, .gravel,
            .cobblestone, .oak_log, .oak_planks, .bricks, .bedrock,
            .gold_ore, .iron_ore, .coal_ore, .diamond_ore,
            .sponge, .pumice, .wool, .gold_block, .iron_block,
            .diamond_block, .bookshelf, .obsidian, .oak_slab_double,
            => true,
        };
    }
    /// Whether this shaped block has solid (opaque material) faces that can participate
    /// in VoxelShape occlusion culling. Slabs and stairs are solid wood — their faces
    /// occlude where they exist. Torches and ladders are too thin/transparent.
    pub fn isSolidShaped(block: BlockType) bool {
        return switch (block) {
            .oak_slab_bottom, .oak_slab_top,
            .oak_stairs_south, .oak_stairs_north, .oak_stairs_east, .oak_stairs_west,
            => true,
            else => false,
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
            .torch, .torch_wall_south, .torch_wall_north, .torch_wall_east, .torch_wall_west => false,
            .ladder_south, .ladder_north, .ladder_east, .ladder_west => false,
            .oak_door_bottom_east, .oak_door_bottom_east_open,
            .oak_door_bottom_south, .oak_door_bottom_south_open,
            .oak_door_bottom_west, .oak_door_bottom_west_open,
            .oak_door_bottom_north, .oak_door_bottom_north_open,
            .oak_door_top_east, .oak_door_top_east_open,
            .oak_door_top_south, .oak_door_top_south_open,
            .oak_door_top_west, .oak_door_top_west_open,
            .oak_door_top_north, .oak_door_top_north_open,
            => false,
            .oak_fence_post, .oak_fence_n, .oak_fence_s, .oak_fence_e, .oak_fence_w,
            .oak_fence_ns, .oak_fence_ne, .oak_fence_nw, .oak_fence_se, .oak_fence_sw, .oak_fence_ew,
            .oak_fence_nse, .oak_fence_nsw, .oak_fence_new, .oak_fence_sew, .oak_fence_nsew,
            => false,
            .grass_block, .dirt, .stone, .glowstone, .sand, .snow, .gravel,
            .cobblestone, .oak_log, .oak_planks, .bricks, .bedrock,
            .gold_ore, .iron_ore, .coal_ore, .diamond_ore,
            .sponge, .pumice, .wool, .gold_block, .iron_block,
            .diamond_block, .bookshelf, .obsidian, .oak_slab_double,
            => true,
        };
    }
    pub fn isSolid(block: BlockType) bool {
        return switch (block) {
            .air, .water, .torch, .torch_wall_south, .torch_wall_north, .torch_wall_east, .torch_wall_west,
            .ladder_south, .ladder_north, .ladder_east, .ladder_west,
            // Open doors are not solid (walkthrough)
            .oak_door_bottom_east_open, .oak_door_bottom_south_open,
            .oak_door_bottom_west_open, .oak_door_bottom_north_open,
            .oak_door_top_east_open, .oak_door_top_south_open,
            .oak_door_top_west_open, .oak_door_top_north_open,
            => false,
            // Closed door variants fall through to else => true
            else => true,
        };
    }
    pub fn isTargetable(block: BlockType) bool {
        return block != .air and block != .water;
    }

    pub const AABB = struct { min: [3]f32, max: [3]f32 };

    /// Get the selection/hitbox AABB for a block (in block-local 0..1 space).
    /// Returns null for full 1x1x1 blocks (use the implicit full cube).
    pub fn getHitbox(block: BlockType) ?AABB {
        return switch (block) {
            // Standing torch: box(6,0,6,10,10,10) — matches Minecraft
            .torch => .{ .min = .{ 6.0 / 16.0, 0.0, 6.0 / 16.0 }, .max = .{ 10.0 / 16.0, 10.0 / 16.0, 10.0 / 16.0 } },
            // Wall torches: MC base is box(5.5,3,11,10.5,16,16) on south face, rotated per direction
            .torch_wall_south => .{ .min = .{ 5.5 / 16.0, 3.0 / 16.0, 11.0 / 16.0 }, .max = .{ 10.5 / 16.0, 1.0, 1.0 } },
            .torch_wall_north => .{ .min = .{ 5.5 / 16.0, 3.0 / 16.0, 0.0 }, .max = .{ 10.5 / 16.0, 1.0, 5.0 / 16.0 } },
            .torch_wall_east => .{ .min = .{ 11.0 / 16.0, 3.0 / 16.0, 5.5 / 16.0 }, .max = .{ 1.0, 1.0, 10.5 / 16.0 } },
            .torch_wall_west => .{ .min = .{ 0.0, 3.0 / 16.0, 5.5 / 16.0 }, .max = .{ 5.0 / 16.0, 1.0, 10.5 / 16.0 } },
            // Ladders: thin panel on wall face (3px thick)
            // ladder_south = facing south, panel on north wall (low Z)
            .ladder_south => .{ .min = .{ 0.0, 0.0, 0.0 }, .max = .{ 1.0, 1.0, 3.0 / 16.0 } },
            .ladder_north => .{ .min = .{ 0.0, 0.0, 13.0 / 16.0 }, .max = .{ 1.0, 1.0, 1.0 } },
            .ladder_east => .{ .min = .{ 0.0, 0.0, 0.0 }, .max = .{ 3.0 / 16.0, 1.0, 1.0 } },
            .ladder_west => .{ .min = .{ 13.0 / 16.0, 0.0, 0.0 }, .max = .{ 1.0, 1.0, 1.0 } },
            // Door hitboxes: 3px slab, position depends on facing + open state
            // Closed east / Open north: slab on west edge (x=0..3/16)
            .oak_door_bottom_east, .oak_door_top_east,
            .oak_door_bottom_north_open, .oak_door_top_north_open,
            => .{ .min = .{ 0.0, 0.0, 0.0 }, .max = .{ 3.0 / 16.0, 1.0, 1.0 } },
            // Closed south / Open east: slab on south edge (z=13/16..1)
            .oak_door_bottom_south, .oak_door_top_south,
            .oak_door_bottom_east_open, .oak_door_top_east_open,
            => .{ .min = .{ 0.0, 0.0, 13.0 / 16.0 }, .max = .{ 1.0, 1.0, 1.0 } },
            // Closed west / Open south: slab on east edge (x=13/16..1)
            .oak_door_bottom_west, .oak_door_top_west,
            .oak_door_bottom_south_open, .oak_door_top_south_open,
            => .{ .min = .{ 13.0 / 16.0, 0.0, 0.0 }, .max = .{ 1.0, 1.0, 1.0 } },
            // Closed north / Open west: slab on north edge (z=0..3/16)
            .oak_door_bottom_north, .oak_door_top_north,
            .oak_door_bottom_west_open, .oak_door_top_west_open,
            => .{ .min = .{ 0.0, 0.0, 0.0 }, .max = .{ 1.0, 1.0, 3.0 / 16.0 } },
            // Slabs: half-block hitbox
            .oak_slab_bottom => .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 0.5, 1 } },
            .oak_slab_top => .{ .min = .{ 0, 0.5, 0 }, .max = .{ 1, 1, 1 } },
            // Fence hitboxes: bounding box covering post + connections
            .oak_fence_post => .{ .min = .{ 6.0 / 16.0, 0.0, 6.0 / 16.0 }, .max = .{ 10.0 / 16.0, 1.0, 10.0 / 16.0 } },
            .oak_fence_n => .{ .min = .{ 6.0 / 16.0, 0.0, 0.0 }, .max = .{ 10.0 / 16.0, 1.0, 10.0 / 16.0 } },
            .oak_fence_s => .{ .min = .{ 6.0 / 16.0, 0.0, 6.0 / 16.0 }, .max = .{ 10.0 / 16.0, 1.0, 1.0 } },
            .oak_fence_e => .{ .min = .{ 6.0 / 16.0, 0.0, 6.0 / 16.0 }, .max = .{ 1.0, 1.0, 10.0 / 16.0 } },
            .oak_fence_w => .{ .min = .{ 0.0, 0.0, 6.0 / 16.0 }, .max = .{ 10.0 / 16.0, 1.0, 10.0 / 16.0 } },
            .oak_fence_ns => .{ .min = .{ 6.0 / 16.0, 0.0, 0.0 }, .max = .{ 10.0 / 16.0, 1.0, 1.0 } },
            .oak_fence_ew => .{ .min = .{ 0.0, 0.0, 6.0 / 16.0 }, .max = .{ 1.0, 1.0, 10.0 / 16.0 } },
            .oak_fence_ne => .{ .min = .{ 6.0 / 16.0, 0.0, 0.0 }, .max = .{ 1.0, 1.0, 10.0 / 16.0 } },
            .oak_fence_nw => .{ .min = .{ 0.0, 0.0, 0.0 }, .max = .{ 10.0 / 16.0, 1.0, 10.0 / 16.0 } },
            .oak_fence_se => .{ .min = .{ 6.0 / 16.0, 0.0, 6.0 / 16.0 }, .max = .{ 1.0, 1.0, 1.0 } },
            .oak_fence_sw => .{ .min = .{ 0.0, 0.0, 6.0 / 16.0 }, .max = .{ 10.0 / 16.0, 1.0, 1.0 } },
            .oak_fence_nse => .{ .min = .{ 6.0 / 16.0, 0.0, 0.0 }, .max = .{ 1.0, 1.0, 1.0 } },
            .oak_fence_nsw => .{ .min = .{ 0.0, 0.0, 0.0 }, .max = .{ 10.0 / 16.0, 1.0, 1.0 } },
            .oak_fence_new => .{ .min = .{ 0.0, 0.0, 0.0 }, .max = .{ 1.0, 1.0, 10.0 / 16.0 } },
            .oak_fence_sew => .{ .min = .{ 0.0, 0.0, 6.0 / 16.0 }, .max = .{ 1.0, 1.0, 1.0 } },
            .oak_fence_nsew => .{ .min = .{ 0.0, 0.0, 0.0 }, .max = .{ 1.0, 1.0, 1.0 } },
            else => null, // full cube
        };
    }
    pub fn renderLayer(block: BlockType) RenderLayer {
        return switch (block) {
            .glass, .water => .translucent,
            .oak_leaves, .torch, .torch_wall_south, .torch_wall_north, .torch_wall_east, .torch_wall_west,
            .ladder_south, .ladder_north, .ladder_east, .ladder_west,
            .oak_door_bottom_east, .oak_door_bottom_east_open,
            .oak_door_bottom_south, .oak_door_bottom_south_open,
            .oak_door_bottom_west, .oak_door_bottom_west_open,
            .oak_door_bottom_north, .oak_door_bottom_north_open,
            .oak_door_top_east, .oak_door_top_east_open,
            .oak_door_top_south, .oak_door_top_south_open,
            .oak_door_top_west, .oak_door_top_west_open,
            .oak_door_top_north, .oak_door_top_north_open,
            .oak_fence_post, .oak_fence_n, .oak_fence_s, .oak_fence_e, .oak_fence_w,
            .oak_fence_ns, .oak_fence_ne, .oak_fence_nw, .oak_fence_se, .oak_fence_sw, .oak_fence_ew,
            .oak_fence_nse, .oak_fence_nsw, .oak_fence_new, .oak_fence_sew, .oak_fence_nsew,
            => .cutout,
            else => .solid,
        };
    }
    pub fn emittedLight(block: BlockType) [3]u8 {
        return switch (block) {
            .glowstone => .{ 255, 200, 100 },
            .torch, .torch_wall_south, .torch_wall_north, .torch_wall_east, .torch_wall_west => .{ 200, 160, 80 },
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
                    const tex_indices = getShapedTexIndices(block);
                    for (shape_faces, 0..) |sf, sf_idx| {
                        if (!sf.always_emit) {
                            const neighbor = padded[@intCast(base + padded_face_deltas[sf.face_bucket])];
                            if (shouldCullShapeFace(sf, neighbor)) continue;
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

                const emits = block_properties.emittedLight(block);
                const is_emitter = emits[0] > 0 or emits[1] > 0 or emits[2] > 0;

                // Water uses lowered models unless water is above
                const water_lowered = block == .water and
                    padded[@intCast(base + padded_face_deltas[4])] != .water;

                for (0..6) |face| {
                    const neighbor = padded[@intCast(base + padded_face_deltas[face])];

                    if (shouldCullFace(block, face, neighbor)) continue;
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
                        .oak_planks, .oak_slab_double => 11,
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
                        .torch, .torch_wall_south, .torch_wall_north, .torch_wall_east, .torch_wall_west,
                        .ladder_south, .ladder_north, .ladder_east, .ladder_west,
                        .oak_door_bottom_east, .oak_door_bottom_east_open,
                        .oak_door_bottom_south, .oak_door_bottom_south_open,
                        .oak_door_bottom_west, .oak_door_bottom_west_open,
                        .oak_door_bottom_north, .oak_door_bottom_north_open,
                        .oak_door_top_east, .oak_door_top_east_open,
                        .oak_door_top_south, .oak_door_top_south_open,
                        .oak_door_top_west, .oak_door_top_west_open,
                        .oak_door_top_north, .oak_door_top_north_open,
                        .oak_fence_post, .oak_fence_n, .oak_fence_s, .oak_fence_e, .oak_fence_w,
                        .oak_fence_ns, .oak_fence_ne, .oak_fence_nw, .oak_fence_se, .oak_fence_sw, .oak_fence_ew,
                        .oak_fence_nse, .oak_fence_nsw, .oak_fence_new, .oak_fence_sew, .oak_fence_nsew,
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

                    const model_index: u9 = if (water_lowered)
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

pub fn generateLodChunkMesh(
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    neighbors: [6]?*const Chunk,
) !ChunkMeshResult {
    const tz = tracy.zone(@src(), "generateLodChunkMesh");
    defer tz.end();

    var padded: [PADDED_BLOCKS]BlockType = undefined;
    buildPaddedBlocks(&padded, chunk, neighbors);

    const max_sky_packed = packLight(255, .{ 0, 0, 0 });
    const lod_light = LightEntry{ .corners = .{ max_sky_packed, max_sky_packed, max_sky_packed, max_sky_packed } };
    const lod_ao: [4]u2 = .{ 0, 0, 0, 0 };

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

                // Water uses lowered models unless water is above
                const water_lowered = block == .water and
                    padded[@intCast(base + padded_face_deltas[4])] != .water;

                for (0..6) |face| {
                    const neighbor = padded[@intCast(base + padded_face_deltas[face])];

                    if (shouldCullFace(block, face, neighbor)) continue;
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
                        .oak_planks, .oak_slab_double => 11,
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
                        .oak_slab_bottom, .oak_slab_top => 11,
                        .oak_stairs_south, .oak_stairs_north, .oak_stairs_east, .oak_stairs_west => 11,
                        .torch, .torch_wall_south, .torch_wall_north, .torch_wall_east, .torch_wall_west => 28,
                        .ladder_south, .ladder_north, .ladder_east, .ladder_west => 29,
                        .oak_door_bottom_east, .oak_door_bottom_east_open,
                        .oak_door_bottom_south, .oak_door_bottom_south_open,
                        .oak_door_bottom_west, .oak_door_bottom_west_open,
                        .oak_door_bottom_north, .oak_door_bottom_north_open,
                        => 32,
                        .oak_door_top_east, .oak_door_top_east_open,
                        .oak_door_top_south, .oak_door_top_south_open,
                        .oak_door_top_west, .oak_door_top_west_open,
                        .oak_door_top_north, .oak_door_top_north_open,
                        => 33,
                        .oak_fence_post, .oak_fence_n, .oak_fence_s, .oak_fence_e, .oak_fence_w,
                        .oak_fence_ns, .oak_fence_ne, .oak_fence_nw, .oak_fence_se, .oak_fence_sw, .oak_fence_ew,
                        .oak_fence_nse, .oak_fence_nsw, .oak_fence_new, .oak_fence_sew, .oak_fence_nsew,
                        => 11, // oak_planks
                    };

                    const model_index: u9 = if (water_lowered)
                        WATER_MODEL_BASE + @as(u9, @intCast(face))
                    else
                        @intCast(face);
                    const face_data = types.packFaceData(
                        @intCast(bx),
                        @intCast(by),
                        @intCast(bz),
                        tex_index,
                        model_index,
                        lod_ao,
                    );

                    try layer_faces[layer][face].append(allocator, face_data);
                    try layer_lights[layer][face].append(allocator, lod_light);
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
                            if (shouldCullShapeFace(sf, neighbor)) continue;
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

                    if (shouldCullFace(block, face, neighbor_block)) continue;
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

// ── Face culling tests ─────────────────────────────────────────────────────

test "oppositeFace: correct pairs" {
    try testing.expectEqual(@as(usize, 1), oppositeFace(0)); // +Z ↔ -Z
    try testing.expectEqual(@as(usize, 0), oppositeFace(1));
    try testing.expectEqual(@as(usize, 3), oppositeFace(2)); // -X ↔ +X
    try testing.expectEqual(@as(usize, 2), oppositeFace(3));
    try testing.expectEqual(@as(usize, 5), oppositeFace(4)); // +Y ↔ -Y
    try testing.expectEqual(@as(usize, 4), oppositeFace(5));
}

test "oppositeFace: double opposite is identity" {
    for (0..6) |f| {
        try testing.expectEqual(f, oppositeFace(oppositeFace(f)));
    }
}

test "getOcclusionBitmap: air is zero" {
    for (0..6) |f| {
        try testing.expectEqual(@as(u16, 0), getOcclusionBitmap(.air, f));
    }
}

test "getOcclusionBitmap: opaque blocks are full" {
    const opaque_blocks = [_]BlockType{ .stone, .dirt, .grass_block, .cobblestone, .oak_planks, .bedrock };
    for (opaque_blocks) |block| {
        for (0..6) |f| {
            try testing.expectEqual(@as(u16, 0xFFFF), getOcclusionBitmap(block, f));
        }
    }
}

test "getOcclusionBitmap: transparent blocks are zero" {
    // Glass, water, leaves have full faces but are transparent — bitmap 0
    try testing.expectEqual(@as(u16, 0), getOcclusionBitmap(.glass, 0));
    try testing.expectEqual(@as(u16, 0), getOcclusionBitmap(.water, 0));
    try testing.expectEqual(@as(u16, 0), getOcclusionBitmap(.oak_leaves, 0));
}

test "getOcclusionBitmap: non-solid shaped blocks are zero" {
    // Torch and ladder are not solid shaped — no occlusion
    try testing.expectEqual(@as(u16, 0), getOcclusionBitmap(.torch, 0));
    try testing.expectEqual(@as(u16, 0), getOcclusionBitmap(.ladder_south, 0));
}

test "shouldCullFace: opaque next to air shows face" {
    try testing.expect(!shouldCullFace(.stone, 0, .air));
}

test "shouldCullFace: opaque next to opaque hides face" {
    try testing.expect(shouldCullFace(.stone, 0, .stone));
}

test "shouldCullFace: opaque next to glass shows face" {
    try testing.expect(!shouldCullFace(.stone, 0, .glass));
}

test "shouldCullFace: glass next to opaque hides face" {
    // Glass bitmap = 0, but neighbor is full → cull (Minecraft: occluder == block())
    try testing.expect(shouldCullFace(.glass, 0, .stone));
}

test "shouldCullFace: glass next to partial shows face" {
    // Glass bitmap = 0, neighbor is partial (slab, no registry) → render
    // Matches Minecraft: shape == empty → return true (render)
    try testing.expect(!shouldCullFace(.glass, 0, .oak_slab_bottom));
}

test "shouldCullFace: opaque next to slab shows face (no registry)" {
    // Without registry, slab bitmap = 0, so it can't occlude anything
    try testing.expect(!shouldCullFace(.stone, 0, .oak_slab_bottom));
}

test "shouldCullFace: slab next to torch shows face" {
    try testing.expect(!shouldCullFace(.oak_slab_bottom, 0, .torch));
}

test "shouldCullFace: slab top face next to air shows" {
    try testing.expect(!shouldCullFace(.oak_slab_bottom, 4, .air));
}

test "bitmap culling logic: slab-vs-slab covers shared area" {
    // Direct bitmap test (no registry needed): bottom slab side = 0x00FF
    const slab_side: u16 = 0x00FF; // bottom 2 rows
    const full_face: u16 = 0xFFFF;

    // Slab vs full block: full covers slab → cull
    try testing.expect((slab_side & ~full_face) == 0);
    // Full block vs slab: slab doesn't cover full → don't cull
    try testing.expect((full_face & ~slab_side) != 0);
    // Slab vs slab: identical bitmaps → cull
    try testing.expect((slab_side & ~slab_side) == 0);
    // Slab vs empty: empty doesn't cover → don't cull
    try testing.expect((slab_side & ~@as(u16, 0)) != 0);
}

test "bitmap culling logic: stairs partial faces" {
    // Stairs west face: bottom slab 0x00FF | upper back 0x3300 = 0x33FF
    const stairs_west: u16 = 0x33FF;
    const full_face: u16 = 0xFFFF;
    const slab_side: u16 = 0x00FF;

    // Full block covers stairs → cull
    try testing.expect((stairs_west & ~full_face) == 0);
    // Stairs don't cover full block → don't cull
    try testing.expect((full_face & ~stairs_west) != 0);
    // Slab doesn't cover stairs (stairs has 0x3300 that slab lacks) → don't cull
    try testing.expect((stairs_west & ~slab_side) != 0);
    // Stairs cover slab (slab is 0x00FF, stairs has 0x00FF subset) → cull
    try testing.expect((slab_side & ~stairs_west) == 0);
}
