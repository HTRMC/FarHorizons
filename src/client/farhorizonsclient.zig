const std = @import("std");
const shared = @import("shared");
const GameConfig = shared.GameConfig;
const Logger = shared.Logger;

pub const FarHorizonsClient = struct {
    const Self = @This();
    const logger = Logger.init("FarHorizonsClient");

    config: GameConfig,

    pub fn init(config: GameConfig) Self {
        return Self{
            .config = config,
        };
    }

    pub fn run(self: *Self) !void {
        logger.info("FarHorizons Client starting...", .{});
        logger.info("Game directory: {s}", .{self.config.location.game_directory});
    }
};
