/// IndexMerger - Coordinate list merging for boolean shape operations
///
/// When performing boolean operations between two VoxelShapes, we need to
/// merge their coordinate lists. For example, if shape A has X coordinates
/// [0, 0.5, 1.0] and shape B has [0, 0.25, 0.75, 1.0], the merged list is
/// [0, 0.25, 0.5, 0.75, 1.0].
///
/// The merger provides iteration over the merged coordinates and mapping
/// back to the original indices.
const std = @import("std");

/// Result of merging two coordinate lists
pub const MergeResult = struct {
    /// Index in first list (-1 if not present)
    first_idx: i32,
    /// Index in second list (-1 if not present)
    second_idx: i32,
    /// Whether iteration should continue
    has_next: bool,
};

/// Interface for index mergers
pub const IndexMerger = struct {
    const Self = @This();

    vtable: *const VTable,

    pub const VTable = struct {
        size: *const fn (self: *const Self) usize,
        getList: *const fn (self: *const Self) []const f64,
        forMergedIndexes: *const fn (
            self: *const Self,
            callback: *const fn (first_idx: i32, second_idx: i32, merged_idx: usize) bool,
        ) bool,
    };

    pub fn size(self: *const Self) usize {
        return self.vtable.size(self);
    }

    pub fn getList(self: *const Self) []const f64 {
        return self.vtable.getList(self);
    }

    /// Iterate over merged indices, calling callback for each
    /// Callback returns false to stop iteration
    pub fn forMergedIndexes(
        self: *const Self,
        callback: *const fn (first_idx: i32, second_idx: i32, merged_idx: usize) bool,
    ) bool {
        return self.vtable.forMergedIndexes(self, callback);
    }
};

/// Merger for two identical coordinate lists (no actual merging needed)
pub const IdenticalMerger = struct {
    const Self = @This();

    base: IndexMerger,
    coords: []const f64,

    const vtable = IndexMerger.VTable{
        .size = size,
        .getList = getList,
        .forMergedIndexes = forMergedIndexes,
    };

    pub fn init(coords: []const f64) Self {
        return .{
            .base = .{ .vtable = &vtable },
            .coords = coords,
        };
    }

    fn size(base: *const IndexMerger) usize {
        const self: *const Self = @fieldParentPtr("base", base);
        return self.coords.len;
    }

    fn getList(base: *const IndexMerger) []const f64 {
        const self: *const Self = @fieldParentPtr("base", base);
        return self.coords;
    }

    fn forMergedIndexes(
        base: *const IndexMerger,
        callback: *const fn (first_idx: i32, second_idx: i32, merged_idx: usize) bool,
    ) bool {
        const self: *const Self = @fieldParentPtr("base", base);
        for (0..self.coords.len) |i| {
            const idx: i32 = @intCast(i);
            if (!callback(idx, idx, i)) {
                return false;
            }
        }
        return true;
    }
};

/// Merger for discrete cube shapes (power-of-2 aligned)
/// Uses LCM to find common resolution
pub const DiscreteCubeMerger = struct {
    const Self = @This();

    base: IndexMerger,
    first_size: usize,
    second_size: usize,
    result_size: usize,
    first_to_result: []const i32,
    second_to_result: []const i32,
    result_coords: []const f64,
    allocator: std.mem.Allocator,

    const vtable = IndexMerger.VTable{
        .size = size,
        .getList = getList,
        .forMergedIndexes = forMergedIndexes,
    };

    pub fn init(allocator: std.mem.Allocator, first_size: usize, second_size: usize) !Self {
        // Calculate LCM for merged resolution
        const result_size = lcm(first_size, second_size);

        // Allocate mapping arrays
        var first_to_result = try allocator.alloc(i32, first_size + 1);
        errdefer allocator.free(first_to_result);

        var second_to_result = try allocator.alloc(i32, second_size + 1);
        errdefer allocator.free(second_to_result);

        var result_coords = try allocator.alloc(f64, result_size + 1);
        errdefer allocator.free(result_coords);

        // Fill coordinate list (0 to 1 in result_size steps)
        for (0..result_size + 1) |i| {
            result_coords[i] = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(result_size));
        }

        // Calculate first_to_result mapping
        const first_scale = result_size / first_size;
        for (0..first_size + 1) |i| {
            first_to_result[i] = @intCast(i * first_scale);
        }

        // Calculate second_to_result mapping
        const second_scale = result_size / second_size;
        for (0..second_size + 1) |i| {
            second_to_result[i] = @intCast(i * second_scale);
        }

        return .{
            .base = .{ .vtable = &vtable },
            .first_size = first_size,
            .second_size = second_size,
            .result_size = result_size,
            .first_to_result = first_to_result,
            .second_to_result = second_to_result,
            .result_coords = result_coords,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.first_to_result);
        self.allocator.free(self.second_to_result);
        self.allocator.free(self.result_coords);
    }

    fn size(base: *const IndexMerger) usize {
        const self: *const Self = @fieldParentPtr("base", base);
        return self.result_size;
    }

    fn getList(base: *const IndexMerger) []const f64 {
        const self: *const Self = @fieldParentPtr("base", base);
        return self.result_coords;
    }

    fn forMergedIndexes(
        base: *const IndexMerger,
        callback: *const fn (first_idx: i32, second_idx: i32, merged_idx: usize) bool,
    ) bool {
        const self: *const Self = @fieldParentPtr("base", base);

        // Iterate through result coordinates
        var first_idx: usize = 0;
        var second_idx: usize = 0;

        for (0..self.result_size + 1) |merged_idx| {
            // Find first index that maps to or past this merged index
            while (first_idx < self.first_size and self.first_to_result[first_idx + 1] <= @as(i32, @intCast(merged_idx))) {
                first_idx += 1;
            }
            while (second_idx < self.second_size and self.second_to_result[second_idx + 1] <= @as(i32, @intCast(merged_idx))) {
                second_idx += 1;
            }

            const fi: i32 = if (self.first_to_result[first_idx] == @as(i32, @intCast(merged_idx))) @intCast(first_idx) else -1;
            const si: i32 = if (self.second_to_result[second_idx] == @as(i32, @intCast(merged_idx))) @intCast(second_idx) else -1;

            if (!callback(fi, si, merged_idx)) {
                return false;
            }
        }
        return true;
    }

    fn lcm(a: usize, b: usize) usize {
        return (a * b) / gcd(a, b);
    }

    fn gcd(a: usize, b: usize) usize {
        var x = a;
        var y = b;
        while (y != 0) {
            const t = y;
            y = x % y;
            x = t;
        }
        return x;
    }
};

/// General-purpose merger for arbitrary coordinate lists (like Minecraft's IndirectMerger)
/// Uses merge-sort algorithm to combine two sorted coordinate lists
pub const IndirectMerger = struct {
    const Self = @This();

    base: IndexMerger,
    result: []f64,
    first_indices: []i32,
    second_indices: []i32,
    result_len: usize,
    allocator: std.mem.Allocator,

    const vtable = IndexMerger.VTable{
        .size = size,
        .getList = getList,
        .forMergedIndexes = forMergedIndexes,
    };

    const EPSILON: f64 = 1.0e-7;

    /// Create merger from two coordinate lists
    /// first_only_matters/second_only_matters: optimization flags for skipping coordinates
    pub fn init(
        allocator: std.mem.Allocator,
        first: []const f64,
        second: []const f64,
        first_only_matters: bool,
        second_only_matters: bool,
    ) !Self {
        const first_size = first.len;
        const second_size = second.len;
        const capacity = first_size + second_size;

        var result = try allocator.alloc(f64, capacity);
        errdefer allocator.free(result);

        var first_indices = try allocator.alloc(i32, capacity);
        errdefer allocator.free(first_indices);

        var second_indices = try allocator.alloc(i32, capacity);
        errdefer allocator.free(second_indices);

        const can_skip_first = !first_only_matters;
        const can_skip_second = !second_only_matters;

        var result_idx: usize = 0;
        var first_idx: usize = 0;
        var second_idx: usize = 0;
        var last_value: f64 = -std.math.inf(f64);

        while (true) {
            const ran_out_first = first_idx >= first_size;
            const ran_out_second = second_idx >= second_size;

            if (ran_out_first and ran_out_second) {
                break;
            }

            // Choose which list to take from (pick smaller value)
            const chose_first = !ran_out_first and (ran_out_second or first[first_idx] < second[second_idx] + EPSILON);

            if (chose_first) {
                first_idx += 1;
                if (can_skip_first and (second_idx == 0 or ran_out_second)) {
                    continue;
                }
            } else {
                second_idx += 1;
                if (can_skip_second and (first_idx == 0 or ran_out_first)) {
                    continue;
                }
            }

            const current_first: i32 = @as(i32, @intCast(first_idx)) - 1;
            const current_second: i32 = @as(i32, @intCast(second_idx)) - 1;
            const next_value = if (chose_first) first[@intCast(current_first)] else second[@intCast(current_second)];

            // Avoid duplicates within epsilon
            if (last_value < next_value - EPSILON) {
                first_indices[result_idx] = current_first;
                second_indices[result_idx] = current_second;
                result[result_idx] = next_value;
                result_idx += 1;
                last_value = next_value;
            } else if (result_idx > 0) {
                // Update mapping for same coordinate
                first_indices[result_idx - 1] = current_first;
                second_indices[result_idx - 1] = current_second;
            }
        }

        const result_len = @max(1, result_idx);

        return .{
            .base = .{ .vtable = &vtable },
            .result = result,
            .first_indices = first_indices,
            .second_indices = second_indices,
            .result_len = result_len,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.result);
        self.allocator.free(self.first_indices);
        self.allocator.free(self.second_indices);
    }

    fn size(base: *const IndexMerger) usize {
        const self: *const Self = @fieldParentPtr("base", base);
        return self.result_len;
    }

    fn getList(base: *const IndexMerger) []const f64 {
        const self: *const Self = @fieldParentPtr("base", base);
        return self.result[0..self.result_len];
    }

    fn forMergedIndexes(
        base: *const IndexMerger,
        callback: *const fn (first_idx: i32, second_idx: i32, merged_idx: usize) bool,
    ) bool {
        const self: *const Self = @fieldParentPtr("base", base);

        if (self.result_len <= 1) return true;

        for (0..self.result_len - 1) |i| {
            if (!callback(self.first_indices[i], self.second_indices[i], i)) {
                return false;
            }
        }
        return true;
    }
};

/// Simple merger for non-overlapping coordinate ranges (like Minecraft's NonOverlappingMerger)
/// Used when one shape's max coordinate < other shape's min coordinate
pub const NonOverlappingMerger = struct {
    const Self = @This();

    base: IndexMerger,
    lower_coords: []const f64,
    upper_coords: []const f64,
    swap: bool, // true if upper_coords came first in original call

    const vtable = IndexMerger.VTable{
        .size = size,
        .getList = getList,
        .forMergedIndexes = forMergedIndexes,
    };

    /// Create from two coordinate lists where lower.max < upper.min
    pub fn initFromCoords(lower: []const f64, upper: []const f64, swap: bool) Self {
        return .{
            .base = .{ .vtable = &vtable },
            .lower_coords = lower,
            .upper_coords = upper,
            .swap = swap,
        };
    }

    fn size(base: *const IndexMerger) usize {
        const self: *const Self = @fieldParentPtr("base", base);
        return self.lower_coords.len + self.upper_coords.len;
    }

    fn getList(_: *const IndexMerger) []const f64 {
        // Would need to concatenate arrays - return empty for now
        // In practice, iteration via forMergedIndexes is used
        return &[_]f64{};
    }

    fn forMergedIndexes(
        base: *const IndexMerger,
        callback: *const fn (first_idx: i32, second_idx: i32, merged_idx: usize) bool,
    ) bool {
        const self: *const Self = @fieldParentPtr("base", base);
        return if (self.swap)
            forNonSwappedIndexes(self, struct {
                fn cb(first: i32, second: i32, merged: usize, inner_callback: *const fn (i32, i32, usize) bool) bool {
                    return inner_callback(second, first, merged);
                }
            }.cb, callback)
        else
            forNonSwappedIndexes(self, struct {
                fn cb(first: i32, second: i32, merged: usize, inner_callback: *const fn (i32, i32, usize) bool) bool {
                    return inner_callback(first, second, merged);
                }
            }.cb, callback);
    }

    fn forNonSwappedIndexes(
        self: *const Self,
        comptime wrapper: fn (i32, i32, usize, *const fn (i32, i32, usize) bool) bool,
        callback: *const fn (first_idx: i32, second_idx: i32, merged_idx: usize) bool,
    ) bool {
        const lower_size = self.lower_coords.len;

        // Iterate through lower coordinates (only first shape matters)
        for (0..lower_size) |i| {
            if (!wrapper(@intCast(i), -1, i, callback)) {
                return false;
            }
        }

        // Iterate through upper coordinates (only second shape matters)
        const upper_size = self.upper_coords.len - 1;
        for (0..upper_size) |i| {
            if (!wrapper(@as(i32, @intCast(lower_size)) - 1, @intCast(i), lower_size + i, callback)) {
                return false;
            }
        }
        return true;
    }
};

/// Create the appropriate merger for two coordinate lists (like Minecraft's createIndexMerger)
/// cost: optimization hint (larger = prefer simpler merger)
/// first_only_matters/second_only_matters: optimization flags for skipping coordinates
pub fn createMerger(
    allocator: std.mem.Allocator,
    cost: usize,
    first_coords: []const f64,
    second_coords: []const f64,
    first_only_matters: bool,
    second_only_matters: bool,
) !MergerUnion {
    const first_size = first_coords.len - 1;
    const second_size = second_coords.len - 1;

    // Check if lists are identical
    if (first_size == second_size) {
        var identical = true;
        for (0..first_coords.len) |i| {
            if (@abs(first_coords[i] - second_coords[i]) > 1.0e-7) {
                identical = false;
                break;
            }
        }
        if (identical) {
            return .{ .identical = IdenticalMerger.init(first_coords) };
        }
    }

    // Check if coordinate lists represent uniform cube ranges (power-of-2)
    const first_is_cube = isUniformRange(first_coords);
    const second_is_cube = isUniformRange(second_coords);

    if (first_is_cube and second_is_cube) {
        // Use DiscreteCubeMerger if LCM is reasonable
        const lcm_size = DiscreteCubeMerger.lcm(first_size, second_size);
        if (cost * lcm_size <= 256) {
            return .{ .discrete_cube = try DiscreteCubeMerger.init(allocator, first_size, second_size) };
        }
    }

    // Check for non-overlapping ranges
    const EPSILON: f64 = 1.0e-7;
    if (first_coords[first_size] < second_coords[0] - EPSILON) {
        return .{ .non_overlapping = NonOverlappingMerger.initFromCoords(first_coords, second_coords, false) };
    } else if (second_coords[second_size] < first_coords[0] - EPSILON) {
        return .{ .non_overlapping = NonOverlappingMerger.initFromCoords(second_coords, first_coords, true) };
    }

    // Fall back to IndirectMerger for general case
    return .{ .indirect = try IndirectMerger.init(allocator, first_coords, second_coords, first_only_matters, second_only_matters) };
}

/// Check if coordinate list represents a uniform range [0, 1/n, 2/n, ..., 1]
pub fn isUniformRange(coords: []const f64) bool {
    if (coords.len < 2) return false;
    const n = coords.len - 1;
    const step = 1.0 / @as(f64, @floatFromInt(n));
    for (0..coords.len) |i| {
        const expected = @as(f64, @floatFromInt(i)) * step;
        if (@abs(coords[i] - expected) > 1.0e-7) {
            return false;
        }
    }
    return true;
}

/// Union type for different merger implementations
pub const MergerUnion = union(enum) {
    identical: IdenticalMerger,
    discrete_cube: DiscreteCubeMerger,
    non_overlapping: NonOverlappingMerger,
    indirect: IndirectMerger,

    pub fn deinit(self: *MergerUnion) void {
        switch (self.*) {
            .discrete_cube => |*dc| dc.deinit(),
            .indirect => |*im| im.deinit(),
            else => {},
        }
    }

    pub fn getMerger(self: *const MergerUnion) *const IndexMerger {
        return switch (self.*) {
            .identical => |*im| &im.base,
            .discrete_cube => |*dc| &dc.base,
            .non_overlapping => |*no| &no.base,
            .indirect => |*im| &im.base,
        };
    }

    pub fn size(self: *const MergerUnion) usize {
        return self.getMerger().size();
    }

    pub fn getList(self: *const MergerUnion) []const f64 {
        return self.getMerger().getList();
    }
};

// Tests
test "IdenticalMerger" {
    const coords = [_]f64{ 0.0, 0.5, 1.0 };
    const merger = IdenticalMerger.init(&coords);

    try std.testing.expectEqual(@as(usize, 3), merger.base.size());

    _ = merger.base.forMergedIndexes(&struct {
        fn callback(first_idx: i32, second_idx: i32, _: usize) bool {
            _ = first_idx;
            _ = second_idx;
            return true;
        }
    }.callback);
}

test "DiscreteCubeMerger LCM" {
    try std.testing.expectEqual(@as(usize, 4), DiscreteCubeMerger.lcm(2, 4));
    try std.testing.expectEqual(@as(usize, 6), DiscreteCubeMerger.lcm(2, 3));
    try std.testing.expectEqual(@as(usize, 8), DiscreteCubeMerger.lcm(4, 8));
}
