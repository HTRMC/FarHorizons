const std = @import("std");

/// Palette-compressed storage for fixed-size arrays of values.
///
/// Instead of storing one T per element (e.g. 32768 × [3]u8 = 96 KB),
/// maintains a small palette of unique values and stores packed indices.
/// Adapts bit-width (0/1/2/4/8) based on how many unique values exist.
///
/// Uses RCU (Read-Copy-Update) for concurrent reader safety:
/// - Readers load an atomic pointer to an immutable Impl snapshot
/// - Writers create a new Impl, atomically swap the pointer, and retire the old one
/// - Old Impls are deferred-freed after 3 generations (all readers should be done)
///
/// Typical savings for lighting data:
///   - Uniform chunk (all dark / all sky): 0 bits/element → ~16 bytes total
///   - Surface chunk (~30 unique values): 8 bits/element → ~33 KB
///   - vs raw storage: 96–128 KB per chunk
pub fn PaletteStorage(comptime T: type, comptime count: u32) type {
    return struct {
        const Self = @This();

        pub const Impl = struct {
            data: ?[]u32,
            bit_size: u5,
            palette: []T,
            occupancy: []u32,
            palette_len: u32,
            active_entries: u32,
            palette_cap: u32,

            fn getPackedIndex(imp: *const Impl, index: u32) u32 {
                const bs: u5 = imp.bit_size;
                const d = imp.data orelse return 0;
                const bit_index: u32 = index * bs;
                const word_index = bit_index >> 5;
                const bit_offset: u5 = @intCast(bit_index & 31);
                const mask: u32 = (@as(u32, 1) << bs) - 1;
                return (d[word_index] >> bit_offset) & mask;
            }

            fn setPackedIndex(imp: *Impl, index: u32, value: u32) void {
                const bs: u5 = imp.bit_size;
                if (bs == 0) return;
                const d = imp.data orelse return;
                const bit_index: u32 = index * bs;
                const word_index = bit_index >> 5;
                const bit_offset: u5 = @intCast(bit_index & 31);
                const mask: u32 = (@as(u32, 1) << bs) - 1;
                d[word_index] = (d[word_index] & ~(mask << bit_offset)) | (@as(u32, value) << bit_offset);
            }

            fn getOrInsertPalette(imp: *Impl, self: *Self, value: T) u32 {
                // Linear search (palette is small — typically <50 entries)
                for (imp.palette[0..imp.palette_len], 0..) |entry, i| {
                    if (valEql(entry, value)) return @intCast(i);
                }

                // Not found — grow if palette is full
                if (imp.palette_len >= imp.palette_cap) {
                    self.growBitSize();
                    // After growth, self.impl points to a new Impl; get it
                    const new_imp = self.impl.load(.acquire);
                    const idx = new_imp.palette_len;
                    new_imp.palette[idx] = value;
                    new_imp.occupancy[idx] = 0;
                    new_imp.palette_len += 1;
                    self.syncFields(new_imp);
                    return idx;
                }

                const idx = imp.palette_len;
                imp.palette[idx] = value;
                imp.occupancy[idx] = 0;
                imp.palette_len += 1;
                return idx;
            }
        };

        /// Atomic pointer to current Impl (readers load with .acquire)
        impl: std.atomic.Value(*Impl),

        // Mirror fields for backward-compatible direct field access (writer's view)
        data: ?[]u32,
        bit_size: u5,
        palette: []T,
        occupancy: []u32,
        palette_len: u32,
        active_entries: u32,
        palette_cap: u32,

        allocator: std.mem.Allocator,

        /// Ring buffer for deferred freeing of old Impls
        retired: [3]?*Impl,

        const default_val: T = std.mem.zeroes(T);

        pub fn init(allocator: std.mem.Allocator) Self {
            const palette = allocator.alloc(T, 1) catch @panic("PaletteStorage: OOM");
            const occupancy = allocator.alloc(u32, 1) catch @panic("PaletteStorage: OOM");
            palette[0] = default_val;
            occupancy[0] = count;

            const imp = allocator.create(Impl) catch @panic("PaletteStorage: OOM");
            imp.* = .{
                .data = null,
                .bit_size = 0,
                .palette = palette,
                .occupancy = occupancy,
                .palette_len = 1,
                .active_entries = 1,
                .palette_cap = 1,
            };

            return .{
                .impl = std.atomic.Value(*Impl).init(imp),
                .data = null,
                .bit_size = 0,
                .palette = palette,
                .occupancy = occupancy,
                .palette_len = 1,
                .active_entries = 1,
                .palette_cap = 1,
                .allocator = allocator,
                .retired = .{ null, null, null },
            };
        }

        pub fn deinit(self: *Self) void {
            // Free current impl
            const imp = self.impl.load(.acquire);
            self.destroyImpl(imp);
            // Free all retired impls
            for (&self.retired) |*slot| {
                if (slot.*) |old| {
                    self.destroyImpl(old);
                    slot.* = null;
                }
            }
        }

        pub fn get(self: *const Self, index: usize) T {
            const imp = self.impl.load(.acquire);
            if (imp.bit_size == 0) return imp.palette[0];
            const pi = imp.getPackedIndex(@intCast(index));
            return imp.palette[pi];
        }

        pub fn set(self: *Self, index: usize, value: T) void {
            const idx: u32 = @intCast(index);
            const imp = self.impl.load(.acquire);

            // Find or insert palette entry (may grow palette + data array via RCU swap)
            const new_pi = imp.getOrInsertPalette(self, value);

            // Re-load impl after potential growth
            const cur = self.impl.load(.acquire);

            // Read old index AFTER potential growth (growth preserves index values)
            const old_pi: u32 = if (cur.bit_size == 0) 0 else cur.getPackedIndex(idx);

            if (old_pi == new_pi) return;

            // In-place modification (caller holds external mutex; u32 writes are atomic on x86)
            cur.setPackedIndex(idx, new_pi);

            cur.occupancy[new_pi] += 1;
            if (cur.occupancy[new_pi] == 1) cur.active_entries += 1;
            cur.occupancy[old_pi] -= 1;
            if (cur.occupancy[old_pi] == 0) cur.active_entries -= 1;

            self.syncFields(cur);
        }

        /// Reset all elements to a single value. Allocates a new minimal Impl,
        /// atomically swaps, and retires the old one.
        pub fn fillUniform(self: *Self, value: T) void {
            const new_palette = self.allocator.alloc(T, 1) catch @panic("PaletteStorage: OOM");
            const new_occupancy = self.allocator.alloc(u32, 1) catch @panic("PaletteStorage: OOM");
            new_palette[0] = value;
            new_occupancy[0] = count;

            const new_imp = self.allocator.create(Impl) catch @panic("PaletteStorage: OOM");
            new_imp.* = .{
                .data = null,
                .bit_size = 0,
                .palette = new_palette,
                .occupancy = new_occupancy,
                .palette_len = 1,
                .active_entries = 1,
                .palette_cap = 1,
            };

            const old = self.impl.swap(new_imp, .release);
            self.retireImpl(old);
            self.syncFields(new_imp);
        }

        /// Copy a contiguous range of values into a destination slice.
        /// Optimized for the uniform case (bit_size == 0).
        /// Loads impl with .acquire once for a consistent snapshot.
        pub fn getRange(self: *const Self, dst: []T, start: u32) void {
            const imp = self.impl.load(.acquire);
            if (imp.bit_size == 0) {
                @memset(dst, imp.palette[0]);
                return;
            }
            for (dst, 0..) |*d, i| {
                const pi = imp.getPackedIndex(start + @as(u32, @intCast(i)));
                d.* = imp.palette[pi];
            }
        }

        /// Pre-allocate palette and data arrays for a known number of unique values.
        /// Resets contents. After calling, use setPaletteEntry + setRawIndex for bulk loading.
        pub fn initCapacity(self: *Self, palette_len_arg: u32) void {
            // Determine bit size needed
            const new_bs: u5 = if (palette_len_arg <= 1) 0 else switch (@as(u5, @intCast(std.math.log2_int_ceil(u32, palette_len_arg)))) {
                0 => 0,
                1 => 1,
                2 => 2,
                3, 4 => 4,
                5, 6, 7, 8 => 8,
                else => 16,
            };
            const new_cap: u32 = if (new_bs == 0) palette_len_arg else @as(u32, 1) << new_bs;

            const new_palette = self.allocator.alloc(T, new_cap) catch @panic("PaletteStorage: OOM");
            const new_occupancy = self.allocator.alloc(u32, new_cap) catch @panic("PaletteStorage: OOM");
            @memset(new_occupancy, 0);

            var new_data: ?[]u32 = null;
            const words = dataWordsNeeded(new_bs);
            if (words > 0) {
                new_data = self.allocator.alloc(u32, words) catch @panic("PaletteStorage: OOM");
                @memset(new_data.?, 0);
            }

            const new_imp = self.allocator.create(Impl) catch @panic("PaletteStorage: OOM");
            new_imp.* = .{
                .data = new_data,
                .bit_size = new_bs,
                .palette = new_palette,
                .occupancy = new_occupancy,
                .palette_len = palette_len_arg,
                .active_entries = palette_len_arg,
                .palette_cap = new_cap,
            };

            const old = self.impl.swap(new_imp, .release);
            self.retireImpl(old);
            self.syncFields(new_imp);
        }

        /// Set a palette entry directly (use after initCapacity).
        /// Bulk-load only — no concurrent readers expected.
        pub fn setPaletteEntry(self: *Self, index: u32, value: T) void {
            const imp = self.impl.load(.acquire);
            imp.palette[index] = value;
            self.palette = imp.palette;
        }

        /// Set the raw palette index for an element (use after initCapacity + setPaletteEntry).
        /// O(1) — just packs a bit index, no palette search.
        /// Bulk-load only — no concurrent readers expected.
        pub fn setRawIndex(self: *Self, element: u32, palette_index: u32) void {
            const imp = self.impl.load(.acquire);
            imp.setPackedIndex(element, palette_index);
            imp.occupancy[palette_index] += 1;
            self.syncFields(imp);
        }

        /// Load values from a flat array, replacing all current contents.
        /// Two-pass: builds palette first, then packs indices.
        pub fn loadFromSlice(self: *Self, src: []const T) void {
            std.debug.assert(src.len == count);

            // Pass 1: build palette (find unique values)
            var temp_palette: [256]T = undefined;
            var temp_palette_len: u32 = 0;
            var overflow = false;

            for (src) |val| {
                var found = false;
                for (temp_palette[0..temp_palette_len]) |p| {
                    if (valEql(p, val)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    if (temp_palette_len >= 256) {
                        overflow = true;
                        break;
                    }
                    temp_palette[temp_palette_len] = val;
                    temp_palette_len += 1;
                }
            }

            if (overflow) {
                // >256 unique values — fall back to individual set()
                self.fillUniform(src[0]);
                for (src[1..], 1..) |val, i| {
                    self.set(i, val);
                }
                return;
            }

            // Pre-allocate exact capacity
            self.initCapacity(temp_palette_len);

            const imp = self.impl.load(.acquire);
            for (0..temp_palette_len) |i| {
                imp.palette[i] = temp_palette[i];
            }

            // Pass 2: pack indices using O(1) setRawIndex
            for (src, 0..) |val, elem| {
                for (0..temp_palette_len) |pi| {
                    if (valEql(temp_palette[pi], val)) {
                        imp.setPackedIndex(@intCast(elem), @intCast(pi));
                        imp.occupancy[@intCast(pi)] += 1;
                        break;
                    }
                }
            }
            self.syncFields(imp);
        }

        /// Estimated heap bytes used by this storage (palette + occupancy + packed data).
        pub fn memoryUsage(self: *const Self) usize {
            const imp = self.impl.load(.acquire);
            var total: usize = imp.palette_cap * @sizeOf(T);
            total += imp.palette_cap * @sizeOf(u32);
            if (imp.data) |d| total += d.len * @sizeOf(u32);
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

        /// Synchronize mirror fields from an Impl (for backward-compatible field access).
        fn syncFields(self: *Self, imp: *Impl) void {
            self.data = imp.data;
            self.bit_size = imp.bit_size;
            self.palette = imp.palette;
            self.occupancy = imp.occupancy;
            self.palette_len = imp.palette_len;
            self.active_entries = imp.active_entries;
            self.palette_cap = imp.palette_cap;
        }

        fn destroyImpl(self: *Self, imp: *Impl) void {
            if (imp.data) |d| self.allocator.free(d);
            self.allocator.free(imp.palette);
            self.allocator.free(imp.occupancy);
            self.allocator.destroy(imp);
        }

        fn retireImpl(self: *Self, old: *Impl) void {
            // Free oldest if ring is full
            if (self.retired[self.retired.len - 1]) |oldest| {
                self.destroyImpl(oldest);
            }
            // Shift ring
            comptime var i = self.retired.len - 1;
            inline while (i > 0) : (i -= 1) {
                self.retired[i] = self.retired[i - 1];
            }
            self.retired[0] = old;
        }

        fn growBitSize(self: *Self) void {
            const cur = self.impl.load(.acquire);
            const old_bs = cur.bit_size;
            const new_bs: u5 = switch (old_bs) {
                0 => 1,
                1 => 2,
                2 => 4,
                4 => 8,
                8 => 16,
                else => @panic("PaletteStorage: palette exceeded 65536 entries"),
            };
            const new_cap: u32 = @as(u32, 1) << new_bs;

            // Allocate new palette + occupancy arrays
            const new_palette = self.allocator.alloc(T, new_cap) catch @panic("PaletteStorage: OOM");
            const new_occupancy = self.allocator.alloc(u32, new_cap) catch @panic("PaletteStorage: OOM");
            @memcpy(new_palette[0..cur.palette_len], cur.palette[0..cur.palette_len]);
            @memcpy(new_occupancy[0..cur.palette_len], cur.occupancy[0..cur.palette_len]);
            @memset(new_occupancy[cur.palette_len..new_cap], 0);

            // Allocate new packed index array (re-pack existing indices at new bit width)
            const new_words = dataWordsNeeded(new_bs);
            const new_data = self.allocator.alloc(u32, new_words) catch @panic("PaletteStorage: OOM");
            @memset(new_data, 0);

            if (cur.data) |old_data| {
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
            }
            // If old bit_size was 0, new_data is already zeroed (all indices = 0).

            const new_imp = self.allocator.create(Impl) catch @panic("PaletteStorage: OOM");
            new_imp.* = .{
                .data = new_data,
                .bit_size = new_bs,
                .palette = new_palette,
                .occupancy = new_occupancy,
                .palette_len = cur.palette_len,
                .active_entries = cur.active_entries,
                .palette_cap = new_cap,
            };

            const old = self.impl.swap(new_imp, .release);
            self.retireImpl(old);
            self.syncFields(new_imp);
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
