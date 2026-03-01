const std = @import("std");
const storage_types = @import("types.zig");

const HEADER_SECTORS = storage_types.HEADER_SECTORS;
const MAX_SECTORS = storage_types.MAX_SECTORS;
const BITMAP_BYTES = storage_types.BITMAP_BYTES;
const ChunkOffsetEntry = storage_types.ChunkOffsetEntry;
const CHUNKS_PER_REGION = storage_types.CHUNKS_PER_REGION;

pub const SectorAllocator = struct {
    bitmap: [BITMAP_BYTES]u8,
    total_sectors: u32,

    pub fn init() SectorAllocator {
        var self = SectorAllocator{
            .bitmap = [_]u8{0} ** BITMAP_BYTES,
            .total_sectors = HEADER_SECTORS,
        };
        self.markRange(0, HEADER_SECTORS);
        return self;
    }

    pub fn rebuildFromCot(cot: *const [CHUNKS_PER_REGION]ChunkOffsetEntry) SectorAllocator {
        var self = SectorAllocator{
            .bitmap = [_]u8{0} ** BITMAP_BYTES,
            .total_sectors = HEADER_SECTORS,
        };

        self.markRange(0, HEADER_SECTORS);

        for (cot) |entry| {
            if (entry.isPresent()) {
                const offset = entry.sector_offset;
                const count = entry.sector_count;
                self.markRange(offset, count);
                const end = @as(u32, offset) + @as(u32, count);
                if (end > self.total_sectors) {
                    self.total_sectors = end;
                }
            }
        }

        return self;
    }

    pub fn allocate(self: *SectorAllocator, count: u8) ?u24 {
        if (count == 0) return null;

        const needed: u32 = count;
        var start: u32 = HEADER_SECTORS;

        while (start + needed <= MAX_SECTORS) {
            if (self.isRangeFree(start, needed)) {
                self.markRange(start, needed);
                const end = start + needed;
                if (end > self.total_sectors) {
                    self.total_sectors = end;
                }
                return @intCast(start);
            }

            start = self.nextFreeAfter(start);
        }

        return null;
    }

    pub fn free(self: *SectorAllocator, offset: u24, count: u8) void {
        self.clearRange(@as(u32, offset), @as(u32, count));
    }

    fn isRangeFree(self: *const SectorAllocator, start: u32, count: u32) bool {
        for (start..start + count) |sector| {
            if (self.isUsed(@intCast(sector))) return false;
        }
        return true;
    }

    fn nextFreeAfter(self: *const SectorAllocator, start: u32) u32 {
        var pos = start;
        while (pos < MAX_SECTORS) : (pos += 1) {
            if (!self.isUsed(@intCast(pos))) return pos;
        }
        return MAX_SECTORS;
    }

    fn isUsed(self: *const SectorAllocator, sector: u32) bool {
        if (sector >= MAX_SECTORS) return true;
        const byte_idx = sector / 8;
        const bit_idx: u3 = @intCast(sector % 8);
        return (self.bitmap[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
    }

    fn markRange(self: *SectorAllocator, start: u32, count: u32) void {
        for (start..start + count) |sector| {
            self.setBit(@intCast(sector));
        }
    }

    fn clearRange(self: *SectorAllocator, start: u32, count: u32) void {
        for (start..start + count) |sector| {
            self.clearBit(@intCast(sector));
        }
    }

    fn setBit(self: *SectorAllocator, sector: u32) void {
        if (sector >= MAX_SECTORS) return;
        const byte_idx = sector / 8;
        const bit_idx: u3 = @intCast(sector % 8);
        self.bitmap[byte_idx] |= @as(u8, 1) << bit_idx;
    }

    fn clearBit(self: *SectorAllocator, sector: u32) void {
        if (sector >= MAX_SECTORS) return;
        const byte_idx = sector / 8;
        const bit_idx: u3 = @intCast(sector % 8);
        self.bitmap[byte_idx] &= ~(@as(u8, 1) << bit_idx);
    }

    pub fn getBitmap(self: *const SectorAllocator) *const [BITMAP_BYTES]u8 {
        return &self.bitmap;
    }

    pub fn loadBitmap(self: *SectorAllocator, data: *const [BITMAP_BYTES]u8) void {
        @memcpy(&self.bitmap, data);
    }
};


test "init reserves header sectors" {
    const alloc = SectorAllocator.init();
    try std.testing.expect(alloc.isUsed(0));
    try std.testing.expect(alloc.isUsed(1));
    try std.testing.expect(alloc.isUsed(2));
    try std.testing.expect(alloc.isUsed(3));
    try std.testing.expect(!alloc.isUsed(4));
}

test "allocate and free" {
    var alloc = SectorAllocator.init();

    const offset1 = alloc.allocate(3) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u24, 4), offset1);

    const offset2 = alloc.allocate(2) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u24, 7), offset2);

    alloc.free(offset1, 3);

    const offset3 = alloc.allocate(3) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u24, 4), offset3);
}

test "rebuildFromCot" {
    var cot: [CHUNKS_PER_REGION]ChunkOffsetEntry = undefined;
    @memset(&cot, ChunkOffsetEntry.empty);

    cot[0] = @bitCast(@as(u64, 0) | (@as(u64, 4) << 0) |
        (@as(u64, 3) << 24) |
        (@as(u64, 1000) << 32) |
        (@as(u64, 1) << 56));
    cot[1] = @bitCast(@as(u64, 0) | (@as(u64, 7) << 0) |
        (@as(u64, 1) << 24) |
        (@as(u64, 500) << 32) |
        (@as(u64, 1) << 56));

    const alloc = SectorAllocator.rebuildFromCot(&cot);

    try std.testing.expect(alloc.isUsed(0));
    try std.testing.expect(alloc.isUsed(1));
    try std.testing.expect(alloc.isUsed(2));
    try std.testing.expect(alloc.isUsed(3));

    try std.testing.expect(alloc.isUsed(4));
    try std.testing.expect(alloc.isUsed(5));
    try std.testing.expect(alloc.isUsed(6));

    try std.testing.expect(alloc.isUsed(7));

    try std.testing.expect(!alloc.isUsed(8));

    try std.testing.expectEqual(@as(u32, 8), alloc.total_sectors);
}
