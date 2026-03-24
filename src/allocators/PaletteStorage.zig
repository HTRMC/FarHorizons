const std = @import("std");

/// Palette-compressed storage for fixed-size arrays of values.
///
/// Instead of storing one T per element (e.g. 32768 × [3]u8 = 96 KB),
/// maintains a small palette of unique values and stores packed indices.
/// Adapts bit-width (0/1/2/4/8) based on how many unique values exist.
///
/// Typical savings for lighting data:
///   - Uniform chunk (all dark / all sky): 0 bits/element → ~16 bytes total
///   - Surface chunk (~30 unique values): 8 bits/element → ~33 KB
///   - vs raw storage: 96–128 KB per chunk
pub fn PaletteStorage(comptime T: type, comptime count: u32) type {
    return struct {
        const Self = @This();

        /// Packed palette indices (null when bit_size == 0; all elements are palette[0])
        data: ?[]u32,
        bit_size: u5,

        palette: []T,
        occupancy: []u32,
        palette_len: u32,
        active_entries: u32,
        palette_cap: u32,

        allocator: std.mem.Allocator,

        const default_val: T = std.mem.zeroes(T);

        pub fn init(allocator: std.mem.Allocator) Self {
            const palette = allocator.alloc(T, 1) catch @panic("PaletteStorage: OOM");
            const occupancy = allocator.alloc(u32, 1) catch @panic("PaletteStorage: OOM");
            palette[0] = default_val;
            occupancy[0] = count;
            return .{
                .data = null,
                .bit_size = 0,
                .palette = palette,
                .occupancy = occupancy,
                .palette_len = 1,
                .active_entries = 1,
                .palette_cap = 1,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.data) |d| self.allocator.free(d);
            self.allocator.free(self.palette);
            self.allocator.free(self.occupancy);
        }

        pub fn get(self: *const Self, index: usize) T {
            if (self.bit_size == 0) return self.palette[0];
            const pi = self.getPackedIndex(@intCast(index));
            return self.palette[pi];
        }

        pub fn set(self: *Self, index: usize, value: T) void {
            const idx: u32 = @intCast(index);

            // Find or insert palette entry (may grow palette + data array)
            const new_pi = self.getOrInsertPalette(value);

            // Read old index AFTER potential growth (growth preserves index values)
            const old_pi: u32 = if (self.bit_size == 0) 0 else self.getPackedIndex(idx);

            if (old_pi == new_pi) return;

            self.setPackedIndex(idx, new_pi);

            self.occupancy[new_pi] += 1;
            if (self.occupancy[new_pi] == 1) self.active_entries += 1;
            self.occupancy[old_pi] -= 1;
            if (self.occupancy[old_pi] == 0) self.active_entries -= 1;
        }

        /// Reset all elements to a single value. Frees the index array
        /// and shrinks the palette to 1 entry — minimal memory footprint.
        pub fn fillUniform(self: *Self, value: T) void {
            if (self.data) |d| {
                self.allocator.free(d);
                self.data = null;
            }

            if (self.palette_cap > 1) {
                self.allocator.free(self.palette);
                self.allocator.free(self.occupancy);
                self.palette = self.allocator.alloc(T, 1) catch @panic("PaletteStorage: OOM");
                self.occupancy = self.allocator.alloc(u32, 1) catch @panic("PaletteStorage: OOM");
                self.palette_cap = 1;
            }

            self.palette[0] = value;
            self.occupancy[0] = count;
            self.palette_len = 1;
            self.active_entries = 1;
            self.bit_size = 0;
        }

        /// Copy a contiguous range of values into a destination slice.
        /// Optimized for the uniform case (bit_size == 0).
        pub fn getRange(self: *const Self, dst: []T, start: u32) void {
            if (self.bit_size == 0) {
                @memset(dst, self.palette[0]);
                return;
            }
            for (dst, 0..) |*d, i| {
                d.* = self.get(start + @as(u32, @intCast(i)));
            }
        }

        /// Load values from a flat array, replacing all current contents.
        /// Resets palette and rebuilds from the source data.
        pub fn loadFromSlice(self: *Self, src: []const T) void {
            std.debug.assert(src.len == count);
            self.fillUniform(src[0]);
            for (src[1..], 1..) |val, i| {
                self.set(i, val);
            }
        }

        /// Estimated heap bytes used by this storage (palette + occupancy + packed data).
        pub fn memoryUsage(self: *const Self) usize {
            var total: usize = self.palette_cap * @sizeOf(T);
            total += self.palette_cap * @sizeOf(u32);
            if (self.data) |d| total += d.len * @sizeOf(u32);
            return total;
        }

        // ── Internal ──────────────────────────────────────────────────

        fn valEql(a: T, b: T) bool {
            return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
        }

        fn dataWordsNeeded(bit_size: u5) u32 {
            if (bit_size == 0) return 0;
            const total_bits: u32 = @as(u32, count) * @as(u32, bit_size);
            return (total_bits + 31) / 32;
        }

        fn getPackedIndex(self: *const Self, index: u32) u32 {
            const bs: u5 = self.bit_size;
            const d = self.data orelse return 0;
            const bit_index: u32 = index * bs;
            const word_index = bit_index >> 5;
            const bit_offset: u5 = @intCast(bit_index & 31);
            const mask: u32 = (@as(u32, 1) << bs) - 1;
            return (d[word_index] >> bit_offset) & mask;
        }

        fn setPackedIndex(self: *Self, index: u32, value: u32) void {
            const bs: u5 = self.bit_size;
            if (bs == 0) return;
            const d = self.data orelse return;
            const bit_index: u32 = index * bs;
            const word_index = bit_index >> 5;
            const bit_offset: u5 = @intCast(bit_index & 31);
            const mask: u32 = (@as(u32, 1) << bs) - 1;
            d[word_index] = (d[word_index] & ~(mask << bit_offset)) | (@as(u32, value) << bit_offset);
        }

        fn getOrInsertPalette(self: *Self, value: T) u32 {
            // Linear search (palette is small — typically <50 entries)
            for (self.palette[0..self.palette_len], 0..) |entry, i| {
                if (valEql(entry, value)) return @intCast(i);
            }

            // Not found — grow if palette is full
            if (self.palette_len >= self.palette_cap) {
                self.growBitSize();
            }

            const idx = self.palette_len;
            self.palette[idx] = value;
            self.occupancy[idx] = 0;
            self.palette_len += 1;
            return idx;
        }

        fn growBitSize(self: *Self) void {
            const old_bs = self.bit_size;
            const new_bs: u5 = switch (old_bs) {
                0 => 1,
                1 => 2,
                2 => 4,
                4 => 8,
                8 => 16,
                else => @panic("PaletteStorage: palette exceeded 65536 entries"),
            };
            const new_cap: u32 = @as(u32, 1) << new_bs;

            // Grow palette + occupancy arrays
            const new_palette = self.allocator.alloc(T, new_cap) catch @panic("PaletteStorage: OOM");
            const new_occupancy = self.allocator.alloc(u32, new_cap) catch @panic("PaletteStorage: OOM");
            @memcpy(new_palette[0..self.palette_len], self.palette[0..self.palette_len]);
            @memcpy(new_occupancy[0..self.palette_len], self.occupancy[0..self.palette_len]);
            @memset(new_occupancy[self.palette_len..new_cap], 0);
            self.allocator.free(self.palette);
            self.allocator.free(self.occupancy);
            self.palette = new_palette;
            self.occupancy = new_occupancy;
            self.palette_cap = new_cap;

            // Grow packed index array (re-pack existing indices at new bit width)
            const new_words = dataWordsNeeded(new_bs);
            const new_data = self.allocator.alloc(u32, new_words) catch @panic("PaletteStorage: OOM");
            @memset(new_data, 0);

            if (self.data) |old_data| {
                if (old_bs > 0) {
                    const obs: u5 = old_bs;
                    const nbs: u5 = new_bs;
                    const old_mask: u32 = (@as(u32, 1) << obs) - 1;
                    for (0..count) |i| {
                        const ci: u32 = @intCast(i);
                        // Read from old layout
                        const old_bit = ci * obs;
                        const old_word = old_bit >> 5;
                        const old_off: u5 = @intCast(old_bit & 31);
                        const val: u32 = (old_data[old_word] >> old_off) & old_mask;
                        // Write to new layout
                        const new_bit = ci * nbs;
                        const new_word = new_bit >> 5;
                        const new_off: u5 = @intCast(new_bit & 31);
                        new_data[new_word] |= @as(u32, val) << new_off;
                    }
                }
                self.allocator.free(old_data);
            }
            // If old bit_size was 0, new_data is already zeroed (all indices = 0). ✓

            self.data = new_data;
            self.bit_size = new_bs;
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "init creates uniform storage" {
    var s = PaletteStorage(u8, 16).init(testing.allocator);
    defer s.deinit();
    try testing.expectEqual(@as(u8, 0), s.get(0));
    try testing.expectEqual(@as(u8, 0), s.get(15));
    try testing.expectEqual(@as(u32, 1), s.palette_len);
    try testing.expectEqual(@as(u5, 0), s.bit_size);
}

test "set single value grows palette" {
    var s = PaletteStorage(u8, 16).init(testing.allocator);
    defer s.deinit();
    s.set(5, 42);
    try testing.expectEqual(@as(u8, 42), s.get(5));
    try testing.expectEqual(@as(u8, 0), s.get(0));
    try testing.expectEqual(@as(u32, 2), s.palette_len);
    try testing.expect(s.bit_size >= 1);
}

test "set same value is no-op" {
    var s = PaletteStorage(u8, 16).init(testing.allocator);
    defer s.deinit();
    s.set(0, 0); // same as default
    try testing.expectEqual(@as(u32, 1), s.palette_len);
    try testing.expectEqual(@as(u5, 0), s.bit_size);
}

test "fillUniform resets to minimal storage" {
    var s = PaletteStorage(u8, 16).init(testing.allocator);
    defer s.deinit();
    s.set(0, 10);
    s.set(1, 20);
    s.set(2, 30);
    s.fillUniform(99);
    try testing.expectEqual(@as(u8, 99), s.get(0));
    try testing.expectEqual(@as(u8, 99), s.get(15));
    try testing.expectEqual(@as(u32, 1), s.palette_len);
    try testing.expectEqual(@as(u5, 0), s.bit_size);
    try testing.expect(s.data == null);
}

test "many unique values trigger bit growth" {
    var s = PaletteStorage(u8, 64).init(testing.allocator);
    defer s.deinit();
    // Insert 20 unique values
    for (0..20) |i| {
        s.set(i, @intCast(i + 1));
    }
    try testing.expect(s.bit_size >= 4); // 16+ entries → at least 4-bit
    // Verify all values
    for (0..20) |i| {
        try testing.expectEqual(@as(u8, @intCast(i + 1)), s.get(i));
    }
    // Unset elements should still be default
    try testing.expectEqual(@as(u8, 0), s.get(63));
}

test "works with [3]u8 type" {
    var s = PaletteStorage([3]u8, 32).init(testing.allocator);
    defer s.deinit();
    s.set(0, .{ 255, 200, 100 });
    s.set(1, .{ 247, 192, 92 });
    try testing.expectEqual([3]u8{ 255, 200, 100 }, s.get(0));
    try testing.expectEqual([3]u8{ 247, 192, 92 }, s.get(1));
    try testing.expectEqual([3]u8{ 0, 0, 0 }, s.get(2));
}

test "overwrite existing value" {
    var s = PaletteStorage(u8, 16).init(testing.allocator);
    defer s.deinit();
    s.set(3, 10);
    try testing.expectEqual(@as(u8, 10), s.get(3));
    s.set(3, 20);
    try testing.expectEqual(@as(u8, 20), s.get(3));
    // Old value's occupancy should have decreased
    try testing.expectEqual(@as(u32, 3), s.palette_len);
}

test "fillUniform after growth then reuse" {
    var s = PaletteStorage(u8, 32).init(testing.allocator);
    defer s.deinit();
    for (0..20) |i| {
        s.set(i, @intCast(i + 1));
    }
    s.fillUniform(0);
    // Should be back to minimal state
    try testing.expectEqual(@as(u5, 0), s.bit_size);
    // Can grow again
    s.set(0, 50);
    s.set(1, 60);
    try testing.expectEqual(@as(u8, 50), s.get(0));
    try testing.expectEqual(@as(u8, 60), s.get(1));
}

test "memoryUsage is zero-ish for uniform" {
    var s = PaletteStorage(u8, 32768).init(testing.allocator);
    defer s.deinit();
    // Uniform: just 1 palette entry + 1 occupancy entry, no data array
    try testing.expect(s.memoryUsage() < 32);
}

test "memoryUsage scales with unique values" {
    var s = PaletteStorage([3]u8, 32768).init(testing.allocator);
    defer s.deinit();
    // Add some unique values to trigger growth
    for (0..5) |i| {
        s.set(i, .{ @intCast(i * 10), @intCast(i * 20), @intCast(i * 30) });
    }
    // Should be much less than raw 32768 * 3 = 98304 bytes
    try testing.expect(s.memoryUsage() < 20000);
}
