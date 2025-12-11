/// Block - Base block behavior interface
/// Equivalent to Minecraft's net.minecraft.world.level.block.Block
///
/// Blocks define the behavior and properties of a block type.
/// Each block can return different VoxelShapes based on block state.
const std = @import("std");
const voxel_shape = @import("../VoxelShape.zig");
const VoxelShape = voxel_shape.VoxelShape;
const shapes = @import("../Shapes.zig");
const Shapes = shapes.Shapes;

/// Block state properties that affect shape
/// Packed into a u8 for efficient storage
pub const BlockState = packed struct {
    /// Slab type (0=bottom, 1=top, 2=double) - 2 bits
    slab_type: SlabType = .bottom,
    /// Axis for rotatable blocks - 2 bits
    axis: Axis = .y,
    /// Waterlogged state - 1 bit
    waterlogged: bool = false,
    /// Reserved for future use
    _reserved: u3 = 0,

    pub const SlabType = enum(u2) {
        bottom = 0,
        top = 1,
        double = 2,
        _,
    };

    pub const Axis = enum(u2) {
        x = 0,
        y = 1,
        z = 2,
        _,
    };

    /// Default state
    pub const DEFAULT = BlockState{};

    /// Create a slab state
    pub fn slab(slab_type: SlabType) BlockState {
        return .{ .slab_type = slab_type };
    }
};

/// Block behavior vtable
pub const BlockVTable = struct {
    /// Get the collision/occlusion shape for this block state
    getShape: *const fn (state: BlockState) *const VoxelShape,
    /// Check if block is opaque (blocks light)
    isOpaque: *const fn (state: BlockState) bool,
    /// Check if block has collision
    isSolid: *const fn (state: BlockState) bool,
};

/// Block definition
pub const Block = struct {
    /// Block identifier
    id: u16,
    /// String name for debugging/resources
    name: []const u8,
    /// Behavior vtable
    vtable: *const BlockVTable,

    /// Get the shape for a given state
    pub fn getShape(self: *const Block, state: BlockState) *const VoxelShape {
        return self.vtable.getShape(state);
    }

    /// Check if opaque
    pub fn isOpaque(self: *const Block, state: BlockState) bool {
        return self.vtable.isOpaque(state);
    }

    /// Check if solid
    pub fn isSolid(self: *const Block, state: BlockState) bool {
        return self.vtable.isSolid(state);
    }
};

// ======================
// Default Block Behaviors
// ======================

/// Full cube block (stone, dirt, etc.)
pub const FULL_BLOCK_VTABLE = BlockVTable{
    .getShape = fullBlockGetShape,
    .isOpaque = fullBlockIsOpaque,
    .isSolid = fullBlockIsSolid,
};

fn fullBlockGetShape(_: BlockState) *const VoxelShape {
    return &Shapes.BLOCK;
}

fn fullBlockIsOpaque(_: BlockState) bool {
    return true;
}

fn fullBlockIsSolid(_: BlockState) bool {
    return true;
}

/// Air block
pub const AIR_BLOCK_VTABLE = BlockVTable{
    .getShape = airBlockGetShape,
    .isOpaque = airBlockIsOpaque,
    .isSolid = airBlockIsSolid,
};

fn airBlockGetShape(_: BlockState) *const VoxelShape {
    return &Shapes.EMPTY;
}

fn airBlockIsOpaque(_: BlockState) bool {
    return false;
}

fn airBlockIsSolid(_: BlockState) bool {
    return false;
}

// ======================
// Tests
// ======================

test "BlockState packing" {
    const state = BlockState.slab(.top);
    try std.testing.expectEqual(BlockState.SlabType.top, state.slab_type);

    // Verify it fits in u8
    const as_int: u8 = @bitCast(state);
    _ = as_int;
}

test "Full block behavior" {
    const block = Block{
        .id = 1,
        .name = "stone",
        .vtable = &FULL_BLOCK_VTABLE,
    };

    try std.testing.expect(block.isOpaque(.{}));
    try std.testing.expect(block.isSolid(.{}));
    try std.testing.expect(block.getShape(.{}).isFullBlock());
}
