const std = @import("std");
const storage_types = @import("types.zig");

const HEADER_SECTORS = storage_types.HEADER_SECTORS;
const MAX_SECTORS = storage_types.MAX_SECTORS;
const BITMAP_BYTES = storage_types.BITMAP_BYTES;
const ChunkOffsetEntry = storage_types.ChunkOffsetEntry;
const CHUNKS_PER_REGION = storage_types.CHUNKS_PER_REGION;

/// Bitmap-based sector allocator for region files.
/// Manages allocation of contiguous sector runs using a first-fit strategy.
/// The bitmap is rebuilt from the COT on file open (the COT is the source of truth).
pub const SectorAllocator = struct {
    bitmap: [BITMAP_BYTES]u8,
    total_sectors: u32,

    pub fn init() SectorAllocator {
        var self = SectorAllocator{
            .bitmap = [_]u8{0} ** BITMAP_BYTES,
            .total_sectors = HEADER_SECTORS,
        };
        // Mark header sectors as used
        self.markRange(0, HEADER_SECTORS);
        return self;
    }

    /// Rebuild the bitmap from a Chunk Offset Table.
    /// This is the crash recovery path — the COT is the single source of truth.
    pub fn rebuildFromCot(cot: *const [CHUNKS_PER_REGION]ChunkOffsetEntry) SectorAllocator {
        var self = SectorAllocator{
            .bitmap = [_]u8{0} ** BITMAP_BYTES,
            .total_sectors = HEADER_SECTORS,
        };

        // Reserve header sectors
        self.markRange(0, HEADER_SECTORS);

        // Mark sectors referenced by each COT entry
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

    /// Allocate a contiguous run of `count` sectors.
    /// Returns the starting sector offset, or null if no space.
    pub fn allocate(self: *SectorAllocator, count: u8) ?u24 {
        if (count == 0) return null;

        const needed: u32 = count;
        var start: u32 = HEADER_SECTORS;

        while (start + needed <= MAX_SECTORS) {
            // Check if the run starting at `start` is entirely free
            if (self.isRangeFree(start, needed)) {
                self.markRange(start, needed);
                const end = start + needed;
                if (end > self.total_sectors) {
                    self.total_sectors = end;
                }
                return @intCast(start);
            }

            // Skip to the next potential starting position
            // Find the first used sector in the range and skip past it
            start = self.nextFreeAfter(start);
        }

        return null;
    }

    /// Free a previously allocated run of sectors.
    pub fn free(self: *SectorAllocator, offset: u24, count: u8) void {
        self.clearRange(@as(u32, offset), @as(u32, count));
    }

    /// Check if a range of sectors is entirely free.
    fn isRangeFree(self: *const SectorAllocator, start: u32, count: u32) bool {
        for (start..start + count) |sector| {
            if (self.isUsed(@intCast(sector))) return false;
        }
        return true;
    }

    /// Find the next free sector at or after `start`.
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

    /// Get the bitmap bytes (for writing to disk).
    pub fn getBitmap(self: *const SectorAllocator) *const [BITMAP_BYTES]u8 {
        return &self.bitmap;
    }

    /// Load bitmap from disk bytes (performance hint only, rebuilt from COT on open).
    pub fn loadBitmap(self: *SectorAllocator, data: *const [BITMAP_BYTES]u8) void {
        @memcpy(&self.bitmap, data);
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "init reserves header sectors" {
    const alloc = SectorAllocator.init();
    // Sectors 0 and 1 should be used
    try std.testing.expect(alloc.isUsed(0));
    try std.testing.expect(alloc.isUsed(1));
    // Sector 2 should be free
    try std.testing.expect(!alloc.isUsed(2));
}

test "allocate and free" {
    var alloc = SectorAllocator.init();

    // Allocate 3 sectors — should start at sector 2
    const offset1 = alloc.allocate(3) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u24, 2), offset1);

    // Next allocation should start at sector 5
    const offset2 = alloc.allocate(2) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u24, 5), offset2);

    // Free first allocation
    alloc.free(offset1, 3);

    // Should be able to reuse sectors 2-4
    const offset3 = alloc.allocate(3) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u24, 2), offset3);
}

test "rebuildFromCot" {
    var cot: [CHUNKS_PER_REGION]ChunkOffsetEntry = undefined;
    @memset(&cot, ChunkOffsetEntry.empty);

    // Set a few entries
    cot[0] = @bitCast(@as(u64, 0) | (@as(u64, 2) << 0) | // sector_offset = 2
        (@as(u64, 3) << 24) | // sector_count = 3
        (@as(u64, 1000) << 32) | // compressed_size
        (@as(u64, 1) << 56)); // compression = deflate
    cot[1] = @bitCast(@as(u64, 0) | (@as(u64, 5) << 0) | // sector_offset = 5
        (@as(u64, 1) << 24) | // sector_count = 1
        (@as(u64, 500) << 32) | // compressed_size
        (@as(u64, 1) << 56));

    const alloc = SectorAllocator.rebuildFromCot(&cot);

    // Header sectors used
    try std.testing.expect(alloc.isUsed(0));
    try std.testing.expect(alloc.isUsed(1));

    // Sectors 2-4 used by entry 0
    try std.testing.expect(alloc.isUsed(2));
    try std.testing.expect(alloc.isUsed(3));
    try std.testing.expect(alloc.isUsed(4));

    // Sector 5 used by entry 1
    try std.testing.expect(alloc.isUsed(5));

    // Sector 6 should be free
    try std.testing.expect(!alloc.isUsed(6));

    try std.testing.expectEqual(@as(u32, 6), alloc.total_sectors);
}
