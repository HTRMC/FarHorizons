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
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: GameConfig) Self {
        const display_data = DisplayData{
            .width = @intCast(config.display.width),
            .height = @intCast(config.display.height),
            .fullscreen = config.display.fullscreen,
        };

        return .{
            .config = config,
            .window = Window.init(display_data),
            .render_system = RenderSystem.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn run(self: *Self) !void {
        logger.info("FarHorizons Client starting...", .{});
        logger.info("Game directory: {s}", .{self.config.location.game_directory});

        // Initialize platform backend (GLFW)
        try platform.initBackend();
        defer platform.terminateBackend();

        // Create window first (needed for surface creation)
        try self.window.create("FarHorizons");
        defer self.window.destroy();

        // Initialize render system (Vulkan) with window for surface
        try self.render_system.initBackend(&self.window);
        defer self.render_system.shutdown();

        // Render first frame before showing window (avoids white flash)
        self.render_system.drawFrame() catch {};
        self.window.show();

        // Main loop
        logger.info("Entering main loop", .{});
        while (!self.window.shouldClose()) {
            platform.pollEvents();

            // Check for escape key
            if (self.window.isKeyPressed(glfw.c.GLFW_KEY_ESCAPE)) {
                self.window.setShouldClose(true);
            }

            // Render frame
            self.render_system.drawFrame() catch |err| {
                logger.err("Failed to draw frame: {}", .{err});
            };
        }

        logger.info("Main loop ended, shutting down", .{});
    }
};
