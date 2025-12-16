/// VoxelShape - Abstract shape interface for block collision and occlusion
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

pub const OctahedralGroup = @import("OctahedralGroup.zig").OctahedralGroup;
pub const SymmetricGroup3 = @import("OctahedralGroup.zig").SymmetricGroup3;

pub const BitSetDiscreteVoxelShape = @import("BitsetDiscreteVoxelShape.zig").BitSetDiscreteVoxelShape;
pub const BitSetDiscreteVoxelShape2D = @import("BitsetDiscreteVoxelShape.zig").BitSetDiscreteVoxelShape2D;

pub const CubeVoxelShape = @import("CubeVoxelShape.zig").CubeVoxelShape;
pub const findRequiredResolution = @import("CubeVoxelShape.zig").findRequiredResolution;
pub const findBits = @import("CubeVoxelShape.zig").findBits;

pub const ArrayVoxelShape = @import("ArrayVoxelShape.zig").ArrayVoxelShape;

pub const SliceShape = @import("SliceShape.zig").SliceShape;
pub const sliceJoinIsNotEmpty = @import("SliceShape.zig").sliceJoinIsNotEmpty;
pub const SubShape = @import("SubShape.zig").SubShape;
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

    /// Check if this shape's face covers a specific rectangular region
    /// Used for per-element-face culling: check if neighbor covers the element's face region
    /// face_bounds are in block coordinates (0-16) as [min_u, min_v, max_u, max_v]
    /// where u,v depend on the face direction (e.g., for UP face: u=x, v=z)
    pub fn faceCoversRegion(
        self: *const Self,
        direction: Direction,
        face_bounds: [4]f32,
    ) bool {
        // If empty, covers nothing
        if (self.isEmpty()) return false;

        // If full block, covers everything
        if (self.isFullBlock()) return true;

        // Get this shape's face in the specified direction
        const face = self.getFaceShapeConst(direction);

        // Convert face_bounds from 0-16 to 0-1 range
        const u_min: f64 = face_bounds[0] / 16.0;
        const v_min: f64 = face_bounds[1] / 16.0;
        const u_max: f64 = face_bounds[2] / 16.0;
        const v_max: f64 = face_bounds[3] / 16.0;

        // Check if this face covers the specified region
        return face.coversRegion(u_min, u_max, v_min, v_max);
    }

    /// Check if a specific region of a face should be rendered given a neighbor
    /// This checks if the neighbor's opposite face covers the specified region
    pub fn shouldRenderFaceRegion(
        self: *const Self,
        direction: Direction,
        neighbor: *const Self,
        face_bounds: [4]f32,
    ) bool {
        _ = self; // We only check the neighbor's face covering the region
        // The region is occluded if the neighbor's opposite face covers it
        return !neighbor.faceCoversRegion(direction.opposite(), face_bounds);
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

    /// Get the underlying DiscreteVoxelShape
    /// Returns null for empty/block singletons (they use static shapes)
    pub fn getDiscreteShape(self: *const Self) ?*const DiscreteVoxelShape {
        return switch (self.*) {
            .empty, .block => null,
            .cube => |*s| &s.shape.base,
            .array => |*s| &s.shape.base,
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

/// Block center point for rotation (0.5, 0.5, 0.5)
pub const BLOCK_CENTER: [3]f64 = .{ 0.5, 0.5, 0.5 };

// =====================
// Shape Rotation
// =====================

/// Rotate a VoxelShape using an OctahedralGroup transformation
pub fn rotate(shape: VoxelShape, rotation: OctahedralGroup) VoxelShape {
    return rotateAroundPoint(shape, rotation, BLOCK_CENTER);
}

/// Rotate a VoxelShape using an OctahedralGroup transformation around a specific point
pub fn rotateAroundPoint(shape: VoxelShape, rotation: OctahedralGroup, rotation_point: [3]f64) VoxelShape {
    if (rotation.isIdentity()) {
        return shape;
    }

    return switch (shape) {
        .empty => .empty,
        .block => .block,
        .cube => |*s| blk: {
            // For CubeVoxelShape, if rotating around block center, just rotate the discrete shape
            const new_discrete = s.shape.rotate(rotation);
            if (rotation_point[0] == 0.5 and rotation_point[1] == 0.5 and rotation_point[2] == 0.5) {
                break :blk VoxelShape{ .cube = CubeVoxelShape.fromDiscrete(new_discrete) };
            }

            // Otherwise need to handle coordinate transformation
            const perm = rotation.permutation;
            const new_x_axis = perm.permuteAxis(.x);
            const new_y_axis = perm.permuteAxis(.y);
            const new_z_axis = perm.permuteAxis(.z);

            const new_xs = flipAxisIfNeeded(
                s.getCoordList(new_x_axis),
                rotation.inverts(.x),
                rotation_point[@intFromEnum(new_x_axis)],
                rotation_point[0],
            );
            const new_ys = flipAxisIfNeeded(
                s.getCoordList(new_y_axis),
                rotation.inverts(.y),
                rotation_point[@intFromEnum(new_y_axis)],
                rotation_point[1],
            );
            const new_zs = flipAxisIfNeeded(
                s.getCoordList(new_z_axis),
                rotation.inverts(.z),
                rotation_point[@intFromEnum(new_z_axis)],
                rotation_point[2],
            );

            break :blk VoxelShape{ .array = ArrayVoxelShape.initWithCoords(new_discrete, new_xs, new_ys, new_zs) };
        },
        .array => |*s| blk: {
            const new_discrete = s.shape.rotate(rotation);
            const perm = rotation.permutation;
            const new_x_axis = perm.permuteAxis(.x);
            const new_y_axis = perm.permuteAxis(.y);
            const new_z_axis = perm.permuteAxis(.z);

            const new_xs = flipAxisIfNeeded(
                s.getCoordList(new_x_axis),
                rotation.inverts(.x),
                rotation_point[@intFromEnum(new_x_axis)],
                rotation_point[0],
            );
            const new_ys = flipAxisIfNeeded(
                s.getCoordList(new_y_axis),
                rotation.inverts(.y),
                rotation_point[@intFromEnum(new_y_axis)],
                rotation_point[1],
            );
            const new_zs = flipAxisIfNeeded(
                s.getCoordList(new_z_axis),
                rotation.inverts(.z),
                rotation_point[@intFromEnum(new_z_axis)],
                rotation_point[2],
            );

            break :blk VoxelShape{ .array = ArrayVoxelShape.initWithCoords(new_discrete, new_xs, new_ys, new_zs) };
        },
    };
}

/// Re-export CoordList from CubeVoxelShape
pub const CoordList = CubeVoxelShape.CoordList;

/// Flip a coordinate list if needed during rotation
fn flipAxisIfNeeded(coords: CoordList, flip: bool, new_relative: f64, old_relative: f64) CoordList {
    if (!flip and new_relative == old_relative) {
        return coords;
    }

    var result = CoordList.init();
    if (flip) {
        // Reverse and transform coordinates
        var i: usize = coords.len;
        while (i > 0) {
            i -= 1;
            result.data[result.len] = -(coords.data[i] - new_relative) + old_relative;
            result.len += 1;
        }
    } else {
        // Just shift coordinates
        for (0..coords.len) |i| {
            result.data[result.len] = coords.data[i] - new_relative + old_relative;
            result.len += 1;
        }
    }
    return result;
}

/// Create rotated horizontal shape variants
/// Returns shapes for [north, east, south, west]
pub fn rotateHorizontal(north_shape: VoxelShape) [4]VoxelShape {
    return .{
        north_shape, // North (base shape)
        rotate(north_shape, OctahedralGroup.BLOCK_ROT_Y_90), // East (90 CW)
        rotate(north_shape, OctahedralGroup.BLOCK_ROT_Y_180), // South (180)
        rotate(north_shape, OctahedralGroup.BLOCK_ROT_Y_270), // West (270 CW / 90 CCW)
    };
}

/// Create rotated horizontal shape variants with an initial rotation applied
/// Returns shapes for [north, east, south, west]
pub fn rotateHorizontalWithInitial(north_shape: VoxelShape, initial: OctahedralGroup) [4]VoxelShape {
    return .{
        rotate(north_shape, initial), // North
        rotate(north_shape, OctahedralGroup.BLOCK_ROT_Y_90.compose(initial)), // East
        rotate(north_shape, OctahedralGroup.BLOCK_ROT_Y_180.compose(initial)), // South
        rotate(north_shape, OctahedralGroup.BLOCK_ROT_Y_270.compose(initial)), // West
    };
}

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

    // Slab's up face is NOT at block boundary (slab ends at y=0.5, not y=1)
    // Therefore it cannot be occluded by a neighbor above
    try std.testing.expect(!slab.faceOccludedBy(.up, &full));

    // Slab's down face IS at boundary (y=0) and can be occluded by full block below
    try std.testing.expect(slab.faceOccludedBy(.down, &full));

    // Full block's down face is NOT occluded by slab above - there's a gap!
    // The slab's top is at y=0.5, not y=1, so there's empty space between
    try std.testing.expect(!full.faceOccludedBy(.down, &slab));

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

// =====================
// Block Occlusion (using SliceShape)
// =====================

/// Static full block shape for blockOccludes fast paths
var static_full_shape: BitSetDiscreteVoxelShape = BitSetDiscreteVoxelShape.initFull(1, 1, 1);

/// Check if a shape's face is occluded by a neighbor shape
///
/// direction: The direction FROM shape TO occluder (e.g., .north means occluder is to the north)
/// Returns true if shape's face in that direction should be culled
pub fn blockOccludes(shape: *const VoxelShape, occluder: *const VoxelShape, direction: Direction) bool {
    // Fast path: both full blocks
    if (shape.isFullBlock() and occluder.isFullBlock()) {
        return true;
    }

    // Empty occluder never occludes anything
    if (occluder.isEmpty()) {
        return false;
    }

    // Empty shape has no visible faces to occlude
    if (shape.isEmpty()) {
        return true;
    }

    const axis = direction.getAxis();
    const axis_dir = direction.getAxisDirection();

    // Determine which shape is "first" and "second" based on direction
    // For positive direction: first=shape, second=occluder, op=ONLY_FIRST
    // For negative direction: first=occluder, second=shape, op=ONLY_SECOND
    const is_positive = axis_dir == .positive;

    // Get the discrete shapes
    const shape_discrete = shape.getDiscreteShape() orelse &static_full_shape.base;
    const occluder_discrete = occluder.getDiscreteShape() orelse &static_full_shape.base;

    // Check boundary conditions using the shape's coordinate system
    const eps: f64 = 1.0e-7;

    if (is_positive) {
        // Shape's max face should be at boundary (1.0)
        if (!fuzzyEquals(shape.max(axis), 1.0, eps)) return false;
        // Occluder's min face should be at boundary (0.0)
        if (!fuzzyEquals(occluder.min(axis), 0.0, eps)) return false;

        // Create slices at the touching faces
        const shape_slice_pos = shape_discrete.getSize(axis) - 1;
        const shape_slice = SliceShape.init(shape_discrete, axis, shape_slice_pos);
        const occluder_slice = SliceShape.init(occluder_discrete, axis, 0);

        // Check if join(shape_face, occluder_face, ONLY_FIRST) is empty
        // If empty, shape's face is fully covered by occluder's face
        return !sliceJoinIsNotEmpty(&shape_slice, &occluder_slice, .only_first);
    } else {
        // For negative direction, we check if occluder covers shape
        // Occluder's max face should be at boundary (1.0)
        if (!fuzzyEquals(occluder.max(axis), 1.0, eps)) return false;
        // Shape's min face should be at boundary (0.0)
        if (!fuzzyEquals(shape.min(axis), 0.0, eps)) return false;

        // Create slices at the touching faces
        const occluder_slice_pos = occluder_discrete.getSize(axis) - 1;
        const occluder_slice = SliceShape.init(occluder_discrete, axis, occluder_slice_pos);
        const shape_slice = SliceShape.init(shape_discrete, axis, 0);

        // Check if join(occluder_face, shape_face, ONLY_SECOND) is empty
        // This checks if there's any part of shape's face NOT covered by occluder
        return !sliceJoinIsNotEmpty(&occluder_slice, &shape_slice, .only_second);
    }
}

fn fuzzyEquals(a: f64, b: f64, eps: f64) bool {
    return @abs(a - b) < eps;
}

test "blockOccludes - full blocks" {
    const full = BLOCK;
    const air = EMPTY;

    // Full blocks occlude each other
    try std.testing.expect(blockOccludes(&full, &full, .north));
    try std.testing.expect(blockOccludes(&full, &full, .up));

    // Air doesn't occlude
    try std.testing.expect(!blockOccludes(&full, &air, .north));

    // Empty is always occluded
    try std.testing.expect(blockOccludes(&air, &full, .north));
}

test "blockOccludes - slabs" {
    const full = BLOCK;
    const bottom_slab = fromBlockBounds(.{ 0, 0, 0 }, .{ 16, 8, 16 });
    const top_slab = fromBlockBounds(.{ 0, 8, 0 }, .{ 16, 16, 16 });

    // Bottom slab's DOWN face is occluded by full block below
    try std.testing.expect(blockOccludes(&bottom_slab, &full, .down));

    // Bottom slab's UP face is at y=0.5, not at boundary, so NOT occluded
    // (there's a gap between the slab top and the neighbor)
    try std.testing.expect(!blockOccludes(&bottom_slab, &full, .up));

    // Full block's DOWN face IS occluded by bottom_slab's UP face
    // because the slab's UP face is at y=0.5 which doesn't touch the boundary
    // Actually no - the slab's UP boundary is at y=0.5, not y=1.0
    // So there's a gap and it should NOT occlude
    try std.testing.expect(!blockOccludes(&full, &bottom_slab, .down));

    // Top slab's UP face IS occluded by full block above
    try std.testing.expect(blockOccludes(&top_slab, &full, .up));

    // Full block's UP face is occluded by top_slab's DOWN face
    // top_slab min(y) = 0.5, not 0.0, so NOT occluded
    try std.testing.expect(!blockOccludes(&full, &top_slab, .up));
}

test "blockOccludes - stairs" {
    const shapes = @import("Shapes.zig").Shapes;
    const full = BLOCK;

    // North-facing stair's NORTH face should be occluded by full block
    // (the north face extends full height at z=0)
    try std.testing.expect(blockOccludes(&shapes.STAIR_BOTTOM_NORTH, &full, .north));

    // Full block's SOUTH face next to north stair's NORTH face
    // Stair's north face is full, so it should occlude
    try std.testing.expect(blockOccludes(&full, &shapes.STAIR_BOTTOM_NORTH, .south));

    // Stair's SOUTH face is only partial (bottom half), so full block's north face
    // is NOT fully occluded by stair
    try std.testing.expect(!blockOccludes(&full, &shapes.STAIR_BOTTOM_NORTH, .north));
}
