const std = @import("std");
const WorldState = @import("../WorldState.zig");
const StateId = WorldState.StateId;
const storage_types = @import("types.zig");

const BLOCKS_PER_CHUNK = storage_types.BLOCKS_PER_CHUNK;


pub const Encoding = enum(u8) {
    raw16 = 0,
    palette16 = 1,
    single_block = 3,
};


const CODEC_HEADER_SIZE = 4;
const CODEC_FORMAT_VERSION: u8 = 2;


pub const EncodeResult = struct {
    data: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *EncodeResult) void {
        self.allocator.free(self.data);
    }
};

pub fn encode(allocator: std.mem.Allocator, blocks: *const [BLOCKS_PER_CHUNK]StateId) !EncodeResult {
    // Count distinct u16 values using a hashmap
    var seen = std.AutoHashMap(u16, void).init(allocator);
    defer seen.deinit();

    for (blocks) |b| {
        try seen.put(b, {});
    }
    const distinct = seen.count();

    if (distinct == 1) {
        return encodeSingleBlock(allocator, blocks[0]);
    } else if (distinct <= 256) {
        return encodePalette16(allocator, blocks, distinct);
    } else {
        return encodeRaw16(allocator, blocks);
    }
}

fn encodeSingleBlock(allocator: std.mem.Allocator, state: StateId) !EncodeResult {
    const data = try allocator.alloc(u8, CODEC_HEADER_SIZE + 2);
    data[0] = CODEC_FORMAT_VERSION;
    data[1] = @intFromEnum(Encoding.single_block);
    data[2] = 0;
    data[3] = 0;
    // Store u16 little-endian
    std.mem.writeInt(u16, data[4..6], state, .little);
    return .{ .data = data, .allocator = allocator };
}

fn encodePalette16(
    allocator: std.mem.Allocator,
    blocks: *const [BLOCKS_PER_CHUNK]StateId,
    distinct: usize,
) !EncodeResult {
    const palette_size: u8 = @intCast(distinct);

    // Build palette and reverse map
    var palette: [256]StateId = undefined;
    var reverse_map = std.AutoHashMap(u16, u8).init(allocator);
    defer reverse_map.deinit();

    var idx: u8 = 0;
    for (blocks) |b| {
        if (!reverse_map.contains(b)) {
            palette[idx] = b;
            try reverse_map.put(b, idx);
            idx += 1;
        }
    }

    // Layout: header(4) + palette_size(1) + palette(palette_size * 2) + indices(BLOCKS_PER_CHUNK)
    const total = CODEC_HEADER_SIZE + 1 + @as(usize, palette_size) * 2 + BLOCKS_PER_CHUNK;
    const data = try allocator.alloc(u8, total);

    data[0] = CODEC_FORMAT_VERSION;
    data[1] = @intFromEnum(Encoding.palette16);
    data[2] = 0;
    data[3] = 0;

    data[4] = palette_size;
    for (0..palette_size) |i| {
        std.mem.writeInt(u16, data[5 + i * 2 ..][0..2], palette[i], .little);
    }

    const indices_start = 5 + @as(usize, palette_size) * 2;
    for (blocks, 0..) |b, i| {
        data[indices_start + i] = reverse_map.get(b).?;
    }

    return .{ .data = data, .allocator = allocator };
}

fn encodeRaw16(
    allocator: std.mem.Allocator,
    blocks: *const [BLOCKS_PER_CHUNK]StateId,
) !EncodeResult {
    const total = CODEC_HEADER_SIZE + BLOCKS_PER_CHUNK * 2;
    const data = try allocator.alloc(u8, total);

    data[0] = CODEC_FORMAT_VERSION;
    data[1] = @intFromEnum(Encoding.raw16);
    data[2] = 0;
    data[3] = 0;

    const block_bytes: [*]const u8 = @ptrCast(blocks);
    @memcpy(data[CODEC_HEADER_SIZE..][0 .. BLOCKS_PER_CHUNK * 2], block_bytes[0 .. BLOCKS_PER_CHUNK * 2]);

    return .{ .data = data, .allocator = allocator };
}


pub const DecodeError = error{
    InvalidFormat,
    UnknownEncoding,
    InvalidPalette,
    DataTruncated,
};

pub fn decode(data: []const u8, out_blocks: *[BLOCKS_PER_CHUNK]StateId) DecodeError!void {
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
        .palette16 => try decodePalette16(data, out_blocks),
        .raw16 => try decodeRaw16(data, out_blocks),
    }
}

fn decodeSingleBlock(data: []const u8, out_blocks: *[BLOCKS_PER_CHUNK]StateId) void {
    if (data.len < CODEC_HEADER_SIZE + 2) {
        @memset(out_blocks, 0); // air
        return;
    }
    const state = std.mem.readInt(u16, data[4..6], .little);
    @memset(out_blocks, state);
}

fn decodePalette16(data: []const u8, out_blocks: *[BLOCKS_PER_CHUNK]StateId) DecodeError!void {
    if (data.len < CODEC_HEADER_SIZE + 1) return error.DataTruncated;

    const palette_size: usize = data[4];
    if (palette_size == 0) return error.InvalidPalette;

    const palette_end = 5 + palette_size * 2;
    if (data.len < palette_end) return error.DataTruncated;

    const indices_end = palette_end + BLOCKS_PER_CHUNK;
    if (data.len < indices_end) return error.DataTruncated;

    var palette: [256]StateId = undefined;
    for (0..palette_size) |i| {
        palette[i] = std.mem.readInt(u16, data[5 + i * 2 ..][0..2], .little);
    }

    for (0..BLOCKS_PER_CHUNK) |i| {
        const idx = data[palette_end + i];
        if (idx >= palette_size) return error.InvalidPalette;
        out_blocks[i] = palette[idx];
    }
}

fn decodeRaw16(data: []const u8, out_blocks: *[BLOCKS_PER_CHUNK]StateId) DecodeError!void {
    if (data.len < CODEC_HEADER_SIZE + BLOCKS_PER_CHUNK * 2) return error.DataTruncated;
    const block_bytes: [*]u8 = @ptrCast(out_blocks);
    @memcpy(block_bytes[0 .. BLOCKS_PER_CHUNK * 2], data[CODEC_HEADER_SIZE..][0 .. BLOCKS_PER_CHUNK * 2]);
}


test "single_block encode/decode round-trip" {
    const allocator = std.testing.allocator;
    const BlockState = WorldState.BlockState;

    var blocks: [BLOCKS_PER_CHUNK]StateId = undefined;
    const stone = BlockState.defaultState(.stone);
    @memset(&blocks, stone);

    var result = try encode(allocator, &blocks);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 6), result.data.len);
    try std.testing.expectEqual(@intFromEnum(Encoding.single_block), result.data[1]);

    var decoded: [BLOCKS_PER_CHUNK]StateId = undefined;
    try decode(result.data, &decoded);

    for (decoded) |b| {
        try std.testing.expectEqual(stone, b);
    }
}

test "palette16 encode/decode round-trip" {
    const allocator = std.testing.allocator;
    const BlockState = WorldState.BlockState;

    var blocks: [BLOCKS_PER_CHUNK]StateId = undefined;
    const stone = BlockState.defaultState(.stone);
    const dirt = BlockState.defaultState(.dirt);
    for (&blocks, 0..) |*b, i| {
        b.* = if (i % 2 == 0) stone else dirt;
    }

    var result = try encode(allocator, &blocks);
    defer result.deinit();

    try std.testing.expectEqual(@intFromEnum(Encoding.palette16), result.data[1]);

    var decoded: [BLOCKS_PER_CHUNK]StateId = undefined;
    try decode(result.data, &decoded);

    for (&decoded, 0..) |b, i| {
        const expected: StateId = if (i % 2 == 0) stone else dirt;
        try std.testing.expectEqual(expected, b);
    }
}

test "air chunk encodes as single_block" {
    const allocator = std.testing.allocator;
    const BlockState = WorldState.BlockState;

    var blocks: [BLOCKS_PER_CHUNK]StateId = undefined;
    const air = BlockState.defaultState(.air);
    @memset(&blocks, air);

    var result = try encode(allocator, &blocks);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 6), result.data.len);
    try std.testing.expectEqual(@intFromEnum(Encoding.single_block), result.data[1]);
    try std.testing.expectEqual(air, std.mem.readInt(u16, result.data[4..6], .little));
}
