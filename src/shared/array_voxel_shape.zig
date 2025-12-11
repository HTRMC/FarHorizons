/// ArrayVoxelShape - VoxelShape with arbitrary coordinate lists
/// Equivalent to Minecraft's net.minecraft.world.phys.shapes.ArrayVoxelShape
///
/// This shape type stores explicit coordinate lists for each axis,
/// allowing representation of shapes that don't align to power-of-2 grids.
/// Less efficient than CubeVoxelShape but more flexible.
const std = @import("std");
const BitSetDiscreteVoxelShape = @import("bitset_discrete_voxel_shape.zig").BitSetDiscreteVoxelShape;
const BitSetDiscreteVoxelShape2D = @import("bitset_discrete_voxel_shape.zig").BitSetDiscreteVoxelShape2D;
const dvs = @import("discrete_voxel_shape.zig");
const Direction = dvs.Direction;
const Axis = dvs.Axis;

/// Maximum number of coordinates per axis
pub const MAX_COORDS: usize = 17; // 16 divisions + 1

/// Bounded array for coordinate storage (replaces std.BoundedArray)
pub const CoordArray = struct {
    data: [MAX_COORDS]f64,
    len: usize,

    pub fn init() CoordArray {
        return .{
            .data = [_]f64{0.0} ** MAX_COORDS,
            .len = 0,
        };
    }

    pub fn appendAssumeCapacity(self: *CoordArray, val: f64) void {
        self.data[self.len] = val;
        self.len += 1;
    }

    pub fn constSlice(self: *const CoordArray) []const f64 {
        return self.data[0..self.len];
    }
};

/// A VoxelShape with explicit coordinate arrays
pub const ArrayVoxelShape = struct {
    const Self = @This();

    /// The discrete shape storing voxel data
    shape: BitSetDiscreteVoxelShape,

    /// Coordinate lists for each axis (sorted, 0.0 to 1.0)
    x_coords: CoordArray,
    y_coords: CoordArray,
    z_coords: CoordArray,

    /// Cached face shapes
    face_cache: [6]?BitSetDiscreteVoxelShape2D,

    allocator: std.mem.Allocator,

    /// Create an array voxel shape from explicit coordinates
    pub fn init(
        allocator: std.mem.Allocator,
        x_coords: []const f64,
        y_coords: []const f64,
        z_coords: []const f64,
    ) !Self {
        std.debug.assert(x_coords.len >= 2 and y_coords.len >= 2 and z_coords.len >= 2);
        std.debug.assert(x_coords.len <= MAX_COORDS and y_coords.len <= MAX_COORDS and z_coords.len <= MAX_COORDS);

        const x_size: u8 = @intCast(x_coords.len - 1);
        const y_size: u8 = @intCast(y_coords.len - 1);
        const z_size: u8 = @intCast(z_coords.len - 1);

        var self = Self{
            .shape = BitSetDiscreteVoxelShape.init(x_size, y_size, z_size),
            .x_coords = CoordArray.init(),
            .y_coords = CoordArray.init(),
            .z_coords = CoordArray.init(),
            .face_cache = [_]?BitSetDiscreteVoxelShape2D{null} ** 6,
            .allocator = allocator,
        };

        // Copy coordinates
        for (x_coords) |c| {
            self.x_coords.appendAssumeCapacity(c);
        }
        for (y_coords) |c| {
            self.y_coords.appendAssumeCapacity(c);
        }
        for (z_coords) |c| {
            self.z_coords.appendAssumeCapacity(c);
        }

        return self;
    }

    /// Create with filled bounds (specified as coordinate indices)
    pub fn withFilledBounds(
        allocator: std.mem.Allocator,
        x_coords: []const f64,
        y_coords: []const f64,
        z_coords: []const f64,
        x_min: u8,
        y_min: u8,
        z_min: u8,
        x_max: u8,
        y_max: u8,
        z_max: u8,
    ) !Self {
        var self = try init(allocator, x_coords, y_coords, z_coords);

        // Fill the specified region
        for (x_min..x_max) |x| {
            for (y_min..y_max) |y| {
                for (z_min..z_max) |z| {
                    self.shape.base.fill(@intCast(x), @intCast(y), @intCast(z));
                }
            }
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // BoundedArrays don't need deallocation
    }

    /// Get coordinates for an axis
    pub fn getCoords(self: *const Self, axis: Axis) []const f64 {
        return switch (axis) {
            .x => self.x_coords.constSlice(),
            .y => self.y_coords.constSlice(),
            .z => self.z_coords.constSlice(),
        };
    }

    /// Get coordinate value at index
    pub fn getCoord(self: *const Self, axis: Axis, index: u8) f64 {
        const coords = self.getCoords(axis);
        if (index >= coords.len) return 1.0;
        return coords[index];
    }

    /// Find index for a coordinate value
    pub fn findIndex(self: *const Self, axis: Axis, coord: f64) u8 {
        const coords = self.getCoords(axis);

        // Binary search for the coordinate
        var low: usize = 0;
        var high: usize = coords.len;

        while (low < high) {
            const mid = low + (high - low) / 2;
            if (coords[mid] < coord) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }

        if (low > 0) low -= 1;
        return @intCast(@min(low, coords.len - 2));
    }

    /// Check if a voxel is filled
    pub fn isFull(self: *const Self, x: u8, y: u8, z: u8) bool {
        return self.shape.base.isFull(x, y, z);
    }

    /// Fill a voxel
    pub fn fill(self: *Self, x: u8, y: u8, z: u8) void {
        self.shape.base.fill(x, y, z);
        self.invalidateFaceCache();
    }

    /// Check if shape is empty
    pub fn isEmpty(self: *const Self) bool {
        return self.shape.base.isEmpty();
    }

    /// Check if shape is full block
    pub fn isFullBlock(self: *const Self) bool {
        return self.shape.base.isFullBlock();
    }

    /// Get size along axis
    pub fn getSize(self: *const Self, axis: Axis) u8 {
        return self.shape.base.getSize(axis);
    }

    /// Get face shape for occlusion testing
    pub fn getFaceShape(self: *Self, direction: Direction) BitSetDiscreteVoxelShape2D {
        const dir_idx = @intFromEnum(direction);
        if (self.face_cache[dir_idx]) |cached| {
            return cached;
        }

        const face = self.computeFaceShape(direction);
        self.face_cache[dir_idx] = face;
        return face;
    }

    pub fn getFaceShapeConst(self: *const Self, direction: Direction) BitSetDiscreteVoxelShape2D {
        const dir_idx = @intFromEnum(direction);
        if (self.face_cache[dir_idx]) |cached| {
            return cached;
        }
        return self.computeFaceShape(direction);
    }

    fn computeFaceShape(self: *const Self, direction: Direction) BitSetDiscreteVoxelShape2D {
        const axis = direction.getAxis();
        const axis_dir = direction.getAxisDirection();

        const pos: u8 = switch (axis_dir) {
            .negative => 0,
            .positive => self.getSize(axis) - 1,
        };

        return self.shape.getSlice(axis, pos);
    }

    fn invalidateFaceCache(self: *Self) void {
        self.face_cache = [_]?BitSetDiscreteVoxelShape2D{null} ** 6;
    }

    /// Get min coordinate along axis
    pub fn min(self: *const Self, axis: Axis) f64 {
        const min_idx = self.shape.base.firstFull(axis);
        return self.getCoord(axis, min_idx);
    }

    /// Get max coordinate along axis - returns end of last filled voxel
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

    /// Get AABB bounds
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
};

/// Create an ArrayVoxelShape from world coordinate bounds
/// Use this when bounds don't align to power-of-2 grid
pub fn fromBounds(
    allocator: std.mem.Allocator,
    x_min: f64,
    y_min: f64,
    z_min: f64,
    x_max: f64,
    y_max: f64,
    z_max: f64,
) !ArrayVoxelShape {
    const x_coords = [_]f64{ x_min, x_max };
    const y_coords = [_]f64{ y_min, y_max };
    const z_coords = [_]f64{ z_min, z_max };

    return ArrayVoxelShape.withFilledBounds(
        allocator,
        &x_coords,
        &y_coords,
        &z_coords,
        0,
        0,
        0,
        1,
        1,
        1,
    );
}

// Tests
test "ArrayVoxelShape basic" {
    const x = [_]f64{ 0.0, 0.5, 1.0 };
    const y = [_]f64{ 0.0, 0.25, 0.75, 1.0 };
    const z = [_]f64{ 0.0, 1.0 };

    var shape = try ArrayVoxelShape.init(std.testing.allocator, &x, &y, &z);
    defer shape.deinit();

    try std.testing.expect(shape.isEmpty());
    try std.testing.expectEqual(@as(u8, 2), shape.getSize(.x));
    try std.testing.expectEqual(@as(u8, 3), shape.getSize(.y));
    try std.testing.expectEqual(@as(u8, 1), shape.getSize(.z));
}

test "ArrayVoxelShape findIndex" {
    const coords = [_]f64{ 0.0, 0.25, 0.5, 0.75, 1.0 };
    const dummy = [_]f64{ 0.0, 1.0 };

    var shape = try ArrayVoxelShape.init(std.testing.allocator, &coords, &dummy, &dummy);
    defer shape.deinit();

    try std.testing.expectEqual(@as(u8, 0), shape.findIndex(.x, 0.0));
    try std.testing.expectEqual(@as(u8, 0), shape.findIndex(.x, 0.1));
    try std.testing.expectEqual(@as(u8, 1), shape.findIndex(.x, 0.25));
    try std.testing.expectEqual(@as(u8, 1), shape.findIndex(.x, 0.3));
    try std.testing.expectEqual(@as(u8, 2), shape.findIndex(.x, 0.5));
    try std.testing.expectEqual(@as(u8, 3), shape.findIndex(.x, 0.9));
}
