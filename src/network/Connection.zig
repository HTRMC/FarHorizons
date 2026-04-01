const std = @import("std");
const Atomic = std.atomic.Value;
const Socket = @import("Socket.zig");
const Address = Socket.Address;
const protocol = @import("protocol.zig");
const BinaryWriter = protocol.BinaryWriter;
const BinaryReader = protocol.BinaryReader;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn milliTimestamp() i64 {
    const ts = std.Io.Clock.Timestamp.now(io(), if (@import("builtin").os.tag == .windows) .real else .awake);
    return @intCast(@divTrunc(ts.raw.toNanoseconds(), 1_000_000));
}

pub const Connection = @This();

pub const max_packet_size: u32 = 65507;

pub const Channel = enum(u8) {
    lossy = 0,
    reliable = 1,
};

pub const State = enum(u8) {
    connecting = 0,
    connected = 1,
    disconnected = 2,
};

// ─── Fields ───

remote_address: Address,
state: Atomic(State),
is_server_side: bool,

/// Opaque user data pointer (set to *server.User on server side).
user_data: ?*anyopaque = null,

// Reliable channel state
next_send_seq: Atomic(u32) = Atomic(u32).init(0),
next_recv_seq: Atomic(u32) = Atomic(u32).init(0),

// Unconfirmed reliable packets for retransmission
unconfirmed: std.ArrayList(UnconfirmedPacket) = .empty,
unconfirmed_mutex: std.Io.Mutex = .init,

// Receive buffer for reordering reliable packets
recv_buffer: std.AutoHashMap(u32, []const u8),
recv_mutex: std.Io.Mutex = .init,

allocator: std.mem.Allocator,

/// Time of last received packet (for timeout detection).
last_receive_time: i64,

/// Time of last sent packet.
last_send_time: i64 = 0,

const UnconfirmedPacket = struct {
    seq: u32,
    data: []const u8,
    send_time: i64,
    retransmit_count: u8 = 0,
};

// ─── Packet format ───
// [channel: u8][protocol_id: u8][payload...]
// For reliable: [channel: u8][seq: u32][protocol_id: u8][payload...]
// For ack:      [0xFF][ack_seq: u32]

const ACK_CHANNEL: u8 = 0xFF;
const RELIABLE_HEADER_SIZE: usize = 1 + 4 + 1; // channel + seq + protocol_id
const LOSSY_HEADER_SIZE: usize = 1 + 1; // channel + protocol_id

pub fn init(allocator: std.mem.Allocator, remote: Address, is_server_side: bool) Connection {
    return .{
        .remote_address = remote,
        .state = Atomic(State).init(.connecting),
        .is_server_side = is_server_side,
        .recv_buffer = std.AutoHashMap(u32, []const u8).init(allocator),
        .allocator = allocator,
        .last_receive_time = milliTimestamp(),
    };
}

pub fn deinit(self: *Connection) void {
    // Free unconfirmed packets
    for (self.unconfirmed.items) |pkt| {
        self.allocator.free(pkt.data);
    }
    self.unconfirmed.deinit(self.allocator);

    // Free receive buffer
    var it = self.recv_buffer.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.value_ptr.*);
    }
    self.recv_buffer.deinit();
}

pub fn isConnected(self: *const Connection) bool {
    return self.state.load(.acquire) == .connected;
}

pub fn disconnect(self: *Connection) void {
    self.state.store(.disconnected, .release);
}

/// Send a packet on the specified channel.
pub fn send(self: *Connection, socket: Socket, channel: Channel, protocol_id: u8, payload: []const u8) void {
    switch (channel) {
        .lossy => self.sendLossy(socket, protocol_id, payload),
        .reliable => self.sendReliable(socket, protocol_id, payload),
    }
    self.last_send_time = milliTimestamp();
}

fn sendLossy(self: *Connection, socket: Socket, protocol_id: u8, payload: []const u8) void {
    var buf: [max_packet_size]u8 = undefined;
    if (LOSSY_HEADER_SIZE + payload.len > max_packet_size) {
        std.log.warn("Lossy packet too large: {} bytes", .{payload.len});
        return;
    }
    buf[0] = @intFromEnum(Channel.lossy);
    buf[1] = protocol_id;
    @memcpy(buf[LOSSY_HEADER_SIZE..][0..payload.len], payload);
    socket.send(buf[0 .. LOSSY_HEADER_SIZE + payload.len], self.remote_address);
}

fn sendReliable(self: *Connection, socket: Socket, protocol_id: u8, payload: []const u8) void {
    const seq = self.next_send_seq.fetchAdd(1, .monotonic);

    var buf: [max_packet_size]u8 = undefined;
    if (RELIABLE_HEADER_SIZE + payload.len > max_packet_size) {
        std.log.warn("Reliable packet too large: {} bytes", .{payload.len});
        return;
    }
    buf[0] = @intFromEnum(Channel.reliable);
    std.mem.writeInt(u32, buf[1..5], seq, .little);
    buf[5] = protocol_id;
    @memcpy(buf[RELIABLE_HEADER_SIZE..][0..payload.len], payload);

    const packet_data = buf[0 .. RELIABLE_HEADER_SIZE + payload.len];
    socket.send(packet_data, self.remote_address);

    // Store for retransmission
    const data_copy = self.allocator.dupe(u8, packet_data) catch return;
    self.unconfirmed_mutex.lockUncancelable(io());
    defer self.unconfirmed_mutex.unlock(io());
    self.unconfirmed.append(self.allocator, .{
        .seq = seq,
        .data = data_copy,
        .send_time = milliTimestamp(),
    }) catch {
        self.allocator.free(data_copy);
    };
}

/// Send an acknowledgment for a reliable packet.
fn sendAck(self: *Connection, socket: Socket, seq: u32) void {
    var buf: [5]u8 = undefined;
    buf[0] = ACK_CHANNEL;
    std.mem.writeInt(u32, buf[1..5], seq, .little);
    socket.send(&buf, self.remote_address);
}

/// Process a received raw packet. Returns protocol data to dispatch, or null.
pub fn onReceive(self: *Connection, socket: Socket, data: []const u8) ?struct { protocol_id: u8, payload: []const u8 } {
    if (data.len < 1) return null;
    self.last_receive_time = milliTimestamp();

    const channel_byte = data[0];

    // Ack packet
    if (channel_byte == ACK_CHANNEL) {
        if (data.len < 5) return null;
        const ack_seq = std.mem.readInt(u32, data[1..5], .little);
        self.processAck(ack_seq);
        return null;
    }

    const channel: Channel = switch (channel_byte) {
        0 => .lossy,
        1 => .reliable,
        else => return null,
    };

    switch (channel) {
        .lossy => {
            if (data.len < LOSSY_HEADER_SIZE) return null;
            return .{
                .protocol_id = data[1],
                .payload = data[LOSSY_HEADER_SIZE..],
            };
        },
        .reliable => {
            if (data.len < RELIABLE_HEADER_SIZE) return null;
            const seq = std.mem.readInt(u32, data[1..5], .little);
            const protocol_id = data[5];
            const payload = data[RELIABLE_HEADER_SIZE..];

            // Always ack
            self.sendAck(socket, seq);

            const expected = self.next_recv_seq.load(.monotonic);
            if (seq == expected) {
                _ = self.next_recv_seq.fetchAdd(1, .monotonic);
                return .{
                    .protocol_id = protocol_id,
                    .payload = payload,
                };
            } else if (seq > expected and seq -% expected > 256) {
                // Too far ahead — reject to prevent unbounded buffer growth
                std.log.warn("Dropped packet seq {} (expected {}, window exceeded)", .{ seq, expected });
                return null;
            } else if (seq > expected) {
                // Future packet within window — buffer it
                self.recv_mutex.lockUncancelable(io());
                defer self.recv_mutex.unlock(io());
                const copy = self.allocator.dupe(u8, data) catch return null;
                self.recv_buffer.put(seq, copy) catch {
                    self.allocator.free(copy);
                };
                return null;
            } else {
                // Duplicate — already processed
                return null;
            }
        },
    }
}

fn processAck(self: *Connection, ack_seq: u32) void {
    self.unconfirmed_mutex.lockUncancelable(io());
    defer self.unconfirmed_mutex.unlock(io());

    var i: usize = 0;
    while (i < self.unconfirmed.items.len) {
        if (self.unconfirmed.items[i].seq == ack_seq) {
            self.allocator.free(self.unconfirmed.items[i].data);
            _ = self.unconfirmed.swapRemove(i);
            return;
        }
        i += 1;
    }
}

/// Retransmit unconfirmed reliable packets that have timed out.
pub fn retransmitTimedOut(self: *Connection, socket: Socket, timeout_ms: i64) void {
    const now = milliTimestamp();
    self.unconfirmed_mutex.lockUncancelable(io());
    defer self.unconfirmed_mutex.unlock(io());

    for (self.unconfirmed.items) |*pkt| {
        if (now - pkt.send_time > timeout_ms) {
            socket.send(pkt.data, self.remote_address);
            pkt.send_time = now;
            pkt.retransmit_count += 1;
        }
    }
}

/// Check if connection has timed out (no packets received for timeout_ms).
pub fn hasTimedOut(self: *const Connection, timeout_ms: i64) bool {
    return milliTimestamp() - self.last_receive_time > timeout_ms;
}

pub const BufferedPacket = struct {
    protocol_id: u8,
    payload: []const u8,
    raw_data: []const u8,
};

/// Pop the next consecutive buffered packet, if available.
/// Caller must free `raw_data` after processing.
pub fn popNextBuffered(self: *Connection) ?BufferedPacket {
    const expected = self.next_recv_seq.load(.monotonic);
    self.recv_mutex.lockUncancelable(io());
    const entry = self.recv_buffer.fetchRemove(expected);
    self.recv_mutex.unlock(io());

    const raw_data = (entry orelse return null).value;
    if (raw_data.len < RELIABLE_HEADER_SIZE) {
        self.allocator.free(raw_data);
        return null;
    }
    _ = self.next_recv_seq.fetchAdd(1, .monotonic);
    return .{
        .protocol_id = raw_data[5],
        .payload = raw_data[RELIABLE_HEADER_SIZE..],
        .raw_data = raw_data,
    };
}
