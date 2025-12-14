/// SliceShape - A thin 3D slice of a VoxelShape
/// Equivalent to Minecraft's net.minecraft.world.phys.shapes.SliceShape
///
/// SliceShape creates a 1-unit thick slice perpendicular to an axis.
/// It's used for face occlusion testing - comparing the face of one block
/// against the opposite face of its neighbor using 3D join operations.
///
/// Key behavior:
/// - For the slice axis: coordinates are always [0, 1] (1 unit thick)
/// - For other axes: coordinates come from the delegate shape
const std = @import("std");
const SubShape = @import("SubShape.zig").SubShape;
const dvs = @import("DiscreteVoxelShape.zig");
const DiscreteVoxelShape = dvs.DiscreteVoxelShape;
const Direction = dvs.Direction;
const Axis = dvs.Axis;

/// Maximum coordinate array size (17 for 16 divisions + 1)
const MAX_COORDS: usize = 17;

/// Coordinate array with normalized values [0.0 to 1.0]
pub const CoordList = struct {
    data: [MAX_COORDS]f64,
    len: usize,

    pub fn init() CoordList {
        return .{
            .data = [_]f64{0.0} ** MAX_COORDS,
            .len = 0,
        };
    }

    /// Create coords for a uniform grid (0/n, 1/n, 2/n, ..., n/n)
    pub fn uniform(grid_size: u8) CoordList {
        var list = CoordList.init();
        const n: f64 = @floatFromInt(grid_size);
        for (0..grid_size + 1) |i| {
            list.data[i] = @as(f64, @floatFromInt(i)) / n;
        }
        list.len = grid_size + 1;
        return list;
    }

    /// Create slice coords [0, 1]
    pub fn slice() CoordList {
        var list = CoordList.init();
        list.data[0] = 0.0;
        list.data[1] = 1.0;
        list.len = 2;
        return list;
    }

    pub fn get(self: *const CoordList, index: usize) f64 {
        if (index >= self.len) return 1.0;
        return self.data[index];
    }

    pub fn size(self: *const CoordList) usize {
        return if (self.len > 0) self.len - 1 else 0;
    }
};

/// A thin 3D slice of a VoxelShape for face occlusion testing
pub const SliceShape = struct {
    const Self = @This();

    /// The SubShape providing the discrete voxel data
    sub_shape: SubShape,

    /// The axis this slice is perpendicular to
    slice_axis: Axis,

    /// Coordinate lists for each axis
    /// For slice_axis: always [0, 1]
    /// For other axes: uniform coords based on delegate size
    x_coords: CoordList,
    y_coords: CoordList,
    z_coords: CoordList,

    /// Create a SliceShape from a DiscreteVoxelShape
    /// Takes a slice at 'point' along 'axis'
    pub fn init(
        parent: *const DiscreteVoxelShape,
        axis: Axis,
        point: u8,
    ) Self {
        const sub = SubShape.makeSlice(parent, axis, point);

        // Create coordinate lists
        // Slice axis gets [0, 1], others get uniform coords from parent
        const x_coords = if (axis == .x) CoordList.slice() else CoordList.uniform(parent.x_size);
        const y_coords = if (axis == .y) CoordList.slice() else CoordList.uniform(parent.y_size);
        const z_coords = if (axis == .z) CoordList.slice() else CoordList.uniform(parent.z_size);

        return .{
            .sub_shape = sub,
            .slice_axis = axis,
            .x_coords = x_coords,
            .y_coords = y_coords,
            .z_coords = z_coords,
        };
    }

    // === Shape queries ===

    pub fn isEmpty(self: *const Self) bool {
        return self.sub_shape.base.isEmpty();
    }

    pub fn isFullBlock(self: *const Self) bool {
        return self.sub_shape.base.isFullBlock();
    }

    /// Check if voxel at position is filled
    pub fn isFull(self: *const Self, x: u8, y: u8, z: u8) bool {
        return self.sub_shape.base.isFull(x, y, z);
    }

    // === Coordinate queries ===

    pub fn getCoords(self: *const Self, axis: Axis) *const CoordList {
        return switch (axis) {
            .x => &self.x_coords,
            .y => &self.y_coords,
            .z => &self.z_coords,
        };
    }

    pub fn getSize(self: *const Self, axis: Axis) u8 {
        return @intCast(self.getCoords(axis).size());
    }

    pub fn getCoord(self: *const Self, axis: Axis, index: u8) f64 {
        return self.getCoords(axis).get(index);
    }

    /// Get min coordinate along axis
    pub fn min(self: *const Self, axis: Axis) f64 {
        const first = self.sub_shape.firstFull(axis);
        return self.getCoord(axis, first);
    }

    /// Get max coordinate along axis
    pub fn max(self: *const Self, axis: Axis) f64 {
        const last = self.sub_shape.lastFull(axis);
        return self.getCoord(axis, last);
    }

    /// Find index for a coordinate value
    /// Returns the voxel index containing the coordinate.
    /// Boundary values belong to the voxel starting at that boundary.
    pub fn findIndex(self: *const Self, axis: Axis, coord: f64) u8 {
        const coords = self.getCoords(axis);
        // Binary search for first index where coords[i] > coord
        var low: usize = 0;
        var high: usize = coords.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (coords.data[mid] <= coord) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        // low is now first index > coord, so voxel index is low - 1
        if (low > 0) low -= 1;
        return @intCast(@min(low, coords.size() -| 1));
    }

    // === Bounds ===

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

/// Check if joining two SliceShapes with an operation produces non-empty result
/// This is the core operation for face occlusion testing
pub fn sliceJoinIsNotEmpty(
    first: *const SliceShape,
    second: *const SliceShape,
    comptime op: enum { only_first, only_second, @"or", @"and" },
) bool {
    // For slices, we need to iterate over the merged coordinate space
    // and check if the boolean operation produces any filled voxels

    // Get merged coordinates for each axis
    const x_merge = mergeCoords(&first.x_coords, &second.x_coords);
    const y_merge = mergeCoords(&first.y_coords, &second.y_coords);
    const z_merge = mergeCoords(&first.z_coords, &second.z_coords);

    // Iterate over merged space
    for (0..x_merge.size()) |xi| {
        for (0..y_merge.size()) |yi| {
            for (0..z_merge.size()) |zi| {
                // Find corresponding indices in each shape
                const x_coord = x_merge.get(xi);
                const y_coord = y_merge.get(yi);
                const z_coord = z_merge.get(zi);

                const first_x = first.findIndex(.x, x_coord);
                const first_y = first.findIndex(.y, y_coord);
                const first_z = first.findIndex(.z, z_coord);
                const first_full = first.isFull(first_x, first_y, first_z);

                const second_x = second.findIndex(.x, x_coord);
                const second_y = second.findIndex(.y, y_coord);
                const second_z = second.findIndex(.z, z_coord);
                const second_full = second.isFull(second_x, second_y, second_z);

                const result = switch (op) {
                    .only_first => first_full and !second_full,
                    .only_second => !first_full and second_full,
                    .@"or" => first_full or second_full,
                    .@"and" => first_full and second_full,
                };

                if (result) return true;
            }
        }
    }

    return false;
}

/// Merge two coordinate lists (union of all coordinates)
fn mergeCoords(a: *const CoordList, b: *const CoordList) CoordList {
    var result = CoordList.init();

    var ai: usize = 0;
    var bi: usize = 0;

    while (ai < a.len or bi < b.len) {
        const av = if (ai < a.len) a.data[ai] else 2.0;
        const bv = if (bi < b.len) b.data[bi] else 2.0;

        const eps = 1.0e-7;
        if (@abs(av - bv) < eps) {
            // Equal - add once
            result.data[result.len] = av;
            result.len += 1;
            ai += 1;
            bi += 1;
        } else if (av < bv) {
            result.data[result.len] = av;
            result.len += 1;
            ai += 1;
        } else {
            result.data[result.len] = bv;
            result.len += 1;
            bi += 1;
        }

        if (result.len >= MAX_COORDS) break;
    }

    return result;
}

// === Tests ===

test "SliceShape creation" {
    const BitSetDiscreteVoxelShape = @import("BitsetDiscreteVoxelShape.zig").BitSetDiscreteVoxelShape;

    // Create a 4x4x4 full shape
    var parent = BitSetDiscreteVoxelShape.initFull(4, 4, 4);

    // Create a Y slice at y=2
    const slice = SliceShape.init(&parent.base, .y, 2);

    // Slice axis should have size 1
    try std.testing.expectEqual(@as(u8, 1), slice.getSize(.y));

    // Other axes should have original size
    try std.testing.expectEqual(@as(u8, 4), slice.getSize(.x));
    try std.testing.expectEqual(@as(u8, 4), slice.getSize(.z));

    // Should not be empty (parent is full)
    try std.testing.expect(!slice.isEmpty());
}

test "SliceShape coords" {
    const BitSetDiscreteVoxelShape = @import("BitsetDiscreteVoxelShape.zig").BitSetDiscreteVoxelShape;

    var parent = BitSetDiscreteVoxelShape.initFull(2, 2, 2);
    const slice = SliceShape.init(&parent.base, .x, 0);

    // X coords should be [0, 1] (slice)
    try std.testing.expectEqual(@as(f64, 0.0), slice.getCoord(.x, 0));
    try std.testing.expectEqual(@as(f64, 1.0), slice.getCoord(.x, 1));

    // Y coords should be [0, 0.5, 1] (uniform for size 2)
    try std.testing.expectEqual(@as(f64, 0.0), slice.getCoord(.y, 0));
    try std.testing.expectEqual(@as(f64, 0.5), slice.getCoord(.y, 1));
    try std.testing.expectEqual(@as(f64, 1.0), slice.getCoord(.y, 2));
}

test "SliceShape join - full covers partial" {
    const BitSetDiscreteVoxelShape = @import("BitsetDiscreteVoxelShape.zig").BitSetDiscreteVoxelShape;

    // Full shape
    var full_parent = BitSetDiscreteVoxelShape.initFull(2, 2, 2);
    const full_slice = SliceShape.init(&full_parent.base, .y, 0);

    // Partial shape (bottom half on X)
    var partial_parent = BitSetDiscreteVoxelShape.withFilledBounds(2, 2, 2, 0, 0, 0, 1, 2, 2);
    const partial_slice = SliceShape.init(&partial_parent.base, .y, 0);

    // full ONLY_FIRST partial = parts of full not in partial = east half = not empty
    try std.testing.expect(sliceJoinIsNotEmpty(&full_slice, &partial_slice, .only_first));

    // partial ONLY_FIRST full = parts of partial not in full = nothing = empty
    try std.testing.expect(!sliceJoinIsNotEmpty(&partial_slice, &full_slice, .only_first));
}

test "mergeCoords" {
    var a = CoordList.init();
    a.data[0] = 0.0;
    a.data[1] = 0.5;
    a.data[2] = 1.0;
    a.len = 3;

    var b = CoordList.init();
    b.data[0] = 0.0;
    b.data[1] = 0.25;
    b.data[2] = 0.5;
    b.data[3] = 0.75;
    b.data[4] = 1.0;
    b.len = 5;

    const merged = mergeCoords(&a, &b);
    // Should be [0, 0.25, 0.5, 0.75, 1.0]
    try std.testing.expectEqual(@as(usize, 5), merged.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), merged.data[0], 1e-7);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), merged.data[1], 1e-7);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), merged.data[2], 1e-7);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), merged.data[3], 1e-7);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), merged.data[4], 1e-7);
}
