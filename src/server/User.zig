const std = @import("std");
const Atomic = std.atomic.Value;
const Connection = @import("../network/Connection.zig").Connection;
const Socket = @import("../network/Socket.zig");
const WorldState = @import("../world/WorldState.zig");
const position_correction = @import("../network/protocols/position_correction.zig");
const player_input = @import("../network/protocols/player_input.zig");

pub const User = @This();

/// Max allowed speed in blocks/tick for validation (generous to avoid false positives).
const MAX_SPEED_PER_TICK: f64 = 20.0;

conn: *Connection,
allocator: std.mem.Allocator,

// Identity
name: []const u8 = "Player",
id: u32 = 0,

// Player state (server-authoritative position)
pos: [3]f64 = .{ 0, 64, 0 },
vel: [3]f64 = .{ 0, 0, 0 },
rotation: [3]f32 = .{ 0, 0, 0 }, // pitch, yaw, roll
on_ground: bool = false,

// Client input state (received from client)
input: player_input.InputState = .{},

// Teleport/correction tracking
next_teleport_id: u32 = 0,
pending_teleport_id: ?u32 = null,

// Chunk management
render_distance: u16 = 8,
last_chunk_pos: WorldState.ChunkKey = .{ .cx = 0, .cy = 0, .cz = 0 },
loaded_chunks: std.AutoHashMap(WorldState.ChunkKey, void),

// Connection state
connected: Atomic(bool) = Atomic(bool).init(true),
ref_count: Atomic(u32) = Atomic(u32).init(1),

pub fn init(allocator: std.mem.Allocator, conn: *Connection, id: u32) !*User {
    const self = try allocator.create(User);
    self.* = .{
        .conn = conn,
        .allocator = allocator,
        .id = id,
        .loaded_chunks = std.AutoHashMap(WorldState.ChunkKey, void).init(allocator),
    };
    conn.user_data = self;
    return self;
}

pub fn deinit(self: *User) void {
    self.loaded_chunks.deinit();
    self.allocator.destroy(self);
}

pub fn increaseRefCount(self: *User) void {
    _ = self.ref_count.fetchAdd(1, .monotonic);
}

pub fn decreaseRefCount(self: *User) void {
    if (self.ref_count.fetchSub(1, .monotonic) == 1) {
        self.deinit();
    }
}

/// Handle a position update from the client. Validates and applies or corrects.
pub fn handlePositionUpdate(self: *User, pos: ?[3]f64, rotation: ?[2]f32, on_ground: bool) void {
    // Ignore position updates while a teleport is pending acknowledgment
    if (self.pending_teleport_id != null) return;

    self.on_ground = on_ground;

    if (rotation) |rot| {
        self.rotation[0] = rot[0]; // pitch
        self.rotation[1] = rot[1]; // yaw
    }

    if (pos) |new_pos| {
        const dx = new_pos[0] - self.pos[0];
        const dy = new_pos[1] - self.pos[1];
        const dz = new_pos[2] - self.pos[2];
        const dist_sq = dx * dx + dy * dy + dz * dz;

        // Speed validation: reject if moving too fast
        if (dist_sq > MAX_SPEED_PER_TICK * MAX_SPEED_PER_TICK) {
            std.log.warn("Player {} moved too fast ({d:.1} blocks), correcting", .{
                self.id,
                @sqrt(dist_sq),
            });
            self.teleport(self.pos, .{ 0, 0, 0 }, .{ self.rotation[0], self.rotation[1] }, .{});
            return;
        }

        self.pos = new_pos;
    }
}

/// Send a position correction to the client and track the pending teleport.
pub fn teleport(
    self: *User,
    pos: [3]f64,
    vel: [3]f64,
    rotation: [2]f32,
    relatives: position_correction.Relative,
) void {
    const teleport_id = self.next_teleport_id;
    self.next_teleport_id +%= 1;
    self.pending_teleport_id = teleport_id;

    // Find socket from ConnectionManager — the server stores it
    const server = @import("Server.zig").getGlobalInstance() orelse return;
    position_correction.send(
        self.conn,
        server.conn_manager.socket,
        teleport_id,
        pos,
        vel,
        rotation,
        relatives,
    );
}

/// Called when the client acknowledges a teleport.
pub fn acknowledgeTeleport(self: *User, teleport_id: u32) void {
    if (self.pending_teleport_id) |pending| {
        if (pending == teleport_id) {
            self.pending_teleport_id = null;
        }
    }
}

/// Get the chunk key for the player's current position.
pub fn getChunkPos(self: *const User) WorldState.ChunkKey {
    const cs: i32 = WorldState.CHUNK_SIZE;
    return .{
        .cx = @intFromFloat(@divFloor(self.pos[0], @as(f64, @floatFromInt(cs)))),
        .cy = @intFromFloat(@divFloor(self.pos[1], @as(f64, @floatFromInt(cs)))),
        .cz = @intFromFloat(@divFloor(self.pos[2], @as(f64, @floatFromInt(cs)))),
    };
}

/// Check if a chunk is within this user's render distance.
pub fn isChunkInRange(self: *const User, key: WorldState.ChunkKey) bool {
    const center = self.getChunkPos();
    const dx: i64 = @as(i64, key.cx) - center.cx;
    const dy: i64 = @as(i64, key.cy) - center.cy;
    const dz: i64 = @as(i64, key.cz) - center.cz;
    const rd: i64 = self.render_distance;
    return dx * dx + dy * dy + dz * dz <= rd * rd;
}

/// Mark a chunk as sent to this user.
pub fn markChunkLoaded(self: *User, key: WorldState.ChunkKey) void {
    self.loaded_chunks.put(key, {}) catch {};
}

/// Check if this user already has a chunk.
pub fn hasChunk(self: *const User, key: WorldState.ChunkKey) bool {
    return self.loaded_chunks.contains(key);
}
