const std = @import("std");
const WorldState = @import("../WorldState.zig");


pub const SECTOR_SIZE = 4096;
pub const REGION_DIM = 8;
pub const CHUNKS_PER_REGION = REGION_DIM * REGION_DIM * REGION_DIM;
pub const HEADER_SECTORS = 4;
pub const MAGIC = [4]u8{ 'F', 'H', 'R', 0x01 };
pub const FORMAT_VERSION: u16 = 2;
pub const BLOCKS_PER_CHUNK = WorldState.BLOCKS_PER_CHUNK;

pub const BITMAP_BYTES = 4060;
pub const MAX_SECTORS = BITMAP_BYTES * 8;


pub const CompressionAlgo = enum(u4) {
    none = 0,
    deflate = 1,
    zstd = 2,
};


pub const ChunkOffsetEntry = packed struct(u64) {
    sector_offset: u24,
    sector_count: u8,
    compressed_size: u24,
    compression: u4,
    flags: u4,

    pub const empty: ChunkOffsetEntry = @bitCast(@as(u64, 0));

    pub fn isPresent(self: ChunkOffsetEntry) bool {
        return self.sector_offset != 0;
    }

    pub fn compressionAlgo(self: ChunkOffsetEntry) CompressionAlgo {
        return @enumFromInt(self.compression);
    }

    pub fn hasLight(self: ChunkOffsetEntry) bool {
        return self.flags & 0x1 != 0;
    }

    pub fn hasEntities(self: ChunkOffsetEntry) bool {
        return self.flags & 0x2 != 0;
    }
};


pub const FileHeader = extern struct {
    magic: [4]u8 align(1) = MAGIC,
    format_version: u16 align(1) = FORMAT_VERSION,
    lod_level: u8 align(1) = 0,
    default_compression: u8 align(1) = @intFromEnum(CompressionAlgo.deflate),
    region_x: i32 align(1) = 0,
    region_y: i32 align(1) = 0,
    region_z: i32 align(1) = 0,
    creation_timestamp: u32 align(1) = 0,
    total_sectors: u32 align(1) = HEADER_SECTORS,
    generation: u32 align(1) = 0,

    comptime {
        std.debug.assert(@sizeOf(FileHeader) == 32);
    }

    pub fn validate(self: *const FileHeader) bool {
        return std.mem.eql(u8, &self.magic, &MAGIC) and
            self.format_version == FORMAT_VERSION;
    }
};


pub const OFFSET_META_A = 0x0000;
pub const OFFSET_COT_A = 0x1000;
pub const OFFSET_META_B = 0x2000;
pub const OFFSET_COT_B = 0x3000;

pub const META_OFFSET_HEADER = 0x00;
pub const META_OFFSET_BITMAP = 0x20;
pub const META_OFFSET_CRC = 0xFFC;


pub const RegionCoord = struct {
    rx: i32,
    ry: i32,
    rz: i32,
    lod: u8,

    pub fn fromChunk(cx: i32, cy: i32, cz: i32, lod: u8) RegionCoord {
        return .{
            .rx = @divFloor(cx, REGION_DIM),
            .ry = @divFloor(cy, REGION_DIM),
            .rz = @divFloor(cz, REGION_DIM),
            .lod = lod,
        };
    }

    pub fn eql(a: RegionCoord, b: RegionCoord) bool {
        return a.rx == b.rx and a.ry == b.ry and a.rz == b.rz and a.lod == b.lod;
    }

    pub fn hash(self: RegionCoord) u64 {
        var h: u64 = 0;
        h ^= @as(u64, @bitCast(@as(i64, self.rx))) *% 0x517cc1b727220a95;
        h ^= @as(u64, @bitCast(@as(i64, self.ry))) *% 0x6c62272e07bb0142;
        h ^= @as(u64, @bitCast(@as(i64, self.rz))) *% 0x305f92d82afb0d53;
        h ^= @as(u64, self.lod) *% 0x9e3779b97f4a7c15;
        return h;
    }
};


pub const ChunkKey = packed struct(u64) {
    cx: i16,
    cy: i16,
    cz: i16,
    lod: u8,
    _reserved: u8 = 0,

    pub fn init(cx: i32, cy: i32, cz: i32, lod: u8) ChunkKey {
        return .{
            .cx = @intCast(cx),
            .cy = @intCast(cy),
            .cz = @intCast(cz),
            .lod = lod,
        };
    }

    pub fn eql(a: ChunkKey, b: ChunkKey) bool {
        return @as(u64, @bitCast(a)) == @as(u64, @bitCast(b));
    }

    pub fn toU64(self: ChunkKey) u64 {
        return @bitCast(self);
    }

    pub fn localIndex(self: ChunkKey) u9 {
        const lx: u3 = @intCast(@as(u16, @bitCast(self.cx)) & (REGION_DIM - 1));
        const ly: u3 = @intCast(@as(u16, @bitCast(self.cy)) & (REGION_DIM - 1));
        const lz: u3 = @intCast(@as(u16, @bitCast(self.cz)) & (REGION_DIM - 1));
        return @as(u9, ly) * (REGION_DIM * REGION_DIM) + @as(u9, lz) * REGION_DIM + @as(u9, lx);
    }

    pub fn regionCoord(self: ChunkKey) RegionCoord {
        return RegionCoord.fromChunk(self.cx, self.cy, self.cz, self.lod);
    }
};


pub const Priority = enum(u3) {
    critical = 0,
    high = 1,
    normal = 2,
    low = 3,
    save = 4,
};


pub const AsyncHandle = struct {
    id: u32,

    pub const invalid: AsyncHandle = .{ .id = std.math.maxInt(u32) };

    pub fn isValid(self: AsyncHandle) bool {
        return self.id != std.math.maxInt(u32);
    }
};


pub fn sectorsNeeded(byte_count: usize) u8 {
    if (byte_count == 0) return 0;
    const sectors = (byte_count + SECTOR_SIZE - 1) / SECTOR_SIZE;
    return @intCast(@min(sectors, 255));
}

pub fn crc32(data: []const u8) u32 {
    return std.hash.Crc32.hash(data);
}


test "ChunkOffsetEntry is 8 bytes" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(ChunkOffsetEntry));
}

test "ChunkOffsetEntry empty" {
    const e = ChunkOffsetEntry.empty;
    try std.testing.expect(!e.isPresent());
    try std.testing.expectEqual(@as(u4, 0), e.compression);
}

test "ChunkKey round-trip" {
    const key = ChunkKey.init(10, -3, 7, 0);
    try std.testing.expectEqual(@as(i16, 10), key.cx);
    try std.testing.expectEqual(@as(i16, -3), key.cy);
    try std.testing.expectEqual(@as(i16, 7), key.cz);
    try std.testing.expectEqual(@as(u8, 0), key.lod);
}

test "ChunkKey localIndex" {
    const k0 = ChunkKey.init(0, 0, 0, 0);
    try std.testing.expectEqual(@as(u9, 0), k0.localIndex());

    const k1 = ChunkKey.init(1, 0, 0, 0);
    try std.testing.expectEqual(@as(u9, 1), k1.localIndex());

    const k8 = ChunkKey.init(0, 0, 1, 0);
    try std.testing.expectEqual(@as(u9, REGION_DIM), k8.localIndex());
}

test "RegionCoord fromChunk" {
    const rc = RegionCoord.fromChunk(9, 0, -1, 0);
    try std.testing.expectEqual(@as(i32, 1), rc.rx);
    try std.testing.expectEqual(@as(i32, 0), rc.ry);
    try std.testing.expectEqual(@as(i32, -1), rc.rz);
}

test "sectorsNeeded" {
    try std.testing.expectEqual(@as(u8, 0), sectorsNeeded(0));
    try std.testing.expectEqual(@as(u8, 1), sectorsNeeded(1));
    try std.testing.expectEqual(@as(u8, 1), sectorsNeeded(4096));
    try std.testing.expectEqual(@as(u8, 2), sectorsNeeded(4097));
}
