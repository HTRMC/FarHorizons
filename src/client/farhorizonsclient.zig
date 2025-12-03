// FarHorizons Client - main client orchestration

const std = @import("std");
const shared = @import("shared");
const platform = @import("platform");
const renderer = @import("renderer");

const GameConfig = shared.GameConfig;
const Logger = shared.Logger;
const Window = platform.Window;
const DisplayData = platform.DisplayData;
const MouseHandler = platform.MouseHandler;
const InputConstants = platform.InputConstants;
const RenderSystem = renderer.RenderSystem;

pub const FarHorizonsClient = struct {
    const Self = @This();
    const logger = Logger.init("FarHorizonsClient");

    config: GameConfig,
    window: Window,
    mouse_handler: MouseHandler,
    render_system: RenderSystem,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: GameConfig) Self {
        const display_data = DisplayData{
            .width = @intCast(config.display.width),
            .height = @intCast(config.display.height),
            .fullscreen = config.display.fullscreen,
        };

        return Self{
            .config = config,
            .window = Window.init(display_data),
            .mouse_handler = undefined, // Initialized in run() after struct is at final location
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

        // Initialize mouse handler (must be done here after struct is at final location)
        self.mouse_handler = MouseHandler.init(&self.window);
        self.mouse_handler.setup();

        // Initialize render system (Vulkan) with window for surface
        try self.render_system.initBackend(&self.window);
        defer self.render_system.shutdown();

        // Render first frame before showing window (avoids white flash)
        self.render_system.drawFrame() catch {};
        self.window.show();

        // Track ESC key state for edge detection
        var esc_was_pressed = false;

        // Main loop
        logger.info("Entering main loop", .{});
        while (!self.window.shouldClose()) {
            platform.pollEvents();

            // Check for escape key (edge detection - only trigger on press, not hold)
            const esc_pressed = self.window.isKeyPressed(InputConstants.KEY_ESCAPE);
            if (esc_pressed and !esc_was_pressed) {
                if (self.mouse_handler.isMouseGrabbed()) {
                    // Release mouse when ESC is pressed (like Minecraft pause menu)
                    self.mouse_handler.releaseMouse();
                } else {
                    // Close window if mouse is already released
                    self.window.setShouldClose(true);
                }
            }
            esc_was_pressed = esc_pressed;

            // Handle mouse movement for camera (when grabbed)
            if (self.mouse_handler.isMouseGrabbed()) {
                const rotation = self.mouse_handler.getCameraRotation();
                // TODO: Apply rotation to camera
                _ = rotation;
            }

            // Render frame
            self.render_system.drawFrame() catch |err| {
                logger.err("Failed to draw frame: {}", .{err});
            };
        }

        logger.info("Main loop ended, shutting down", .{});
    }
};
