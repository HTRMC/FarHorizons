const std = @import("std");

/// Two-Level Segregated Fit allocator for managing sub-regions within a fixed-size
/// buffer (e.g. a GPU heap). Operates on abstract offset/size ranges — no Vulkan
/// or graphics dependencies.
///
/// First level: floor(log2(size))   → index into `fl_bitmap`
/// Second level: subdivides each first-level range into `SL_COUNT` linear buckets
///
/// All sizes/offsets are in *elements* (vertices, indices, bytes — caller decides).
pub const TlsfAllocator = struct {
    pub const FL_MAX = 24; // supports up to 2^24 = 16M elements per allocation
    pub const SL_BITS = 4;
    pub const SL_COUNT = 1 << SL_BITS; // 16 second-level buckets

    pub const Allocation = struct {
        offset: u32,
        size: u32,
    };

    pub const Handle = u16;
    pub const null_handle: Handle = std.math.maxInt(Handle);

    const Block = struct {
        offset: u32,
        size: u32,
        free: bool,
        prev_phys: Handle, // previous block in physical (address) order
        next_phys: Handle, // next block in physical (address) order
        prev_free: Handle, // previous block in same free-list bucket
        next_free: Handle, // next block in same free-list bucket
    };

    blocks: [max_blocks]Block,
    block_count: u16,
    free_block_stack: [max_blocks]Handle, // stack of recycled block indices
    free_stack_top: u16,

    // Segregated free lists: fl_bitmap and sl_bitmap track which buckets are non-empty
    fl_bitmap: u32, // bit i set => first-level class i has at least one free block
    sl_bitmap: [FL_MAX]u16, // bit j set => second-level bucket j of class i is non-empty
    free_lists: [FL_MAX][SL_COUNT]Handle, // head of free list for each (fl, sl) bucket

    capacity: u32, // total size of the managed region

    const max_blocks = 4096;

    pub fn init(capacity: u32) TlsfAllocator {
        var self = TlsfAllocator{
            .blocks = undefined,
            .block_count = 0,
            .free_block_stack = undefined,
            .free_stack_top = 0,
            .fl_bitmap = 0,
            .sl_bitmap = .{0} ** FL_MAX,
            .free_lists = .{.{null_handle} ** SL_COUNT} ** FL_MAX,
            .capacity = capacity,
        };

        // Create one free block spanning the entire region
        const handle = self.newBlock();
        self.blocks[handle] = .{
            .offset = 0,
            .size = capacity,
            .free = true,
            .prev_phys = null_handle,
            .next_phys = null_handle,
            .prev_free = null_handle,
            .next_free = null_handle,
        };
        self.insertFreeBlock(handle);

        return self;
    }

    /// Allocate a region of at least `size` elements. Returns null if no suitable
    /// free block exists.
    pub fn alloc(self: *TlsfAllocator, size: u32) ?Allocation {
        if (size == 0) return null;

        const suitable = self.searchSuitableBlock(size) orelse return null;
        const handle = self.free_lists[suitable.fl][suitable.sl];
        if (handle == null_handle) return null;

        self.removeFreeBlock(handle);

        const block = &self.blocks[handle];
        const remainder = block.size - size;

        // Split if remainder is large enough to be useful (>= 1 element)
        if (remainder > 0) {
            const split_handle = self.newBlock();
            self.blocks[split_handle] = .{
                .offset = block.offset + size,
                .size = remainder,
                .free = true,
                .prev_phys = handle,
                .next_phys = block.next_phys,
                .prev_free = null_handle,
                .next_free = null_handle,
            };

            if (block.next_phys != null_handle) {
                self.blocks[block.next_phys].prev_phys = split_handle;
            }
            block.next_phys = split_handle;
            block.size = size;

            self.insertFreeBlock(split_handle);
        }

        block.free = false;
        return .{ .offset = block.offset, .size = block.size };
    }

    /// Free a previously allocated region. The offset must exactly match a prior
    /// allocation's offset.
    pub fn free(self: *TlsfAllocator, offset: u32) void {
        // Find the block by offset
        const handle = self.findBlockByOffset(offset) orelse return;
        var block = &self.blocks[handle];
        block.free = true;

        // Merge with next physical neighbor if free
        var current_handle = handle;
        if (block.next_phys != null_handle) {
            const next = block.next_phys;
            if (self.blocks[next].free) {
                self.removeFreeBlock(next);
                block.size += self.blocks[next].size;
                block.next_phys = self.blocks[next].next_phys;
                if (self.blocks[next].next_phys != null_handle) {
                    self.blocks[self.blocks[next].next_phys].prev_phys = current_handle;
                }
                self.recycleBlock(next);
            }
        }

        // Merge with previous physical neighbor if free
        if (block.prev_phys != null_handle) {
            const prev = block.prev_phys;
            if (self.blocks[prev].free) {
                self.removeFreeBlock(prev);
                self.blocks[prev].size += block.size;
                self.blocks[prev].next_phys = block.next_phys;
                if (block.next_phys != null_handle) {
                    self.blocks[block.next_phys].prev_phys = prev;
                }
                self.recycleBlock(current_handle);
                current_handle = prev;
                block = &self.blocks[prev];
            }
        }

        self.insertFreeBlock(current_handle);
    }

    /// Returns total free space available (sum of all free blocks).
    pub fn totalFree(self: *const TlsfAllocator) u32 {
        var total: u32 = 0;
        var i: u16 = 0;
        while (i < self.block_count) : (i += 1) {
            if (!self.isRecycled(i) and self.blocks[i].free) {
                total += self.blocks[i].size;
            }
        }
        return total;
    }

    /// Returns the largest single free block size.
    pub fn largestFree(self: *const TlsfAllocator) u32 {
        var largest: u32 = 0;
        var i: u16 = 0;
        while (i < self.block_count) : (i += 1) {
            if (!self.isRecycled(i) and self.blocks[i].free and self.blocks[i].size > largest) {
                largest = self.blocks[i].size;
            }
        }
        return largest;
    }

    // ── Internal helpers ──────────────────────────────────────────────

    const FLSLPair = struct { fl: u5, sl: u4 };

    fn mapping(size: u32) FLSLPair {
        if (size == 0) return .{ .fl = 0, .sl = 0 };
        const fl = flIndex(size);
        const sl = slIndex(size, fl);
        return .{ .fl = fl, .sl = sl };
    }

    fn flIndex(size: u32) u5 {
        if (size == 0) return 0;
        return @intCast(@as(u5, @truncate(std.math.log2_int(u32, size))));
    }

    fn slIndex(size: u32, fl: u5) u4 {
        if (fl < SL_BITS) return 0;
        const shift: u5 = fl - SL_BITS;
        return @truncate((size >> shift) ^ (@as(u32, 1) << SL_BITS));
    }

    /// Like mapping(), but rounds up size so the found bucket is guaranteed to
    /// contain blocks >= the requested size.
    fn searchMapping(size: u32) FLSLPair {
        var rounded = size;
        if (size > 0) {
            const fl = flIndex(size);
            if (fl >= SL_BITS) {
                const round = (@as(u32, 1) << (fl - SL_BITS)) - 1;
                rounded = size +| round; // saturating add
            }
        }
        return mapping(rounded);
    }

    fn searchSuitableBlock(self: *const TlsfAllocator, size: u32) ?FLSLPair {
        const m = searchMapping(size);
        var fl = m.fl;
        const sl = m.sl;

        // Search in the rounded-up (fl, sl) bucket and above within same fl
        var sl_map = self.sl_bitmap[fl] & (~@as(u16, 0) << sl);
        if (sl_map != 0) {
            const found_sl: u4 = @intCast(@ctz(sl_map));
            return .{ .fl = fl, .sl = found_sl };
        }

        // Search higher first-level classes
        const fl_map = self.fl_bitmap & (~@as(u32, 0) << (@as(u5, fl) +| 1));
        if (fl_map == 0) return null; // no large enough free block

        fl = @intCast(@ctz(fl_map));
        sl_map = self.sl_bitmap[fl];
        if (sl_map == 0) return null; // shouldn't happen if fl_bitmap is consistent
        const found_sl: u4 = @intCast(@ctz(sl_map));
        return .{ .fl = fl, .sl = found_sl };
    }

    fn insertFreeBlock(self: *TlsfAllocator, handle: Handle) void {
        const m = mapping(self.blocks[handle].size);
        const fl = m.fl;
        const sl = m.sl;

        const head = self.free_lists[fl][sl];
        self.blocks[handle].prev_free = null_handle;
        self.blocks[handle].next_free = head;
        if (head != null_handle) {
            self.blocks[head].prev_free = handle;
        }
        self.free_lists[fl][sl] = handle;

        self.fl_bitmap |= @as(u32, 1) << fl;
        self.sl_bitmap[fl] |= @as(u16, 1) << sl;
    }

    fn removeFreeBlock(self: *TlsfAllocator, handle: Handle) void {
        const block = &self.blocks[handle];
        const m = mapping(block.size);
        const fl = m.fl;
        const sl = m.sl;

        if (block.prev_free != null_handle) {
            self.blocks[block.prev_free].next_free = block.next_free;
        } else {
            self.free_lists[fl][sl] = block.next_free;
        }

        if (block.next_free != null_handle) {
            self.blocks[block.next_free].prev_free = block.prev_free;
        }

        block.prev_free = null_handle;
        block.next_free = null_handle;

        // Update bitmaps if this bucket is now empty
        if (self.free_lists[fl][sl] == null_handle) {
            self.sl_bitmap[fl] &= ~(@as(u16, 1) << sl);
            if (self.sl_bitmap[fl] == 0) {
                self.fl_bitmap &= ~(@as(u32, 1) << fl);
            }
        }
    }

    fn findBlockByOffset(self: *const TlsfAllocator, offset: u32) ?Handle {
        var i: u16 = 0;
        while (i < self.block_count) : (i += 1) {
            if (!self.isRecycled(i) and self.blocks[i].offset == offset and !self.blocks[i].free) {
                return i;
            }
        }
        return null;
    }

    fn newBlock(self: *TlsfAllocator) Handle {
        if (self.free_stack_top > 0) {
            self.free_stack_top -= 1;
            return self.free_block_stack[self.free_stack_top];
        }
        const handle = self.block_count;
        self.block_count += 1;
        return handle;
    }

    fn recycleBlock(self: *TlsfAllocator, handle: Handle) void {
        self.blocks[handle] = .{
            .offset = std.math.maxInt(u32),
            .size = 0,
            .free = false,
            .prev_phys = null_handle,
            .next_phys = null_handle,
            .prev_free = null_handle,
            .next_free = null_handle,
        };
        self.free_block_stack[self.free_stack_top] = handle;
        self.free_stack_top += 1;
    }

    fn isRecycled(self: *const TlsfAllocator, handle: Handle) bool {
        for (self.free_block_stack[0..self.free_stack_top]) |h| {
            if (h == handle) return true;
        }
        return false;
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "basic alloc and free" {
    var a = TlsfAllocator.init(1024);

    const r1 = a.alloc(100).?;
    try std.testing.expectEqual(0, r1.offset);
    try std.testing.expectEqual(100, r1.size);

    const r2 = a.alloc(200).?;
    try std.testing.expectEqual(100, r2.offset);
    try std.testing.expectEqual(200, r2.size);

    a.free(r1.offset);

    // Should reuse the freed region
    const r3 = a.alloc(50).?;
    try std.testing.expectEqual(0, r3.offset);
    try std.testing.expectEqual(50, r3.size);
}

test "merge coalesces adjacent free blocks" {
    var a = TlsfAllocator.init(1024);

    const r1 = a.alloc(100).?;
    const r2 = a.alloc(100).?;
    const r3 = a.alloc(100).?;
    _ = r2;

    a.free(r1.offset);
    a.free(r3.offset); // r3 is not adjacent to r1

    // Free r2 — should merge r1+r2+r3 into one 300-element block
    a.free(100); // r2's offset

    const big = a.alloc(300).?;
    try std.testing.expectEqual(0, big.offset);
    try std.testing.expectEqual(300, big.size);
}

test "alloc returns null when full" {
    var a = TlsfAllocator.init(100);

    _ = a.alloc(100).?;
    try std.testing.expect(a.alloc(1) == null);
}

test "alloc zero returns null" {
    var a = TlsfAllocator.init(100);
    try std.testing.expect(a.alloc(0) == null);
}

test "full alloc-free cycle restores capacity" {
    var a = TlsfAllocator.init(1024);

    const r1 = a.alloc(512).?;
    const r2 = a.alloc(512).?;

    try std.testing.expect(a.alloc(1) == null);

    a.free(r1.offset);
    a.free(r2.offset);

    // After freeing everything, should have full capacity again
    const big = a.alloc(1024).?;
    try std.testing.expectEqual(0, big.offset);
    try std.testing.expectEqual(1024, big.size);
}

test "many small allocations" {
    var a = TlsfAllocator.init(1000);
    var offsets: [100]u32 = undefined;

    for (0..100) |i| {
        const r = a.alloc(10).?;
        offsets[i] = r.offset;
    }

    // Should be full
    try std.testing.expect(a.alloc(1) == null);

    // Free all
    for (0..100) |i| {
        a.free(offsets[i]);
    }

    // Should have full capacity
    try std.testing.expectEqual(1000, a.totalFree());
}

test "totalFree and largestFree" {
    var a = TlsfAllocator.init(1024);

    try std.testing.expectEqual(1024, a.totalFree());
    try std.testing.expectEqual(1024, a.largestFree());

    _ = a.alloc(100).?;
    try std.testing.expectEqual(924, a.totalFree());

    const r2 = a.alloc(200).?;
    _ = a.alloc(100).?;

    a.free(r2.offset);
    // Now we have a 200-element hole at offset 100 and a free tail
    // 200 (freed r2 hole) + 624 (tail) = 824
    try std.testing.expectEqual(824, a.totalFree());
}

test "split creates properly linked blocks" {
    var a = TlsfAllocator.init(1000);

    const r1 = a.alloc(300).?;
    const r2 = a.alloc(300).?;

    try std.testing.expectEqual(0, r1.offset);
    try std.testing.expectEqual(300, r2.offset);

    // Remainder block should exist at offset 600 with size 400
    try std.testing.expectEqual(400, a.totalFree());

    const r3 = a.alloc(400).?;
    try std.testing.expectEqual(600, r3.offset);
    try std.testing.expectEqual(0, a.totalFree());
}

test "free in reverse order merges correctly" {
    var a = TlsfAllocator.init(1024);

    const r1 = a.alloc(256).?;
    const r2 = a.alloc(256).?;
    const r3 = a.alloc(256).?;
    const r4 = a.alloc(256).?;

    // Free in reverse: r4, r3, r2, r1
    a.free(r4.offset);
    a.free(r3.offset);
    a.free(r2.offset);
    a.free(r1.offset);

    // Should coalesce back to one big block
    try std.testing.expectEqual(1024, a.largestFree());
    const big = a.alloc(1024).?;
    try std.testing.expectEqual(0, big.offset);
}

test "searchMapping rounds up to guarantee block >= requested size" {
    // Regression: without rounding up, a block smaller than `size` could be
    // returned from a bucket whose range straddles the request, causing an
    // integer overflow in the split path (block.size - size).
    var a = TlsfAllocator.init(600_000);

    // Create fragmentation: allocate many varied-size chunks then free some
    var allocs: [50]TlsfAllocator.Allocation = undefined;
    for (0..50) |i| {
        const sz: u32 = @intCast(1000 + i * 137); // varying sizes
        allocs[i] = a.alloc(sz).?;
    }

    // Free every other allocation to create non-contiguous free blocks
    for (0..50) |i| {
        if (i % 2 == 0) a.free(allocs[i].offset);
    }

    // Now allocate sizes that are likely to hit inter-bucket boundaries.
    // The key property: every returned allocation must have size >= requested.
    for (0..25) |i| {
        const req: u32 = @intCast(500 + i * 200);
        if (a.alloc(req)) |result| {
            try std.testing.expect(result.size >= req);
        }
    }
}
