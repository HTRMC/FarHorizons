const std = @import("std");
const WorldState = @import("../WorldState.zig");
const BlockType = WorldState.BlockType;
const storage_types = @import("types.zig");

const BLOCKS_PER_CHUNK = storage_types.BLOCKS_PER_CHUNK;


pub const Encoding = enum(u8) {
    raw = 0,
    palette8 = 1,
    palette16 = 2,
    single_block = 3,
};


const CODEC_HEADER_SIZE = 4;
const CODEC_FORMAT_VERSION: u8 = 1;


pub const EncodeResult = struct {
    data: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *EncodeResult) void {
        self.allocator.free(self.data);
    }
};

pub fn encode(allocator: std.mem.Allocator, blocks: *const [BLOCKS_PER_CHUNK]BlockType) !EncodeResult {
    var seen = [_]bool{false} ** 256;
    var distinct: u16 = 0;
    for (blocks) |b| {
        const id = @intFromEnum(b);
        if (!seen[id]) {
            seen[id] = true;
            distinct += 1;
        }
    }

    if (distinct == 1) {
        return encodeSingleBlock(allocator, blocks[0]);
    } else if (distinct <= 256) {
        return encodePalette8(allocator, blocks, &seen, distinct);
    } else {
        return encodeRaw(allocator, blocks);
    }
}

fn encodeSingleBlock(allocator: std.mem.Allocator, block: BlockType) !EncodeResult {
    const data = try allocator.alloc(u8, CODEC_HEADER_SIZE + 1);
    data[0] = CODEC_FORMAT_VERSION;
    data[1] = @intFromEnum(Encoding.single_block);
    data[2] = 0;
    data[3] = 0;
    data[4] = @intFromEnum(block);
    return .{ .data = data, .allocator = allocator };
}

fn encodePalette8(
    allocator: std.mem.Allocator,
    blocks: *const [BLOCKS_PER_CHUNK]BlockType,
    seen: *const [256]bool,
    distinct: u16,
) !EncodeResult {
    const palette_size: u8 = @intCast(distinct);

    var palette: [256]BlockType = undefined;
    var reverse_map: [256]u8 = undefined;
    var idx: u8 = 0;
    for (0..256) |i| {
        if (seen[i]) {
            palette[idx] = @enumFromInt(i);
            reverse_map[i] = idx;
            idx += 1;
        }
    }

    const total = CODEC_HEADER_SIZE + 1 + @as(usize, palette_size) + BLOCKS_PER_CHUNK;
    const data = try allocator.alloc(u8, total);

    data[0] = CODEC_FORMAT_VERSION;
    data[1] = @intFromEnum(Encoding.palette8);
    data[2] = 0;
    data[3] = 0;

    data[4] = palette_size;
    for (0..palette_size) |i| {
        data[5 + i] = @intFromEnum(palette[i]);
    }

    const indices_start = 5 + @as(usize, palette_size);
    for (blocks, 0..) |b, i| {
        data[indices_start + i] = reverse_map[@intFromEnum(b)];
    }

    return .{ .data = data, .allocator = allocator };
}

fn encodeRaw(
    allocator: std.mem.Allocator,
    blocks: *const [BLOCKS_PER_CHUNK]BlockType,
) !EncodeResult {
    const total = CODEC_HEADER_SIZE + BLOCKS_PER_CHUNK;
    const data = try allocator.alloc(u8, total);

    data[0] = CODEC_FORMAT_VERSION;
    data[1] = @intFromEnum(Encoding.raw);
    data[2] = 0;
    data[3] = 0;

    const block_bytes: [*]const u8 = @ptrCast(blocks);
    @memcpy(data[CODEC_HEADER_SIZE..][0..BLOCKS_PER_CHUNK], block_bytes[0..BLOCKS_PER_CHUNK]);

    return .{ .data = data, .allocator = allocator };
}


pub const DecodeError = error{
    InvalidFormat,
    UnknownEncoding,
    InvalidPalette,
    DataTruncated,
};

pub fn decode(data: []const u8, out_blocks: *[BLOCKS_PER_CHUNK]BlockType) DecodeError!void {
    if (data.len < CODEC_HEADER_SIZE) return error.DataTruncated;
    if (data[0] != CODEC_FORMAT_VERSION) return error.InvalidFormat;

    const raw_encoding = data[1];
    const valid = inline for (@typeInfo(Encoding).@"enum".fields) |f| {
        if (raw_encoding == f.value) break true;
    } else false;
    if (!valid) return error.UnknownEncoding;
    const encoding: Encoding = @enumFromInt(raw_encoding);

    switch (encoding) {
        .single_block => decodeSingleBlock(data, out_blocks),
        .palette8 => try decodePalette8(data, out_blocks),
        .raw => try decodeRaw(data, out_blocks),
        .palette16 => return error.UnknownEncoding,
    }
}

fn decodeSingleBlock(data: []const u8, out_blocks: *[BLOCKS_PER_CHUNK]BlockType) void {
    if (data.len < CODEC_HEADER_SIZE + 1) {
        @memset(out_blocks, .air);
        return;
    }
    const block: BlockType = @enumFromInt(data[4]);
    @memset(out_blocks, block);
}

fn decodePalette8(data: []const u8, out_blocks: *[BLOCKS_PER_CHUNK]BlockType) DecodeError!void {
    if (data.len < CODEC_HEADER_SIZE + 1) return error.DataTruncated;

    const palette_size: usize = data[4];
    if (palette_size == 0) return error.InvalidPalette;

    const palette_end = 5 + palette_size;
    if (data.len < palette_end) return error.DataTruncated;

    const indices_end = palette_end + BLOCKS_PER_CHUNK;
    if (data.len < indices_end) return error.DataTruncated;

    var palette: [256]BlockType = undefined;
    for (0..palette_size) |i| {
        palette[i] = @enumFromInt(data[5 + i]);
    }

    for (0..BLOCKS_PER_CHUNK) |i| {
        const idx = data[palette_end + i];
        if (idx >= palette_size) return error.InvalidPalette;
        out_blocks[i] = palette[idx];
    }
}

fn decodeRaw(data: []const u8, out_blocks: *[BLOCKS_PER_CHUNK]BlockType) DecodeError!void {
    if (data.len < CODEC_HEADER_SIZE + BLOCKS_PER_CHUNK) return error.DataTruncated;
    const block_bytes: [*]u8 = @ptrCast(out_blocks);
    @memcpy(block_bytes[0..BLOCKS_PER_CHUNK], data[CODEC_HEADER_SIZE..][0..BLOCKS_PER_CHUNK]);
}


test "single_block encode/decode round-trip" {
    const allocator = std.testing.allocator;

    var blocks: [BLOCKS_PER_CHUNK]BlockType = undefined;
    @memset(&blocks, .stone);

    var result = try encode(allocator, &blocks);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 5), result.data.len);
    try std.testing.expectEqual(@intFromEnum(Encoding.single_block), result.data[1]);

    var decoded: [BLOCKS_PER_CHUNK]BlockType = undefined;
    try decode(result.data, &decoded);

    for (decoded) |b| {
        try std.testing.expectEqual(BlockType.stone, b);
    }
}

test "palette8 encode/decode round-trip" {
    const allocator = std.testing.allocator;

    var blocks: [BLOCKS_PER_CHUNK]BlockType = undefined;
    for (&blocks, 0..) |*b, i| {
        b.* = if (i % 2 == 0) .stone else .dirt;
    }

    var result = try encode(allocator, &blocks);
    defer result.deinit();

    try std.testing.expectEqual(@intFromEnum(Encoding.palette8), result.data[1]);

    var decoded: [BLOCKS_PER_CHUNK]BlockType = undefined;
    try decode(result.data, &decoded);

    for (&decoded, 0..) |b, i| {
        const expected: BlockType = if (i % 2 == 0) .stone else .dirt;
        try std.testing.expectEqual(expected, b);
    }
}

test "air chunk encodes as single_block" {
    const allocator = std.testing.allocator;

    var blocks: [BLOCKS_PER_CHUNK]BlockType = undefined;
    @memset(&blocks, .air);

    var result = try encode(allocator, &blocks);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 5), result.data.len);
    try std.testing.expectEqual(@intFromEnum(Encoding.single_block), result.data[1]);
    try std.testing.expectEqual(@intFromEnum(BlockType.air), result.data[4]);
}
