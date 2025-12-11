/// Blocks - Block registry and definitions
/// Equivalent to Minecraft's net.minecraft.world.level.block.Blocks
///
/// This module contains all block definitions and provides
/// lookup by ID.
const std = @import("std");
const block_mod = @import("Block.zig");
const Block = block_mod.Block;
const BlockState = block_mod.BlockState;
const BlockVTable = block_mod.BlockVTable;
const slab_block = @import("SlabBlock.zig");
const voxel_shape = @import("../VoxelShape.zig");
const VoxelShape = voxel_shape.VoxelShape;
const shapes = @import("../Shapes.zig");
const Shapes = shapes.Shapes;

// ======================
// Block IDs
// ======================

pub const BlockId = enum(u16) {
    air = 0,
    stone = 1,
    oak_slab = 2,
    dirt = 3,
    grass_block = 4,
    cobblestone = 5,
    oak_planks = 6,
    spruce_slab = 7,
    birch_slab = 8,
    // Add more as needed
    _,
};

// ======================
// Block Definitions
// ======================

pub const AIR = Block{
    .id = @intFromEnum(BlockId.air),
    .name = "air",
    .vtable = &block_mod.AIR_BLOCK_VTABLE,
};

pub const STONE = Block{
    .id = @intFromEnum(BlockId.stone),
    .name = "stone",
    .vtable = &block_mod.FULL_BLOCK_VTABLE,
};

pub const OAK_SLAB = Block{
    .id = @intFromEnum(BlockId.oak_slab),
    .name = "oak_slab",
    .vtable = &slab_block.SLAB_BLOCK_VTABLE,
};

pub const DIRT = Block{
    .id = @intFromEnum(BlockId.dirt),
    .name = "dirt",
    .vtable = &block_mod.FULL_BLOCK_VTABLE,
};

pub const GRASS_BLOCK = Block{
    .id = @intFromEnum(BlockId.grass_block),
    .name = "grass_block",
    .vtable = &block_mod.FULL_BLOCK_VTABLE,
};

pub const COBBLESTONE = Block{
    .id = @intFromEnum(BlockId.cobblestone),
    .name = "cobblestone",
    .vtable = &block_mod.FULL_BLOCK_VTABLE,
};

pub const OAK_PLANKS = Block{
    .id = @intFromEnum(BlockId.oak_planks),
    .name = "oak_planks",
    .vtable = &block_mod.FULL_BLOCK_VTABLE,
};

pub const SPRUCE_SLAB = Block{
    .id = @intFromEnum(BlockId.spruce_slab),
    .name = "spruce_slab",
    .vtable = &slab_block.SLAB_BLOCK_VTABLE,
};

pub const BIRCH_SLAB = Block{
    .id = @intFromEnum(BlockId.birch_slab),
    .name = "birch_slab",
    .vtable = &slab_block.SLAB_BLOCK_VTABLE,
};

// ======================
// Block Registry
// ======================

/// All registered blocks indexed by ID
const BLOCK_REGISTRY = [_]*const Block{
    &AIR, // 0
    &STONE, // 1
    &OAK_SLAB, // 2
    &DIRT, // 3
    &GRASS_BLOCK, // 4
    &COBBLESTONE, // 5
    &OAK_PLANKS, // 6
    &SPRUCE_SLAB, // 7
    &BIRCH_SLAB, // 8
};

/// Get block by ID
pub fn getBlock(id: u16) *const Block {
    if (id < BLOCK_REGISTRY.len) {
        return BLOCK_REGISTRY[id];
    }
    return &AIR; // Unknown blocks become air
}

/// Get block name by ID
pub fn getBlockName(id: u16) []const u8 {
    return getBlock(id).name;
}

/// Get block by BlockId enum
pub fn getBlockById(id: BlockId) *const Block {
    return getBlock(@intFromEnum(id));
}

/// Get shape for a block ID and state
pub fn getShape(id: u16, state: BlockState) *const VoxelShape {
    return getBlock(id).getShape(state);
}

/// Check if block is opaque
pub fn isOpaque(id: u16, state: BlockState) bool {
    return getBlock(id).isOpaque(state);
}

/// Check if block is solid
pub fn isSolid(id: u16, state: BlockState) bool {
    return getBlock(id).isSolid(state);
}

// ======================
// Tests
// ======================

test "Block registry lookup" {
    const stone = getBlock(1);
    try std.testing.expectEqualStrings("stone", stone.name);

    const slab = getBlock(2);
    try std.testing.expectEqualStrings("oak_slab", slab.name);
}

test "Unknown block returns air" {
    const unknown = getBlock(9999);
    try std.testing.expectEqualStrings("air", unknown.name);
}

test "Slab shapes by state" {
    const bottom = getShape(2, BlockState.slab(.bottom));
    const top = getShape(2, BlockState.slab(.top));
    const double = getShape(2, BlockState.slab(.double));

    try std.testing.expect(!bottom.isFullBlock());
    try std.testing.expect(!top.isFullBlock());
    try std.testing.expect(double.isFullBlock());
}
