const std = @import("std");

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

pub const Logger = struct {
    const Self = @This();

    name: []const u8,
    min_level: Level = .info,

    pub fn init(name: []const u8) Self {
        return Self{
            .name = name,
        };
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

        const timestamp = std.time.timestamp();
        const hours: u64 = @mod(@divTrunc(timestamp, 3600), 24);
        const minutes: u64 = @mod(@divTrunc(timestamp, 60), 60);
        const seconds: u64 = @mod(timestamp, 60);

        std.debug.print("[{d:0>2}:{d:0>2}:{d:0>2}] [{s}] [{s}]: " ++ fmt ++ "\n", .{
            hours,
            minutes,
            seconds,
            level.toString(),
            self.name,
        } ++ args);
    }
};
