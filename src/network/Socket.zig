const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;

pub const Address = struct {
    ip: u32,
    port: u16,

    pub const localhost: u32 = 0x0100007f; // 127.0.0.1

    pub fn fromIpPort(ip: u32, port: u16) Address {
        return .{ .ip = ip, .port = port };
    }

    pub fn eql(self: Address, other: Address) bool {
        return self.ip == other.ip and self.port == other.port;
    }

    pub fn format(self: Address, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const ip = self.ip;
        try writer.print("{}.{}.{}.{}:{}", .{
            ip & 0xFF,
            (ip >> 8) & 0xFF,
            (ip >> 16) & 0xFF,
            (ip >> 24) & 0xFF,
            self.port,
        });
    }
};

const SocketId = if (builtin.os.tag == .windows) ws2.SOCKET else posix.socket_t;

pub const Socket = @This();

socket_id: SocketId,

const ws2 = if (builtin.os.tag == .windows) @cImport({
    @cInclude("winsock2.h");
}) else struct {};

fn windowsError(err: c_int) !void {
    if (err == 0) return;
    switch (err) {
        ws2.WSASYSNOTREADY => return error.NetworkDown,
        ws2.WSAVERNOTSUPPORTED => return error.VersionUnsupported,
        ws2.WSAEINPROGRESS => return error.BlockingOperationInProgress,
        ws2.WSAEPROCLIM => return error.ProcessFdQuotaExceeded,
        ws2.WSAENETDOWN => return error.NetworkDown,
        ws2.WSAEACCES => return error.AccessDenied,
        ws2.WSAEADDRINUSE => return error.AddressInUse,
        ws2.WSAEADDRNOTAVAIL => return error.AddressNotAvailable,
        ws2.WSAENOBUFS => return error.SystemResources,
        ws2.WSAENOTSOCK => return error.FileDescriptorNotASocket,
        ws2.WSAECONNRESET => return error.ConnectionReset,
        else => return error.Unexpected,
    }
}

pub fn startup() void {
    if (builtin.os.tag == .windows) {
        var data: ws2.WSADATA = undefined;
        windowsError(ws2.WSAStartup(0x0202, &data)) catch |err| {
            std.log.err("Could not initialize Windows Socket API: {s}", .{@errorName(err)});
            @panic("Could not init networking.");
        };
    }
}

pub fn cleanup() void {
    if (builtin.os.tag == .windows) {
        _ = ws2.WSACleanup();
    }
}

pub fn init(local_port: u16) !Socket {
    const self = Socket{
        .socket_id = blk: {
            if (builtin.os.tag == .windows) {
                const sock = ws2.socket(ws2.AF_INET, ws2.SOCK_DGRAM, ws2.IPPROTO_UDP);
                if (sock == ws2.INVALID_SOCKET) {
                    try windowsError(ws2.WSAGetLastError());
                    return error.Unexpected;
                }
                break :blk sock;
            } else {
                break :blk try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
            }
        },
    };
    errdefer self.deinit();

    const binding_addr = posix.sockaddr.in{
        .port = @byteSwap(local_port),
        .addr = 0,
    };
    if (builtin.os.tag == .windows) {
        if (ws2.bind(self.socket_id, @ptrCast(&binding_addr), @sizeOf(posix.sockaddr.in)) == ws2.SOCKET_ERROR) {
            try windowsError(ws2.WSAGetLastError());
        }
    } else {
        try posix.bind(self.socket_id, @ptrCast(&binding_addr), @sizeOf(posix.sockaddr.in));
    }
    return self;
}

pub fn deinit(self: Socket) void {
    if (builtin.os.tag == .windows) {
        _ = ws2.closesocket(self.socket_id);
    } else {
        posix.close(self.socket_id);
    }
}

pub fn send(self: Socket, data: []const u8, destination: Address) void {
    const addr = posix.sockaddr.in{
        .port = @byteSwap(destination.port),
        .addr = destination.ip,
    };
    if (builtin.os.tag == .windows) {
        const result = ws2.sendto(self.socket_id, data.ptr, @intCast(data.len), 0, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
        if (result == ws2.SOCKET_ERROR) {
            const err: anyerror = if (windowsError(ws2.WSAGetLastError())) error.Unexpected else |e| e;
            std.log.warn("Send error to {}: {s}", .{ destination, @errorName(err) });
        }
    } else {
        _ = posix.sendto(self.socket_id, data, 0, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) catch |err| {
            std.log.warn("Send error to {}: {s}", .{ destination, @errorName(err) });
        };
    }
}

pub fn receive(self: Socket, buffer: []u8, result_address: *Address) ![]u8 {
    if (builtin.os.tag == .windows) {
        var pfd = [1]ws2.pollfd{
            .{ .fd = self.socket_id, .events = std.c.POLL.RDNORM | std.c.POLL.RDBAND, .revents = undefined },
        };
        const length = ws2.WSAPoll(&pfd, pfd.len, 1);
        if (length == ws2.SOCKET_ERROR) {
            try windowsError(ws2.WSAGetLastError());
        } else if (length == 0) {
            return error.Timeout;
        }
    } else {
        var pfd = [1]posix.pollfd{
            .{ .fd = self.socket_id, .events = posix.POLL.IN, .revents = undefined },
        };
        const length = try posix.poll(&pfd, 1);
        if (length == 0) return error.Timeout;
    }

    var addr: posix.sockaddr.in = undefined;
    const length: usize = blk: {
        if (builtin.os.tag == .windows) {
            var addr_len: c_int = @sizeOf(posix.sockaddr.in);
            const result = ws2.recvfrom(self.socket_id, buffer.ptr, @intCast(buffer.len), 0, @ptrCast(&addr), &addr_len);
            if (result == ws2.SOCKET_ERROR) {
                try windowsError(ws2.WSAGetLastError());
                return error.Unexpected;
            }
            break :blk @intCast(result);
        } else {
            var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
            break :blk try posix.recvfrom(self.socket_id, buffer, 0, @ptrCast(&addr), &addr_len);
        }
    };
    result_address.ip = addr.addr;
    result_address.port = @byteSwap(addr.port);
    return buffer[0..length];
}

pub fn getPort(self: Socket) !u16 {
    var addr: posix.sockaddr.in = undefined;
    if (builtin.os.tag == .windows) {
        var addr_len: c_int = @sizeOf(posix.sockaddr.in);
        if (ws2.getsockname(self.socket_id, @ptrCast(&addr), &addr_len) == ws2.SOCKET_ERROR) {
            try windowsError(ws2.WSAGetLastError());
        }
    } else {
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        try posix.getsockname(self.socket_id, @ptrCast(&addr), &addr_len);
    }
    return @byteSwap(addr.port);
}

pub fn resolveIp(name: []const u8) !u32 {
    // Try parsing as dotted-quad first
    if (parseIpv4(name)) |ip| return ip;

    // Fall back to DNS lookup
    var name_buf: [255]u8 = undefined;
    var buf: [16]std.Io.net.HostName.LookupResult = undefined;
    var result_queue = std.Io.Queue(std.Io.net.HostName.LookupResult).init(&buf);
    if (name.len == 0) return error.UnknownHostName;

    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.net.HostName.lookup(.{ .bytes = name }, io, &result_queue, .{ .canonical_name_buffer = &name_buf, .port = 0 });
    while (true) {
        const entry = result_queue.getOneUncancelable(io) catch break;
        switch (entry) {
            .address => |addr| {
                if (addr != .ip4) continue;
                return std.mem.bytesToValue(u32, addr.ip4.bytes[0..4]);
            },
            .canonical_name => {},
        }
    }
    return error.UnknownHostName;
}

fn parseIpv4(s: []const u8) ?u32 {
    var result: u32 = 0;
    var octet: u8 = 0;
    var octet_count: u8 = 0;
    var digit_count: u8 = 0;

    for (s) |c| {
        if (c == '.') {
            if (digit_count == 0 or octet_count >= 3) return null;
            result |= @as(u32, octet) << @intCast(octet_count * 8);
            octet = 0;
            octet_count += 1;
            digit_count = 0;
        } else if (c >= '0' and c <= '9') {
            const new = @as(u16, octet) * 10 + (c - '0');
            if (new > 255) return null;
            octet = @intCast(new);
            digit_count += 1;
        } else {
            return null;
        }
    }
    if (digit_count == 0 or octet_count != 3) return null;
    result |= @as(u32, octet) << 24;
    return result;
}
