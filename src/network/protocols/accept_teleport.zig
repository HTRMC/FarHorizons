const std = @import("std");
const protocol = @import("../protocol.zig");
const Connection = @import("../Connection.zig").Connection;
const Socket = @import("../Socket.zig");
const BinaryReader = protocol.BinaryReader;
const BinaryWriter = protocol.BinaryWriter;

pub const id: u8 = protocol.ACCEPT_TELEPORT;

/// Client → Server: acknowledge a position correction.
pub fn send(conn: *Connection, socket: Socket, teleport_id: u32) void {
    var writer = BinaryWriter.init(std.heap.page_allocator);
    defer writer.deinit();
    writer.writeInt(u32, teleport_id);
    conn.send(socket, .reliable, id, writer.data.items);
}

/// Server receives teleport acknowledgment from client.
pub fn serverReceive(conn: *Connection, reader: *BinaryReader) anyerror!void {
    const teleport_id = try reader.readInt(u32);

    if (conn.user_data) |ud| {
        const User = @import("../../server/User.zig");
        const user: *User = @ptrCast(@alignCast(ud));
        user.acknowledgeTeleport(teleport_id);
    }
}

pub fn register() void {
    protocol.registerServerHandler(id, serverReceive);
}
