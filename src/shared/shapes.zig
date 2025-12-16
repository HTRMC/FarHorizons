/// Shapes - Factory methods and common shape definitions
/// Equivalent to Minecraft's net.minecraft.world.phys.shapes.Shapes
///
/// This module provides:
/// - Pre-defined common shapes (EMPTY, BLOCK, slabs, etc.)
/// - Factory methods for creating shapes
/// - Boolean operations (join, or, and)
/// - Occlusion testing utilities
/// - Rotation support for generating directional variants
const std = @import("std");
const voxel_shape = @import("VoxelShape.zig");
const VoxelShape = voxel_shape.VoxelShape;
const CubeVoxelShape = voxel_shape.CubeVoxelShape;
const BitSetDiscreteVoxelShape = voxel_shape.BitSetDiscreteVoxelShape;
const BitSetDiscreteVoxelShape2D = voxel_shape.BitSetDiscreteVoxelShape2D;
const Direction = voxel_shape.Direction;
const Axis = voxel_shape.Axis;
const OctahedralGroup = voxel_shape.OctahedralGroup;
const rotate = voxel_shape.rotate;
const rotateHorizontal = voxel_shape.rotateHorizontal;

/// Boolean operations for shape joining
pub const BooleanOp = enum {
    /// false, false -> false
    /// false, true  -> false
    /// true,  false -> false
    /// true,  true  -> true
    @"and",

    /// false, false -> false
    /// false, true  -> true
    /// true,  false -> true
    /// true,  true  -> true
    @"or",

    /// false, false -> false
    /// false, true  -> false
    /// true,  false -> true
    /// true,  true  -> false
    only_first,

    /// false, false -> false
    /// false, true  -> true
    /// true,  false -> false
    /// true,  true  -> false
    only_second,

    /// false, false -> true
    /// false, true  -> true
    /// true,  false -> true
    /// true,  true  -> false
    not_and,

    /// false, false -> false
    /// false, true  -> true
    /// true,  false -> true
    /// true,  true  -> false
    not_same,

    pub fn apply(self: BooleanOp, a: bool, b: bool) bool {
        return switch (self) {
            .@"and" => a and b,
            .@"or" => a or b,
            .only_first => a and !b,
            .only_second => !a and b,
            .not_and => !(a and b),
            .not_same => a != b,
        };
    }
};

// ======================
// Pre-defined Shapes
// ======================

pub const Shapes = struct {
    /// Empty shape (air, no collision/occlusion)
    pub const EMPTY = voxel_shape.EMPTY;

    /// Full block (16x16x16)
    pub const BLOCK = voxel_shape.BLOCK;

    /// Bottom half slab (y: 0-8)
    pub const SLAB_BOTTOM = voxel_shape.fromBlockBounds(.{ 0, 0, 0 }, .{ 16, 8, 16 });

    /// Top half slab (y: 8-16)
    pub const SLAB_TOP = voxel_shape.fromBlockBounds(.{ 0, 8, 0 }, .{ 16, 16, 16 });

    /// Double slab (full block)
    pub const SLAB_DOUBLE = BLOCK;

    /// Carpet / snow layer (y: 0-1, uses 16 divisions)
    pub const CARPET = voxel_shape.fromBlockBounds(.{ 0, 0, 0 }, .{ 16, 1, 16 });

    /// Fence post center (6-10 on X and Z)
    pub const FENCE_POST = voxel_shape.fromBlockBounds(.{ 6, 0, 6 }, .{ 10, 16, 10 });

    /// Wall post center (same as fence post)
    pub const WALL_POST = FENCE_POST;

    /// Pressure plate (inset on sides, y: 0-1)
    pub const PRESSURE_PLATE = voxel_shape.fromBlockBounds(.{ 1, 0, 1 }, .{ 15, 1, 15 });

    /// Trapdoor bottom (y: 0-3)
    pub const TRAPDOOR_BOTTOM = voxel_shape.fromBlockBounds(.{ 0, 0, 0 }, .{ 16, 3, 16 });

    /// Trapdoor top (y: 13-16)
    pub const TRAPDOOR_TOP = voxel_shape.fromBlockBounds(.{ 0, 13, 0 }, .{ 16, 16, 16 });

    /// Ladder (facing north, z: 0-2)
    pub const LADDER_NORTH = voxel_shape.fromBlockBounds(.{ 0, 0, 0 }, .{ 16, 16, 2 });

    /// Torch (centered, y: 0-10)
    pub const TORCH = voxel_shape.fromBlockBounds(.{ 6, 0, 6 }, .{ 10, 10, 10 });

    /// Path block (full XZ, y: 0-15)
    pub const PATH_BLOCK = voxel_shape.fromBlockBounds(.{ 0, 0, 0 }, .{ 16, 15, 16 });

    /// Farmland (full XZ, y: 0-15)
    pub const FARMLAND = PATH_BLOCK;

    /// Soul sand (slightly shorter than full block)
    pub const SOUL_SAND = voxel_shape.fromBlockBounds(.{ 0, 0, 0 }, .{ 16, 14, 16 });

    /// Lily pad (full XZ, thin on Y)
    pub const LILY_PAD = voxel_shape.fromBlockBounds(.{ 0, 0, 0 }, .{ 16, 1.5, 16 });

    // === Stair shapes ===
    // Exact Minecraft implementation from StairBlock.java
    //
    // Base shapes:
    // - SHAPE_OUTER = column(16, 0, 8) OR box(0, 8, 0, 8, 16, 8)
    //   = bottom_slab OR NW_corner_step
    // - SHAPE_STRAIGHT = SHAPE_OUTER OR rotate(SHAPE_OUTER, 90)
    //   = bottom_slab + NW + NE corners = north-facing straight stair
    // - SHAPE_INNER = SHAPE_STRAIGHT OR rotate(SHAPE_STRAIGHT, 90)
    //   = bottom_slab + N + E edges = NE inner corner stair

    /// Block.column(16.0, 0.0, 8.0) = bottom slab
    fn column(size_xz: f32, min_y: f32, max_y: f32) VoxelShape {
        const half = size_xz / 2.0;
        return voxel_shape.fromBlockBounds(
            .{ 8.0 - half, min_y, 8.0 - half },
            .{ 8.0 + half, max_y, 8.0 + half },
        );
    }

    /// SHAPE_OUTER: bottom slab + NW corner step
    /// farhorizons: Shapes.or(Block.column(16.0, 0.0, 8.0), Block.box(0.0, 8.0, 0.0, 8.0, 16.0, 8.0))
    const SHAPE_OUTER: VoxelShape = blk: {
        const bottom_slab = column(16.0, 0.0, 8.0);
        const nw_corner = voxel_shape.fromBlockBounds(.{ 0, 8, 0 }, .{ 8, 16, 8 });
        break :blk @"or"(&bottom_slab, &nw_corner);
    };

    /// SHAPE_STRAIGHT: SHAPE_OUTER + rotate(SHAPE_OUTER, 90)
    /// = bottom slab + NW corner + NE corner = north-facing straight stair
    const SHAPE_STRAIGHT: VoxelShape = blk: {
        const rotated = rotate(SHAPE_OUTER, OctahedralGroup.BLOCK_ROT_Y_90);
        break :blk @"or"(&SHAPE_OUTER, &rotated);
    };

    /// SHAPE_INNER: SHAPE_STRAIGHT + rotate(SHAPE_STRAIGHT, 90)
    /// = north edge + east edge = NE inner corner
    const SHAPE_INNER: VoxelShape = blk: {
        const rotated = rotate(SHAPE_STRAIGHT, OctahedralGroup.BLOCK_ROT_Y_90);
        break :blk @"or"(&SHAPE_STRAIGHT, &rotated);
    };

    // === Direction-indexed shape maps ===
    // Indexed by Direction enum: [down, up, north, south, west, east]
    // Only horizontal directions are used: north=2, south=3, west=4, east=5

    /// rotateHorizontal creates Map<Direction, VoxelShape>
    /// Returns shapes indexed by direction
    fn rotateHorizontalMap(base: VoxelShape, initial: OctahedralGroup) [6]VoxelShape {
        var result: [6]VoxelShape = undefined;
        // North
        result[@intFromEnum(Direction.north)] = rotate(base, initial);
        // East (90 CW)
        result[@intFromEnum(Direction.east)] = rotate(base, OctahedralGroup.BLOCK_ROT_Y_90.compose(initial));
        // South (180)
        result[@intFromEnum(Direction.south)] = rotate(base, OctahedralGroup.BLOCK_ROT_Y_180.compose(initial));
        // West (270)
        result[@intFromEnum(Direction.west)] = rotate(base, OctahedralGroup.BLOCK_ROT_Y_270.compose(initial));
        // Fill unused directions with empty
        result[@intFromEnum(Direction.down)] = EMPTY;
        result[@intFromEnum(Direction.up)] = EMPTY;
        return result;
    }

    /// Bottom half shape maps (indexed by Direction)
    pub const SHAPE_BOTTOM_OUTER = rotateHorizontalMap(SHAPE_OUTER, OctahedralGroup.IDENTITY);
    pub const SHAPE_BOTTOM_STRAIGHT = rotateHorizontalMap(SHAPE_STRAIGHT, OctahedralGroup.IDENTITY);
    pub const SHAPE_BOTTOM_INNER = rotateHorizontalMap(SHAPE_INNER, OctahedralGroup.IDENTITY);

    /// Top half shape maps (INVERT_Y as initial rotation)
    pub const SHAPE_TOP_OUTER = rotateHorizontalMap(SHAPE_OUTER, OctahedralGroup.INVERT_Y);
    pub const SHAPE_TOP_STRAIGHT = rotateHorizontalMap(SHAPE_STRAIGHT, OctahedralGroup.INVERT_Y);
    pub const SHAPE_TOP_INNER = rotateHorizontalMap(SHAPE_INNER, OctahedralGroup.INVERT_Y);

    /// Get stair shape by state (exact Minecraft getShape implementation)
    /// shape_type: straight, inner_left, inner_right, outer_left, outer_right
    /// half: bottom, top
    /// facing: north, south, east, west (as Direction enum)
    pub fn getStairShape(shape_type: StairShape, half: StairHalf, facing: Direction) *const VoxelShape {
        // Select the map based on shape type and half
        const map: *const [6]VoxelShape = switch (shape_type) {
            .straight => if (half == .bottom) &SHAPE_BOTTOM_STRAIGHT else &SHAPE_TOP_STRAIGHT,
            .outer_left, .outer_right => if (half == .bottom) &SHAPE_BOTTOM_OUTER else &SHAPE_TOP_OUTER,
            .inner_left, .inner_right => if (half == .bottom) &SHAPE_BOTTOM_INNER else &SHAPE_TOP_INNER,
        };

        // Determine lookup direction based on shape type
        // farhorizons: STRAIGHT, OUTER_LEFT, INNER_RIGHT -> facing
        //           INNER_LEFT -> facing.getCounterClockWise()
        //           OUTER_RIGHT -> facing.getClockWise()
        const lookup_dir: Direction = switch (shape_type) {
            .straight, .outer_left, .inner_right => facing,
            .inner_left => facing.counterClockwise(),
            .outer_right => facing.clockwise(),
        };

        return &map[@intFromEnum(lookup_dir)];
    }

    /// Stair shape variants
    pub const StairShape = enum {
        straight,
        inner_left,
        inner_right,
        outer_left,
        outer_right,
    };

    /// Stair half (top or bottom)
    pub const StairHalf = enum {
        bottom,
        top,
    };

    // === Direct access constants for backwards compatibility ===
    // These index into the direction maps

    // Bottom-half straight stairs
    pub const STAIR_BOTTOM_NORTH = SHAPE_BOTTOM_STRAIGHT[@intFromEnum(Direction.north)];
    pub const STAIR_BOTTOM_EAST = SHAPE_BOTTOM_STRAIGHT[@intFromEnum(Direction.east)];
    pub const STAIR_BOTTOM_SOUTH = SHAPE_BOTTOM_STRAIGHT[@intFromEnum(Direction.south)];
    pub const STAIR_BOTTOM_WEST = SHAPE_BOTTOM_STRAIGHT[@intFromEnum(Direction.west)];

    // Top-half straight stairs
    pub const STAIR_TOP_NORTH = SHAPE_TOP_STRAIGHT[@intFromEnum(Direction.north)];
    pub const STAIR_TOP_EAST = SHAPE_TOP_STRAIGHT[@intFromEnum(Direction.east)];
    pub const STAIR_TOP_SOUTH = SHAPE_TOP_STRAIGHT[@intFromEnum(Direction.south)];
    pub const STAIR_TOP_WEST = SHAPE_TOP_STRAIGHT[@intFromEnum(Direction.west)];

    // Bottom-half inner corners (indexed by the corner direction they form)
    pub const STAIR_BOTTOM_INNER_NE = SHAPE_BOTTOM_INNER[@intFromEnum(Direction.north)];
    pub const STAIR_BOTTOM_INNER_SE = SHAPE_BOTTOM_INNER[@intFromEnum(Direction.east)];
    pub const STAIR_BOTTOM_INNER_SW = SHAPE_BOTTOM_INNER[@intFromEnum(Direction.south)];
    pub const STAIR_BOTTOM_INNER_NW = SHAPE_BOTTOM_INNER[@intFromEnum(Direction.west)];

    // Top-half inner corners
    pub const STAIR_TOP_INNER_NE = SHAPE_TOP_INNER[@intFromEnum(Direction.north)];
    pub const STAIR_TOP_INNER_SE = SHAPE_TOP_INNER[@intFromEnum(Direction.east)];
    pub const STAIR_TOP_INNER_SW = SHAPE_TOP_INNER[@intFromEnum(Direction.south)];
    pub const STAIR_TOP_INNER_NW = SHAPE_TOP_INNER[@intFromEnum(Direction.west)];

    // Bottom-half outer corners
    pub const STAIR_BOTTOM_OUTER_NW = SHAPE_BOTTOM_OUTER[@intFromEnum(Direction.north)];
    pub const STAIR_BOTTOM_OUTER_NE = SHAPE_BOTTOM_OUTER[@intFromEnum(Direction.east)];
    pub const STAIR_BOTTOM_OUTER_SE = SHAPE_BOTTOM_OUTER[@intFromEnum(Direction.south)];
    pub const STAIR_BOTTOM_OUTER_SW = SHAPE_BOTTOM_OUTER[@intFromEnum(Direction.west)];

    // Top-half outer corners
    pub const STAIR_TOP_OUTER_NW = SHAPE_TOP_OUTER[@intFromEnum(Direction.north)];
    pub const STAIR_TOP_OUTER_NE = SHAPE_TOP_OUTER[@intFromEnum(Direction.east)];
    pub const STAIR_TOP_OUTER_SE = SHAPE_TOP_OUTER[@intFromEnum(Direction.south)];
    pub const STAIR_TOP_OUTER_SW = SHAPE_TOP_OUTER[@intFromEnum(Direction.west)];
};

// ======================
// Factory Functions
// ======================

/// Create an empty shape
pub fn empty() VoxelShape {
    return voxel_shape.empty();
}

/// Create a full block shape
pub fn block() VoxelShape {
    return voxel_shape.block();
}

/// Create a box shape from normalized coordinates (0-1)
pub fn box(
    x_min: f64,
    y_min: f64,
    z_min: f64,
    x_max: f64,
    y_max: f64,
    z_max: f64,
) VoxelShape {
    return voxel_shape.create(x_min, y_min, z_min, x_max, y_max, z_max);
}

/// Create a box shape from block coordinates (0-16)
pub fn boxFromBlock(from: [3]f32, to: [3]f32) VoxelShape {
    return voxel_shape.fromBlockBounds(from, to);
}

// ======================
// Boolean Operations
// ======================

/// Join two shapes with a boolean operation
/// Currently only supports same-resolution CubeVoxelShapes
pub fn join(a: *const VoxelShape, b: *const VoxelShape, op: BooleanOp) VoxelShape {
    // Fast paths for common cases
    switch (op) {
        .@"or" => {
            if (a.isEmpty()) return b.*;
            if (b.isEmpty()) return a.*;
            if (a.isFullBlock() or b.isFullBlock()) return Shapes.BLOCK;
        },
        .@"and" => {
            if (a.isEmpty() or b.isEmpty()) return Shapes.EMPTY;
            if (a.isFullBlock()) return b.*;
            if (b.isFullBlock()) return a.*;
        },
        .only_first => {
            if (a.isEmpty()) return Shapes.EMPTY;
            if (b.isEmpty()) return a.*;
            if (b.isFullBlock()) return Shapes.EMPTY;
        },
        .only_second => {
            if (b.isEmpty()) return Shapes.EMPTY;
            if (a.isEmpty()) return b.*;
            if (a.isFullBlock()) return Shapes.EMPTY;
        },
        else => {},
    }

    // For cube shapes with same resolution, do direct bitwise operations
    if (a.* == .cube and b.* == .cube) {
        const ac = &a.cube;
        const bc = &b.cube;

        if (ac.shape.base.x_size == bc.shape.base.x_size and
            ac.shape.base.y_size == bc.shape.base.y_size and
            ac.shape.base.z_size == bc.shape.base.z_size)
        {
            return joinCubesDirectly(ac, bc, op);
        }
    }

    // For different resolutions or types, would need coordinate merging
    // For now, return first shape as fallback
    return a.*;
}

/// Join two same-resolution CubeVoxelShapes directly
fn joinCubesDirectly(a: *const CubeVoxelShape, b: *const CubeVoxelShape, op: BooleanOp) VoxelShape {
    var result = CubeVoxelShape.init(
        a.shape.base.x_size,
        a.shape.base.y_size,
        a.shape.base.z_size,
    );

    // Apply boolean operation to each voxel
    for (0..a.shape.base.x_size) |x| {
        for (0..a.shape.base.y_size) |y| {
            for (0..a.shape.base.z_size) |z| {
                const xu8: u8 = @intCast(x);
                const yu8: u8 = @intCast(y);
                const zu8: u8 = @intCast(z);
                const av = a.isFull(xu8, yu8, zu8);
                const bv = b.isFull(xu8, yu8, zu8);
                if (op.apply(av, bv)) {
                    result.fill(xu8, yu8, zu8);
                }
            }
        }
    }

    if (result.isEmpty()) return Shapes.EMPTY;
    if (result.isFullBlock()) return Shapes.BLOCK;

    return .{ .cube = result };
}

/// OR two shapes together (union)
pub fn @"or"(a: *const VoxelShape, b: *const VoxelShape) VoxelShape {
    return join(a, b, .@"or");
}

/// AND two shapes together (intersection)
pub fn @"and"(a: *const VoxelShape, b: *const VoxelShape) VoxelShape {
    return join(a, b, .@"and");
}

// ======================
// Occlusion Testing
// ======================

/// Check if joining two shapes with an operation produces a non-empty result
/// Used for fast occlusion testing without creating the full result shape
pub fn joinIsNotEmpty(a: *const VoxelShape, b: *const VoxelShape, op: BooleanOp) bool {
    // Fast paths
    switch (op) {
        .@"or" => return !a.isEmpty() or !b.isEmpty(),
        .@"and" => {
            if (a.isEmpty() or b.isEmpty()) return false;
            if (a.isFullBlock() and b.isFullBlock()) return true;
        },
        .only_first => {
            if (a.isEmpty()) return false;
            if (b.isFullBlock()) return false;
            if (b.isEmpty()) return !a.isEmpty();
        },
        .only_second => {
            if (b.isEmpty()) return false;
            if (a.isFullBlock()) return false;
            if (a.isEmpty()) return !b.isEmpty();
        },
        else => {},
    }

    // For cube shapes, do direct check
    if (a.* == .cube and b.* == .cube) {
        const ac = &a.cube;
        const bc = &b.cube;

        if (ac.shape.base.x_size == bc.shape.base.x_size and
            ac.shape.base.y_size == bc.shape.base.y_size and
            ac.shape.base.z_size == bc.shape.base.z_size)
        {
            for (0..ac.shape.base.x_size) |x| {
                for (0..ac.shape.base.y_size) |y| {
                    for (0..ac.shape.base.z_size) |z| {
                        const xu8: u8 = @intCast(x);
                        const yu8: u8 = @intCast(y);
                        const zu8: u8 = @intCast(z);
                        if (op.apply(ac.isFull(xu8, yu8, zu8), bc.isFull(xu8, yu8, zu8))) {
                            return true;
                        }
                    }
                }
            }
            return false;
        }
    }

    // Fallback: compute the join and check if empty
    const result = join(a, b, op);
    return !result.isEmpty();
}

/// Check if a face should be rendered based on neighbor occlusion
/// This is the main entry point for face culling
pub fn shouldRenderFace(
    block_shape: *const VoxelShape,
    neighbor_shape: *const VoxelShape,
    direction: Direction,
) bool {
    // Use the optimized face occlusion check
    return block_shape.shouldRenderFace(direction, neighbor_shape);
}

/// Get face occlusion shape for a direction
/// Returns a 2D shape representing which parts of the face are solid
pub fn getFaceOcclusionShape(shape: *const VoxelShape, direction: Direction) BitSetDiscreteVoxelShape2D {
    return shape.getFaceShapeConst(direction);
}

// ======================
// Tests
// ======================

test "Shapes constants" {
    try std.testing.expect(Shapes.EMPTY.isEmpty());
    try std.testing.expect(Shapes.BLOCK.isFullBlock());
    try std.testing.expect(!Shapes.SLAB_BOTTOM.isEmpty());
    try std.testing.expect(!Shapes.SLAB_BOTTOM.isFullBlock());
}

test "BooleanOp apply" {
    try std.testing.expect(BooleanOp.@"and".apply(true, true));
    try std.testing.expect(!BooleanOp.@"and".apply(true, false));
    try std.testing.expect(!BooleanOp.@"and".apply(false, true));
    try std.testing.expect(!BooleanOp.@"and".apply(false, false));

    try std.testing.expect(BooleanOp.@"or".apply(true, true));
    try std.testing.expect(BooleanOp.@"or".apply(true, false));
    try std.testing.expect(BooleanOp.@"or".apply(false, true));
    try std.testing.expect(!BooleanOp.@"or".apply(false, false));

    try std.testing.expect(BooleanOp.only_first.apply(true, false));
    try std.testing.expect(!BooleanOp.only_first.apply(true, true));
    try std.testing.expect(!BooleanOp.only_first.apply(false, true));
}

test "join OR" {
    const result = @"or"(&Shapes.EMPTY, &Shapes.BLOCK);
    try std.testing.expect(result.isFullBlock());

    const result2 = @"or"(&Shapes.EMPTY, &Shapes.EMPTY);
    try std.testing.expect(result2.isEmpty());
}

test "join AND" {
    const result = @"and"(&Shapes.BLOCK, &Shapes.BLOCK);
    try std.testing.expect(result.isFullBlock());

    const result2 = @"and"(&Shapes.EMPTY, &Shapes.BLOCK);
    try std.testing.expect(result2.isEmpty());
}

test "joinIsNotEmpty" {
    try std.testing.expect(joinIsNotEmpty(&Shapes.BLOCK, &Shapes.BLOCK, .@"and"));
    try std.testing.expect(!joinIsNotEmpty(&Shapes.EMPTY, &Shapes.BLOCK, .@"and"));
    try std.testing.expect(joinIsNotEmpty(&Shapes.BLOCK, &Shapes.EMPTY, .only_first));
    try std.testing.expect(!joinIsNotEmpty(&Shapes.BLOCK, &Shapes.BLOCK, .only_first));
}

test "shouldRenderFace" {
    // Full block next to full block: don't render
    try std.testing.expect(!shouldRenderFace(&Shapes.BLOCK, &Shapes.BLOCK, .north));

    // Full block next to air: render
    try std.testing.expect(shouldRenderFace(&Shapes.BLOCK, &Shapes.EMPTY, .north));

    // Slab next to air: render
    try std.testing.expect(shouldRenderFace(&Shapes.SLAB_BOTTOM, &Shapes.EMPTY, .north));
}

test "stair shape is cube type" {
    // Verify stair shapes are cubes, not blocks
    try std.testing.expect(Shapes.STAIR_BOTTOM_EAST == .cube);
    try std.testing.expect(Shapes.STAIR_TOP_EAST == .cube);
    try std.testing.expect(Shapes.STAIR_BOTTOM_NORTH == .cube);

    // Verify they're not full blocks or empty
    try std.testing.expect(!Shapes.STAIR_BOTTOM_EAST.isFullBlock());
    try std.testing.expect(!Shapes.STAIR_BOTTOM_EAST.isEmpty());
}

test "stair shape voxel pattern" {
    // STAIR_BOTTOM_EAST should be L-shaped in 2x2x2 grid:
    // Bottom layer (y=0): all 4 voxels filled
    // Top layer (y=1): only east half (x=1) filled
    const shape = Shapes.STAIR_BOTTOM_EAST;
    try std.testing.expect(shape == .cube);

    const cube = &shape.cube;
    try std.testing.expectEqual(@as(u8, 2), cube.shape.base.x_size);
    try std.testing.expectEqual(@as(u8, 2), cube.shape.base.y_size);
    try std.testing.expectEqual(@as(u8, 2), cube.shape.base.z_size);

    // Bottom layer - all filled
    try std.testing.expect(cube.isFull(0, 0, 0));
    try std.testing.expect(cube.isFull(0, 0, 1));
    try std.testing.expect(cube.isFull(1, 0, 0));
    try std.testing.expect(cube.isFull(1, 0, 1));

    // Top layer - only east half (x=1)
    try std.testing.expect(!cube.isFull(0, 1, 0)); // west side empty
    try std.testing.expect(!cube.isFull(0, 1, 1)); // west side empty
    try std.testing.expect(cube.isFull(1, 1, 0)); // east side filled
    try std.testing.expect(cube.isFull(1, 1, 1)); // east side filled
}

test "stair face occlusion with stone" {
    // Stone block (full) below top stair
    // Stone's UP face next to stair's DOWN face should render
    // because stair's DOWN is only partially covered (east half)

    const stone = Shapes.BLOCK;
    const top_stair = Shapes.STAIR_TOP_EAST;

    // Top stair's DOWN face (y=0) should be partial (only east half)
    const down_face = top_stair.getFaceShapeConst(.down);
    try std.testing.expect(!down_face.isFull()); // Should be partial

    // Stone's UP face is full
    const up_face = stone.getFaceShapeConst(.up);
    try std.testing.expect(up_face.isFull());

    // Stone's UP face should NOT be occluded by top stair's DOWN face
    // (stone's full face is not a subset of stair's partial face)
    try std.testing.expect(!up_face.isSubsetOf(&down_face));

    // Therefore stone should render its UP face next to top stair
    try std.testing.expect(shouldRenderFace(&stone, &top_stair, .up));
}
