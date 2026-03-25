const std = @import("std");
const protocol = @import("../protocol.zig");
const Connection = @import("../Connection.zig").Connection;
const BinaryReader = protocol.BinaryReader;
const BinaryWriter = protocol.BinaryWriter;
const WorldState = @import("../../world/WorldState.zig");

pub const id: u8 = protocol.CHUNK_TRANSMISSION;

/// Server → Client: send a chunk's block data.
pub fn sendChunk(
    conn: *Connection,
    socket: anytype,
    key: WorldState.ChunkKey,
    block_data: []const u8,
) void {
    var writer = BinaryWriter.init(std.heap.page_allocator);
    defer writer.deinit();
    writer.writeInt(i32, key.cx);
    writer.writeInt(i32, key.cy);
    writer.writeInt(i32, key.cz);
    writer.writeLenPrefixedSlice(block_data);
    conn.send(socket, .reliable, id, writer.data.items);
}

/// Client receives chunk data.
pub fn clientReceive(conn: *Connection, reader: *BinaryReader) anyerror!void {
    _ = conn;
    const cx = try reader.readInt(i32);
    const cy = try reader.readInt(i32);
    const cz = try reader.readInt(i32);
    const data = try reader.readLenPrefixedSlice();

    _ = cx;
    _ = cy;
    _ = cz;
    _ = data;
    // TODO: Phase 4 — decompress and insert into client ChunkMap
}

pub fn register() void {
    protocol.registerClientHandler(id, clientReceive);
}
