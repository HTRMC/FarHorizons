const std = @import("std");
const shared = @import("shared");
const glfw = @import("glfw");
const volk = @import("volk");
const c = glfw.c;
const vk = volk.c;

const GameConfig = shared.GameConfig;
const Logger = shared.Logger;

pub const FarHorizonsClient = struct {
    const Self = @This();
    const logger = Logger.init("FarHorizonsClient");

    config: GameConfig,
    window: ?*c.GLFWwindow = null,
    vk_instance: vk.VkInstance = null,

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

        // Check Vulkan support
        if (c.glfwVulkanSupported() == c.GLFW_FALSE) {
            logger.err("Vulkan is not supported on this system", .{});
            return error.VulkanNotSupported;
        }

        // Initialize volk (Vulkan loader)
        volk.init() catch {
            logger.err("Failed to initialize Vulkan loader", .{});
            return error.VulkanLoaderFailed;
        };

        const vk_version = volk.getInstanceVersion();
        logger.info("Vulkan instance version: {}.{}.{}", .{
            (vk_version >> 22) & 0x7F,
            (vk_version >> 12) & 0x3FF,
            vk_version & 0xFFF,
        });

        // Create Vulkan instance
        try self.createVulkanInstance();
        defer self.destroyVulkanInstance();

        // Create window (no OpenGL context for Vulkan)
        c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
        c.glfwWindowHint(c.GLFW_RESIZABLE, c.GLFW_FALSE);

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

        // Main loop
        logger.info("Entering main loop", .{});
        while (c.glfwWindowShouldClose(self.window) == c.GLFW_FALSE) {
            c.glfwPollEvents();

            // Check for escape key
            if (c.glfwGetKey(self.window, c.GLFW_KEY_ESCAPE) == c.GLFW_PRESS) {
                c.glfwSetWindowShouldClose(self.window, c.GLFW_TRUE);
            }

            // TODO: Render frame with Vulkan
        }

        logger.info("Main loop ended, shutting down", .{});
    }

    fn createVulkanInstance(self: *Self) !void {
        // Get required GLFW extensions
        var glfw_extension_count: u32 = 0;
        const glfw_extensions = c.glfwGetRequiredInstanceExtensions(&glfw_extension_count);

        if (glfw_extensions == null) {
            logger.err("Failed to get required Vulkan extensions from GLFW", .{});
            return error.VulkanExtensionsFailed;
        }

        logger.info("Required GLFW extensions: {}", .{glfw_extension_count});

        const app_info = vk.VkApplicationInfo{
            .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pNext = null,
            .pApplicationName = "FarHorizons",
            .applicationVersion = vk.VK_MAKE_VERSION(0, 0, 1),
            .pEngineName = "FarHorizons Engine",
            .engineVersion = vk.VK_MAKE_VERSION(0, 0, 1),
            .apiVersion = vk.VK_API_VERSION_1_0,
        };

        const create_info = vk.VkInstanceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .pApplicationInfo = &app_info,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = glfw_extension_count,
            .ppEnabledExtensionNames = glfw_extensions,
        };

        const vkCreateInstance = vk.vkCreateInstance orelse {
            logger.err("vkCreateInstance not loaded", .{});
            return error.VulkanFunctionNotLoaded;
        };

        const result = vkCreateInstance(&create_info, null, &self.vk_instance);
        if (result != vk.VK_SUCCESS) {
            logger.err("Failed to create Vulkan instance: {}", .{result});
            return error.VulkanInstanceFailed;
        }

        // Load instance-level Vulkan functions
        volk.loadInstance(self.vk_instance);

        logger.info("Vulkan instance created successfully", .{});
    }

    fn destroyVulkanInstance(self: *Self) void {
        if (self.vk_instance) |instance| {
            if (vk.vkDestroyInstance) |destroy| {
                destroy(instance, null);
            }
            self.vk_instance = null;
        }
    }
};
