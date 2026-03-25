const std = @import("std");
const protocol = @import("../protocol.zig");
const Connection = @import("../Connection.zig").Connection;
const BinaryReader = protocol.BinaryReader;
const BinaryWriter = protocol.BinaryWriter;
const WorldState = @import("../../world/WorldState.zig");

pub const id: u8 = protocol.CHUNK_REQUEST;

/// Client → Server: request chunks around a position.
pub fn sendRequest(
    conn: *Connection,
    socket: anytype,
    base_cx: i32,
    base_cy: i32,
    base_cz: i32,
    render_distance: u16,
    requests: []const WorldState.ChunkKey,
) void {
    var writer = BinaryWriter.init(std.heap.page_allocator);
    defer writer.deinit();
    writer.writeInt(i32, base_cx);
    writer.writeInt(i32, base_cy);
    writer.writeInt(i32, base_cz);
    writer.writeInt(u16, render_distance);
    writer.writeInt(u32, @intCast(requests.len));
    for (requests) |key| {
        writer.writeInt(i32, key.cx);
        writer.writeInt(i32, key.cy);
        writer.writeInt(i32, key.cz);
    }
    conn.send(socket, .reliable, id, writer.data.items);
}

/// Server receives chunk request.
pub fn serverReceive(conn: *Connection, reader: *BinaryReader) anyerror!void {
    const base_cx = try reader.readInt(i32);
    const base_cy = try reader.readInt(i32);
    const base_cz = try reader.readInt(i32);
    const render_distance = try reader.readInt(u16);
    const count = try reader.readInt(u32);

    if (conn.user_data) |ud| {
        const User = @import("../../server/User.zig");
        const user: *User = @ptrCast(@alignCast(ud));
        user.render_distance = render_distance;
        user.last_chunk_pos = .{ .cx = base_cx, .cy = base_cy, .cz = base_cz };
    }

    // TODO: Queue requested chunks for transmission
    _ = count;
}

pub fn register() void {
    protocol.registerServerHandler(id, serverReceive);
}
