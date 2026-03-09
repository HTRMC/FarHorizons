const std = @import("std");
const compression = @import("world/storage/compression.zig");

/// Binary Tag format — a compact, self-describing binary data format.
///
/// Improvements over Minecraft's NBT:
///   - Little-endian (native on x86, no byte swaps)
///   - u8 name lengths (max 255, sufficient for field names)
///   - Native bool type
///   - ZSTD compression (faster + better ratio than GZIP)
///   - No root compound name
///   - File header stores uncompressed size for single-alloc decompress

pub const TagType = enum(u8) {
    end = 0x00,
    i8 = 0x01,
    i16 = 0x02,
    i32 = 0x03,
    i64 = 0x04,
    f32 = 0x05,
    f64 = 0x06,
    string = 0x07,
    compound = 0x08,
    list = 0x09,
    byte_array = 0x0A,
    bool = 0x0B,
};

fn enumCast(comptime E: type, value: @typeInfo(E).@"enum".tag_type) ?E {
    inline for (@typeInfo(E).@"enum".fields) |f| {
        if (value == f.value) return @enumFromInt(f.value);
    }
    return null;
}

// File header: magic (4) + version (1) + uncompressed size (4) = 9 bytes
const MAGIC = [4]u8{ 'F', 'H', 'B', 'T' }; // FarHorizons Binary Tag
const VERSION: u8 = 1;
const HEADER_SIZE: usize = 9;

// ============================================================
// Writer
// ============================================================

pub const Writer = struct {
    buf: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Writer {
        return .{ .buf = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *Writer) void {
        self.buf.deinit(self.allocator);
    }

    pub fn putBool(self: *Writer, name: []const u8, val: bool) void {
        self.writeTag(.bool, name);
        self.buf.append(self.allocator, @intFromBool(val)) catch {};
    }

    pub fn putI8(self: *Writer, name: []const u8, val: i8) void {
        self.writeTag(.i8, name);
        self.buf.append(self.allocator, @bitCast(val)) catch {};
    }

    pub fn putI16(self: *Writer, name: []const u8, val: i16) void {
        self.writeTag(.i16, name);
        self.buf.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToLittle(@TypeOf(val), val))) catch {};
    }

    pub fn putI32(self: *Writer, name: []const u8, val: i32) void {
        self.writeTag(.i32, name);
        self.buf.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToLittle(@TypeOf(val), val))) catch {};
    }

    pub fn putI64(self: *Writer, name: []const u8, val: i64) void {
        self.writeTag(.i64, name);
        self.buf.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToLittle(@TypeOf(val), val))) catch {};
    }

    pub fn putF32(self: *Writer, name: []const u8, val: f32) void {
        self.writeTag(.f32, name);
        const bits: u32 = @bitCast(val);
        self.buf.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToLittle(@TypeOf(bits), bits))) catch {};
    }

    pub fn putF64(self: *Writer, name: []const u8, val: f64) void {
        self.writeTag(.f64, name);
        const bits: u64 = @bitCast(val);
        self.buf.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToLittle(@TypeOf(bits), bits))) catch {};
    }

    pub fn putString(self: *Writer, name: []const u8, val: []const u8) void {
        self.writeTag(.string, name);
        const len: u16 = @intCast(@min(val.len, std.math.maxInt(u16)));
        self.buf.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToLittle(@TypeOf(len), len))) catch {};
        self.buf.appendSlice(self.allocator, val[0..len]) catch {};
    }

    pub fn putBytes(self: *Writer, name: []const u8, val: []const u8) void {
        self.writeTag(.byte_array, name);
        const len: u32 = @intCast(@min(val.len, std.math.maxInt(u32)));
        self.buf.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToLittle(@TypeOf(len), len))) catch {};
        self.buf.appendSlice(self.allocator, val[0..len]) catch {};
    }

    pub fn beginCompound(self: *Writer, name: []const u8) void {
        self.writeTag(.compound, name);
    }

    pub fn endCompound(self: *Writer) void {
        self.buf.append(self.allocator, @intFromEnum(TagType.end)) catch {};
    }

    pub fn beginList(self: *Writer, name: []const u8, element_type: TagType, count: u16) void {
        self.writeTag(.list, name);
        self.buf.append(self.allocator, @intFromEnum(element_type)) catch {};
        self.buf.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToLittle(@TypeOf(count), count))) catch {};
    }

    /// Write a list element value (no tag type or name — those are implicit in lists).
    pub fn listPutF32(self: *Writer, val: f32) void {
        const bits: u32 = @bitCast(val);
        self.buf.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToLittle(@TypeOf(bits), bits))) catch {};
    }

    pub fn listPutI32(self: *Writer, val: i32) void {
        self.buf.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToLittle(@TypeOf(val), val))) catch {};
    }

    /// Returns the raw (uncompressed) tag data. Caller owns the slice.
    pub fn toOwnedSlice(self: *Writer) ?[]u8 {
        // Append root end tag
        self.buf.append(self.allocator, @intFromEnum(TagType.end)) catch {};
        return self.buf.toOwnedSlice(self.allocator) catch null;
    }

    fn writeTag(self: *Writer, tag_type: TagType, name: []const u8) void {
        const name_len: u8 = @intCast(@min(name.len, 255));
        self.buf.append(self.allocator, @intFromEnum(tag_type)) catch {};
        self.buf.append(self.allocator, name_len) catch {};
        self.buf.appendSlice(self.allocator, name[0..name_len]) catch {};
    }
};

// ============================================================
// Reader
// ============================================================

pub const Reader = struct {
    data: []const u8,

    pub fn init(data: []const u8) Reader {
        return .{ .data = data };
    }

    pub fn getBool(self: Reader, name: []const u8) ?bool {
        const payload = self.findTag(.bool, name, self.data) orelse return null;
        if (payload.len < 1) return null;
        return payload[0] != 0;
    }

    pub fn getI8(self: Reader, name: []const u8) ?i8 {
        const payload = self.findTag(.i8, name, self.data) orelse return null;
        if (payload.len < 1) return null;
        return @bitCast(payload[0]);
    }

    pub fn getI16(self: Reader, name: []const u8) ?i16 {
        const payload = self.findTag(.i16, name, self.data) orelse return null;
        if (payload.len < 2) return null;
        return std.mem.littleToNative(i16, std.mem.bytesToValue(i16, payload[0..2]));
    }

    pub fn getI32(self: Reader, name: []const u8) ?i32 {
        const payload = self.findTag(.i32, name, self.data) orelse return null;
        if (payload.len < 4) return null;
        return std.mem.littleToNative(i32, std.mem.bytesToValue(i32, payload[0..4]));
    }

    pub fn getI64(self: Reader, name: []const u8) ?i64 {
        const payload = self.findTag(.i64, name, self.data) orelse return null;
        if (payload.len < 8) return null;
        return std.mem.littleToNative(i64, std.mem.bytesToValue(i64, payload[0..8]));
    }

    pub fn getF32(self: Reader, name: []const u8) ?f32 {
        const payload = self.findTag(.f32, name, self.data) orelse return null;
        if (payload.len < 4) return null;
        const bits = std.mem.littleToNative(u32, std.mem.bytesToValue(u32, payload[0..4]));
        return @bitCast(bits);
    }

    pub fn getF64(self: Reader, name: []const u8) ?f64 {
        const payload = self.findTag(.f64, name, self.data) orelse return null;
        if (payload.len < 8) return null;
        const bits = std.mem.littleToNative(u64, std.mem.bytesToValue(u64, payload[0..8]));
        return @bitCast(bits);
    }

    pub fn getString(self: Reader, name: []const u8) ?[]const u8 {
        const payload = self.findTag(.string, name, self.data) orelse return null;
        if (payload.len < 2) return null;
        const len = std.mem.littleToNative(u16, std.mem.bytesToValue(u16, payload[0..2]));
        if (payload.len < 2 + len) return null;
        return payload[2..][0..len];
    }

    pub fn getBytes(self: Reader, name: []const u8) ?[]const u8 {
        const payload = self.findTag(.byte_array, name, self.data) orelse return null;
        if (payload.len < 4) return null;
        const len = std.mem.littleToNative(u32, std.mem.bytesToValue(u32, payload[0..4]));
        if (payload.len < 4 + len) return null;
        return payload[4..][0..len];
    }

    pub fn getCompound(self: Reader, name: []const u8) ?Reader {
        const payload = self.findTag(.compound, name, self.data) orelse return null;
        return Reader{ .data = payload };
    }

    // Linear scan through entries at the current compound level to find a named tag.
    // Returns a slice starting at the payload (after type + name).
    fn findTag(_: Reader, expected_type: TagType, name: []const u8, data: []const u8) ?[]const u8 {
        var pos: usize = 0;
        while (pos < data.len) {
            const tag_byte = data[pos];
            pos += 1;

            const tag_type: TagType = enumCast(TagType, tag_byte) orelse return null;
            if (tag_type == .end) return null;

            // Read name
            if (pos >= data.len) return null;
            const name_len = data[pos];
            pos += 1;
            if (pos + name_len > data.len) return null;
            const entry_name = data[pos..][0..name_len];
            pos += name_len;

            const payload_start = pos;

            // Skip payload to advance pos
            pos = skipPayload(data, pos, tag_type) orelse return null;

            if (tag_type == expected_type and std.mem.eql(u8, entry_name, name)) {
                return data[payload_start..];
            }
        }
        return null;
    }

    /// Advance past the payload of a given tag type. Returns new position or null on error.
    fn skipPayload(data: []const u8, start: usize, tag_type: TagType) ?usize {
        var pos = start;
        switch (tag_type) {
            .end => {},
            .bool, .i8 => pos += 1,
            .i16 => pos += 2,
            .i32, .f32 => pos += 4,
            .i64, .f64 => pos += 8,
            .string => {
                if (pos + 2 > data.len) return null;
                const len = std.mem.littleToNative(u16, std.mem.bytesToValue(u16, data[pos..][0..2]));
                pos += 2 + len;
            },
            .byte_array => {
                if (pos + 4 > data.len) return null;
                const len = std.mem.littleToNative(u32, std.mem.bytesToValue(u32, data[pos..][0..4]));
                pos += 4 + len;
            },
            .compound => {
                // Skip until end tag
                while (pos < data.len) {
                    const inner_byte = data[pos];
                    pos += 1;
                    const inner_type: TagType = enumCast(TagType, inner_byte) orelse return null;
                    if (inner_type == .end) break;
                    // Skip name
                    if (pos >= data.len) return null;
                    const nlen = data[pos];
                    pos += 1 + nlen;
                    // Skip value
                    pos = skipPayload(data, pos, inner_type) orelse return null;
                }
            },
            .list => {
                if (pos + 3 > data.len) return null;
                const elem_byte = data[pos];
                pos += 1;
                const elem_type: TagType = enumCast(TagType, elem_byte) orelse return null;
                const count = std.mem.littleToNative(u16, std.mem.bytesToValue(u16, data[pos..][0..2]));
                pos += 2;
                for (0..count) |_| {
                    pos = skipPayload(data, pos, elem_type) orelse return null;
                }
            },
        }
        if (pos > data.len) return null;
        return pos;
    }
};

// ============================================================
// File I/O (with ZSTD compression)
// ============================================================

const Io = std.Io;
const Dir = Io.Dir;

/// Write tag data to a ZSTD-compressed file with header.
pub fn writeFile(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const io = Io.Threaded.global_single_threaded.io();

    const bound = compression.compressBound(.zstd, data.len);
    const comp_buf = try allocator.alloc(u8, HEADER_SIZE + bound);
    defer allocator.free(comp_buf);

    // Header
    @memcpy(comp_buf[0..4], &MAGIC);
    comp_buf[4] = VERSION;
    std.mem.writeInt(u32, comp_buf[5..9], @intCast(data.len), .little);

    // Compress into buffer after header
    const comp_len = compression.compress(.zstd, data, comp_buf[HEADER_SIZE..]) catch return error.CompressionFailed;

    const file = try Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    file.writePositionalAll(io, comp_buf[0 .. HEADER_SIZE + comp_len], 0) catch return error.WriteFailed;
}

/// Read and decompress a tag file. Caller owns the returned slice.
pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = Io.Threaded.global_single_threaded.io();

    const file = Dir.openFileAbsolute(io, path, .{}) catch return error.FileNotFound;
    defer file.close(io);

    // Read header
    var header: [HEADER_SIZE]u8 = undefined;
    const hdr_n = file.readPositionalAll(io, &header, 0) catch return error.ReadFailed;
    if (hdr_n < HEADER_SIZE) return error.InvalidHeader;
    if (!std.mem.eql(u8, header[0..4], &MAGIC)) return error.InvalidHeader;
    if (header[4] != VERSION) return error.InvalidHeader;

    const uncompressed_size = std.mem.readInt(u32, header[5..9], .little);

    // Read compressed data
    const stat = file.stat(io) catch return error.ReadFailed;
    const comp_size = stat.size - HEADER_SIZE;
    const comp_buf = try allocator.alloc(u8, comp_size);
    defer allocator.free(comp_buf);

    const read_n = file.readPositionalAll(io, comp_buf, HEADER_SIZE) catch return error.ReadFailed;
    if (read_n < comp_size) return error.ReadFailed;

    // Decompress
    const out_buf = try allocator.alloc(u8, uncompressed_size);
    errdefer allocator.free(out_buf);

    _ = compression.decompress(.zstd, comp_buf, out_buf, uncompressed_size) catch {
        allocator.free(out_buf);
        return error.DecompressionFailed;
    };

    return out_buf;
}

pub const FileError = error{
    FileNotFound,
    ReadFailed,
    WriteFailed,
    InvalidHeader,
    CompressionFailed,
    DecompressionFailed,
    OutOfMemory,
};

// ============================================================
// Tests
// ============================================================

test "round-trip primitives" {
    const allocator = std.testing.allocator;

    var w = Writer.init(allocator);
    defer w.deinit();

    w.putBool("alive", true);
    w.putI8("direction", -1);
    w.putI16("health", 20);
    w.putI32("score", 123456);
    w.putI64("uuid", 0x123456789ABCDEF0);
    w.putF32("x", 1.5);
    w.putF64("precise_y", 64.123456789);
    w.putString("name", "Steve");
    w.putBytes("data", &[_]u8{ 0xDE, 0xAD });

    const data = w.toOwnedSlice() orelse return error.OutOfMemory;
    defer allocator.free(data);

    const r = Reader.init(data);

    try std.testing.expectEqual(true, r.getBool("alive").?);
    try std.testing.expectEqual(@as(i8, -1), r.getI8("direction").?);
    try std.testing.expectEqual(@as(i16, 20), r.getI16("health").?);
    try std.testing.expectEqual(@as(i32, 123456), r.getI32("score").?);
    try std.testing.expectEqual(@as(i64, 0x123456789ABCDEF0), r.getI64("uuid").?);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), r.getF32("x").?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 64.123456789), r.getF64("precise_y").?, 0.0001);
    try std.testing.expectEqualSlices(u8, "Steve", r.getString("name").?);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xDE, 0xAD }, r.getBytes("data").?);

    // Missing keys return null
    try std.testing.expect(r.getBool("missing") == null);
    try std.testing.expect(r.getF32("missing") == null);
}

test "nested compound" {
    const allocator = std.testing.allocator;

    var w = Writer.init(allocator);
    defer w.deinit();

    w.putF32("x", 10.0);
    w.beginCompound("position");
    w.putF64("px", 1.0);
    w.putF64("py", 2.0);
    w.putF64("pz", 3.0);
    w.endCompound();
    w.putF32("y", 20.0);

    const data = w.toOwnedSlice() orelse return error.OutOfMemory;
    defer allocator.free(data);

    const r = Reader.init(data);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), r.getF32("x").?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), r.getF32("y").?, 0.001);

    const pos = r.getCompound("position").?;
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), pos.getF64("px").?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), pos.getF64("py").?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), pos.getF64("pz").?, 0.001);
}

test "missing tag returns null" {
    const r = Reader.init(&[_]u8{@intFromEnum(TagType.end)});
    try std.testing.expect(r.getF32("x") == null);
    try std.testing.expect(r.getBool("alive") == null);
    try std.testing.expect(r.getCompound("pos") == null);
}
