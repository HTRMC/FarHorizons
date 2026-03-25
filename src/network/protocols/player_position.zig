const std = @import("std");
const protocol = @import("../protocol.zig");
const Connection = @import("../Connection.zig").Connection;
const BinaryReader = protocol.BinaryReader;
const BinaryWriter = protocol.BinaryWriter;

pub const id: u8 = protocol.PLAYER_POSITION;

/// Client → Server: send own position/velocity.
pub fn sendPosition(
    conn: *Connection,
    socket: anytype,
    pos: [3]f64,
    vel: [3]f64,
    rotation: [3]f32,
) void {
    var writer = BinaryWriter.init(std.heap.page_allocator);
    defer writer.deinit();
    writer.writeFloat(f64, pos[0]);
    writer.writeFloat(f64, pos[1]);
    writer.writeFloat(f64, pos[2]);
    writer.writeFloat(f64, vel[0]);
    writer.writeFloat(f64, vel[1]);
    writer.writeFloat(f64, vel[2]);
    writer.writeFloat(f32, rotation[0]);
    writer.writeFloat(f32, rotation[1]);
    writer.writeFloat(f32, rotation[2]);
    conn.send(socket, .lossy, id, writer.data.items);
}

/// Server → Client: broadcast other players' positions.
pub fn sendOtherPlayers(
    conn: *Connection,
    socket: anytype,
    players: []const PlayerInfo,
) void {
    var writer = BinaryWriter.init(std.heap.page_allocator);
    defer writer.deinit();
    writer.writeInt(u32, @intCast(players.len));
    for (players) |p| {
        writer.writeInt(u32, p.id);
        writer.writeFloat(f64, p.pos[0]);
        writer.writeFloat(f64, p.pos[1]);
        writer.writeFloat(f64, p.pos[2]);
        writer.writeFloat(f32, p.rotation[0]);
        writer.writeFloat(f32, p.rotation[1]);
        writer.writeFloat(f32, p.rotation[2]);
    }
    conn.send(socket, .lossy, id, writer.data.items);
}

pub const PlayerInfo = struct {
    id: u32,
    pos: [3]f64,
    rotation: [3]f32,
};

/// Server receives player position.
pub fn serverReceive(conn: *Connection, reader: *BinaryReader) anyerror!void {
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
    const rotation = [3]f32{
        try reader.readFloat(f32),
        try reader.readFloat(f32),
        try reader.readFloat(f32),
    };

    if (conn.user_data) |ud| {
        const User = @import("../../server/User.zig");
        const user: *User = @ptrCast(@alignCast(ud));
        user.pos = pos;
        user.vel = vel;
        user.rotation = rotation;
    }
}

/// Client receives other players' positions.
pub fn clientReceive(conn: *Connection, reader: *BinaryReader) anyerror!void {
    _ = conn;
    const count = try reader.readInt(u32);
    for (0..count) |_| {
        _ = try reader.readInt(u32); // id
        _ = try reader.readFloat(f64); // x
        _ = try reader.readFloat(f64); // y
        _ = try reader.readFloat(f64); // z
        _ = try reader.readFloat(f32); // pitch
        _ = try reader.readFloat(f32); // yaw
        _ = try reader.readFloat(f32); // roll
    }
    // TODO: Phase 5 — update client-side remote player list for rendering
}

pub fn register() void {
    protocol.registerServerHandler(id, serverReceive);
    protocol.registerClientHandler(id, clientReceive);
}
