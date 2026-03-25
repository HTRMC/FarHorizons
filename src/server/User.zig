const std = @import("std");
const Atomic = std.atomic.Value;
const Connection = @import("../network/Connection.zig").Connection;
const WorldState = @import("../world/WorldState.zig");

pub const User = @This();

conn: *Connection,
allocator: std.mem.Allocator,

// Identity
name: []const u8 = "Player",
id: u32 = 0,

// Player state (server-authoritative position)
pos: [3]f64 = .{ 0, 64, 0 },
vel: [3]f64 = .{ 0, 0, 0 },
rotation: [3]f32 = .{ 0, 0, 0 }, // pitch, yaw, roll

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
