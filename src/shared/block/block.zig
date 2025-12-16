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
///
/// Bit layout (different block types interpret bits differently):
/// - Bits 0-1: slab_type (slabs) OR stair_facing (stairs)
/// - Bits 2-3: axis (logs) OR stair_half + shape_low (stairs)
/// - Bit 4: waterlogged
/// - Bits 5-6: reserved OR stair_shape_high (stairs)
/// - Bit 7: reserved
pub const BlockState = packed struct {
    /// Slab type (0=bottom, 1=top, 2=double) - 2 bits
    /// For stairs: facing (north=0, south=1, east=2, west=3)
    slab_type: SlabType = .bottom,
    /// Axis for rotatable blocks - 2 bits
    /// For stairs: half (bit 1) + shape_low (bit 0)
    axis: Axis = .y,
    /// Waterlogged state - 1 bit
    waterlogged: bool = false,
    /// For stairs: shape_high (2 bits), otherwise reserved
    _extra: u2 = 0,
    /// Reserved for future use
    _reserved: u1 = 0,

    // === Slab Types (existing) ===
    pub const SlabType = enum(u2) {
        bottom = 0,
        top = 1,
        double = 2,
        _,
    };

    // === Axis Types (existing) ===
    pub const Axis = enum(u2) {
        x = 0,
        y = 1,
        z = 2,
        _,
    };

    // === Stair Types (new) ===
    pub const StairFacing = enum(u2) {
        north = 0,
        south = 1,
        east = 2,
        west = 3,

        /// Get clockwise rotation (Y rotation)
        /// north -> east -> south -> west -> north
        pub fn clockwise(self: StairFacing) StairFacing {
            return switch (self) {
                .north => .east,
                .east => .south,
                .south => .west,
                .west => .north,
            };
        }

        /// Get counter-clockwise rotation (Y rotation)
        /// north -> west -> south -> east -> north
        pub fn counterClockwise(self: StairFacing) StairFacing {
            return switch (self) {
                .north => .west,
                .west => .south,
                .south => .east,
                .east => .north,
            };
        }
    };

    pub const StairHalf = enum(u1) {
        bottom = 0,
        top = 1,
    };

    pub const StairShape = enum(u3) {
        straight = 0,
        inner_left = 1,
        inner_right = 2,
        outer_left = 3,
        outer_right = 4,
        _,
    };

    /// Default state
    pub const DEFAULT = BlockState{};

    /// Create a slab state
    pub fn slab(slab_type_val: SlabType) BlockState {
        return .{ .slab_type = slab_type_val };
    }

    /// Create a stair state
    pub fn stair(facing: StairFacing, half: StairHalf, shape: StairShape) BlockState {
        const shape_val: u3 = @intFromEnum(shape);
        return .{
            .slab_type = @enumFromInt(@intFromEnum(facing)), // reuse bits 0-1
            .axis = @enumFromInt((@as(u2, @intFromEnum(half)) << 1) | @as(u2, @truncate(shape_val))), // bits 2-3
            ._extra = @truncate(shape_val >> 1), // bits 5-6 for shape high
        };
    }

    /// Get stair facing direction
    pub fn getStairFacing(self: BlockState) StairFacing {
        return @enumFromInt(@intFromEnum(self.slab_type));
    }

    /// Get stair half (bottom/top)
    pub fn getStairHalf(self: BlockState) StairHalf {
        const axis_val: u2 = @intFromEnum(self.axis);
        return @enumFromInt((axis_val >> 1) & 1);
    }

    /// Get stair shape
    pub fn getStairShape(self: BlockState) StairShape {
        const axis_val: u2 = @intFromEnum(self.axis);
        const low: u3 = axis_val & 1;
        const high: u3 = @as(u3, self._extra) << 1;
        return @enumFromInt(high | low);
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

/// Leaves block (full shape, not opaque, solid)
pub const LEAVES_BLOCK_VTABLE = BlockVTable{
    .getShape = fullBlockGetShape,
    .isOpaque = leavesBlockIsOpaque,
    .isSolid = fullBlockIsSolid,
};

fn leavesBlockIsOpaque(_: BlockState) bool {
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
