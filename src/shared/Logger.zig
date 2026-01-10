const std = @import("std");
const builtin = @import("builtin");

pub const Level = enum {
    debug,
    info,
    warn,
    err,
    fatal,

    pub fn toString(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
            .fatal => "FATAL",
        };
    }
};

/// Get current Unix timestamp in seconds (cross-platform)
fn getTimestamp() i64 {
    if (builtin.os.tag == .windows) {
        // RtlGetSystemTimePrecise returns 100ns intervals since Windows epoch (1601-01-01)
        const windows_time = std.os.windows.ntdll.RtlGetSystemTimePrecise();
        const epoch_offset = std.time.epoch.windows * std.time.ns_per_s;
        const ns: i96 = @as(i96, windows_time) * 100 + epoch_offset;
        return @intCast(@divTrunc(ns, std.time.ns_per_s));
    } else {
        // POSIX: use clock_gettime with CLOCK_REALTIME
        const ts = std.posix.clock_gettime(.REALTIME) catch return 0;
        return ts.sec;
    }
}

pub const Logger = struct {
    const Self = @This();

    name: []const u8,
    min_level: Level = .info,

    pub fn init(name: []const u8) Self {
        return Self{
            .name = name,
        };
    }

    /// Create a logger scoped to a type, automatically using the type name
    /// Usage: `const logger = Logger.scoped(@This());`
    pub fn scoped(comptime T: type) Self {
        return Self{
            .name = typeName(T),
        };
    }

    /// Extract just the struct name from a fully qualified type name
    /// e.g., "client.BlockInteraction.BlockInteraction" -> "BlockInteraction"
    fn typeName(comptime T: type) []const u8 {
        const full_name = @typeName(T);
        // Find the last '.' to get just the type name
        var i: usize = full_name.len;
        while (i > 0) {
            i -= 1;
            if (full_name[i] == '.') {
                return full_name[i + 1 ..];
            }
        }
        return full_name;
    }

    pub fn debug(self: Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args);
    }

    pub fn info(self: Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }

    pub fn warn(self: Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }

    pub fn err(self: Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args);
    }

    pub fn fatal(self: Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.fatal, fmt, args);
    }

    fn log(self: Self, level: Level, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(level) < @intFromEnum(self.min_level)) return;

        const timestamp = getTimestamp();
        const hours: u64 = @intCast(@mod(@divTrunc(timestamp, 3600), 24));
        const minutes: u64 = @intCast(@mod(@divTrunc(timestamp, 60), 60));
        const seconds: u64 = @intCast(@mod(timestamp, 60));

        std.debug.print("[{d:0>2}:{d:0>2}:{d:0>2}] [{s}] [{s}]: " ++ fmt ++ "\n", .{
            hours,
            minutes,
            seconds,
            level.toString(),
            self.name,
        } ++ args);
    }
};
