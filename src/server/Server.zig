const std = @import("std");
const Atomic = std.atomic.Value;
const network = @import("../network/network.zig");
const ConnectionManager = network.ConnectionManager;
const Connection = network.Connection;
const Address = network.Address;
const ServerWorld = @import("ServerWorld.zig");
const User = @import("User.zig");

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn nanoTimestamp() i128 {
    const ts = std.Io.Clock.Timestamp.now(io(), if (@import("builtin").os.tag == .windows) .real else .awake);
    return ts.raw.toNanoseconds();
}

pub const Server = @This();

var global_instance: ?*Server = null;

pub fn getGlobalInstance() ?*Server {
    return global_instance;
}

pub const TICK_RATE: u32 = 30;
pub const TICK_INTERVAL_NS: u64 = 1_000_000_000 / TICK_RATE;
pub const DEFAULT_PORT: u16 = 7777;

allocator: std.mem.Allocator,
world: *ServerWorld,
conn_manager: ConnectionManager,

users: std.ArrayList(*User),
users_mutex: std.Io.Mutex = .init,
next_user_id: u32 = 1,

running: Atomic(bool) = Atomic(bool).init(false),
thread: ?std.Thread = null,

pub fn init(allocator: std.mem.Allocator, world_name: []const u8, port: u16) !*Server {
    const self = try allocator.create(Server);
    errdefer allocator.destroy(self);

    const world = try ServerWorld.init(allocator, world_name, null);
    errdefer world.deinit();

    var conn_manager = try ConnectionManager.init(allocator, port);
    conn_manager.on_new_connection = onNewConnection;

    self.* = .{
        .allocator = allocator,
        .world = world,
        .conn_manager = conn_manager,
        .users = .empty,
    };

    // Set global server pointer for protocol handlers
    @import("../network/protocols/block_update.zig").server_instance = self;
    global_instance = self;

    std.log.info("Server initialized on port {}", .{conn_manager.local_port});
    return self;
}

pub fn deinit(self: *Server) void {
    @import("../network/protocols/block_update.zig").server_instance = null;
    global_instance = null;
    self.stop();

    // Disconnect all users
    self.users_mutex.lockUncancelable(io());
    for (self.users.items) |user| {
        user.conn.disconnect();
        user.decreaseRefCount();
    }
    self.users.deinit(self.allocator);
    self.users_mutex.unlock(io());

    self.world.save();
    self.world.deinit();
    self.conn_manager.deinit();
    self.allocator.destroy(self);
}

/// Start the server on a background thread.
pub fn startBackground(self: *Server) void {
    if (self.running.load(.acquire)) return;
    self.running.store(true, .release);
    self.conn_manager.start();
    self.thread = std.Thread.spawn(.{}, serverLoop, .{self}) catch |err| {
        std.log.err("Failed to spawn server thread: {s}", .{@errorName(err)});
        self.running.store(false, .release);
        return;
    };
    std.log.info("Server started (background thread, {} ticks/sec)", .{TICK_RATE});
}

/// Run the server on the current thread (blocks until stopped).
pub fn run(self: *Server) void {
    self.running.store(true, .release);
    self.conn_manager.start();
    std.log.info("Server running ({} ticks/sec, port {})", .{ TICK_RATE, self.conn_manager.local_port });
    serverLoop(self);
}

/// Stop the server.
pub fn stop(self: *Server) void {
    if (!self.running.load(.acquire)) return;
    std.log.info("Server stopping...", .{});
    self.running.store(false, .release);
    self.conn_manager.stop();
    if (self.thread) |t| {
        t.join();
        self.thread = null;
    }
}

fn serverLoop(self: *Server) void {
    var last_time = nanoTimestamp();

    while (self.running.load(.acquire)) {
        const now = nanoTimestamp();
        const elapsed: u64 = @intCast(@max(0, now - last_time));

        if (elapsed < TICK_INTERVAL_NS) {
            // Sleep for remaining time
            const remaining = TICK_INTERVAL_NS - elapsed;
            io().sleep(.{ .nanoseconds = remaining }, .awake) catch {};
            last_time += @as(i128, TICK_INTERVAL_NS);
        } else {
            last_time = now;
        }

        self.update();
    }
}

fn update(self: *Server) void {
    self.world.game_time += 1;

    // Drain newly loaded chunks
    _ = self.world.drainLoadedChunks();

    // Process storage I/O
    if (self.world.storage) |s| s.tick();

    // Update each user
    self.users_mutex.lockUncancelable(io());
    const user_snapshot = self.allocator.dupe(*User, self.users.items) catch {
        self.users_mutex.unlock(io());
        return;
    };
    self.users_mutex.unlock(io());
    defer self.allocator.free(user_snapshot);

    for (user_snapshot) |user| {
        self.updateUser(user);
    }

    // Broadcast positions to all clients every tick
    if (user_snapshot.len > 0) {
        self.broadcastPositions(user_snapshot);
    }

    // Clean up disconnected users
    self.users_mutex.lockUncancelable(io());
    var i: usize = 0;
    while (i < self.users.items.len) {
        const user = self.users.items[i];
        if (!user.connected.load(.acquire) or !user.conn.isConnected()) {
            std.log.info("User {} disconnected", .{user.id});
            _ = self.users.swapRemove(i);
            user.decreaseRefCount();
            continue;
        }
        i += 1;
    }
    self.users_mutex.unlock(io());
}

const WorldState = @import("../world/WorldState.zig");
const chunk_codec = @import("../world/storage/chunk_codec.zig");
const chunk_transmission = @import("../network/protocols/chunk_transmission.zig");
const BLOCKS_PER_CHUNK = WorldState.BLOCKS_PER_CHUNK;

/// Send unsent chunks within render distance to the user (max per tick to avoid flooding).
/// Loads/generates missing chunks synchronously on the server if needed.
fn updateUser(self: *Server, user: *User) void {
    if (!user.connected.load(.acquire)) return;

    const center = user.getChunkPos();
    const rd: i32 = @intCast(@min(user.render_distance, 8)); // cap for safety
    var sent: u32 = 0;
    const max_per_tick: u32 = 4; // limit bandwidth
    const TerrainGen = @import("../world/TerrainGen.zig");

    var cy: i32 = center.cy - rd;
    while (cy <= center.cy + rd) : (cy += 1) {
        var cx: i32 = center.cx - rd;
        while (cx <= center.cx + rd) : (cx += 1) {
            var cz: i32 = center.cz - rd;
            while (cz <= center.cz + rd) : (cz += 1) {
                if (sent >= max_per_tick) return;
                const key = WorldState.ChunkKey{ .cx = cx, .cy = cy, .cz = cz };
                if (user.hasChunk(key)) continue;

                // Load or generate the chunk if not present on server
                var chunk = self.world.chunk_map.get(key);
                if (chunk == null) {
                    const new_chunk = self.world.chunk_pool.acquire();
                    var loaded = false;
                    if (self.world.storage) |s| {
                        if (s.loadChunkInto(key.cx, key.cy, key.cz, new_chunk)) {
                            loaded = true;
                        }
                    }
                    if (!loaded) {
                        switch (self.world.world_type) {
                            .normal => TerrainGen.generateChunk(new_chunk, key, self.world.seed),
                            .debug => WorldState.generateDebugChunk(new_chunk, key),
                        }
                        if (self.world.storage) |s| {
                            s.markDirty(key.cx, key.cy, key.cz, new_chunk);
                        }
                    }
                    self.world.chunk_map.put(key, new_chunk);
                    chunk = new_chunk;
                }

                // Encode chunk data
                var flat_blocks: [BLOCKS_PER_CHUNK]WorldState.StateId = undefined;
                chunk.?.blocks.getRange(&flat_blocks, 0);
                var encoded = chunk_codec.encode(self.allocator, &flat_blocks) catch continue;
                defer encoded.deinit();

                // Send via protocol
                chunk_transmission.sendChunk(user.conn, self.conn_manager.socket, key, encoded.data);
                user.markChunkLoaded(key);
                sent += 1;
            }
        }
    }
}

/// Broadcast all player positions to all connected clients (called each tick).
fn broadcastPositions(self: *Server, users: []*User) void {
    const player_position = @import("../network/protocols/player_position.zig");

    // Build player info list
    var infos: [64]player_position.PlayerInfo = undefined;
    const count = @min(users.len, infos.len);
    for (users[0..count], 0..) |u, i| {
        infos[i] = .{
            .id = u.id,
            .pos = u.pos,
            .rotation = u.rotation,
        };
    }

    // Send to each user (excluding themselves)
    for (users[0..count]) |user| {
        if (!user.connected.load(.acquire)) continue;
        // Build a filtered list excluding the recipient
        var filtered: [64]player_position.PlayerInfo = undefined;
        var filtered_count: usize = 0;
        for (infos[0..count]) |info| {
            if (info.id != user.id) {
                filtered[filtered_count] = info;
                filtered_count += 1;
            }
        }
        if (filtered_count > 0) {
            player_position.sendOtherPlayers(user.conn, self.conn_manager.socket, filtered[0..filtered_count]);
        }
    }
}

/// Callback from ConnectionManager when a new connection arrives.
fn onNewConnection(manager: *ConnectionManager, addr: Address) ?*Connection {
    // Find the Server that owns this manager
    const self: *Server = @fieldParentPtr("conn_manager", manager);

    const conn = self.allocator.create(Connection) catch return null;
    conn.* = Connection.init(self.allocator, addr, true);
    conn.state.store(.connected, .release);

    const id = self.next_user_id;
    self.next_user_id += 1;

    const user = User.init(self.allocator, conn, id) catch {
        self.allocator.destroy(conn);
        return null;
    };

    self.users_mutex.lockUncancelable(io());
    self.users.append(self.allocator, user) catch {
        self.users_mutex.unlock(io());
        user.decreaseRefCount();
        self.allocator.destroy(conn);
        return null;
    };
    self.users_mutex.unlock(io());

    std.log.info("User {} connected from {}", .{ id, addr });
    return conn;
}

/// Get number of connected users.
pub fn userCount(self: *Server) usize {
    self.users_mutex.lockUncancelable(io());
    defer self.users_mutex.unlock(io());
    return self.users.items.len;
}
