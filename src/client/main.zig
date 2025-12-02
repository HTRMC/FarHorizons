const std = @import("std");
const shared = @import("shared");
const Logger = shared.Logger;
const FarHorizonsClient = @import("farhorizonsclient.zig").FarHorizonsClient;

pub const Main = struct {
    const Self = @This();
    const logger = Logger.init("Main");

    pub fn init() Self {
        return Self{};
    }

    pub fn run() !void {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        var args = try std.process.argsWithAllocator(allocator);
        defer args.deinit();

        logger.info("Starting FarHorizons Client", .{});

        // TODO: Parse arguments here
        // Minecraft uses OptionParser for --version, --demo, --server, etc.

        var client = FarHorizonsClient.init();
        try client.run();
    }
};

pub fn main() !void {
    try Main.run();
}
