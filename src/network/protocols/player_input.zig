const std = @import("std");
const protocol = @import("../protocol.zig");
const Connection = @import("../Connection.zig").Connection;
const Socket = @import("../Socket.zig");
const BinaryReader = protocol.BinaryReader;
const BinaryWriter = protocol.BinaryWriter;

pub const id: u8 = protocol.PLAYER_INPUT;

/// Packed input state bitfield.
pub const InputState = packed struct(u8) {
    forward: bool = false,
    backward: bool = false,
    left: bool = false,
    right: bool = false,
    jump: bool = false,
    sneak: bool = false,
    sprint: bool = false,
    _pad: u1 = 0,
};

/// Client → Server: send input state when it changes.
pub fn send(conn: *Connection, socket: Socket, input: InputState) void {
    var writer = BinaryWriter.init(std.heap.page_allocator);
    defer writer.deinit();
    writer.writeInt(u8, @bitCast(input));
    conn.send(socket, .lossy, id, writer.data.items);
}

/// Server receives input state from client.
pub fn serverReceive(conn: *Connection, reader: *BinaryReader) anyerror!void {
    const bits = try reader.readInt(u8);
    const input: InputState = @bitCast(bits);

    if (conn.user_data) |ud| {
        const User = @import("../../server/User.zig");
        const user: *User = @ptrCast(@alignCast(ud));
        user.input = input;
    }
}

pub fn register() void {
    protocol.registerServerHandler(id, serverReceive);
}
