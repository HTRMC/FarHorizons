const std = @import("std");
const shared = @import("shared");
const glfw = @import("glfw");
const c = glfw.c;

const GameConfig = shared.GameConfig;
const Logger = shared.Logger;

pub const FarHorizonsClient = struct {
    const Self = @This();
    const logger = Logger.init("FarHorizonsClient");

    config: GameConfig,
    window: ?*c.GLFWwindow = null,

    pub fn init(config: GameConfig) Self {
        return Self{
            .config = config,
        };
    }

    fn glfwErrorCallback(error_code: c_int, description: [*c]const u8) callconv(.c) void {
        const desc = std.mem.span(description);
        logger.err("GLFW Error {}: {s}", .{ error_code, desc });
    }

    pub fn run(self: *Self) !void {
        logger.info("FarHorizons Client starting...", .{});
        logger.info("Game directory: {s}", .{self.config.location.game_directory});

        // Set error callback first
        _ = c.glfwSetErrorCallback(glfwErrorCallback);

        // Initialize GLFW
        if (c.glfwInit() == c.GLFW_FALSE) {
            logger.err("Failed to initialize GLFW", .{});
            return error.GLFWInitFailed;
        }
        defer c.glfwTerminate();

        logger.info("GLFW initialized successfully", .{});

        // Create window
        c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 3);
        c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 3);
        c.glfwWindowHint(c.GLFW_OPENGL_PROFILE, c.GLFW_OPENGL_CORE_PROFILE);

        self.window = c.glfwCreateWindow(
            @intCast(self.config.display.width),
            @intCast(self.config.display.height),
            "FarHorizons",
            null,
            null,
        );

        if (self.window == null) {
            logger.err("Failed to create GLFW window", .{});
            return error.WindowCreationFailed;
        }
        defer c.glfwDestroyWindow(self.window);

        logger.info("Window created: {}x{}", .{ self.config.display.width, self.config.display.height });

        c.glfwMakeContextCurrent(self.window);
        c.glfwSwapInterval(1); // VSync

        // Main loop
        logger.info("Entering main loop", .{});
        while (c.glfwWindowShouldClose(self.window) == c.GLFW_FALSE) {
            c.glfwPollEvents();

            // Check for escape key
            if (c.glfwGetKey(self.window, c.GLFW_KEY_ESCAPE) == c.GLFW_PRESS) {
                c.glfwSetWindowShouldClose(self.window, c.GLFW_TRUE);
            }

            c.glfwSwapBuffers(self.window);
        }

        logger.info("Main loop ended, shutting down", .{});
    }
};
