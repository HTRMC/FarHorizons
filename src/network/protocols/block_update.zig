const std = @import("std");
const protocol = @import("../protocol.zig");
const Connection = @import("../Connection.zig").Connection;
const BinaryReader = protocol.BinaryReader;
const BinaryWriter = protocol.BinaryWriter;
const WorldState = @import("../../world/WorldState.zig");

pub const id: u8 = protocol.BLOCK_UPDATE;

/// Pointer to server instance (set on server init).
pub var server_instance: ?*@import("../../server/Server.zig").Server = null;

/// Pointer to client game state (set on client connect).
pub var client_game_state: ?*@import("../../world/GameState.zig") = null;

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
    writer.writeInt(u8, 0); // sub-type: request
    writer.writeInt(i32, wx);
    writer.writeInt(i32, wy);
    writer.writeInt(i32, wz);
    writer.writeInt(u16, new_block.toRaw());
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
    writer.writeInt(u8, 1); // sub-type: confirmed update
    writer.writeInt(u32, @intCast(changes.len));
    for (changes) |change| {
        writer.writeInt(i32, change.wx);
        writer.writeInt(i32, change.wy);
        writer.writeInt(i32, change.wz);
        writer.writeInt(u16, change.new_block.toRaw());
    }
    conn.send(socket, .reliable, id, writer.data.items);
}

/// Server receives block change request from client.
pub fn serverReceive(conn: *Connection, reader: *BinaryReader) anyerror!void {
    const sub_type = try reader.readInt(u8);
    if (sub_type != 0) return; // only handle requests

    const wx = try reader.readInt(i32);
    const wy = try reader.readInt(i32);
    const wz = try reader.readInt(i32);
    const new_block = WorldState.StateId.fromRaw(try reader.readInt(u16));

    const srv = server_instance orelse return;

    // Apply to server world (may fail if chunk not loaded, but still broadcast)
    _ = srv.world.setBlock(wx, wy, wz, new_block);

    // Broadcast to all connected clients
    const change = [1]BlockChange{.{ .wx = wx, .wy = wy, .wz = wz, .new_block = new_block }};
    const io = std.Io.Threaded.global_single_threaded.io();
    srv.users_mutex.lockUncancelable(io);
    const users = srv.allocator.dupe(*@import("../../server/User.zig"), srv.users.items) catch {
        srv.users_mutex.unlock(io);
        return;
    };
    srv.users_mutex.unlock(io);
    defer srv.allocator.free(users);

    for (users) |user| {
        if (!user.connected.load(.acquire)) continue;
        sendBlockUpdates(user.conn, srv.conn_manager.socket, &change);
    }
    _ = conn;
}

/// Client receives confirmed block updates from server.
pub fn clientReceive(_: *Connection, reader: *BinaryReader) anyerror!void {
    const sub_type = try reader.readInt(u8);
    if (sub_type != 1) return; // only handle confirmed updates

    const count = try reader.readInt(u32);
    const state = client_game_state orelse return;

    for (0..count) |_| {
        const wx = try reader.readInt(i32);
        const wy = try reader.readInt(i32);
        const wz = try reader.readInt(i32);
        const new_block = WorldState.StateId.fromRaw(try reader.readInt(u16));

        // Queue for main thread (thread-safe ring buffer)
        state.queueNetworkBlockChange(WorldState.WorldBlockPos.init(wx, wy, wz), new_block);
    }
}

pub fn register() void {
    protocol.registerServerHandler(id, serverReceive);
    protocol.registerClientHandler(id, clientReceive);
}
