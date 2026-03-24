const std = @import("std");
const WorldState = @import("../WorldState.zig");
const BlockState = WorldState.BlockState;
const StateId = WorldState.StateId;
const storage_types = @import("types.zig");

const BLOCKS_PER_CHUNK = storage_types.BLOCKS_PER_CHUNK;


pub const Encoding = enum(u8) {
    raw16 = 0,
    palette16 = 1,
    single_block = 3,
};

const V1Encoding = enum(u8) {
    raw = 0,
    palette8 = 1,
    single_block = 3,
};


const CODEC_HEADER_SIZE = 4;
const CODEC_FORMAT_VERSION: u8 = 2;

// Registry version tracks block enum/state layout changes within codec v2.
// Bump this when adding, removing, or reordering blocks so old chunks can be migrated.
// data[2] in the codec header stores this value.
//   0 = initial v2 registry (current)
// When bumping: add a migration function in the v2 migration section below.
pub const REGISTRY_VERSION: u8 = 0;

// V1 stored BlockType as u8. This table maps each old u8 value to the current StateId.
// Old registry (34 blocks):
//   0:air 1:glass 2:grass_block 3:dirt 4:stone 5:glowstone 6:sand 7:snow
//   8:water 9:gravel 10:cobblestone 11:oak_log 12:oak_planks 13:bricks
//   14:bedrock 15:gold_ore 16:iron_ore 17:coal_ore 18:diamond_ore 19:sponge
//   20:pumice 21:wool 22:gold_block 23:iron_block 24:diamond_block 25:bookshelf
//   26:obsidian 27:oak_leaves 28:oak_slab_bottom 29:oak_slab_top
//   30:oak_stairs_south 31:oak_stairs_north 32:oak_stairs_east 33:oak_stairs_west
const V1_BLOCK_COUNT = 34;
const v1_to_v2: [V1_BLOCK_COUNT]StateId = blk: {
    var table: [V1_BLOCK_COUNT]StateId = undefined;
    table[0] = BlockState.defaultState(.air);
    table[1] = BlockState.defaultState(.glass);
    table[2] = BlockState.defaultState(.grass_block);
    table[3] = BlockState.defaultState(.dirt);
    table[4] = BlockState.defaultState(.stone);
    table[5] = BlockState.defaultState(.glowstone);
    table[6] = BlockState.defaultState(.sand);
    table[7] = BlockState.defaultState(.snow);
    table[8] = BlockState.defaultState(.water);
    table[9] = BlockState.defaultState(.gravel);
    table[10] = BlockState.defaultState(.cobblestone);
    table[11] = BlockState.defaultState(.oak_log);
    table[12] = BlockState.defaultState(.oak_planks);
    table[13] = BlockState.defaultState(.bricks);
    table[14] = BlockState.defaultState(.bedrock);
    table[15] = BlockState.defaultState(.gold_ore);
    table[16] = BlockState.defaultState(.iron_ore);
    table[17] = BlockState.defaultState(.coal_ore);
    table[18] = BlockState.defaultState(.diamond_ore);
    table[19] = BlockState.defaultState(.sponge);
    table[20] = BlockState.defaultState(.pumice);
    table[21] = BlockState.defaultState(.wool);
    table[22] = BlockState.defaultState(.gold_block);
    table[23] = BlockState.defaultState(.iron_block);
    table[24] = BlockState.defaultState(.diamond_block);
    table[25] = BlockState.defaultState(.bookshelf);
    table[26] = BlockState.defaultState(.obsidian);
    table[27] = BlockState.defaultState(.oak_leaves);
    table[28] = BlockState.fromBlockProps(.oak_slab, @intFromEnum(BlockState.SlabType.bottom));
    table[29] = BlockState.fromBlockProps(.oak_slab, @intFromEnum(BlockState.SlabType.top));
    table[30] = BlockState.makeStairState(.south, .bottom, .straight);
    table[31] = BlockState.makeStairState(.north, .bottom, .straight);
    table[32] = BlockState.makeStairState(.east, .bottom, .straight);
    table[33] = BlockState.makeStairState(.west, .bottom, .straight);
    break :blk table;
};

fn migrateV1(old: u8) StateId {
    if (old < V1_BLOCK_COUNT) return v1_to_v2[old];
    return 0; // unknown → air
}


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
    data[2] = REGISTRY_VERSION;
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
    data[2] = REGISTRY_VERSION;
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
    data[2] = REGISTRY_VERSION;
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

const PaletteBlocks = @import("../WorldState.zig").PaletteBlocks;

/// Decode directly into PaletteStorage — avoids flat array intermediate.
pub fn decodeToPalette(data: []const u8, blocks: *PaletteBlocks) DecodeError!void {
    if (data.len < CODEC_HEADER_SIZE) return error.DataTruncated;

    if (data[0] == 1) {
        // V1 format — decode to flat then load (rare, legacy only)
        var temp: [BLOCKS_PER_CHUNK]StateId = undefined;
        try decodeV1(data, &temp);
        blocks.loadFromSlice(&temp);
        return;
    }

    if (data[0] != CODEC_FORMAT_VERSION) return error.InvalidFormat;
    const raw_encoding = data[1];
    const valid = inline for (@typeInfo(Encoding).@"enum".fields) |f| {
        if (raw_encoding == f.value) break true;
    } else false;
    if (!valid) return error.UnknownEncoding;
    const encoding: Encoding = @enumFromInt(raw_encoding);

    switch (encoding) {
        .single_block => {
            if (data.len < CODEC_HEADER_SIZE + 2) {
                blocks.fillUniform(0);
                return;
            }
            blocks.fillUniform(std.mem.readInt(u16, data[4..6], .little));
        },
        .palette16 => try decodePalette16Direct(data, blocks),
        .raw16 => {
            // >256 unique values — decode to flat then load
            var temp: [BLOCKS_PER_CHUNK]StateId = undefined;
            try decodeRaw16(data, &temp);
            blocks.loadFromSlice(&temp);
        },
    }
}

fn decodePalette16Direct(data: []const u8, blocks: *PaletteBlocks) DecodeError!void {
    if (data.len < CODEC_HEADER_SIZE + 1) return error.DataTruncated;

    const palette_size: u32 = data[4];
    if (palette_size == 0) return error.InvalidPalette;

    const palette_end = 5 + palette_size * 2;
    if (data.len < palette_end) return error.DataTruncated;

    const indices_end = palette_end + BLOCKS_PER_CHUNK;
    if (data.len < indices_end) return error.DataTruncated;

    // Load directly: pre-allocate exact palette, set raw indices (O(1) per block)
    blocks.initCapacity(palette_size);
    for (0..palette_size) |i| {
        blocks.setPaletteEntry(@intCast(i), std.mem.readInt(u16, data[5 + i * 2 ..][0..2], .little));
    }

    for (0..BLOCKS_PER_CHUNK) |i| {
        const idx = data[palette_end + i];
        if (idx >= palette_size) return error.InvalidPalette;
        blocks.setRawIndex(@intCast(i), idx);
    }
}

pub fn decode(data: []const u8, out_blocks: *[BLOCKS_PER_CHUNK]StateId) DecodeError!void {
    if (data.len < CODEC_HEADER_SIZE) return error.DataTruncated;

    if (data[0] == 1) {
        return decodeV1(data, out_blocks);
    }

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


// ---- V1 migration decoders (u8 BlockType → u16 StateId) ----

fn decodeV1(data: []const u8, out_blocks: *[BLOCKS_PER_CHUNK]StateId) DecodeError!void {
    const raw_encoding = data[1];
    const valid = inline for (@typeInfo(V1Encoding).@"enum".fields) |f| {
        if (raw_encoding == f.value) break true;
    } else false;
    if (!valid) return error.UnknownEncoding;
    const encoding: V1Encoding = @enumFromInt(raw_encoding);

    switch (encoding) {
        .single_block => decodeV1SingleBlock(data, out_blocks),
        .palette8 => try decodeV1Palette8(data, out_blocks),
        .raw => try decodeV1Raw(data, out_blocks),
    }
}

fn decodeV1SingleBlock(data: []const u8, out_blocks: *[BLOCKS_PER_CHUNK]StateId) void {
    if (data.len < CODEC_HEADER_SIZE + 1) {
        @memset(out_blocks, 0);
        return;
    }
    @memset(out_blocks, migrateV1(data[4]));
}

fn decodeV1Palette8(data: []const u8, out_blocks: *[BLOCKS_PER_CHUNK]StateId) DecodeError!void {
    if (data.len < CODEC_HEADER_SIZE + 1) return error.DataTruncated;

    const palette_size: usize = data[4];
    if (palette_size == 0) return error.InvalidPalette;

    const palette_end = 5 + palette_size;
    if (data.len < palette_end) return error.DataTruncated;

    const indices_end = palette_end + BLOCKS_PER_CHUNK;
    if (data.len < indices_end) return error.DataTruncated;

    var palette: [256]StateId = undefined;
    for (0..palette_size) |i| {
        palette[i] = migrateV1(data[5 + i]);
    }

    for (0..BLOCKS_PER_CHUNK) |i| {
        const idx = data[palette_end + i];
        if (idx >= palette_size) return error.InvalidPalette;
        out_blocks[i] = palette[idx];
    }
}

fn decodeV1Raw(data: []const u8, out_blocks: *[BLOCKS_PER_CHUNK]StateId) DecodeError!void {
    if (data.len < CODEC_HEADER_SIZE + BLOCKS_PER_CHUNK) return error.DataTruncated;
    for (0..BLOCKS_PER_CHUNK) |i| {
        out_blocks[i] = migrateV1(data[CODEC_HEADER_SIZE + i]);
    }
}


test "single_block encode/decode round-trip" {
    const allocator = std.testing.allocator;

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

    var blocks: [BLOCKS_PER_CHUNK]StateId = undefined;
    const air = BlockState.defaultState(.air);
    @memset(&blocks, air);

    var result = try encode(allocator, &blocks);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 6), result.data.len);
    try std.testing.expectEqual(@intFromEnum(Encoding.single_block), result.data[1]);
    try std.testing.expectEqual(air, std.mem.readInt(u16, result.data[4..6], .little));
}

test "v1 single_block migration" {
    // V1 format: [version=1][encoding=3][0][0][block_u8]
    var data = [_]u8{ 1, 3, 0, 0, 4 }; // stone was v1 id 4
    var decoded: [BLOCKS_PER_CHUNK]StateId = undefined;
    try decode(&data, &decoded);
    try std.testing.expectEqual(BlockState.defaultState(.stone), decoded[0]);
    try std.testing.expectEqual(BlockState.defaultState(.stone), decoded[BLOCKS_PER_CHUNK - 1]);
}

test "v1 slab and stair migration" {
    // V1 palette8: [1][1][0][0][palette_size][palette...][indices...]
    const palette_size: u8 = 4;
    const header = [_]u8{ 1, 1, 0, 0, palette_size };
    // palette: oak_slab_bottom(28), oak_slab_top(29), oak_stairs_south(30), oak_stairs_east(32)
    const palette = [_]u8{ 28, 29, 30, 32 };
    var data: [header.len + palette.len + BLOCKS_PER_CHUNK]u8 = undefined;
    @memcpy(data[0..header.len], &header);
    @memcpy(data[header.len..][0..palette.len], &palette);
    // Fill indices: alternating 0,1,2,3
    for (0..BLOCKS_PER_CHUNK) |i| {
        data[header.len + palette.len + i] = @intCast(i % 4);
    }

    var decoded: [BLOCKS_PER_CHUNK]StateId = undefined;
    try decode(&data, &decoded);

    const slab_bottom = BlockState.fromBlockProps(.oak_slab, @intFromEnum(BlockState.SlabType.bottom));
    const slab_top = BlockState.fromBlockProps(.oak_slab, @intFromEnum(BlockState.SlabType.top));
    const stairs_south = BlockState.makeStairState(.south, .bottom, .straight);
    const stairs_east = BlockState.makeStairState(.east, .bottom, .straight);

    try std.testing.expectEqual(slab_bottom, decoded[0]);
    try std.testing.expectEqual(slab_top, decoded[1]);
    try std.testing.expectEqual(stairs_south, decoded[2]);
    try std.testing.expectEqual(stairs_east, decoded[3]);
}

test "v1 raw migration" {
    // V1 raw: [1][0][0][0][block_bytes...]
    var data: [CODEC_HEADER_SIZE + BLOCKS_PER_CHUNK]u8 = undefined;
    data[0] = 1;
    data[1] = 0;
    data[2] = 0;
    data[3] = 0;
    // Fill with sand(6) and cobblestone(10)
    for (0..BLOCKS_PER_CHUNK) |i| {
        data[CODEC_HEADER_SIZE + i] = if (i % 2 == 0) 6 else 10;
    }

    var decoded: [BLOCKS_PER_CHUNK]StateId = undefined;
    try decode(&data, &decoded);

    const sand = BlockState.defaultState(.sand);
    const cobblestone = BlockState.defaultState(.cobblestone);
    for (0..BLOCKS_PER_CHUNK) |i| {
        const expected: StateId = if (i % 2 == 0) sand else cobblestone;
        try std.testing.expectEqual(expected, decoded[i]);
    }
}

test "v1 migration table correctness" {
    // Verify all 34 entries map to the correct block
    try std.testing.expectEqual(BlockState.Block.air, BlockState.getBlock(v1_to_v2[0]));
    try std.testing.expectEqual(BlockState.Block.glass, BlockState.getBlock(v1_to_v2[1]));
    try std.testing.expectEqual(BlockState.Block.grass_block, BlockState.getBlock(v1_to_v2[2]));
    try std.testing.expectEqual(BlockState.Block.stone, BlockState.getBlock(v1_to_v2[4]));
    try std.testing.expectEqual(BlockState.Block.glowstone, BlockState.getBlock(v1_to_v2[5]));
    try std.testing.expectEqual(BlockState.Block.sand, BlockState.getBlock(v1_to_v2[6]));
    try std.testing.expectEqual(BlockState.Block.oak_leaves, BlockState.getBlock(v1_to_v2[27]));
    try std.testing.expectEqual(BlockState.Block.oak_slab, BlockState.getBlock(v1_to_v2[28]));
    try std.testing.expectEqual(BlockState.Block.oak_slab, BlockState.getBlock(v1_to_v2[29]));
    try std.testing.expectEqual(BlockState.Block.oak_stairs, BlockState.getBlock(v1_to_v2[30]));
    try std.testing.expectEqual(BlockState.Block.oak_stairs, BlockState.getBlock(v1_to_v2[33]));

    // Unknown v1 id maps to air
    try std.testing.expectEqual(BlockState.defaultState(.air), migrateV1(255));
}
