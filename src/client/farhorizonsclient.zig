// FarHorizons Client - main client orchestration

const std = @import("std");
const shared = @import("shared");
const platform = @import("platform");
const renderer = @import("renderer");
const glfw = @import("glfw");

const GameConfig = shared.GameConfig;
const Logger = shared.Logger;
const Window = platform.Window;
const DisplayData = platform.DisplayData;
const RenderSystem = renderer.RenderSystem;

pub const FarHorizonsClient = struct {
    const Self = @This();
    const logger = Logger.init("FarHorizonsClient");

    config: GameConfig,
    window: Window,
    render_system: RenderSystem,

    pub fn init(config: GameConfig) Self {
        const display_data = DisplayData{
            .width = @intCast(config.display.width),
            .height = @intCast(config.display.height),
            .fullscreen = config.display.fullscreen,
        };

        return .{
            .config = config,
            .window = Window.init(display_data),
            .render_system = RenderSystem.init(),
        };
    }

    pub fn run(self: *Self) !void {
        logger.info("FarHorizons Client starting...", .{});
        logger.info("Game directory: {s}", .{self.config.location.game_directory});

        // Initialize platform backend (GLFW)
        try platform.initBackend();
        defer platform.terminateBackend();

        // Initialize render system (Vulkan)
        try self.render_system.initBackend();
        defer self.render_system.shutdown();

        // Create window
        try self.window.create("FarHorizons");
        defer self.window.destroy();

        // Main loop
        logger.info("Entering main loop", .{});
        while (!self.window.shouldClose()) {
            platform.pollEvents();

            // Check for escape key
            if (self.window.isKeyPressed(glfw.c.GLFW_KEY_ESCAPE)) {
                self.window.setShouldClose(true);
            }

            // TODO: Render frame with Vulkan
        }

        logger.info("Main loop ended, shutting down", .{});
    }
};
