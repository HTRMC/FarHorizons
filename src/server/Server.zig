const std = @import("std");
const Atomic = std.atomic.Value;
const network = @import("../network.zig");
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

pub const TICK_RATE: u32 = 20;
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

    std.log.info("Server initialized on port {}", .{conn_manager.local_port});
    return self;
}

pub fn deinit(self: *Server) void {
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

fn updateUser(self: *Server, user: *User) void {
    if (!user.connected.load(.acquire)) return;
    _ = self;
    // TODO: send chunk data to users within render distance
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
        // For now send all players including self — client can filter
        player_position.sendOtherPlayers(user.conn, self.conn_manager.socket, infos[0..count]);
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
