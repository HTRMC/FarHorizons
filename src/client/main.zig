const std = @import("std");
const FarHorizonsClient = @import("farhorizonsclient.zig").FarHorizonsClient;

pub const Main = struct {
    const Self = @This();

    pub fn init() Self {
        return Self{};
    }

    pub fn run() !void {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        var args = try std.process.argsWithAllocator(allocator);
        defer args.deinit();

        std.debug.print("Arguments:\n", .{});
        var i: usize = 0;
        while (args.next()) |arg| {
            std.debug.print("  [{d}] {s}\n", .{ i, arg });
            i += 1;
        }

        // TODO: Parse arguments here
        // Minecraft uses OptionParser for --version, --demo, --server, etc.

        var client = FarHorizonsClient.init();
        try client.run();
    }
};

pub fn main() !void {
    try Main.run();
}
