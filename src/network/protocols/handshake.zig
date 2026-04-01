const std = @import("std");
const protocol = @import("../protocol.zig");
const Connection = @import("../Connection.zig").Connection;
const BinaryReader = protocol.BinaryReader;
const BinaryWriter = protocol.BinaryWriter;

pub const id: u8 = protocol.HANDSHAKE;

/// Protocol version — must match between client and server.
pub const PROTOCOL_VERSION: u32 = 1;

pub const HandshakeState = enum(u8) {
    none = 0,
    client_hello = 1, // Client → Server: name + version
    server_hello = 2, // Server → Client: seed + spawn + settings
    complete = 255,
};

// ─── Client → Server ───

pub fn sendClientHello(conn: *Connection, socket: anytype, player_name: []const u8) void {
    var writer = BinaryWriter.init(std.heap.page_allocator);
    defer writer.deinit();
    writer.writeInt(u8, @intFromEnum(HandshakeState.client_hello));
    writer.writeInt(u32, PROTOCOL_VERSION);
    writer.writeLenPrefixedString(player_name);
    conn.send(socket, .reliable, id, writer.data.items);
}

// ─── Server → Client ───

pub fn sendServerHello(conn: *Connection, socket: anytype, seed: u64, spawn_x: f64, spawn_y: f64, spawn_z: f64) void {
    var writer = BinaryWriter.init(std.heap.page_allocator);
    defer writer.deinit();
    writer.writeInt(u8, @intFromEnum(HandshakeState.server_hello));
    writer.writeInt(u64, seed);
    writer.writeFloat(f64, spawn_x);
    writer.writeFloat(f64, spawn_y);
    writer.writeFloat(f64, spawn_z);
    conn.send(socket, .reliable, id, writer.data.items);
}

// ─── Handlers ───

/// Server receives client_hello.
pub fn serverReceive(conn: *Connection, reader: *BinaryReader) anyerror!void {
    const state: HandshakeState = @enumFromInt(try reader.readInt(u8));
    switch (state) {
        .client_hello => {
            const version = try reader.readInt(u32);
            if (version != PROTOCOL_VERSION) {
                std.log.warn("Client version mismatch: got {}, expected {}", .{ version, PROTOCOL_VERSION });
                conn.disconnect();
                return;
            }
            const name = try reader.readLenPrefixedString();
            std.log.info("Handshake from player: {s}", .{name});

            // Update user name if available
            if (conn.user_data) |ud| {
                const User = @import("../../server/User.zig");
                const user: *User = @ptrCast(@alignCast(ud));
                user.name = name;
            }

            conn.state.store(.connected, .release);

            // Send server_hello back with world info
            const Server = @import("../../server/Server.zig");
            const srv = Server.getGlobalInstance() orelse return;
            const spawn = srv.world.spawn_pos;
            sendServerHello(conn, srv.conn_manager.socket, srv.world.seed, spawn[0], spawn[1], spawn[2]);
        },
        else => {},
    }
}

/// Client receives server_hello.
pub fn clientReceive(conn: *Connection, reader: *BinaryReader) anyerror!void {
    const state: HandshakeState = @enumFromInt(try reader.readInt(u8));
    switch (state) {
        .server_hello => {
            const seed = try reader.readInt(u64);
            const spawn_x = try reader.readFloat(f64);
            const spawn_y = try reader.readFloat(f64);
            const spawn_z = try reader.readFloat(f64);
            std.log.info("Server hello: seed={}, spawn=({d:.1}, {d:.1}, {d:.1})", .{ seed, spawn_x, spawn_y, spawn_z });
            conn.state.store(.connected, .release);
        },
        else => {},
    }
}

pub fn register() void {
    protocol.registerServerHandler(id, serverReceive);
    protocol.registerClientHandler(id, clientReceive);
}
