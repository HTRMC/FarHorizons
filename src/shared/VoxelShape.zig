/// VoxelShape - Abstract shape interface for block collision and occlusion
/// Equivalent to Minecraft's net.minecraft.world.phys.shapes.VoxelShape
///
/// VoxelShape is the main interface for representing block shapes.
/// It provides methods for:
/// - Collision detection
/// - Face occlusion testing (which faces to cull)
/// - Bounds queries
///
/// Implementations:
/// - CubeVoxelShape: Power-of-2 aligned shapes (most efficient)
/// - ArrayVoxelShape: Arbitrary coordinate shapes (more flexible)
const std = @import("std");

// Re-export core types
pub const DiscreteVoxelShape = @import("DiscreteVoxelShape.zig").DiscreteVoxelShape;
pub const Axis = @import("DiscreteVoxelShape.zig").Axis;
pub const Direction = @import("DiscreteVoxelShape.zig").Direction;
pub const AxisDirection = @import("DiscreteVoxelShape.zig").AxisDirection;

pub const BitSetDiscreteVoxelShape = @import("BitsetDiscreteVoxelShape.zig").BitSetDiscreteVoxelShape;
pub const BitSetDiscreteVoxelShape2D = @import("BitsetDiscreteVoxelShape.zig").BitSetDiscreteVoxelShape2D;

pub const CubeVoxelShape = @import("CubeVoxelShape.zig").CubeVoxelShape;
pub const findRequiredResolution = @import("CubeVoxelShape.zig").findRequiredResolution;
pub const findBits = @import("CubeVoxelShape.zig").findBits;

pub const ArrayVoxelShape = @import("ArrayVoxelShape.zig").ArrayVoxelShape;

pub const SliceShape = @import("SliceShape.zig").SliceShape;
pub const IndexMerger = @import("IndexMerger.zig").IndexMerger;
pub const DiscreteCubeMerger = @import("IndexMerger.zig").DiscreteCubeMerger;
pub const IdenticalMerger = @import("IndexMerger.zig").IdenticalMerger;

/// VoxelShape variant union - the main shape type
/// Use this when you need runtime polymorphism between shape types
pub const VoxelShape = union(enum) {
    const Self = @This();

    /// Power-of-2 aligned shape (most common, most efficient)
    cube: CubeVoxelShape,
    /// Arbitrary coordinate shape
    array: ArrayVoxelShape,
    /// Empty shape singleton
    empty: void,
    /// Full block singleton
    block: void,

    // =====================
    // Shape Queries
    // =====================

    /// Check if shape is empty (no volume)
    pub fn isEmpty(self: *const Self) bool {
        return switch (self.*) {
            .empty => true,
            .block => false,
            .cube => |*s| s.isEmpty(),
            .array => |*s| s.isEmpty(),
        };
    }

    /// Check if shape fills the entire block
    pub fn isFullBlock(self: *const Self) bool {
        return switch (self.*) {
            .empty => false,
            .block => true,
            .cube => |*s| s.isFullBlock(),
            .array => |*s| s.isFullBlock(),
        };
    }

    /// Get AABB bounds [minX, minY, minZ, maxX, maxY, maxZ]
    pub fn getBounds(self: *const Self) [6]f64 {
        return switch (self.*) {
            .empty => .{ 0, 0, 0, 0, 0, 0 },
            .block => .{ 0, 0, 0, 1, 1, 1 },
            .cube => |*s| s.getBounds(),
            .array => |*s| s.getBounds(),
        };
    }

    /// Get min bound along axis
    pub fn min(self: *const Self, axis: Axis) f64 {
        return switch (self.*) {
            .empty => 1.0,
            .block => 0.0,
            .cube => |*s| s.min(axis),
            .array => |*s| s.min(axis),
        };
    }

    /// Get max bound along axis
    pub fn max(self: *const Self, axis: Axis) f64 {
        return switch (self.*) {
            .empty => 0.0,
            .block => 1.0,
            .cube => |*s| s.max(axis),
            .array => |*s| s.max(axis),
        };
    }

    // =====================
    // Face Occlusion
    // =====================

    /// Get the 2D face shape for occlusion testing
    pub fn getFaceShape(self: *Self, direction: Direction) BitSetDiscreteVoxelShape2D {
        return switch (self.*) {
            .empty => BitSetDiscreteVoxelShape2D.init(1, 1),
            .block => BitSetDiscreteVoxelShape2D.initFull(1, 1),
            .cube => |*s| s.getFaceShape(direction),
            .array => |*s| s.getFaceShape(direction),
        };
    }

    /// Get face shape (const version)
    pub fn getFaceShapeConst(self: *const Self, direction: Direction) BitSetDiscreteVoxelShape2D {
        return switch (self.*) {
            .empty => BitSetDiscreteVoxelShape2D.init(1, 1),
            .block => BitSetDiscreteVoxelShape2D.initFull(1, 1),
            .cube => |*s| s.getFaceShapeConst(direction),
            .array => |*s| s.getFaceShapeConst(direction),
        };
    }

    /// Check if this shape's face reaches the block boundary
    /// Only faces at the boundary can be occluded by neighbors
    pub fn isFaceAtBoundary(self: *const Self, direction: Direction) bool {
        return switch (self.*) {
            .empty => false,
            .block => true,
            .cube => |*s| s.isFaceAtBoundary(direction),
            .array => |*s| s.isFaceAtBoundary(direction),
        };
    }

    /// Check if this shape's face is fully occluded by another shape's opposite face
    /// Returns true if the face SHOULD BE CULLED (not rendered)
    pub fn faceOccludedBy(self: *const Self, direction: Direction, other: *const Self) bool {
        // Fast paths
        if (other.isEmpty()) return false; // Empty neighbor never occludes
        if (self.isEmpty()) return true; // Empty shape has no visible faces

        // Check if our face is at the block boundary
        // If not, it can't be occluded by a neighbor (there's a gap)
        if (!self.isFaceAtBoundary(direction)) {
            return false;
        }

        // Check if neighbor's face is at the block boundary
        // If not, it can't occlude us (there's a gap)
        if (!other.isFaceAtBoundary(direction.opposite())) {
            return false;
        }

        // Both faces are at boundaries - check if neighbor fully covers our face
        if (other.isFullBlock()) return true; // Full block occludes everything at boundary

        // Get face shapes and compare
        const self_face = self.getFaceShapeConst(direction);
        const other_face = other.getFaceShapeConst(direction.opposite());

        // Check if self's face is covered by other's face
        return self_face.isSubsetOf(&other_face);
    }

    /// Check if face should be rendered (inverse of faceOccludedBy)
    pub fn shouldRenderFace(self: *const Self, direction: Direction, neighbor: *const Self) bool {
        return !self.faceOccludedBy(direction, neighbor);
    }

    // =====================
    // Coordinate Queries
    // =====================

    /// Get size along axis (number of divisions)
    pub fn getSize(self: *const Self, axis: Axis) u8 {
        return switch (self.*) {
            .empty, .block => 1,
            .cube => |*s| s.getSize(axis),
            .array => |*s| s.getSize(axis),
        };
    }

    /// Get coordinate value at index along axis
    pub fn getCoord(self: *const Self, axis: Axis, index: u8) f64 {
        return switch (self.*) {
            .empty, .block => if (index == 0) @as(f64, 0.0) else 1.0,
            .cube => |*s| s.getCoord(axis, index),
            .array => |*s| s.getCoord(axis, index),
        };
    }

    /// Find index for a coordinate value
    pub fn findIndex(self: *const Self, axis: Axis, coord: f64) u8 {
        return switch (self.*) {
            .empty, .block => 0,
            .cube => |*s| s.findIndex(axis, coord),
            .array => |*s| s.findIndex(axis, coord),
        };
    }

    // =====================
    // Voxel Queries
    // =====================

    /// Check if voxel at position is filled
    pub fn isFull(self: *const Self, x: u8, y: u8, z: u8) bool {
        return switch (self.*) {
            .empty => false,
            .block => true,
            .cube => |*s| s.isFull(x, y, z),
            .array => |*s| s.isFull(x, y, z),
        };
    }

    // =====================
    // Cleanup
    // =====================

    pub fn deinit(self: *Self) void {
        switch (self.*) {
            .array => |*s| s.deinit(),
            else => {},
        }
    }
};

// =====================
// Factory Functions
// =====================

/// Create an empty shape
pub fn empty() VoxelShape {
    return .empty;
}

/// Create a full block shape
pub fn block() VoxelShape {
    return .block;
}

/// Create a shape from block model bounds (0-16 range)
pub fn fromBlockBounds(from: [3]f32, to: [3]f32) VoxelShape {
    // Check for degenerate bounds
    if (from[0] >= to[0] or from[1] >= to[1] or from[2] >= to[2]) {
        return .empty;
    }

    // Check if full block
    if (from[0] == 0 and from[1] == 0 and from[2] == 0 and
        to[0] == 16 and to[1] == 16 and to[2] == 16)
    {
        return .block;
    }

    // Use CubeVoxelShape for power-of-2 aligned bounds
    return .{ .cube = CubeVoxelShape.fromBlockBounds(from, to) };
}

/// Create a shape from normalized bounds (0-1 range)
pub fn create(
    x_min: f64,
    y_min: f64,
    z_min: f64,
    x_max: f64,
    y_max: f64,
    z_max: f64,
) VoxelShape {
    // Convert to 0-16 range
    const from = [3]f32{
        @floatCast(x_min * 16.0),
        @floatCast(y_min * 16.0),
        @floatCast(z_min * 16.0),
    };
    const to = [3]f32{
        @floatCast(x_max * 16.0),
        @floatCast(y_max * 16.0),
        @floatCast(z_max * 16.0),
    };
    return fromBlockBounds(from, to);
}

// =====================
// Pre-defined Shapes
// =====================

/// Empty shape constant
pub const EMPTY = VoxelShape{ .empty = {} };

/// Full block shape constant
pub const BLOCK = VoxelShape{ .block = {} };

// =====================
// Tests
// =====================

test "VoxelShape empty and block" {
    try std.testing.expect(EMPTY.isEmpty());
    try std.testing.expect(!EMPTY.isFullBlock());

    try std.testing.expect(!BLOCK.isEmpty());
    try std.testing.expect(BLOCK.isFullBlock());
}

test "VoxelShape fromBlockBounds" {
    const full = fromBlockBounds(.{ 0, 0, 0 }, .{ 16, 16, 16 });
    try std.testing.expect(full.isFullBlock());

    const slab = fromBlockBounds(.{ 0, 0, 0 }, .{ 16, 8, 16 });
    try std.testing.expect(!slab.isEmpty());
    try std.testing.expect(!slab.isFullBlock());

    const degenerate = fromBlockBounds(.{ 5, 5, 5 }, .{ 5, 5, 5 });
    try std.testing.expect(degenerate.isEmpty());
}

test "VoxelShape face occlusion" {
    const full = BLOCK;
    const slab = fromBlockBounds(.{ 0, 0, 0 }, .{ 16, 8, 16 });

    // Full block's face is occluded by another full block
    try std.testing.expect(full.faceOccludedBy(.north, &full));

    // Slab's up face is occluded by full block above
    try std.testing.expect(slab.faceOccludedBy(.up, &full));

    // Full block's down face is occluded by slab's up face
    // (slab's up face is full on XZ plane)
    try std.testing.expect(full.faceOccludedBy(.down, &slab));

    // Slab's face is NOT occluded by empty
    try std.testing.expect(!slab.faceOccludedBy(.north, &EMPTY));
}

test "VoxelShape shouldRenderFace" {
    const stone = BLOCK;
    const slab = fromBlockBounds(.{ 0, 0, 0 }, .{ 16, 8, 16 });
    const air = EMPTY;

    // Stone next to air: render
    try std.testing.expect(stone.shouldRenderFace(.north, &air));

    // Stone next to stone: don't render
    try std.testing.expect(!stone.shouldRenderFace(.north, &stone));

    // Slab's down face next to stone: don't render
    try std.testing.expect(!slab.shouldRenderFace(.down, &stone));

    // Slab next to air: render
    try std.testing.expect(slab.shouldRenderFace(.north, &air));
}
