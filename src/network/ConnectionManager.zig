const std = @import("std");
const Atomic = std.atomic.Value;
const Socket = @import("Socket.zig");
const Address = Socket.Address;
const Connection = @import("Connection.zig").Connection;
const protocol = @import("protocol.zig");

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const ConnectionManager = @This();

socket: Socket,
thread: ?std.Thread = null,
running: Atomic(bool) = Atomic(bool).init(false),
local_port: u16,

connections: std.ArrayList(*Connection),
connections_mutex: std.Io.Mutex = .init,

allocator: std.mem.Allocator,

/// Callback invoked when a new connection request arrives (server-side).
/// Return a Connection to accept, or null to reject.
on_new_connection: ?*const fn (*ConnectionManager, Address) ?*Connection = null,

receive_buffer: [Connection.max_packet_size]u8 = undefined,

/// Retransmission timeout in milliseconds.
const RETRANSMIT_TIMEOUT_MS: i64 = 500;

/// Connection timeout in milliseconds (no packets for this long = disconnected).
const CONNECTION_TIMEOUT_MS: i64 = 10_000;

pub fn init(allocator: std.mem.Allocator, local_port: u16) !ConnectionManager {
    Socket.startup();
    const socket = try Socket.init(local_port);
    const actual_port = socket.getPort() catch local_port;

    return .{
        .socket = socket,
        .local_port = actual_port,
        .connections = .empty,
        .allocator = allocator,
    };
}

pub fn deinit(self: *ConnectionManager) void {
    self.stop();
    self.socket.deinit();
    self.connections.deinit(self.allocator);
}

/// Start the network receive thread.
pub fn start(self: *ConnectionManager) void {
    if (self.running.load(.acquire)) return;
    self.running.store(true, .release);
    self.thread = std.Thread.spawn(.{}, receiveLoop, .{self}) catch |err| {
        std.log.err("Failed to spawn network thread: {s}", .{@errorName(err)});
        self.running.store(false, .release);
        return;
    };
}

/// Stop the network receive thread.
pub fn stop(self: *ConnectionManager) void {
    if (!self.running.load(.acquire)) return;
    self.running.store(false, .release);
    if (self.thread) |t| {
        t.join();
        self.thread = null;
    }
}

/// Add a connection to be managed.
pub fn addConnection(self: *ConnectionManager, conn: *Connection) void {
    self.connections_mutex.lockUncancelable(io());
    defer self.connections_mutex.unlock(io());
    self.connections.append(self.allocator, conn) catch {
        std.log.err("Failed to add connection", .{});
    };
}

/// Remove a connection from management.
pub fn removeConnection(self: *ConnectionManager, conn: *Connection) void {
    self.connections_mutex.lockUncancelable(io());
    defer self.connections_mutex.unlock(io());
    for (self.connections.items, 0..) |c, i| {
        if (c == conn) {
            _ = self.connections.swapRemove(i);
            return;
        }
    }
}

/// Find a connection by remote address.
fn findConnection(self: *ConnectionManager, addr: Address) ?*Connection {
    self.connections_mutex.lockUncancelable(io());
    defer self.connections_mutex.unlock(io());
    for (self.connections.items) |conn| {
        if (conn.remote_address.eql(addr)) return conn;
    }
    return null;
}

/// Get a snapshot of current connections (caller must not hold connections_mutex).
pub fn getConnections(self: *ConnectionManager, allocator: std.mem.Allocator) []*Connection {
    self.connections_mutex.lockUncancelable(io());
    defer self.connections_mutex.unlock(io());
    return allocator.dupe(*Connection, self.connections.items) catch &.{};
}

/// Send raw data to an address (used for handshake before Connection exists).
pub fn sendRaw(self: *ConnectionManager, data: []const u8, target: Address) void {
    self.socket.send(data, target);
}

/// Main receive loop — runs on a background thread.
fn receiveLoop(self: *ConnectionManager) void {
    while (self.running.load(.acquire)) {
        var source_addr: Address = undefined;
        const data = self.socket.receive(&self.receive_buffer, &source_addr) catch |err| {
            switch (err) {
                error.Timeout => {},
                error.ConnectionReset => {}, // ICMP port unreachable on Windows
                else => std.log.warn("Socket receive error: {s}", .{@errorName(err)}),
            }
            // Periodic maintenance even when no packets
            self.maintenance();
            continue;
        };

        if (data.len == 0) continue;

        // Find existing connection
        if (self.findConnection(source_addr)) |conn| {
            self.handlePacket(conn, data);
        } else {
            // Unknown source — try new connection callback
            if (self.on_new_connection) |callback| {
                if (callback(self, source_addr)) |conn| {
                    self.addConnection(conn);
                    self.handlePacket(conn, data);
                }
            }
        }

        self.maintenance();
    }
}

fn handlePacket(self: *ConnectionManager, conn: *Connection, data: []const u8) void {
    if (conn.onReceive(self.socket, data)) |result| {
        protocol.dispatch(conn, result.protocol_id, result.payload) catch |err| {
            std.log.warn("Protocol dispatch error: {s}", .{@errorName(err)});
        };
        // Drain consecutive buffered packets that are now in order
        while (conn.popNextBuffered()) |buffered| {
            defer conn.allocator.free(buffered.raw_data);
            protocol.dispatch(conn, buffered.protocol_id, buffered.payload) catch |err| {
                std.log.warn("Protocol dispatch error: {s}", .{@errorName(err)});
            };
        }
    }
}

/// Periodic maintenance: retransmit timed-out packets, detect dead connections.
fn maintenance(self: *ConnectionManager) void {
    self.connections_mutex.lockUncancelable(io());
    defer self.connections_mutex.unlock(io());

    var i: usize = 0;
    while (i < self.connections.items.len) {
        const conn = self.connections.items[i];
        conn.retransmitTimedOut(self.socket, RETRANSMIT_TIMEOUT_MS);

        if (conn.hasTimedOut(CONNECTION_TIMEOUT_MS)) {
            conn.disconnect();
            _ = self.connections.swapRemove(i);
            continue;
        }
        i += 1;
    }
}
