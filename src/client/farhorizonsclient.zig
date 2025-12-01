const std = @import("std");

pub const FarHorizonsClient = struct {
    const Self = @This();

    pub fn init() Self {
        return Self{};
    }

    pub fn run(self: *Self) !void {
        _ = self;
        std.debug.print("FarHorizons Client starting...\n", .{});
    }
};
