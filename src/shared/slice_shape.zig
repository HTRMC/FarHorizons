/// SliceShape - 2D cross-section of a VoxelShape
/// Equivalent to Minecraft's net.minecraft.world.phys.shapes.SliceShape
///
/// A SliceShape is a 2D projection of a 3D VoxelShape along one axis.
/// It's used for face occlusion testing - comparing the face shape of
/// one block against the opposite face of its neighbor.
const std = @import("std");
const BitSetDiscreteVoxelShape2D = @import("bitset_discrete_voxel_shape.zig").BitSetDiscreteVoxelShape2D;
const dvs = @import("discrete_voxel_shape.zig");
const Direction = dvs.Direction;
const Axis = dvs.Axis;

/// Maximum size for coordinate arrays
const MAX_COORDS: usize = 17;

/// Bounded array for coordinate storage (replaces std.BoundedArray)
const CoordArray = struct {
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

/// A 2D slice of a 3D VoxelShape
pub const SliceShape = struct {
    const Self = @This();

    /// The 2D shape data
    shape: BitSetDiscreteVoxelShape2D,

    /// Coordinate lists for the two axes of this slice
    /// For example, if this is a YZ slice, u_coords is Y and v_coords is Z
    u_coords: CoordArray,
    v_coords: CoordArray,

    /// Create a slice shape from a 2D bitset with uniform coordinates
    pub fn fromBitSet(shape: BitSetDiscreteVoxelShape2D) Self {
        var self = Self{
            .shape = shape,
            .u_coords = CoordArray.init(),
            .v_coords = CoordArray.init(),
        };

        // Generate uniform coordinates
        for (0..shape.u_size + 1) |i| {
            const coord = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(shape.u_size));
            self.u_coords.appendAssumeCapacity(coord);
        }
        for (0..shape.v_size + 1) |i| {
            const coord = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(shape.v_size));
            self.v_coords.appendAssumeCapacity(coord);
        }

        return self;
    }

    /// Create a slice shape with explicit coordinates
    pub fn withCoords(
        shape_param: BitSetDiscreteVoxelShape2D,
        u_coords_param: []const f64,
        v_coords_param: []const f64,
    ) Self {
        var self = Self{
            .shape = shape_param,
            .u_coords = CoordArray.init(),
            .v_coords = CoordArray.init(),
        };

        for (u_coords_param) |c| {
            self.u_coords.appendAssumeCapacity(c);
        }
        for (v_coords_param) |c| {
            self.v_coords.appendAssumeCapacity(c);
        }

        return self;
    }

    /// Create an empty slice
    pub fn empty(u_size: u8, v_size: u8) Self {
        return fromBitSet(BitSetDiscreteVoxelShape2D.init(u_size, v_size));
    }

    /// Create a full slice
    pub fn full(u_size: u8, v_size: u8) Self {
        return fromBitSet(BitSetDiscreteVoxelShape2D.initFull(u_size, v_size));
    }

    /// Check if position is filled
    pub fn isFull(self: *const Self, u: u8, v: u8) bool {
        return self.shape.get(u, v);
    }

    /// Check if slice is empty
    pub fn isEmpty(self: *const Self) bool {
        return self.shape.isEmpty();
    }

    /// Check if slice fills entire area
    pub fn isFullCoverage(self: *const Self) bool {
        return self.shape.isFull();
    }

    /// Check if another slice completely covers this one
    /// Returns true if every filled cell in self is also filled in other
    pub fn isCoveredBy(self: *const Self, other: *const Self) bool {
        // Fast path: if other is full, it covers everything
        if (other.isFullCoverage()) {
            return true;
        }

        // Fast path: if self is empty, it's covered by anything
        if (self.isEmpty()) {
            return true;
        }

        // If sizes match, we can do direct bitset comparison
        if (self.shape.u_size == other.shape.u_size and
            self.shape.v_size == other.shape.v_size)
        {
            // Check if coordinates match (for uniform shapes they will)
            var coords_match = true;
            if (self.u_coords.len == other.u_coords.len and
                self.v_coords.len == other.v_coords.len)
            {
                for (self.u_coords.constSlice(), other.u_coords.constSlice()) |a, b| {
                    if (a != b) {
                        coords_match = false;
                        break;
                    }
                }
                if (coords_match) {
                    for (self.v_coords.constSlice(), other.v_coords.constSlice()) |a, b| {
                        if (a != b) {
                            coords_match = false;
                            break;
                        }
                    }
                }
            } else {
                coords_match = false;
            }

            if (coords_match) {
                return self.shape.isSubsetOf(&other.shape);
            }
        }

        // Different resolutions - need to check coverage cell by cell
        // This is the expensive path
        return self.checkCoverageWithMerge(other);
    }

    /// Check coverage when shapes have different resolutions
    fn checkCoverageWithMerge(self: *const Self, other: *const Self) bool {
        // For each cell in self, check if it's covered by other
        for (0..self.shape.u_size) |u| {
            for (0..self.shape.v_size) |v| {
                if (self.shape.get(@intCast(u), @intCast(v))) {
                    // Get the coordinate range for this cell
                    const u_min = self.u_coords.constSlice()[u];
                    const u_max = self.u_coords.constSlice()[u + 1];
                    const v_min = self.v_coords.constSlice()[v];
                    const v_max = self.v_coords.constSlice()[v + 1];

                    // Check if other covers this entire range
                    if (!other.coversRange(u_min, u_max, v_min, v_max)) {
                        return false;
                    }
                }
            }
        }
        return true;
    }

    /// Check if this slice covers a coordinate range
    fn coversRange(self: *const Self, u_min: f64, u_max: f64, v_min: f64, v_max: f64) bool {
        // Find cells that overlap with this range
        const u_start = self.findIndex(self.u_coords.constSlice(), u_min);
        const u_end = self.findIndex(self.u_coords.constSlice(), u_max);
        const v_start = self.findIndex(self.v_coords.constSlice(), v_min);
        const v_end = self.findIndex(self.v_coords.constSlice(), v_max);

        // All cells in the range must be filled
        for (u_start..u_end + 1) |u| {
            for (v_start..v_end + 1) |v| {
                if (!self.shape.get(@intCast(@min(u, self.shape.u_size - 1)), @intCast(@min(v, self.shape.v_size - 1)))) {
                    return false;
                }
            }
        }
        return true;
    }

    fn findIndex(self: *const Self, coords: []const f64, value: f64) usize {
        _ = self;
        // Binary search for the coordinate
        var low: usize = 0;
        var high: usize = coords.len;

        while (low < high) {
            const mid = low + (high - low) / 2;
            if (coords[mid] < value) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }

        if (low > 0) low -= 1;
        return @min(low, coords.len - 2);
    }

    /// Get coordinate at index
    pub fn getUCoord(self: *const Self, index: u8) f64 {
        if (index >= self.u_coords.len) return 1.0;
        return self.u_coords.constSlice()[index];
    }

    pub fn getVCoord(self: *const Self, index: u8) f64 {
        if (index >= self.v_coords.len) return 1.0;
        return self.v_coords.constSlice()[index];
    }

    /// Get bounds [u_min, v_min, u_max, v_max]
    pub fn getBounds(self: *const Self) [4]f64 {
        var u_min: f64 = 1.0;
        var v_min: f64 = 1.0;
        var u_max: f64 = 0.0;
        var v_max: f64 = 0.0;

        for (0..self.shape.u_size) |u| {
            for (0..self.shape.v_size) |v| {
                if (self.shape.get(@intCast(u), @intCast(v))) {
                    u_min = @min(u_min, self.u_coords.constSlice()[u]);
                    v_min = @min(v_min, self.v_coords.constSlice()[v]);
                    u_max = @max(u_max, self.u_coords.constSlice()[u + 1]);
                    v_max = @max(v_max, self.v_coords.constSlice()[v + 1]);
                }
            }
        }

        return .{ u_min, v_min, u_max, v_max };
    }
};

/// Create a face shape for occlusion testing from direction
pub fn getFaceShapeForDirection(
    comptime ShapeType: type,
    shape: *const ShapeType,
    direction: Direction,
) SliceShape {
    const face_2d = shape.getFaceShapeConst(direction);
    return SliceShape.fromBitSet(face_2d);
}

// Tests
test "SliceShape empty and full" {
    const empty_slice = SliceShape.empty(4, 4);
    try std.testing.expect(empty_slice.isEmpty());
    try std.testing.expect(!empty_slice.isFullCoverage());

    const full_slice = SliceShape.full(4, 4);
    try std.testing.expect(!full_slice.isEmpty());
    try std.testing.expect(full_slice.isFullCoverage());
}

test "SliceShape coverage" {
    const full_slice = SliceShape.full(4, 4);
    var partial = SliceShape.empty(4, 4);

    // Set some cells
    partial.shape.set(0, 0, true);
    partial.shape.set(1, 1, true);

    // Partial should be covered by full
    try std.testing.expect(partial.isCoveredBy(&full_slice));
    // Full should NOT be covered by partial
    try std.testing.expect(!full_slice.isCoveredBy(&partial));
}

test "SliceShape self-coverage" {
    var slice = SliceShape.empty(4, 4);
    slice.shape.set(0, 0, true);
    slice.shape.set(1, 1, true);
    slice.shape.set(2, 2, true);

    // Shape should cover itself
    try std.testing.expect(slice.isCoveredBy(&slice));
}
