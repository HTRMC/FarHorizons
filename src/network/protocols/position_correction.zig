const std = @import("std");
const protocol = @import("../protocol.zig");
const Connection = @import("../Connection.zig").Connection;
const Socket = @import("../Socket.zig");
const BinaryReader = protocol.BinaryReader;
const BinaryWriter = protocol.BinaryWriter;

pub const id: u8 = protocol.POSITION_CORRECTION;

/// Flags indicating which fields are relative (added to current) vs absolute (replace).
pub const Relative = packed struct(u16) {
    x: bool = false,
    y: bool = false,
    z: bool = false,
    yaw: bool = false,
    pitch: bool = false,
    vel_x: bool = false,
    vel_y: bool = false,
    vel_z: bool = false,
    _pad: u8 = 0,
};

/// Server → Client: correct the player's position/rotation/velocity.
pub fn send(
    conn: *Connection,
    socket: Socket,
    teleport_id: u32,
    pos: [3]f64,
    vel: [3]f64,
    rotation: [2]f32, // pitch, yaw
    relatives: Relative,
) void {
    var writer = BinaryWriter.init(std.heap.page_allocator);
    defer writer.deinit();
    writer.writeInt(u32, teleport_id);
    writer.writeFloat(f64, pos[0]);
    writer.writeFloat(f64, pos[1]);
    writer.writeFloat(f64, pos[2]);
    writer.writeFloat(f64, vel[0]);
    writer.writeFloat(f64, vel[1]);
    writer.writeFloat(f64, vel[2]);
    writer.writeFloat(f32, rotation[0]);
    writer.writeFloat(f32, rotation[1]);
    writer.writeInt(u16, @bitCast(relatives));
    conn.send(socket, .reliable, id, writer.data.items);
}

/// Module-level client references (set on connect, cleared on disconnect).
pub var client_game_state: ?*@import("../../world/GameState.zig") = null;
pub var client_socket: Socket = undefined;
pub var client_socket_valid: bool = false;

/// Client receives a position correction from server.
pub fn clientReceive(conn: *Connection, reader: *BinaryReader) anyerror!void {
    const teleport_id = try reader.readInt(u32);
    const pos = [3]f64{
        try reader.readFloat(f64),
        try reader.readFloat(f64),
        try reader.readFloat(f64),
    };
    const vel = [3]f64{
        try reader.readFloat(f64),
        try reader.readFloat(f64),
        try reader.readFloat(f64),
    };
    const rotation = [2]f32{
        try reader.readFloat(f32),
        try reader.readFloat(f32),
    };
    const rel_bits = try reader.readInt(u16);
    const relatives: Relative = @bitCast(rel_bits);

    const state = client_game_state orelse return;
    state.applyPositionCorrection(pos, vel, rotation, relatives);

    if (!client_socket_valid) return;

    // Send ACK
    const accept_teleport = @import("accept_teleport.zig");
    accept_teleport.send(conn, client_socket, teleport_id);

    // Send current position back immediately
    const player_position = @import("player_position.zig");
    player_position.sendPositionImmediate(conn, client_socket, state);
}

pub fn register() void {
    protocol.registerClientHandler(id, clientReceive);
}
