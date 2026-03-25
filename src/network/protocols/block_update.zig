const std = @import("std");
const protocol = @import("../protocol.zig");
const Connection = @import("../Connection.zig").Connection;
const BinaryReader = protocol.BinaryReader;
const BinaryWriter = protocol.BinaryWriter;
const WorldState = @import("../../world/WorldState.zig");

pub const id: u8 = protocol.BLOCK_UPDATE;

pub const BlockChange = struct {
    wx: i32,
    wy: i32,
    wz: i32,
    new_block: WorldState.StateId,
};

/// Client → Server: request a block change.
pub fn sendBlockChangeRequest(
    conn: *Connection,
    socket: anytype,
    wx: i32,
    wy: i32,
    wz: i32,
    new_block: WorldState.StateId,
) void {
    var writer = BinaryWriter.init(std.heap.page_allocator);
    defer writer.deinit();
    writer.writeInt(i32, wx);
    writer.writeInt(i32, wy);
    writer.writeInt(i32, wz);
    writer.writeInt(u16, new_block);
    conn.send(socket, .reliable, id, writer.data.items);
}

/// Server → Client: broadcast confirmed block changes.
pub fn sendBlockUpdates(
    conn: *Connection,
    socket: anytype,
    changes: []const BlockChange,
) void {
    var writer = BinaryWriter.init(std.heap.page_allocator);
    defer writer.deinit();
    writer.writeInt(u32, @intCast(changes.len));
    for (changes) |change| {
        writer.writeInt(i32, change.wx);
        writer.writeInt(i32, change.wy);
        writer.writeInt(i32, change.wz);
        writer.writeInt(u16, change.new_block);
    }
    conn.send(socket, .reliable, id, writer.data.items);
}

/// Server receives block change request from client.
pub fn serverReceive(conn: *Connection, reader: *BinaryReader) anyerror!void {
    _ = conn;
    const wx = try reader.readInt(i32);
    const wy = try reader.readInt(i32);
    const wz = try reader.readInt(i32);
    const new_block = try reader.readInt(u16);

    _ = wx;
    _ = wy;
    _ = wz;
    _ = new_block;
    // TODO: Validate and apply via ServerWorld.setBlock(), broadcast to all clients
}

/// Client receives confirmed block updates.
pub fn clientReceive(conn: *Connection, reader: *BinaryReader) anyerror!void {
    _ = conn;
    const count = try reader.readInt(u32);
    for (0..count) |_| {
        _ = try reader.readInt(i32); // wx
        _ = try reader.readInt(i32); // wy
        _ = try reader.readInt(i32); // wz
        _ = try reader.readInt(u16); // new_block
    }
    // TODO: Phase 4 — apply to client ChunkMap and trigger remesh
}

pub fn register() void {
    protocol.registerServerHandler(id, serverReceive);
    protocol.registerClientHandler(id, clientReceive);
}
