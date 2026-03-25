const std = @import("std");
const Connection = @import("Connection.zig");

/// Binary reader for deserializing network packets.
pub const BinaryReader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) BinaryReader {
        return .{ .data = data };
    }

    pub fn remaining(self: *const BinaryReader) []const u8 {
        return self.data[self.pos..];
    }

    pub fn readInt(self: *BinaryReader, comptime T: type) !T {
        const size = @sizeOf(T);
        if (self.pos + size > self.data.len) return error.EndOfStream;
        const bytes: *const [size]u8 = @ptrCast(self.data[self.pos..][0..size]);
        self.pos += size;
        return std.mem.readInt(T, bytes, .little);
    }

    pub fn readFloat(self: *BinaryReader, comptime T: type) !T {
        const IntType = std.meta.Int(.unsigned, @bitSizeOf(T));
        const int_val = try self.readInt(IntType);
        return @bitCast(int_val);
    }

    pub fn readSlice(self: *BinaryReader, len: usize) ![]const u8 {
        if (self.pos + len > self.data.len) return error.EndOfStream;
        const result = self.data[self.pos..][0..len];
        self.pos += len;
        return result;
    }

    pub fn readLenPrefixedSlice(self: *BinaryReader) ![]const u8 {
        const len = try self.readInt(u32);
        return try self.readSlice(len);
    }

    pub fn readLenPrefixedString(self: *BinaryReader) ![]const u8 {
        return try self.readLenPrefixedSlice();
    }
};

/// Binary writer for serializing network packets.
pub const BinaryWriter = struct {
    data: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BinaryWriter {
        return .{ .data = .empty, .allocator = allocator };
    }

    pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) BinaryWriter {
        var self = BinaryWriter{ .data = .empty, .allocator = allocator };
        self.data.ensureTotalCapacity(allocator, capacity) catch {};
        return self;
    }

    pub fn deinit(self: *BinaryWriter) void {
        self.data.deinit(self.allocator);
    }

    pub fn toOwnedSlice(self: *BinaryWriter) []const u8 {
        return self.data.toOwnedSlice(self.allocator) catch self.data.items;
    }

    pub fn writeInt(self: *BinaryWriter, comptime T: type, value: T) void {
        const bytes = std.mem.toBytes(std.mem.nativeToLittle(T, value));
        self.data.appendSlice(self.allocator, &bytes) catch @panic("OOM in BinaryWriter");
    }

    pub fn writeFloat(self: *BinaryWriter, comptime T: type, value: T) void {
        const IntType = std.meta.Int(.unsigned, @bitSizeOf(T));
        self.writeInt(IntType, @bitCast(value));
    }

    pub fn writeSlice(self: *BinaryWriter, slice: []const u8) void {
        self.data.appendSlice(self.allocator, slice) catch @panic("OOM in BinaryWriter");
    }

    pub fn writeLenPrefixedSlice(self: *BinaryWriter, slice: []const u8) void {
        self.writeInt(u32, @intCast(slice.len));
        self.writeSlice(slice);
    }

    pub fn writeLenPrefixedString(self: *BinaryWriter, string: []const u8) void {
        self.writeLenPrefixedSlice(string);
    }
};

/// Protocol handler function type.
pub const HandlerFn = *const fn (*Connection, *BinaryReader) anyerror!void;

/// Protocol registry — maps protocol IDs to handler functions.
/// Separate arrays for client-side and server-side handlers.
var client_handlers: [256]?HandlerFn = .{null} ** 256;
var server_handlers: [256]?HandlerFn = .{null} ** 256;

pub fn registerClientHandler(id: u8, handler: HandlerFn) void {
    std.debug.assert(client_handlers[id] == null);
    client_handlers[id] = handler;
}

pub fn registerServerHandler(id: u8, handler: HandlerFn) void {
    std.debug.assert(server_handlers[id] == null);
    server_handlers[id] = handler;
}

/// Dispatch a received packet to the appropriate handler.
pub fn dispatch(conn: *Connection, protocol_id: u8, data: []const u8) !void {
    const handler = if (conn.is_server_side)
        server_handlers[protocol_id]
    else
        client_handlers[protocol_id];

    if (handler) |h| {
        var reader = BinaryReader.init(data);
        try h(conn, &reader);
    } else {
        std.log.warn("Unknown protocol ID: {}", .{protocol_id});
    }
}

// ─── Protocol IDs ───

pub const HANDSHAKE: u8 = 1;
pub const CHUNK_REQUEST: u8 = 2;
pub const CHUNK_TRANSMISSION: u8 = 3;
pub const PLAYER_POSITION: u8 = 4;
pub const BLOCK_UPDATE: u8 = 5;

// ─── Tests ───

test "BinaryReader: read integers" {
    const data = [_]u8{ 0x01, 0x00, 0x02, 0x00, 0x00, 0x00 };
    var reader = BinaryReader.init(&data);
    try std.testing.expectEqual(@as(u16, 1), try reader.readInt(u16));
    try std.testing.expectEqual(@as(u32, 2), try reader.readInt(u32));
}

test "BinaryReader: end of stream" {
    const data = [_]u8{0x01};
    var reader = BinaryReader.init(&data);
    try std.testing.expectError(error.EndOfStream, reader.readInt(u32));
}

test "BinaryWriter: write integers" {
    var writer = BinaryWriter.init(std.testing.allocator);
    defer writer.deinit();
    writer.writeInt(u16, 1);
    writer.writeInt(u32, 2);
    try std.testing.expectEqual(@as(usize, 6), writer.data.items.len);

    var reader = BinaryReader.init(writer.data.items);
    try std.testing.expectEqual(@as(u16, 1), try reader.readInt(u16));
    try std.testing.expectEqual(@as(u32, 2), try reader.readInt(u32));
}

test "BinaryWriter: len-prefixed slice roundtrip" {
    var writer = BinaryWriter.init(std.testing.allocator);
    defer writer.deinit();
    writer.writeLenPrefixedString("hello");

    var reader = BinaryReader.init(writer.data.items);
    const s = try reader.readLenPrefixedString();
    try std.testing.expectEqualStrings("hello", s);
}
