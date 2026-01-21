/// RotatedPillarBlock - Axis-rotated block behavior (logs, wood, pillars)
///
/// Based on Minecraft's RotatedPillarBlock.java
/// These blocks have an axis property (X, Y, Z) that determines their orientation.
/// The axis is set based on which face was clicked during placement:
/// - Click top/bottom face -> axis=Y (vertical)
/// - Click north/south face -> axis=Z (horizontal, Z-aligned)
/// - Click east/west face -> axis=X (horizontal, X-aligned)
const std = @import("std");
const block_mod = @import("Block.zig");
const Block = block_mod.Block;
const BlockState = block_mod.BlockState;
const BlockVTable = block_mod.BlockVTable;
const RenderLayer = block_mod.RenderLayer;
const voxel_shape = @import("../VoxelShape.zig");
const VoxelShape = voxel_shape.VoxelShape;
const Direction = voxel_shape.Direction;
const shapes = @import("../Shapes.zig");
const Shapes = shapes.Shapes;

/// Rotated pillar block vtable
/// These are full blocks - the axis only affects the model/texture orientation
pub const ROTATED_PILLAR_BLOCK_VTABLE = BlockVTable{
    .getShape = pillarGetShape,
    .isOpaque = pillarIsOpaque,
    .isSolid = pillarIsSolid,
    .getRenderLayer = pillarGetRenderLayer,
};

/// Pillar blocks are always full cubes
fn pillarGetShape(_: BlockState) *const VoxelShape {
    return &Shapes.BLOCK;
}

/// Pillar blocks are always opaque
fn pillarIsOpaque(_: BlockState) bool {
    return true;
}

/// Pillar blocks are always solid
fn pillarIsSolid(_: BlockState) bool {
    return true;
}

/// Pillar blocks use solid render layer
fn pillarGetRenderLayer(_: BlockState) RenderLayer {
    return .solid;
}

/// Get the axis from a clicked face direction
/// This is used during block placement to determine the log orientation
pub fn getAxisFromDirection(dir: Direction) BlockState.Axis {
    return switch (dir) {
        .up, .down => .y,
        .north, .south => .z,
        .east, .west => .x,
    };
}

/// Rotate the pillar axis based on rotation
/// Used for structure rotation (90/180/270 degrees)
pub fn rotatePillar(axis: BlockState.Axis, rotation: Rotation) BlockState.Axis {
    return switch (rotation) {
        .none, .clockwise_180 => axis,
        .clockwise_90, .counterclockwise_90 => switch (axis) {
            .x => .z,
            .z => .x,
            .y => .y,
            _ => axis,
        },
    };
}

/// Rotation enum for structure rotation
pub const Rotation = enum {
    none,
    clockwise_90,
    clockwise_180,
    counterclockwise_90,
};

/// Create a rotated pillar block definition
pub fn createRotatedPillarBlock(id: u16, name: []const u8) Block {
    return Block{
        .id = id,
        .name = name,
        .vtable = &ROTATED_PILLAR_BLOCK_VTABLE,
    };
}

// ======================
// Tests
// ======================

test "Pillar block shape is always full" {
    const state_y = BlockState{ .axis = .y };
    const state_x = BlockState{ .axis = .x };
    const state_z = BlockState{ .axis = .z };

    try std.testing.expect(pillarGetShape(state_y).isFullBlock());
    try std.testing.expect(pillarGetShape(state_x).isFullBlock());
    try std.testing.expect(pillarGetShape(state_z).isFullBlock());
}

test "Pillar block is always opaque and solid" {
    const state = BlockState{ .axis = .y };
    try std.testing.expect(pillarIsOpaque(state));
    try std.testing.expect(pillarIsSolid(state));
}

test "Axis from direction" {
    // Top/bottom -> Y axis
    try std.testing.expectEqual(BlockState.Axis.y, getAxisFromDirection(.up));
    try std.testing.expectEqual(BlockState.Axis.y, getAxisFromDirection(.down));

    // North/south -> Z axis
    try std.testing.expectEqual(BlockState.Axis.z, getAxisFromDirection(.north));
    try std.testing.expectEqual(BlockState.Axis.z, getAxisFromDirection(.south));

    // East/west -> X axis
    try std.testing.expectEqual(BlockState.Axis.x, getAxisFromDirection(.east));
    try std.testing.expectEqual(BlockState.Axis.x, getAxisFromDirection(.west));
}

test "Rotate pillar" {
    // No rotation or 180 rotation keeps axis the same
    try std.testing.expectEqual(BlockState.Axis.x, rotatePillar(.x, .none));
    try std.testing.expectEqual(BlockState.Axis.x, rotatePillar(.x, .clockwise_180));
    try std.testing.expectEqual(BlockState.Axis.y, rotatePillar(.y, .none));
    try std.testing.expectEqual(BlockState.Axis.y, rotatePillar(.y, .clockwise_180));

    // 90 degree rotation swaps X and Z
    try std.testing.expectEqual(BlockState.Axis.z, rotatePillar(.x, .clockwise_90));
    try std.testing.expectEqual(BlockState.Axis.x, rotatePillar(.z, .clockwise_90));
    try std.testing.expectEqual(BlockState.Axis.z, rotatePillar(.x, .counterclockwise_90));
    try std.testing.expectEqual(BlockState.Axis.x, rotatePillar(.z, .counterclockwise_90));

    // Y axis is unchanged by any rotation (rotating around Y)
    try std.testing.expectEqual(BlockState.Axis.y, rotatePillar(.y, .clockwise_90));
    try std.testing.expectEqual(BlockState.Axis.y, rotatePillar(.y, .counterclockwise_90));
}
