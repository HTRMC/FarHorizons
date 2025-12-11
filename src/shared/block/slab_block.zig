/// SlabBlock - Slab block behavior
/// Equivalent to Minecraft's net.minecraft.world.level.block.SlabBlock
///
/// Slabs have three states:
/// - Bottom: occupies y=0 to y=0.5
/// - Top: occupies y=0.5 to y=1.0
/// - Double: full block (y=0 to y=1.0)
const std = @import("std");
const block_mod = @import("block.zig");
const Block = block_mod.Block;
const BlockState = block_mod.BlockState;
const BlockVTable = block_mod.BlockVTable;
const voxel_shape = @import("../voxel_shape.zig");
const VoxelShape = voxel_shape.VoxelShape;
const shapes = @import("../shapes.zig");
const Shapes = shapes.Shapes;

/// Slab block vtable
pub const SLAB_BLOCK_VTABLE = BlockVTable{
    .getShape = slabGetShape,
    .isOpaque = slabIsOpaque,
    .isSolid = slabIsSolid,
};

/// Get the shape based on slab type
fn slabGetShape(state: BlockState) *const VoxelShape {
    return switch (state.slab_type) {
        .bottom => &Shapes.SLAB_BOTTOM,
        .top => &Shapes.SLAB_TOP,
        .double => &Shapes.BLOCK,
        _ => &Shapes.SLAB_BOTTOM, // Default to bottom
    };
}

/// Slabs are only opaque when double
fn slabIsOpaque(state: BlockState) bool {
    return state.slab_type == .double;
}

/// Slabs are always solid (have collision)
fn slabIsSolid(_: BlockState) bool {
    return true;
}

/// Create a slab block definition
pub fn createSlabBlock(id: u16, name: []const u8) Block {
    return Block{
        .id = id,
        .name = name,
        .vtable = &SLAB_BLOCK_VTABLE,
    };
}

// ======================
// Tests
// ======================

test "Slab bottom shape" {
    const state = BlockState.slab(.bottom);
    const shape = slabGetShape(state);

    try std.testing.expect(!shape.isEmpty());
    try std.testing.expect(!shape.isFullBlock());

    // Bottom slab should have max Y of 0.5
    const bounds = shape.getBounds();
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), bounds[4], 0.01); // maxY
}

test "Slab top shape" {
    const state = BlockState.slab(.top);
    const shape = slabGetShape(state);

    try std.testing.expect(!shape.isEmpty());
    try std.testing.expect(!shape.isFullBlock());

    // Top slab should have min Y of 0.5
    const bounds = shape.getBounds();
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), bounds[1], 0.01); // minY
}

test "Slab double shape" {
    const state = BlockState.slab(.double);
    const shape = slabGetShape(state);

    try std.testing.expect(shape.isFullBlock());
}

test "Slab opacity" {
    try std.testing.expect(!slabIsOpaque(BlockState.slab(.bottom)));
    try std.testing.expect(!slabIsOpaque(BlockState.slab(.top)));
    try std.testing.expect(slabIsOpaque(BlockState.slab(.double)));
}
