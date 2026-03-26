const std = @import("std");
const protocol = @import("../protocol.zig");
const Connection = @import("../Connection.zig").Connection;
const Socket = @import("../Socket.zig");
const BinaryReader = protocol.BinaryReader;
const BinaryWriter = protocol.BinaryWriter;
const GameState = @import("../../world/GameState.zig");

pub const id: u8 = protocol.PLAYER_POSITION;

/// Position movement threshold (squared) — only send if moved more than this.
const MOVE_THRESHOLD_SQ: f64 = 4e-8; // ~2e-4 blocks
/// Rotation threshold in degrees.
const ROT_THRESHOLD: f32 = 0.01;
/// Max ticks between forced position updates.
const POSITION_REMINDER_TICKS: u16 = 20;

/// What changed since last send.
const UpdateFlags = packed struct(u8) {
    has_pos: bool = false,
    has_rot: bool = false,
    on_ground: bool = false,
    _pad: u5 = 0,
};

/// Client-side tracking for smart position sending.
var last_pos: [3]f64 = .{ 0, 0, 0 };
var last_rotation: [2]f32 = .{ 0, 0 };
var last_on_ground: bool = false;
var position_reminder: u16 = 0;

pub fn resetTracking() void {
    last_pos = .{ 0, 0, 0 };
    last_rotation = .{ 0, 0 };
    last_on_ground = false;
    position_reminder = 0;
}

/// Client → Server: send position update, only including what changed.
pub fn sendPositionSmart(
    conn: *Connection,
    socket: Socket,
    pos: [3]f64,
    rotation: [2]f32, // pitch, yaw
    on_ground: bool,
) void {
    const dx = pos[0] - last_pos[0];
    const dy = pos[1] - last_pos[1];
    const dz = pos[2] - last_pos[2];
    const dist_sq = dx * dx + dy * dy + dz * dz;

    const pos_changed = dist_sq > MOVE_THRESHOLD_SQ;
    const rot_changed = @abs(rotation[0] - last_rotation[0]) > ROT_THRESHOLD or
        @abs(rotation[1] - last_rotation[1]) > ROT_THRESHOLD;
    const ground_changed = on_ground != last_on_ground;

    position_reminder += 1;
    const force_send = position_reminder >= POSITION_REMINDER_TICKS;

    if (!pos_changed and !rot_changed and !ground_changed and !force_send) return;

    const flags = UpdateFlags{
        .has_pos = pos_changed or force_send,
        .has_rot = rot_changed or force_send,
        .on_ground = on_ground,
    };

    var writer = BinaryWriter.init(std.heap.page_allocator);
    defer writer.deinit();
    writer.writeInt(u8, @bitCast(flags));

    if (flags.has_pos) {
        writer.writeFloat(f64, pos[0]);
        writer.writeFloat(f64, pos[1]);
        writer.writeFloat(f64, pos[2]);
        last_pos = pos;
    }
    if (flags.has_rot) {
        writer.writeFloat(f32, rotation[0]);
        writer.writeFloat(f32, rotation[1]);
        last_rotation = rotation;
    }
    last_on_ground = on_ground;
    position_reminder = 0;

    conn.send(socket, .lossy, id, writer.data.items);
}

/// Client → Server: send full position immediately (after correction ACK).
pub fn sendPositionImmediate(conn: *Connection, socket: Socket, state: *GameState) void {
    const cam = state.camera;
    const entity_flags = state.entities.flags[0];

    const flags = UpdateFlags{
        .has_pos = true,
        .has_rot = true,
        .on_ground = entity_flags.on_ground,
    };

    var writer = BinaryWriter.init(std.heap.page_allocator);
    defer writer.deinit();
    writer.writeInt(u8, @bitCast(flags));
    writer.writeFloat(f64, cam.position.x);
    writer.writeFloat(f64, cam.position.y);
    writer.writeFloat(f64, cam.position.z);
    writer.writeFloat(f32, cam.pitch);
    writer.writeFloat(f32, cam.yaw);

    last_pos = .{ cam.position.x, cam.position.y, cam.position.z };
    last_rotation = .{ cam.pitch, cam.yaw };
    last_on_ground = entity_flags.on_ground;
    position_reminder = 0;

    conn.send(socket, .lossy, id, writer.data.items);
}

/// Server → Client: broadcast other players' positions.
pub fn sendOtherPlayers(
    conn: *Connection,
    socket: Socket,
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
    const flag_bits = try reader.readInt(u8);
    const flags: UpdateFlags = @bitCast(flag_bits);

    var pos: ?[3]f64 = null;
    var rotation: ?[2]f32 = null;

    if (flags.has_pos) {
        pos = .{
            try reader.readFloat(f64),
            try reader.readFloat(f64),
            try reader.readFloat(f64),
        };
    }
    if (flags.has_rot) {
        rotation = .{
            try reader.readFloat(f32),
            try reader.readFloat(f32),
        };
    }

    if (conn.user_data) |ud| {
        const User = @import("../../server/User.zig");
        const user: *User = @ptrCast(@alignCast(ud));
        user.handlePositionUpdate(pos, rotation, flags.on_ground);
    }
}

/// Pointer to client game state (set on client connect).
pub var client_game_state: ?*GameState = null;

/// Client receives other players' positions.
pub fn clientReceive(conn: *Connection, reader: *BinaryReader) anyerror!void {
    _ = conn;
    const count = try reader.readInt(u32);
    const state = client_game_state orelse {
        // Drain the data even if no game state
        for (0..count) |_| {
            _ = try reader.readInt(u32);
            _ = try reader.readFloat(f64);
            _ = try reader.readFloat(f64);
            _ = try reader.readFloat(f64);
            _ = try reader.readFloat(f32);
            _ = try reader.readFloat(f32);
            _ = try reader.readFloat(f32);
        }
        return;
    };

    for (0..count) |_| {
        const pid = try reader.readInt(u32);
        const p = [3]f64{
            try reader.readFloat(f64),
            try reader.readFloat(f64),
            try reader.readFloat(f64),
        };
        const rot = [3]f32{
            try reader.readFloat(f32),
            try reader.readFloat(f32),
            try reader.readFloat(f32),
        };
        state.updateRemotePlayer(pid, p, rot);
    }
}

pub fn register() void {
    protocol.registerServerHandler(id, serverReceive);
    protocol.registerClientHandler(id, clientReceive);
}
