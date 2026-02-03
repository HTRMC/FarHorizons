const std = @import("std");
const shared = @import("Shared");
const Logger = shared.Logger;
const FarHorizonsServer = @import("FarHorizonsServer.zig").FarHorizonsServer;

pub const Main = struct {
    const Self = @This();
    const logger = Logger.scoped(Self);

    pub fn init() Self {
        return Self{};
    }

    pub fn run() !void {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        const cmd_line = std.os.windows.peb().ProcessParameters.CommandLine;
        const cmd_line_slice = cmd_line.Buffer.?[0 .. cmd_line.Length / 2];
        var args = try std.process.Args.Iterator.initAllocator(.{ .vector = cmd_line_slice }, allocator);
        defer args.deinit();

        logger.info("Starting FarHorizons Server", .{});

        // TODO: Parse arguments here (--port, --world, --nogui, etc.)

        var server = FarHorizonsServer.init();
        try server.run();
    }
};

pub fn main() !void {
    try Main.run();
}
