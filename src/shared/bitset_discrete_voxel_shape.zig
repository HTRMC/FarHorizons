/// BitSetDiscreteVoxelShape - Bitset-backed discrete voxel shape
/// Equivalent to Minecraft's net.minecraft.world.phys.shapes.BitSetDiscreteVoxelShape
///
/// Uses a linear bitset to store which voxels are filled.
/// Index calculation: index = x * ySize * zSize + y * zSize + z
const std = @import("std");
const DiscreteVoxelShape = @import("discrete_voxel_shape.zig").DiscreteVoxelShape;

/// Maximum supported size per axis (16 for block shapes)
pub const MAX_SIZE: u8 = 16;

/// Maximum total volume (16^3 = 4096 voxels = 64 u64 words)
pub const MAX_VOLUME: usize = @as(usize, MAX_SIZE) * @as(usize, MAX_SIZE) * @as(usize, MAX_SIZE);
pub const MAX_WORDS: usize = (MAX_VOLUME + 63) / 64;

/// BitSet storage for voxel data
pub const BitSetDiscreteVoxelShape = struct {
    const Self = @This();

    /// Base discrete shape fields
    base: DiscreteVoxelShape,

    /// Bitset storage - 64 u64 words for up to 4096 bits (16x16x16)
    storage: [MAX_WORDS]u64,

    /// Static vtable for DiscreteVoxelShape interface
    const vtable = DiscreteVoxelShape.VTable{
        .isFull = isFull,
        .fill = fill,
        .clear = clear,
        .isEmpty = isEmpty,
        .isFullBlock = isFullBlock,
    };

    /// Create an empty shape with given dimensions
    pub fn init(x_size: u8, y_size: u8, z_size: u8) Self {
        std.debug.assert(x_size <= MAX_SIZE and y_size <= MAX_SIZE and z_size <= MAX_SIZE);
        return .{
            .base = DiscreteVoxelShape.init(x_size, y_size, z_size, &vtable),
            .storage = [_]u64{0} ** MAX_WORDS,
        };
    }

    /// Create a shape with a filled rectangular region
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
        var shape = init(x_size, y_size, z_size);

        // Fill the specified region
        for (x_min..x_max) |x| {
            for (y_min..y_max) |y| {
                for (z_min..z_max) |z| {
                    shape.setDirect(@intCast(x), @intCast(y), @intCast(z), true);
                }
            }
        }

        // Update bounds
        if (x_min < x_max and y_min < y_max and z_min < z_max) {
            shape.base.x_min = x_min;
            shape.base.y_min = y_min;
            shape.base.z_min = z_min;
            shape.base.x_max = x_max;
            shape.base.y_max = y_max;
            shape.base.z_max = z_max;
        }

        return shape;
    }

    /// Create a fully filled shape
    pub fn initFull(x_size: u8, y_size: u8, z_size: u8) Self {
        return withFilledBounds(x_size, y_size, z_size, 0, 0, 0, x_size, y_size, z_size);
    }

    /// Get linear index from 3D coordinates
    fn getIndex(self: *const Self, x: u8, y: u8, z: u8) usize {
        return @as(usize, x) * self.base.y_size * self.base.z_size +
            @as(usize, y) * self.base.z_size +
            @as(usize, z);
    }

    /// Check if voxel is filled (internal, direct access)
    fn getDirect(self: *const Self, x: u8, y: u8, z: u8) bool {
        const idx = self.getIndex(x, y, z);
        const word_idx = idx / 64;
        const bit_idx: u6 = @intCast(idx % 64);
        return (self.storage[word_idx] & (@as(u64, 1) << bit_idx)) != 0;
    }

    /// Set voxel state (internal, direct access)
    fn setDirect(self: *Self, x: u8, y: u8, z: u8, value: bool) void {
        const idx = self.getIndex(x, y, z);
        const word_idx = idx / 64;
        const bit_idx: u6 = @intCast(idx % 64);
        if (value) {
            self.storage[word_idx] |= (@as(u64, 1) << bit_idx);
        } else {
            self.storage[word_idx] &= ~(@as(u64, 1) << bit_idx);
        }
    }

    // === DiscreteVoxelShape interface implementation ===

    fn isFull(base: *const DiscreteVoxelShape, x: u8, y: u8, z: u8) bool {
        const self: *const Self = @fieldParentPtr("base", base);
        if (x >= self.base.x_size or y >= self.base.y_size or z >= self.base.z_size) {
            return false;
        }
        return self.getDirect(x, y, z);
    }

    fn fill(base: *DiscreteVoxelShape, x: u8, y: u8, z: u8) void {
        const self: *Self = @fieldParentPtr("base", base);
        if (x >= self.base.x_size or y >= self.base.y_size or z >= self.base.z_size) {
            return;
        }
        self.setDirect(x, y, z, true);
    }

    fn clear(base: *DiscreteVoxelShape, x: u8, y: u8, z: u8) void {
        const self: *Self = @fieldParentPtr("base", base);
        if (x >= self.base.x_size or y >= self.base.y_size or z >= self.base.z_size) {
            return;
        }
        self.setDirect(x, y, z, false);
    }

    fn isEmpty(base: *const DiscreteVoxelShape) bool {
        const self: *const Self = @fieldParentPtr("base", base);
        const volume = @as(usize, self.base.x_size) * self.base.y_size * self.base.z_size;
        const words_used = (volume + 63) / 64;
        for (0..words_used) |i| {
            if (self.storage[i] != 0) return false;
        }
        return true;
    }

    fn isFullBlock(base: *const DiscreteVoxelShape) bool {
        const self: *const Self = @fieldParentPtr("base", base);
        const volume = @as(usize, self.base.x_size) * self.base.y_size * self.base.z_size;
        const full_words = volume / 64;
        const remaining_bits: u6 = @intCast(volume % 64);

        for (0..full_words) |i| {
            if (self.storage[i] != std.math.maxInt(u64)) return false;
        }
        if (remaining_bits > 0) {
            const expected = (@as(u64, 1) << remaining_bits) - 1;
            if (self.storage[full_words] != expected) return false;
        }
        return true;
    }

    // === Additional methods specific to BitSetDiscreteVoxelShape ===

    /// Get the raw bitset storage
    pub fn getStorage(self: *const Self) []const u64 {
        const volume = @as(usize, self.base.x_size) * self.base.y_size * self.base.z_size;
        const words_used = (volume + 63) / 64;
        return self.storage[0..words_used];
    }

    /// Perform OR operation with another shape (union)
    pub fn orWith(self: *Self, other: *const Self) void {
        std.debug.assert(self.base.x_size == other.base.x_size and
            self.base.y_size == other.base.y_size and
            self.base.z_size == other.base.z_size);

        const volume = @as(usize, self.base.x_size) * self.base.y_size * self.base.z_size;
        const words_used = (volume + 63) / 64;
        for (0..words_used) |i| {
            self.storage[i] |= other.storage[i];
        }

        // Update bounds
        self.base.x_min = @min(self.base.x_min, other.base.x_min);
        self.base.y_min = @min(self.base.y_min, other.base.y_min);
        self.base.z_min = @min(self.base.z_min, other.base.z_min);
        self.base.x_max = @max(self.base.x_max, other.base.x_max);
        self.base.y_max = @max(self.base.y_max, other.base.y_max);
        self.base.z_max = @max(self.base.z_max, other.base.z_max);
    }

    /// Perform AND operation with another shape (intersection)
    pub fn andWith(self: *Self, other: *const Self) void {
        std.debug.assert(self.base.x_size == other.base.x_size and
            self.base.y_size == other.base.y_size and
            self.base.z_size == other.base.z_size);

        const volume = @as(usize, self.base.x_size) * self.base.y_size * self.base.z_size;
        const words_used = (volume + 63) / 64;
        for (0..words_used) |i| {
            self.storage[i] &= other.storage[i];
        }

        // Bounds need recalculation after AND
        self.base.recalculateBounds();
    }

    /// Perform NOT operation (invert)
    pub fn invert(self: *Self) void {
        const volume = @as(usize, self.base.x_size) * self.base.y_size * self.base.z_size;
        const full_words = volume / 64;
        const remaining_bits: u6 = @intCast(volume % 64);

        for (0..full_words) |i| {
            self.storage[i] = ~self.storage[i];
        }
        if (remaining_bits > 0) {
            const mask = (@as(u64, 1) << remaining_bits) - 1;
            self.storage[full_words] = (~self.storage[full_words]) & mask;
        }

        self.base.recalculateBounds();
    }

    /// Check if (self AND NOT other) is empty
    /// Used for occlusion: returns true if other completely covers self
    pub fn isSubsetOf(self: *const Self, other: *const Self) bool {
        std.debug.assert(self.base.x_size == other.base.x_size and
            self.base.y_size == other.base.y_size and
            self.base.z_size == other.base.z_size);

        const volume = @as(usize, self.base.x_size) * self.base.y_size * self.base.z_size;
        const words_used = (volume + 63) / 64;
        for (0..words_used) |i| {
            if ((self.storage[i] & ~other.storage[i]) != 0) {
                return false;
            }
        }
        return true;
    }

    /// Count filled voxels (population count)
    pub fn popCount(self: *const Self) usize {
        const volume = @as(usize, self.base.x_size) * self.base.y_size * self.base.z_size;
        const words_used = (volume + 63) / 64;
        var count: usize = 0;
        for (0..words_used) |i| {
            count += @popCount(self.storage[i]);
        }
        return count;
    }

    /// Create a 2D slice of the shape along an axis at a given position
    /// Returns a new 2D BitSetDiscreteVoxelShape
    pub fn getSlice(self: *const Self, axis: @import("discrete_voxel_shape.zig").Axis, pos: u8) BitSetDiscreteVoxelShape2D {
        return switch (axis) {
            .x => blk: {
                // YZ slice at X=pos
                var slice = BitSetDiscreteVoxelShape2D.init(self.base.y_size, self.base.z_size);
                if (pos < self.base.x_size) {
                    for (0..self.base.y_size) |y| {
                        for (0..self.base.z_size) |z| {
                            if (self.getDirect(pos, @intCast(y), @intCast(z))) {
                                slice.set(@intCast(y), @intCast(z), true);
                            }
                        }
                    }
                }
                break :blk slice;
            },
            .y => blk: {
                // XZ slice at Y=pos
                var slice = BitSetDiscreteVoxelShape2D.init(self.base.x_size, self.base.z_size);
                if (pos < self.base.y_size) {
                    for (0..self.base.x_size) |x| {
                        for (0..self.base.z_size) |z| {
                            if (self.getDirect(@intCast(x), pos, @intCast(z))) {
                                slice.set(@intCast(x), @intCast(z), true);
                            }
                        }
                    }
                }
                break :blk slice;
            },
            .z => blk: {
                // XY slice at Z=pos
                var slice = BitSetDiscreteVoxelShape2D.init(self.base.x_size, self.base.y_size);
                if (pos < self.base.z_size) {
                    for (0..self.base.x_size) |x| {
                        for (0..self.base.y_size) |y| {
                            if (self.getDirect(@intCast(x), @intCast(y), pos)) {
                                slice.set(@intCast(x), @intCast(y), true);
                            }
                        }
                    }
                }
                break :blk slice;
            },
        };
    }
};

/// 2D Bitset for face shapes / slices
pub const BitSetDiscreteVoxelShape2D = struct {
    const Self = @This();

    u_size: u8,
    v_size: u8,
    storage: [4]u64, // Max 16x16 = 256 bits = 4 u64s

    pub fn init(u_size: u8, v_size: u8) Self {
        std.debug.assert(u_size <= MAX_SIZE and v_size <= MAX_SIZE);
        return .{
            .u_size = u_size,
            .v_size = v_size,
            .storage = [_]u64{0} ** 4,
        };
    }

    pub fn initFull(u_size: u8, v_size: u8) Self {
        var shape = init(u_size, v_size);
        const area = @as(usize, u_size) * v_size;
        const full_words = area / 64;
        const remaining_bits: u6 = @intCast(area % 64);

        for (0..full_words) |i| {
            shape.storage[i] = std.math.maxInt(u64);
        }
        if (remaining_bits > 0) {
            shape.storage[full_words] = (@as(u64, 1) << remaining_bits) - 1;
        }
        return shape;
    }

    fn getIndex(self: *const Self, u: u8, v: u8) usize {
        return @as(usize, u) * self.v_size + v;
    }

    pub fn get(self: *const Self, u: u8, v: u8) bool {
        if (u >= self.u_size or v >= self.v_size) return false;
        const idx = self.getIndex(u, v);
        const word_idx = idx / 64;
        const bit_idx: u6 = @intCast(idx % 64);
        return (self.storage[word_idx] & (@as(u64, 1) << bit_idx)) != 0;
    }

    pub fn set(self: *Self, u: u8, v: u8, value: bool) void {
        if (u >= self.u_size or v >= self.v_size) return;
        const idx = self.getIndex(u, v);
        const word_idx = idx / 64;
        const bit_idx: u6 = @intCast(idx % 64);
        if (value) {
            self.storage[word_idx] |= (@as(u64, 1) << bit_idx);
        } else {
            self.storage[word_idx] &= ~(@as(u64, 1) << bit_idx);
        }
    }

    pub fn isEmpty(self: *const Self) bool {
        const area = @as(usize, self.u_size) * self.v_size;
        const words_used = (area + 63) / 64;
        for (0..words_used) |i| {
            if (self.storage[i] != 0) return false;
        }
        return true;
    }

    pub fn isFull(self: *const Self) bool {
        const area = @as(usize, self.u_size) * self.v_size;
        const full_words = area / 64;
        const remaining_bits: u6 = @intCast(area % 64);

        for (0..full_words) |i| {
            if (self.storage[i] != std.math.maxInt(u64)) return false;
        }
        if (remaining_bits > 0) {
            const expected = (@as(u64, 1) << remaining_bits) - 1;
            if (self.storage[full_words] != expected) return false;
        }
        return true;
    }

    /// Check if other completely covers self
    /// Handles shapes with different resolutions
    pub fn isSubsetOf(self: *const Self, other: *const Self) bool {
        // Fast path: if other is full, it covers everything
        if (other.isFull()) {
            return true;
        }

        // Fast path: if self is empty, it's covered by anything
        if (self.isEmpty()) {
            return true;
        }

        // Fast path: if other is empty but self is not, self is not covered
        if (other.isEmpty()) {
            return false;
        }

        // Same resolution: direct bitwise comparison
        if (self.u_size == other.u_size and self.v_size == other.v_size) {
            const area = @as(usize, self.u_size) * self.v_size;
            const words_used = (area + 63) / 64;
            for (0..words_used) |i| {
                if ((self.storage[i] & ~other.storage[i]) != 0) {
                    return false;
                }
            }
            return true;
        }

        // Different resolutions: check each cell of self against corresponding region in other
        // For each cell in self that is set, check if the corresponding region in other is covered
        for (0..self.u_size) |u| {
            for (0..self.v_size) |v| {
                if (self.get(@intCast(u), @intCast(v))) {
                    // Calculate normalized coordinates (0.0 to 1.0)
                    const u_min = @as(f64, @floatFromInt(u)) / @as(f64, @floatFromInt(self.u_size));
                    const u_max = @as(f64, @floatFromInt(u + 1)) / @as(f64, @floatFromInt(self.u_size));
                    const v_min = @as(f64, @floatFromInt(v)) / @as(f64, @floatFromInt(self.v_size));
                    const v_max = @as(f64, @floatFromInt(v + 1)) / @as(f64, @floatFromInt(self.v_size));

                    // Check if other covers this region
                    if (!other.coversRegion(u_min, u_max, v_min, v_max)) {
                        return false;
                    }
                }
            }
        }
        return true;
    }

    /// Check if this shape covers the given normalized coordinate region
    fn coversRegion(self: *const Self, u_min: f64, u_max: f64, v_min: f64, v_max: f64) bool {
        // Convert to cell indices in this shape's resolution
        const u_start: usize = @intFromFloat(@floor(u_min * @as(f64, @floatFromInt(self.u_size))));
        const u_end: usize = @intFromFloat(@ceil(u_max * @as(f64, @floatFromInt(self.u_size))));
        const v_start: usize = @intFromFloat(@floor(v_min * @as(f64, @floatFromInt(self.v_size))));
        const v_end: usize = @intFromFloat(@ceil(v_max * @as(f64, @floatFromInt(self.v_size))));

        // All cells in the region must be filled
        for (u_start..@min(u_end, self.u_size)) |u| {
            for (v_start..@min(v_end, self.v_size)) |v| {
                if (!self.get(@intCast(u), @intCast(v))) {
                    return false;
                }
            }
        }
        return true;
    }
};

// Tests
test "BitSetDiscreteVoxelShape basic operations" {
    var shape = BitSetDiscreteVoxelShape.init(4, 4, 4);
    try std.testing.expect(shape.base.isEmpty());

    shape.base.fill(0, 0, 0);
    try std.testing.expect(!shape.base.isEmpty());
    try std.testing.expect(shape.base.isFull(0, 0, 0));
    try std.testing.expect(!shape.base.isFull(1, 0, 0));

    shape.base.clear(0, 0, 0);
    try std.testing.expect(shape.base.isEmpty());
}

test "BitSetDiscreteVoxelShape filled bounds" {
    const shape = BitSetDiscreteVoxelShape.withFilledBounds(4, 4, 4, 1, 1, 1, 3, 3, 3);

    try std.testing.expect(!shape.base.isFull(0, 0, 0));
    try std.testing.expect(shape.base.isFull(1, 1, 1));
    try std.testing.expect(shape.base.isFull(2, 2, 2));
    try std.testing.expect(!shape.base.isFull(3, 3, 3));

    try std.testing.expectEqual(@as(u8, 1), shape.base.x_min);
    try std.testing.expectEqual(@as(u8, 3), shape.base.x_max);
}

test "BitSetDiscreteVoxelShape full block" {
    const shape = BitSetDiscreteVoxelShape.initFull(2, 2, 2);
    try std.testing.expect(shape.base.isFullBlock());
    try std.testing.expect(!shape.base.isEmpty());
}

test "BitSetDiscreteVoxelShape2D subset" {
    var full = BitSetDiscreteVoxelShape2D.initFull(4, 4);
    var partial = BitSetDiscreteVoxelShape2D.init(4, 4);
    partial.set(0, 0, true);
    partial.set(1, 1, true);

    try std.testing.expect(partial.isSubsetOf(&full));
    try std.testing.expect(!full.isSubsetOf(&partial));
}

test "BitSetDiscreteVoxelShape slice" {
    // Create a slab shape (full on XZ, half on Y)
    const shape = BitSetDiscreteVoxelShape.withFilledBounds(4, 4, 4, 0, 0, 0, 4, 2, 4);

    // Get slice at Y=0 (should be full)
    const slice_y0 = shape.getSlice(.y, 0);
    try std.testing.expect(slice_y0.isFull());

    // Get slice at Y=3 (should be empty)
    const slice_y3 = shape.getSlice(.y, 3);
    try std.testing.expect(slice_y3.isEmpty());
}
