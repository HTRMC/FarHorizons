/// CubeVoxelShape - VoxelShape with power-of-2 aligned coordinates
/// Equivalent to Minecraft's net.minecraft.world.phys.shapes.CubeVoxelShape
///
/// This is the most efficient VoxelShape implementation for shapes that
/// align to a power-of-2 grid (1, 2, 4, 8, or 16 divisions per axis).
/// Most block shapes fall into this category.
const std = @import("std");
const BitSetDiscreteVoxelShape = @import("BitsetDiscreteVoxelShape.zig").BitSetDiscreteVoxelShape;
const BitSetDiscreteVoxelShape2D = @import("BitsetDiscreteVoxelShape.zig").BitSetDiscreteVoxelShape2D;
const dvs = @import("DiscreteVoxelShape.zig");
const Direction = dvs.Direction;
const Axis = dvs.Axis;
const OctahedralGroup = @import("OctahedralGroup.zig").OctahedralGroup;

/// Coordinate list for VoxelShape rotation
pub const CoordList = struct {
    data: [17]f64,
    len: u8,

    pub fn init() CoordList {
        return .{
            .data = [_]f64{0.0} ** 17,
            .len = 0,
        };
    }

    /// Create a uniform coordinate list for a given resolution (e.g., resolution=2 -> [0, 0.5, 1])
    pub fn uniform(resolution: u8) CoordList {
        var list = init();
        const n: f64 = @floatFromInt(resolution);
        for (0..resolution + 1) |i| {
            list.data[i] = @as(f64, @floatFromInt(i)) / n;
        }
        list.len = resolution + 1;
        return list;
    }
};

/// A VoxelShape backed by a discrete voxel grid with power-of-2 divisions
pub const CubeVoxelShape = struct {
    const Self = @This();

    /// The discrete shape storing voxel data
    shape: BitSetDiscreteVoxelShape,

    /// Cached face shapes (lazily computed)
    /// Indexed by Direction enum value
    face_cache: [6]?BitSetDiscreteVoxelShape2D,

    /// Create an empty cube voxel shape with given resolution
    pub fn init(x_size: u8, y_size: u8, z_size: u8) Self {
        return .{
            .shape = BitSetDiscreteVoxelShape.init(x_size, y_size, z_size),
            .face_cache = [_]?BitSetDiscreteVoxelShape2D{null} ** 6,
        };
    }

    /// Create a cube voxel shape with filled bounds
    pub fn withFilledBounds(
        x_size: u8,
        y_size: u8,
        z_size: u8,
        x_min: u8,
        y_min: u8,
        z_min: u8,
        x_max: u8,
        y_max: u8,
        z_max: u8,
    ) Self {
        return .{
            .shape = BitSetDiscreteVoxelShape.withFilledBounds(
                x_size,
                y_size,
                z_size,
                x_min,
                y_min,
                z_min,
                x_max,
                y_max,
                z_max,
            ),
            .face_cache = [_]?BitSetDiscreteVoxelShape2D{null} ** 6,
        };
    }

    /// Create a fully filled cube voxel shape
    pub fn initFull(x_size: u8, y_size: u8, z_size: u8) Self {
        var shape = Self{
            .shape = BitSetDiscreteVoxelShape.initFull(x_size, y_size, z_size),
            .face_cache = undefined,
        };
        // Pre-fill face cache for full shape
        for (0..6) |i| {
            const dir: Direction = @enumFromInt(i);
            shape.face_cache[i] = shape.computeFaceShape(dir);
        }
        return shape;
    }

    /// Create from an existing BitSetDiscreteVoxelShape (e.g., after rotation)
    pub fn fromDiscrete(discrete: BitSetDiscreteVoxelShape) Self {
        return .{
            .shape = discrete,
            .face_cache = [_]?BitSetDiscreteVoxelShape2D{null} ** 6,
        };
    }

    /// Check if a voxel is filled
    pub fn isFull(self: *const Self, x: u8, y: u8, z: u8) bool {
        return self.shape.base.isFull(x, y, z);
    }

    /// Check if a voxel is filled (with wide coordinate support)
    pub fn isFullWide(self: *const Self, x: u8, y: u8, z: u8) bool {
        return self.shape.base.isFullWide(x, y, z);
    }

    /// Fill a voxel
    pub fn fill(self: *Self, x: u8, y: u8, z: u8) void {
        self.shape.base.fill(x, y, z);
        self.invalidateFaceCache();
    }

    /// Check if the shape is empty
    pub fn isEmpty(self: *const Self) bool {
        return self.shape.base.isEmpty();
    }

    /// Check if the shape fills the entire volume
    pub fn isFullBlock(self: *const Self) bool {
        return self.shape.base.isFullBlock();
    }

    /// Get the shape's size along an axis
    pub fn getSize(self: *const Self, axis: Axis) u8 {
        return self.shape.base.getSize(axis);
    }

    /// Get coordinate value at index along axis (0.0 to 1.0)
    pub fn getCoord(self: *const Self, axis: Axis, index: u8) f64 {
        const size = self.getSize(axis);
        return @as(f64, @floatFromInt(index)) / @as(f64, @floatFromInt(size));
    }

    /// Find index for a coordinate value (0.0 to 1.0)
    pub fn findIndex(self: *const Self, axis: Axis, coord: f64) u8 {
        const size = self.getSize(axis);
        const idx = @as(u8, @intFromFloat(coord * @as(f64, @floatFromInt(size))));
        return @min(idx, size - 1);
    }

    /// Get coordinate list along axis (for rotation)
    pub fn getCoordList(self: *const Self, axis: Axis) CoordList {
        return CoordList.uniform(self.getSize(axis));
    }

    /// Get the face shape for occlusion testing
    pub fn getFaceShape(self: *Self, direction: Direction) BitSetDiscreteVoxelShape2D {
        const dir_idx = @intFromEnum(direction);
        if (self.face_cache[dir_idx]) |cached| {
            return cached;
        }

        const face = self.computeFaceShape(direction);
        self.face_cache[dir_idx] = face;
        return face;
    }

    /// Get face shape (const version, may compute but can't cache)
    pub fn getFaceShapeConst(self: *const Self, direction: Direction) BitSetDiscreteVoxelShape2D {
        const dir_idx = @intFromEnum(direction);
        if (self.face_cache[dir_idx]) |cached| {
            return cached;
        }
        return self.computeFaceShape(direction);
    }

    /// Compute the 2D projection of the shape onto a face
    fn computeFaceShape(self: *const Self, direction: Direction) BitSetDiscreteVoxelShape2D {
        const axis = direction.getAxis();
        const axis_dir = direction.getAxisDirection();

        // Determine which slice position to use
        const pos: u8 = switch (axis_dir) {
            .negative => 0,
            .positive => self.getSize(axis) - 1,
        };

        return self.shape.getSlice(axis, pos);
    }

    /// Invalidate face cache (call when shape changes)
    fn invalidateFaceCache(self: *Self) void {
        self.face_cache = [_]?BitSetDiscreteVoxelShape2D{null} ** 6;
    }

    /// Get min coordinate along axis (for bounds)
    pub fn min(self: *const Self, axis: Axis) f64 {
        const min_idx = self.shape.base.firstFull(axis);
        return self.getCoord(axis, min_idx);
    }

    /// Get max coordinate along axis (for bounds) - returns end of last filled voxel
    pub fn max(self: *const Self, axis: Axis) f64 {
        const max_idx = self.shape.base.lastFull(axis);
        // lastFull already returns one past the last filled index
        return self.getCoord(axis, max_idx);
    }

    /// Check if a face of this shape reaches the block boundary
    /// Only faces at the boundary can be occluded by neighbors
    pub fn isFaceAtBoundary(self: *const Self, direction: Direction) bool {
        const axis = direction.getAxis();
        const axis_dir = direction.getAxisDirection();

        // Tolerance for floating point comparison
        const eps: f64 = 0.001;

        return switch (axis_dir) {
            // Negative direction faces (DOWN, NORTH, WEST) - check if shape reaches 0.0
            .negative => self.min(axis) < eps,
            // Positive direction faces (UP, SOUTH, EAST) - check if shape reaches 1.0
            .positive => self.max(axis) > (1.0 - eps),
        };
    }

    /// Get AABB bounds [minX, minY, minZ, maxX, maxY, maxZ]
    pub fn getBounds(self: *const Self) [6]f64 {
        return .{
            self.min(.x),
            self.min(.y),
            self.min(.z),
            self.max(.x),
            self.max(.y),
            self.max(.z),
        };
    }

    /// Create from world coordinate bounds (0-16 range, like block models)
    pub fn fromBlockBounds(from: [3]f32, to: [3]f32) Self {
        const resolution = findRequiredResolution(from, to);
        const scale = 16.0 / @as(f32, @floatFromInt(resolution));

        const x_min: u8 = @intFromFloat(from[0] / scale);
        const y_min: u8 = @intFromFloat(from[1] / scale);
        const z_min: u8 = @intFromFloat(from[2] / scale);
        const x_max: u8 = @intFromFloat(to[0] / scale);
        const y_max: u8 = @intFromFloat(to[1] / scale);
        const z_max: u8 = @intFromFloat(to[2] / scale);

        return withFilledBounds(
            resolution,
            resolution,
            resolution,
            x_min,
            y_min,
            z_min,
            x_max,
            y_max,
            z_max,
        );
    }

    /// Create from normalized bounds (0-1 range)
    pub fn fromNormalizedBounds(
        x_min: f64,
        y_min: f64,
        z_min: f64,
        x_max: f64,
        y_max: f64,
        z_max: f64,
    ) Self {
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
};

/// Find the minimum resolution that can exactly represent the given bounds
/// Returns the number of divisions per axis (1, 2, 4, 8, or 16)
pub fn findRequiredResolution(from: [3]f32, to: [3]f32) u8 {
    const resolutions = [_]u8{ 1, 2, 4, 8, 16 };
    const scales = [_]f32{ 16.0, 8.0, 4.0, 2.0, 1.0 };

    for (resolutions, scales) |res, scale| {
        var aligned = true;
        for (0..3) |axis| {
            const f = from[axis];
            const t = to[axis];
            // Check if coordinates align to this grid
            if (@mod(f, scale) != 0 or @mod(t, scale) != 0) {
                aligned = false;
                break;
            }
        }
        if (aligned) return res;
    }
    return 16; // Maximum resolution as fallback
}

/// Determine bits needed to represent a size (Minecraft's findBits)
/// Returns number of bits (0-4) or -1 if not a power of 2
pub fn findBits(coord_min: f64, coord_max: f64) i8 {
    if (coord_min < 0 or coord_max > 1 or coord_min >= coord_max) {
        return -1;
    }

    // Check each resolution
    for (0..5) |bits| {
        const divisions: f64 = @floatFromInt(@as(u8, 1) << @as(u3, @intCast(bits)));
        const scale = 1.0 / divisions;

        const min_aligned = @mod(coord_min, scale) == 0;
        const max_aligned = @mod(coord_max, scale) == 0;

        if (min_aligned and max_aligned) {
            return @intCast(bits);
        }
    }

    return -1; // Not aligned to any power of 2
}

// Pre-defined shapes
pub const EMPTY = CubeVoxelShape.init(1, 1, 1);
pub const BLOCK = CubeVoxelShape.initFull(1, 1, 1);

// Tests
test "CubeVoxelShape basic operations" {
    var shape = CubeVoxelShape.init(4, 4, 4);
    try std.testing.expect(shape.isEmpty());

    shape.fill(0, 0, 0);
    try std.testing.expect(!shape.isEmpty());
    try std.testing.expect(shape.isFull(0, 0, 0));
}

test "CubeVoxelShape face projection" {
    // Half slab (bottom half) - filled y=0 only in a 2-division grid
    const slab = CubeVoxelShape.withFilledBounds(2, 2, 2, 0, 0, 0, 2, 1, 2);

    // Down face should be full (slab covers entire bottom at y=0)
    const down_face = slab.getFaceShapeConst(.down);
    try std.testing.expect(down_face.isFull());

    // Up face is at y=1 (top block boundary) - slab doesn't reach there!
    // The slab ends at y=0.5, so up face at y=1 is EMPTY
    const up_face = slab.getFaceShapeConst(.up);
    try std.testing.expect(up_face.isEmpty());

    // North face should be half-filled (only bottom half)
    const north_face = slab.getFaceShapeConst(.north);
    try std.testing.expect(!north_face.isFull());
    try std.testing.expect(!north_face.isEmpty());
}

test "CubeVoxelShape fromBlockBounds" {
    // Full block
    const full = CubeVoxelShape.fromBlockBounds(.{ 0, 0, 0 }, .{ 16, 16, 16 });
    try std.testing.expect(full.isFullBlock());

    // Half slab
    const slab = CubeVoxelShape.fromBlockBounds(.{ 0, 0, 0 }, .{ 16, 8, 16 });
    try std.testing.expect(!slab.isFullBlock());
    try std.testing.expect(!slab.isEmpty());
}

test "findRequiredResolution" {
    // Full block needs only 1 division
    try std.testing.expectEqual(@as(u8, 1), findRequiredResolution(.{ 0, 0, 0 }, .{ 16, 16, 16 }));

    // Half slab needs 2 divisions
    try std.testing.expectEqual(@as(u8, 2), findRequiredResolution(.{ 0, 0, 0 }, .{ 16, 8, 16 }));

    // Quarter height needs 4 divisions
    try std.testing.expectEqual(@as(u8, 4), findRequiredResolution(.{ 0, 0, 0 }, .{ 16, 4, 16 }));
}

test "findBits" {
    try std.testing.expectEqual(@as(i8, 0), findBits(0.0, 1.0)); // Full block
    try std.testing.expectEqual(@as(i8, 1), findBits(0.0, 0.5)); // Half
    try std.testing.expectEqual(@as(i8, 2), findBits(0.0, 0.25)); // Quarter
    try std.testing.expectEqual(@as(i8, -1), findBits(0.0, 0.3)); // Not aligned
}
