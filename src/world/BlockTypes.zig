// Shared types for block definitions.
// Self-contained — no imports from BlockState or WorldState.

// ==== Property Types ====

pub const Facing = enum(u2) { south, north, east, west };
pub const Half = enum(u1) { bottom, top };
pub const SlabType = enum(u2) { bottom, top, double };
pub const Placement = enum(u3) { standing, wall_south, wall_north, wall_east, wall_west };
pub const StairShape = enum(u3) { straight, inner_left, inner_right, outer_left, outer_right };

// ==== Geometry Types ====

pub const AABB = struct { min: [3]f32, max: [3]f32 };
pub const Transform = enum { none, flip_y, rotate_90, rotate_180, rotate_270, flip_y_rotate_90, flip_y_rotate_180, flip_y_rotate_270 };
pub const ModelInfo = struct { json_file: []const u8, transform: Transform };

// ==== Collision Types ====

pub const BlockBox = struct { min: [3]f32, max: [3]f32 };
pub const BlockBoxes = struct { boxes: [3]BlockBox, count: u8 };

pub fn oneBox(min: [3]f32, max: [3]f32) BlockBoxes {
    return .{ .boxes = .{ .{ .min = min, .max = max }, undefined, undefined }, .count = 1 };
}

pub fn fullCubeBox() BlockBoxes {
    return oneBox(.{ 0, 0, 0 }, .{ 1, 1, 1 });
}

// ==== Display Types ====

pub const RenderLayer = enum(u2) { solid, cutout, translucent };
pub const LAYER_COUNT = 3;
pub const TexIndices = struct { top: i16, side: i16 };
pub const BlockShape = enum(u8) { full, slab_bottom, slab_top, stairs, torch, ladder, fence, door };

// ==== Block Definition ====

pub const BlockDef = struct {
    name: []const u8,
    state_count: u16 = 1,

    // Per-block constants
    color: [4]f32 = .{ 0.5, 0.5, 0.5, 1.0 },
    tex_indices: TexIndices = .{ .top = 0, .side = 0 },
    render_layer: RenderLayer = .solid,
    emitted_light: [3]u8 = .{ 0, 0, 0 },
    canonical_props: u8 = 0,

    // Base boolean flags (used when fn is null)
    is_targetable: bool = true,
    base_opaque: bool = true,
    base_solid: bool = true,
    base_culls_self: bool = true,
    base_shaped: bool = false,
    base_solid_shaped: bool = false,
    base_block_shape: BlockShape = .full,

    // State-dependent overrides (null = use base value)
    is_opaque_fn: ?*const fn (u8) bool = null,
    is_solid_fn: ?*const fn (u8) bool = null,
    culls_self_fn: ?*const fn (u8) bool = null,
    is_shaped_fn: ?*const fn (u8) bool = null,
    is_solid_shaped_fn: ?*const fn (u8) bool = null,
    hitbox_fn: ?*const fn (u8) ?AABB = null,
    collision_fn: ?*const fn (u8) BlockBoxes = null,
    model_info_fn: ?*const fn (u8) ?ModelInfo = null,
    tex_indices_fn: ?*const fn (u8) TexIndices = null,
    block_shape_fn: ?*const fn (u8) BlockShape = null,
};

// ==== Shared Geometry Helpers ====

pub fn facingToRotation(facing: Facing) Transform {
    return switch (facing) {
        .south => .none,
        .north => .rotate_180,
        .east => .rotate_90,
        .west => .rotate_270,
    };
}

pub fn oppositeFacing(facing: Facing) Facing {
    return switch (facing) {
        .south => .north,
        .north => .south,
        .east => .west,
        .west => .east,
    };
}

pub fn rotateCW(facing: Facing) Facing {
    return switch (facing) {
        .south => .west,
        .west => .north,
        .north => .east,
        .east => .south,
    };
}

pub fn rotateCCW(facing: Facing) Facing {
    return switch (facing) {
        .south => .east,
        .east => .north,
        .north => .west,
        .west => .south,
    };
}

/// Step box covering the back half of the block for a given facing.
pub fn straightStepBox(facing: Facing, sy0: f32, sy1: f32) BlockBox {
    return switch (facing) {
        .south => .{ .min = .{ 0, sy0, 0 }, .max = .{ 1, sy1, 0.5 } },
        .north => .{ .min = .{ 0, sy0, 0.5 }, .max = .{ 1, sy1, 1 } },
        .east => .{ .min = .{ 0, sy0, 0 }, .max = .{ 0.5, sy1, 1 } },
        .west => .{ .min = .{ 0.5, sy0, 0 }, .max = .{ 1, sy1, 1 } },
    };
}

/// Quarter block at the intersection of two perpendicular facing directions.
pub fn quadrantBox(facing: Facing, side: Facing, sy0: f32, sy1: f32) BlockBox {
    const x0: f32 = if (facing == .east or side == .east) 0.0 else if (facing == .west or side == .west) 0.5 else 0.0;
    const x1: f32 = if (facing == .west or side == .west) 1.0 else if (facing == .east or side == .east) 0.5 else 1.0;
    const z0: f32 = if (facing == .south or side == .south) 0.0 else if (facing == .north or side == .north) 0.5 else 0.0;
    const z1: f32 = if (facing == .north or side == .north) 1.0 else if (facing == .south or side == .south) 0.5 else 1.0;
    return .{ .min = .{ x0, sy0, z0 }, .max = .{ x1, sy1, z1 } };
}
