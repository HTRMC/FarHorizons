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

/// Simple merger for non-overlapping ranges
pub const NonOverlappingMerger = struct {
    const Self = @This();

    base: IndexMerger,
    lower: f64,
    upper: f64,
    first_is_lower: bool,

    const vtable = IndexMerger.VTable{
        .size = size,
        .getList = getList,
        .forMergedIndexes = forMergedIndexes,
    };

    pub fn init(first_lower: f64, first_upper: f64, second_lower: f64, second_upper: f64) Self {
        // Determine which shape is lower
        const first_is_lower = first_lower <= second_lower;
        const lower = @min(first_lower, second_lower);
        const upper = @max(first_upper, second_upper);

        return .{
            .base = .{ .vtable = &vtable },
            .lower = lower,
            .upper = upper,
            .first_is_lower = first_is_lower,
        };
    }

    fn size(_: *const IndexMerger) usize {
        return 2; // Just lower and upper bounds
    }

    fn getList(_: *const IndexMerger) []const f64 {
        // Would need allocated storage for this - simplified version
        return &[_]f64{ 0.0, 1.0 };
    }

    fn forMergedIndexes(
        base: *const IndexMerger,
        callback: *const fn (first_idx: i32, second_idx: i32, merged_idx: usize) bool,
    ) bool {
        const self: *const Self = @fieldParentPtr("base", base);

        if (self.first_is_lower) {
            if (!callback(0, -1, 0)) return false;
            if (!callback(1, 0, 1)) return false;
            return callback(-1, 1, 2);
        } else {
            if (!callback(-1, 0, 0)) return false;
            if (!callback(0, 1, 1)) return false;
            return callback(1, -1, 2);
        }
    }
};

/// Create the appropriate merger for two coordinate lists
pub fn createMerger(
    allocator: std.mem.Allocator,
    first_size: usize,
    second_size: usize,
    first_coords: ?[]const f64,
    second_coords: ?[]const f64,
) !MergerUnion {
    // Check if lists are identical
    if (first_size == second_size) {
        if (first_coords != null and second_coords != null) {
            const fc = first_coords.?;
            const sc = second_coords.?;
            var identical = true;
            for (0..first_size + 1) |i| {
                if (fc[i] != sc[i]) {
                    identical = false;
                    break;
                }
            }
            if (identical) {
                return .{ .identical = IdenticalMerger.init(fc) };
            }
        }
    }

    // Use discrete cube merger for power-of-2 sizes
    const lcm_size = DiscreteCubeMerger.lcm(first_size, second_size);
    if (lcm_size <= 256) {
        return .{ .discrete_cube = try DiscreteCubeMerger.init(allocator, first_size, second_size) };
    }

    // Fall back to discrete cube anyway (would be IndirectMerger)
    return .{ .discrete_cube = try DiscreteCubeMerger.init(allocator, first_size, second_size) };
}

/// Union type for different merger implementations
pub const MergerUnion = union(enum) {
    identical: IdenticalMerger,
    discrete_cube: DiscreteCubeMerger,
    non_overlapping: NonOverlappingMerger,

    pub fn deinit(self: *MergerUnion) void {
        switch (self.*) {
            .discrete_cube => |*dc| dc.deinit(),
            else => {},
        }
    }

    pub fn getMerger(self: *const MergerUnion) *const IndexMerger {
        return switch (self.*) {
            .identical => |*im| &im.base,
            .discrete_cube => |*dc| &dc.base,
            .non_overlapping => |*no| &no.base,
        };
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
