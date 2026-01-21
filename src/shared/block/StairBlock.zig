/// StairBlock - Stair block behavior
const std = @import("std");
const block_mod = @import("Block.zig");
const BlockState = block_mod.BlockState;
const BlockVTable = block_mod.BlockVTable;
const RenderLayer = block_mod.RenderLayer;
const voxel_shape = @import("../VoxelShape.zig");
const VoxelShape = voxel_shape.VoxelShape;
const shapes = @import("../Shapes.zig");
const Shapes = shapes.Shapes;

/// Stair block VTable
pub const STAIR_BLOCK_VTABLE = BlockVTable{
    .getShape = stairGetShape,
    .isOpaque = stairIsOpaque,
    .isSolid = stairIsSolid,
    .getRenderLayer = stairGetRenderLayer,
};

/// Get the shape based on stair state
/// Shape selection uses direction lookup with clockwise/counterclockwise rotation
fn stairGetShape(state: BlockState) *const VoxelShape {
    const shape = state.getStairShape();
    const half = state.getStairHalf();
    const facing = state.getStairFacing();

    // - STRAIGHT, OUTER_LEFT, INNER_RIGHT -> use facing directly
    // - INNER_LEFT -> use facing.getCounterClockWise()
    // - OUTER_RIGHT -> use facing.getClockWise()
    const lookup_facing = switch (shape) {
        .straight, .outer_left, .inner_right => facing,
        .inner_left => facing.counterClockwise(),
        .outer_right => facing.clockwise(),
        _ => facing,
    };

    // Select shape type map based on shape variant and half
    return switch (shape) {
        .straight => getStraightByFacing(lookup_facing, half),
        .inner_left, .inner_right => getInnerByFacing(lookup_facing, half),
        .outer_left, .outer_right => getOuterByFacing(lookup_facing, half),
        _ => getStraightByFacing(lookup_facing, half),
    };
}

/// Get straight stair shape by facing direction
fn getStraightByFacing(facing: BlockState.StairFacing, half: BlockState.StairHalf) *const VoxelShape {
    return switch (half) {
        .bottom => switch (facing) {
            .north => &Shapes.STAIR_BOTTOM_NORTH,
            .south => &Shapes.STAIR_BOTTOM_SOUTH,
            .east => &Shapes.STAIR_BOTTOM_EAST,
            .west => &Shapes.STAIR_BOTTOM_WEST,
        },
        .top => switch (facing) {
            .north => &Shapes.STAIR_TOP_NORTH,
            .south => &Shapes.STAIR_TOP_SOUTH,
            .east => &Shapes.STAIR_TOP_EAST,
            .west => &Shapes.STAIR_TOP_WEST,
        },
    };
}

/// Get inner corner shape by facing direction
/// The base inner shape fills the L covering facing direction + clockwise direction
fn getInnerByFacing(facing: BlockState.StairFacing, half: BlockState.StairHalf) *const VoxelShape {
    return switch (half) {
        .bottom => switch (facing) {
            // NORTH inner: fills north step + east step = NE corner L-shape
            .north => &Shapes.STAIR_BOTTOM_INNER_NE,
            // EAST inner: fills east step + south step = SE corner L-shape
            .east => &Shapes.STAIR_BOTTOM_INNER_SE,
            // SOUTH inner: fills south step + west step = SW corner L-shape
            .south => &Shapes.STAIR_BOTTOM_INNER_SW,
            // WEST inner: fills west step + north step = NW corner L-shape
            .west => &Shapes.STAIR_BOTTOM_INNER_NW,
        },
        .top => switch (facing) {
            .north => &Shapes.STAIR_TOP_INNER_NE,
            .east => &Shapes.STAIR_TOP_INNER_SE,
            .south => &Shapes.STAIR_TOP_INNER_SW,
            .west => &Shapes.STAIR_TOP_INNER_NW,
        },
    };
}

/// Get outer corner shape by facing direction
/// The base outer shape fills only the corner at facing direction
fn getOuterByFacing(facing: BlockState.StairFacing, half: BlockState.StairHalf) *const VoxelShape {
    return switch (half) {
        .bottom => switch (facing) {
            // NORTH outer: fills only NW corner (northwest of stair)
            .north => &Shapes.STAIR_BOTTOM_OUTER_NW,
            // EAST outer: fills only NE corner
            .east => &Shapes.STAIR_BOTTOM_OUTER_NE,
            // SOUTH outer: fills only SE corner
            .south => &Shapes.STAIR_BOTTOM_OUTER_SE,
            // WEST outer: fills only SW corner
            .west => &Shapes.STAIR_BOTTOM_OUTER_SW,
        },
        .top => switch (facing) {
            .north => &Shapes.STAIR_TOP_OUTER_NW,
            .east => &Shapes.STAIR_TOP_OUTER_NE,
            .south => &Shapes.STAIR_TOP_OUTER_SE,
            .west => &Shapes.STAIR_TOP_OUTER_SW,
        },
    };
}

/// Stairs are never fully opaque (they have gaps)
fn stairIsOpaque(_: BlockState) bool {
    return false;
}

/// Stairs are always solid (have collision)
fn stairIsSolid(_: BlockState) bool {
    return true;
}

/// Stairs use solid render layer
fn stairGetRenderLayer(_: BlockState) RenderLayer {
    return .solid;
}

// ======================
// Tests
// ======================

test "StairBlock state encoding" {
    // Test stair state creation
    const state = BlockState.stair(.north, .bottom, .straight);
    try std.testing.expectEqual(BlockState.StairFacing.north, state.getStairFacing());
    try std.testing.expectEqual(BlockState.StairHalf.bottom, state.getStairHalf());
    try std.testing.expectEqual(BlockState.StairShape.straight, state.getStairShape());

    // Test different combinations
    const state2 = BlockState.stair(.east, .top, .inner_left);
    try std.testing.expectEqual(BlockState.StairFacing.east, state2.getStairFacing());
    try std.testing.expectEqual(BlockState.StairHalf.top, state2.getStairHalf());
    try std.testing.expectEqual(BlockState.StairShape.inner_left, state2.getStairShape());

    // Test outer corner
    const state3 = BlockState.stair(.west, .bottom, .outer_right);
    try std.testing.expectEqual(BlockState.StairFacing.west, state3.getStairFacing());
    try std.testing.expectEqual(BlockState.StairHalf.bottom, state3.getStairHalf());
    try std.testing.expectEqual(BlockState.StairShape.outer_right, state3.getStairShape());
}

test "StairBlock VTable" {
    const state = BlockState.stair(.north, .bottom, .straight);

    // Test shape retrieval
    const shape = stairGetShape(state);
    try std.testing.expect(!shape.isEmpty());

    // Test opacity/solidity
    try std.testing.expect(!stairIsOpaque(state));
    try std.testing.expect(stairIsSolid(state));
}

test "StairFacing clockwise/counterclockwise" {
    // Test clockwise rotation: north -> east -> south -> west -> north
    try std.testing.expectEqual(BlockState.StairFacing.east, BlockState.StairFacing.north.clockwise());
    try std.testing.expectEqual(BlockState.StairFacing.south, BlockState.StairFacing.east.clockwise());
    try std.testing.expectEqual(BlockState.StairFacing.west, BlockState.StairFacing.south.clockwise());
    try std.testing.expectEqual(BlockState.StairFacing.north, BlockState.StairFacing.west.clockwise());

    // Test counterclockwise rotation: north -> west -> south -> east -> north
    try std.testing.expectEqual(BlockState.StairFacing.west, BlockState.StairFacing.north.counterClockwise());
    try std.testing.expectEqual(BlockState.StairFacing.south, BlockState.StairFacing.west.counterClockwise());
    try std.testing.expectEqual(BlockState.StairFacing.east, BlockState.StairFacing.south.counterClockwise());
    try std.testing.expectEqual(BlockState.StairFacing.north, BlockState.StairFacing.east.counterClockwise());
}

test "Stair shape selection - straight stairs" {
    // Straight stairs should use facing direction directly
    const north_state = BlockState.stair(.north, .bottom, .straight);
    const north_shape = stairGetShape(north_state);
    try std.testing.expect(north_shape == &Shapes.STAIR_BOTTOM_NORTH);

    const east_state = BlockState.stair(.east, .bottom, .straight);
    const east_shape = stairGetShape(east_state);
    try std.testing.expect(east_shape == &Shapes.STAIR_BOTTOM_EAST);
}

test "Stair shape selection - inner corners" {
    // INNER_RIGHT uses facing directly -> gets NE corner for north facing
    const inner_right_north = BlockState.stair(.north, .bottom, .inner_right);
    const ir_shape = stairGetShape(inner_right_north);
    try std.testing.expect(ir_shape == &Shapes.STAIR_BOTTOM_INNER_NE);

    // INNER_LEFT uses facing.counterClockwise() -> north.ccw = west -> gets NW corner
    const inner_left_north = BlockState.stair(.north, .bottom, .inner_left);
    const il_shape = stairGetShape(inner_left_north);
    try std.testing.expect(il_shape == &Shapes.STAIR_BOTTOM_INNER_NW);
}

test "Stair shape selection - outer corners" {
    // OUTER_LEFT uses facing directly -> gets NW corner for north facing
    const outer_left_north = BlockState.stair(.north, .bottom, .outer_left);
    const ol_shape = stairGetShape(outer_left_north);
    try std.testing.expect(ol_shape == &Shapes.STAIR_BOTTOM_OUTER_NW);

    // OUTER_RIGHT uses facing.clockwise() -> north.cw = east -> gets NE corner
    const outer_right_north = BlockState.stair(.north, .bottom, .outer_right);
    const or_shape = stairGetShape(outer_right_north);
    try std.testing.expect(or_shape == &Shapes.STAIR_BOTTOM_OUTER_NE);
}

test "Stair face projections - bottom north straight" {
    // A bottom north-facing straight stair has:
    // - Full coverage on DOWN face (bottom slab fills entire bottom)
    // - Partial coverage on UP face (only north half)
    // - Partial coverage on NORTH face (L-shaped: full bottom, north half on top)
    // - Partial coverage on SOUTH face (only bottom half)
    // - Full coverage on WEST face (L-shaped fills entire face)
    // - Full coverage on EAST face (L-shaped fills entire face)
    const shape = &Shapes.STAIR_BOTTOM_NORTH;

    // DOWN face should be full (entire bottom is covered)
    const down_face = shape.getFaceShapeConst(.down);
    try std.testing.expect(down_face.isFull());

    // UP face should NOT be full (only north half)
    const up_face = shape.getFaceShapeConst(.up);
    try std.testing.expect(!up_face.isFull());
    try std.testing.expect(!up_face.isEmpty());

    // NORTH face at boundary should be full (step reaches north edge top to bottom)
    try std.testing.expect(shape.isFaceAtBoundary(.north));
    const north_face = shape.getFaceShapeConst(.north);
    try std.testing.expect(north_face.isFull());

    // SOUTH face should be partial (only bottom half touches south boundary)
    try std.testing.expect(shape.isFaceAtBoundary(.south));
    const south_face = shape.getFaceShapeConst(.south);
    try std.testing.expect(!south_face.isFull());

    // WEST face should be full (L-shape covers entire west face)
    try std.testing.expect(shape.isFaceAtBoundary(.west));
    const west_face = shape.getFaceShapeConst(.west);
    try std.testing.expect(west_face.isFull());

    // EAST face should be full (L-shape covers entire east face)
    try std.testing.expect(shape.isFaceAtBoundary(.east));
    const east_face = shape.getFaceShapeConst(.east);
    try std.testing.expect(east_face.isFull());
}

test "Stair culling - stair next to solid block" {
    const stair = &Shapes.STAIR_BOTTOM_NORTH;
    const solid = &Shapes.BLOCK;

    // Stair's DOWN face next to solid block above: should be culled
    try std.testing.expect(stair.faceOccludedBy(.down, solid));

    // Stair's NORTH face next to solid block to north: should be culled (full coverage)
    try std.testing.expect(stair.faceOccludedBy(.north, solid));

    // Stair's SOUTH face next to solid block to south: should NOT be fully culled
    // because the south face is only partial (bottom half)
    // But wait - the check is whether OUR face is covered by their face
    // Solid block's north face fully covers our partial south face
    try std.testing.expect(stair.faceOccludedBy(.south, solid));

    // Solid block's face next to stair should NOT be culled if stair doesn't fully cover
    // Solid's SOUTH face next to stair's NORTH face: stair's north face is full, so solid should be culled
    try std.testing.expect(solid.faceOccludedBy(.south, stair));

    // Solid's NORTH face next to stair's SOUTH face: stair's south face is partial
    // So solid's north face should NOT be culled
    try std.testing.expect(!solid.faceOccludedBy(.north, stair));
}
