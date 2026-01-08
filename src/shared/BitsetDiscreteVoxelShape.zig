/// BitSetDiscreteVoxelShape - Bitset-backed discrete voxel shape
///
/// Uses a linear bitset to store which voxels are filled.
/// Index calculation: index = x * ySize * zSize + y * zSize + z
const std = @import("std");
const DiscreteVoxelShape = @import("DiscreteVoxelShape.zig").DiscreteVoxelShape;
const OctahedralGroup = @import("OctahedralGroup.zig").OctahedralGroup;

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

    /// Rotate the shape using an OctahedralGroup transformation
    /// Returns a new rotated shape
    pub fn rotate(self: *const Self, rotation: OctahedralGroup) Self {
        if (rotation.isIdentity()) {
            return self.*;
        }

        // Rotate the size vector to get new dimensions
        const size_vec = rotation.rotateVec(
            @as(i32, self.base.x_size),
            @as(i32, self.base.y_size),
            @as(i32, self.base.z_size),
        );

        // Handle negative sizes (absolute value) and calculate shift
        const new_x_size: u8 = @intCast(if (size_vec.x < 0) -size_vec.x else size_vec.x);
        const new_y_size: u8 = @intCast(if (size_vec.y < 0) -size_vec.y else size_vec.y);
        const new_z_size: u8 = @intCast(if (size_vec.z < 0) -size_vec.z else size_vec.z);

        // Calculate shift for negative coordinates (fixupCoordinate equivalent)
        const shift_x: i32 = if (size_vec.x < 0) -size_vec.x - 1 else 0;
        const shift_y: i32 = if (size_vec.y < 0) -size_vec.y - 1 else 0;
        const shift_z: i32 = if (size_vec.z < 0) -size_vec.z - 1 else 0;

        var result = init(new_x_size, new_y_size, new_z_size);

        // Iterate over all voxels and rotate their positions
        for (0..self.base.x_size) |x| {
            for (0..self.base.y_size) |y| {
                for (0..self.base.z_size) |z| {
                    if (self.getDirect(@intCast(x), @intCast(y), @intCast(z))) {
                        const rotated = rotation.rotateVec(
                            @as(i32, @intCast(x)),
                            @as(i32, @intCast(y)),
                            @as(i32, @intCast(z)),
                        );
                        const new_x: u8 = @intCast(shift_x + rotated.x);
                        const new_y: u8 = @intCast(shift_y + rotated.y);
                        const new_z: u8 = @intCast(shift_z + rotated.z);
                        result.setDirect(new_x, new_y, new_z, true);
                    }
                }
            }
        }

        // Update bounds
        result.base.recalculateBounds();
        return result;
    }

    // === Edge Iteration (for block outline rendering) ===

    /// Callback type for edge iteration
    /// Called with (x1, y1, z1, x2, y2, z2) for each edge in discrete voxel coordinates
    pub const IntEdgeConsumer = *const fn (x1: u8, y1: u8, z1: u8, x2: u8, y2: u8, z2: u8, ctx: *anyopaque) void;

    /// Iterate over all visible edges of the shape
    /// This implements Minecraft's edge detection algorithm that correctly handles
    /// complex shapes like stairs by checking adjacent voxel configurations.
    ///
    /// An edge is drawn when:
    /// - Exactly 1 adjacent voxel is filled (external edge)
    /// - Exactly 3 adjacent voxels are filled (concave corner)
    /// - Exactly 2 diagonal voxels are filled (internal corner)
    ///
    /// merge_neighbors: if true, collinear edge segments are merged into single lines
    pub fn forAllEdges(self: *const Self, consumer: IntEdgeConsumer, ctx: *anyopaque, merge_neighbors: bool) void {
        // Process edges along each axis
        // X-axis edges (lines parallel to X)
        self.forAllAxisEdges(consumer, ctx, merge_neighbors, .x);
        // Y-axis edges (lines parallel to Y)
        self.forAllAxisEdges(consumer, ctx, merge_neighbors, .y);
        // Z-axis edges (lines parallel to Z)
        self.forAllAxisEdges(consumer, ctx, merge_neighbors, .z);
    }

    /// Process edges along a specific axis
    /// edge_axis: the axis that edges run parallel to (the "c" axis in the algorithm)
    fn forAllAxisEdges(
        self: *const Self,
        consumer: IntEdgeConsumer,
        ctx: *anyopaque,
        merge_neighbors: bool,
        edge_axis: @import("DiscreteVoxelShape.zig").Axis,
    ) void {
        // Get the two perpendicular axes (a, b) and the edge axis (c)
        // We iterate over all (a, b) positions and scan along c
        const a_size: usize = switch (edge_axis) {
            .x => self.base.y_size,
            .y => self.base.x_size,
            .z => self.base.x_size,
        };
        const b_size: usize = switch (edge_axis) {
            .x => self.base.z_size,
            .y => self.base.z_size,
            .z => self.base.y_size,
        };
        const c_size: usize = switch (edge_axis) {
            .x => self.base.x_size,
            .y => self.base.y_size,
            .z => self.base.z_size,
        };

        // Iterate over all edge positions in the (a, b) plane
        // Edges can be at positions 0..=a_size and 0..=b_size (on the boundary)
        var a: usize = 0;
        while (a <= a_size) : (a += 1) {
            var b: usize = 0;
            while (b <= b_size) : (b += 1) {
                var last_start: i32 = -1;

                // Scan along the c axis
                var c: usize = 0;
                while (c <= c_size) : (c += 1) {
                    // Check the 4 adjacent voxels around this edge position
                    // The edge is at the corner of 4 voxels: (a-1,b-1), (a-1,b), (a,b-1), (a,b)
                    var full_sectors: u8 = 0;
                    var odd_sectors: u8 = 0;

                    var da: usize = 0;
                    while (da <= 1) : (da += 1) {
                        var db: usize = 0;
                        while (db <= 1) : (db += 1) {
                            // Calculate voxel coordinates with bounds checking
                            const va = if (a + da > 0) a + da - 1 else continue;
                            const vb = if (b + db > 0) b + db - 1 else continue;

                            if (self.isFullWideAxis(edge_axis, va, vb, c)) {
                                full_sectors += 1;
                                // XOR for diagonal detection: odd if da != db
                                odd_sectors ^= @intCast(da ^ db);
                            }
                        }
                    }

                    // Determine if this edge should be drawn
                    // Edge conditions:
                    // - 1 voxel filled: external boundary edge
                    // - 3 voxels filled: concave corner (one voxel missing)
                    // - 2 voxels filled AND diagonal: internal corner (checkerboard pattern)
                    const should_draw = (full_sectors == 1) or
                        (full_sectors == 3) or
                        (full_sectors == 2 and (odd_sectors & 1) == 0);

                    if (should_draw) {
                        if (merge_neighbors) {
                            if (last_start == -1) {
                                last_start = @intCast(c);
                            }
                        } else {
                            // Emit single unit edge
                            self.emitEdge(consumer, ctx, edge_axis, a, b, c, c + 1);
                        }
                    } else if (last_start != -1) {
                        // End of merged segment
                        self.emitEdge(consumer, ctx, edge_axis, a, b, @intCast(last_start), c);
                        last_start = -1;
                    }
                }

                // Handle segment that extends to the end
                if (last_start != -1) {
                    self.emitEdge(consumer, ctx, edge_axis, a, b, @intCast(last_start), c_size);
                }
            }
        }
    }

    /// Check if voxel is filled using axis-relative coordinates
    /// edge_axis is the axis we're iterating edges along
    fn isFullWideAxis(self: *const Self, edge_axis: @import("DiscreteVoxelShape.zig").Axis, a: usize, b: usize, c: usize) bool {
        // Convert axis-relative (a, b, c) to absolute (x, y, z) coordinates
        const coords = switch (edge_axis) {
            .x => .{ c, a, b }, // X edges: c=x, a=y, b=z
            .y => .{ a, c, b }, // Y edges: a=x, c=y, b=z
            .z => .{ a, b, c }, // Z edges: a=x, b=y, c=z
        };

        const x = coords[0];
        const y = coords[1];
        const z = coords[2];

        if (x >= self.base.x_size or y >= self.base.y_size or z >= self.base.z_size) {
            return false;
        }

        return self.getDirect(@intCast(x), @intCast(y), @intCast(z));
    }

    /// Emit an edge to the consumer, converting from axis-relative to absolute coordinates
    fn emitEdge(
        self: *const Self,
        consumer: IntEdgeConsumer,
        ctx: *anyopaque,
        edge_axis: @import("DiscreteVoxelShape.zig").Axis,
        a: usize,
        b: usize,
        c1: usize,
        c2: usize,
    ) void {
        _ = self;
        // Convert axis-relative coordinates to absolute (x, y, z)
        const start = switch (edge_axis) {
            .x => .{ c1, a, b },
            .y => .{ a, c1, b },
            .z => .{ a, b, c1 },
        };
        const end = switch (edge_axis) {
            .x => .{ c2, a, b },
            .y => .{ a, c2, b },
            .z => .{ a, b, c2 },
        };

        consumer(
            @intCast(start[0]),
            @intCast(start[1]),
            @intCast(start[2]),
            @intCast(end[0]),
            @intCast(end[1]),
            @intCast(end[2]),
            ctx,
        );
    }

    /// Create a 2D slice of the shape along an axis at a given position
    /// Returns a new 2D BitSetDiscreteVoxelShape
    pub fn getSlice(self: *const Self, axis: @import("DiscreteVoxelShape.zig").Axis, pos: u8) BitSetDiscreteVoxelShape2D {
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
    pub fn coversRegion(self: *const Self, u_min: f64, u_max: f64, v_min: f64, v_max: f64) bool {
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

test "BitSetDiscreteVoxelShape rotate Y 90" {
    // Create a shape with a single voxel at (0, 0, 0) in a 2x2x2 space
    var shape = BitSetDiscreteVoxelShape.init(2, 2, 2);
    shape.setDirect(0, 0, 0, true);

    // Rotate 90 degrees around Y axis
    // In block coords: (0,0,0) -> looking down, 90 CW rotation
    // X becomes -Z, Z becomes X (with coordinate system adjustments)
    const rotated = shape.rotate(OctahedralGroup.BLOCK_ROT_Y_90);

    // The rotated shape should still be 2x2x2
    try std.testing.expectEqual(@as(u8, 2), rotated.base.x_size);
    try std.testing.expectEqual(@as(u8, 2), rotated.base.y_size);
    try std.testing.expectEqual(@as(u8, 2), rotated.base.z_size);

    // Should have exactly one voxel
    try std.testing.expectEqual(@as(usize, 1), rotated.popCount());
}

test "BitSetDiscreteVoxelShape rotate Y 180" {
    // Create a shape with voxels at one corner
    var shape = BitSetDiscreteVoxelShape.init(2, 2, 2);
    shape.setDirect(0, 0, 0, true);

    // Rotate 180 degrees around Y axis
    const rotated = shape.rotate(OctahedralGroup.BLOCK_ROT_Y_180);

    // Should have exactly one voxel at opposite corner
    try std.testing.expectEqual(@as(usize, 1), rotated.popCount());
    try std.testing.expect(rotated.getDirect(1, 0, 1));
}

test "BitSetDiscreteVoxelShape rotate identity" {
    const shape = BitSetDiscreteVoxelShape.withFilledBounds(4, 4, 4, 0, 0, 0, 2, 2, 2);

    // Identity rotation should return identical shape
    const rotated = shape.rotate(OctahedralGroup.IDENTITY);

    try std.testing.expectEqual(shape.base.x_size, rotated.base.x_size);
    try std.testing.expectEqual(shape.base.y_size, rotated.base.y_size);
    try std.testing.expectEqual(shape.base.z_size, rotated.base.z_size);
    try std.testing.expectEqual(shape.popCount(), rotated.popCount());
}

test "BitSetDiscreteVoxelShape rotate INVERT_Y" {
    // Create bottom slab (filled Y=0,1 of 4)
    const shape = BitSetDiscreteVoxelShape.withFilledBounds(4, 4, 4, 0, 0, 0, 4, 2, 4);

    // Invert Y should create top slab
    const rotated = shape.rotate(OctahedralGroup.INVERT_Y);

    // Check that bottom is now empty and top is filled
    try std.testing.expect(!rotated.getDirect(0, 0, 0));
    try std.testing.expect(!rotated.getDirect(0, 1, 0));
    try std.testing.expect(rotated.getDirect(0, 2, 0));
    try std.testing.expect(rotated.getDirect(0, 3, 0));
}

test "forAllEdges full block" {
    // A full 2x2x2 block should have 12 edges (like a cube)
    const shape = BitSetDiscreteVoxelShape.initFull(2, 2, 2);

    var edge_count: usize = 0;
    const CountContext = struct {
        count: *usize,
    };
    var ctx = CountContext{ .count = &edge_count };

    shape.forAllEdges(struct {
        fn callback(_: u8, _: u8, _: u8, _: u8, _: u8, _: u8, ctx_ptr: *anyopaque) void {
            const c: *CountContext = @ptrCast(@alignCast(ctx_ptr));
            c.count.* += 1;
        }
    }.callback, @ptrCast(&ctx), true);

    // A cube has 12 edges
    try std.testing.expectEqual(@as(usize, 12), edge_count);
}

test "forAllEdges single voxel" {
    // A single 1x1x1 voxel should have 12 edges
    var shape = BitSetDiscreteVoxelShape.init(1, 1, 1);
    shape.setDirect(0, 0, 0, true);

    var edge_count: usize = 0;
    const CountContext = struct {
        count: *usize,
    };
    var ctx = CountContext{ .count = &edge_count };

    shape.forAllEdges(struct {
        fn callback(_: u8, _: u8, _: u8, _: u8, _: u8, _: u8, ctx_ptr: *anyopaque) void {
            const c: *CountContext = @ptrCast(@alignCast(ctx_ptr));
            c.count.* += 1;
        }
    }.callback, @ptrCast(&ctx), true);

    try std.testing.expectEqual(@as(usize, 12), edge_count);
}

test "forAllEdges L-shaped stair" {
    // Create an L-shaped stair in 2x2x2:
    // Bottom layer (y=0): all 4 voxels filled
    // Top layer (y=1): only half filled (x=1)
    // This is like a stair facing east
    var shape = BitSetDiscreteVoxelShape.init(2, 2, 2);

    // Fill bottom layer
    shape.setDirect(0, 0, 0, true);
    shape.setDirect(0, 0, 1, true);
    shape.setDirect(1, 0, 0, true);
    shape.setDirect(1, 0, 1, true);

    // Fill top east half (x=1)
    shape.setDirect(1, 1, 0, true);
    shape.setDirect(1, 1, 1, true);

    var edge_count: usize = 0;
    const CountContext = struct {
        count: *usize,
    };
    var ctx = CountContext{ .count = &edge_count };

    shape.forAllEdges(struct {
        fn callback(_: u8, _: u8, _: u8, _: u8, _: u8, _: u8, ctx_ptr: *anyopaque) void {
            const c: *CountContext = @ptrCast(@alignCast(ctx_ptr));
            c.count.* += 1;
        }
    }.callback, @ptrCast(&ctx), true);

    // L-shape should have more than 12 edges (full cube)
    // Expected: 18 edges for L-shape
    // - Bottom face: 4 edges
    // - Top faces: 4 (upper) + 2 (step top) = 6 edges
    // - Vertical edges: 4 (corners) + 2 (step) = 6 edges
    // - Step horizontal edge: 2 edges
    // Total: approximately 18 edges (merged)
    try std.testing.expect(edge_count > 12);
    try std.testing.expect(edge_count <= 24); // Reasonable upper bound
}

test "forAllEdges empty shape" {
    // Empty shape should have no edges
    const shape = BitSetDiscreteVoxelShape.init(2, 2, 2);

    var edge_count: usize = 0;
    const CountContext = struct {
        count: *usize,
    };
    var ctx = CountContext{ .count = &edge_count };

    shape.forAllEdges(struct {
        fn callback(_: u8, _: u8, _: u8, _: u8, _: u8, _: u8, ctx_ptr: *anyopaque) void {
            const c: *CountContext = @ptrCast(@alignCast(ctx_ptr));
            c.count.* += 1;
        }
    }.callback, @ptrCast(&ctx), true);

    try std.testing.expectEqual(@as(usize, 0), edge_count);
}

test "forAllEdges slab shape" {
    // Bottom slab (half height) should have 12 edges like a full block
    // since it's still a simple box shape
    const shape = BitSetDiscreteVoxelShape.withFilledBounds(2, 2, 2, 0, 0, 0, 2, 1, 2);

    var edge_count: usize = 0;
    const CountContext = struct {
        count: *usize,
    };
    var ctx = CountContext{ .count = &edge_count };

    shape.forAllEdges(struct {
        fn callback(_: u8, _: u8, _: u8, _: u8, _: u8, _: u8, ctx_ptr: *anyopaque) void {
            const c: *CountContext = @ptrCast(@alignCast(ctx_ptr));
            c.count.* += 1;
        }
    }.callback, @ptrCast(&ctx), true);

    // Slab is still a box, so 12 edges
    try std.testing.expectEqual(@as(usize, 12), edge_count);
}
