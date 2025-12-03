// Window management using GLFW

const std = @import("std");
const glfw = @import("glfw");
const c = glfw.c;
const shared = @import("shared");
const Logger = shared.Logger;
const DisplayData = @import("display_data.zig").DisplayData;

// Vulkan types for surface creation
pub const VkInstance = ?*opaque {};
pub const VkSurfaceKHR = ?*opaque {};
pub const VkResult = i32;
pub const VK_SUCCESS: VkResult = 0;

extern fn glfwCreateWindowSurface(instance: VkInstance, window: ?*c.GLFWwindow, allocator: ?*anyopaque, surface: *VkSurfaceKHR) callconv(.c) VkResult;

pub const Window = struct {
    const Self = @This();
    const logger = Logger.init("Window");

    handle: ?*c.GLFWwindow = null,
    width: u32,
    height: u32,
    framebuffer_width: u32 = 0,
    framebuffer_height: u32 = 0,
    framebuffer_resized: bool = false,
    fullscreen: bool,
    vsync: bool,

    pub fn init(display_data: DisplayData) Self {
        return .{
            .width = display_data.width,
            .height = display_data.height,
            .fullscreen = display_data.fullscreen,
            .vsync = display_data.vsync,
        };
    }

    pub fn create(self: *Self, title: [*:0]const u8) !void {
        // No OpenGL context for Vulkan
        c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
        c.glfwWindowHint(c.GLFW_RESIZABLE, c.GLFW_TRUE);
        // Hide window initially to avoid white flash during Vulkan init
        c.glfwWindowHint(c.GLFW_VISIBLE, c.GLFW_FALSE);

        const monitor: ?*c.GLFWmonitor = if (self.fullscreen) c.glfwGetPrimaryMonitor() else null;

        self.handle = c.glfwCreateWindow(
            @intCast(self.width),
            @intCast(self.height),
            title,
            monitor,
            null,
        );

        if (self.handle == null) {
            logger.err("Failed to create GLFW window", .{});
            return error.WindowCreationFailed;
        }

        // Get actual framebuffer size (may differ on high-DPI displays)
        var fb_width: c_int = 0;
        var fb_height: c_int = 0;
        c.glfwGetFramebufferSize(self.handle, &fb_width, &fb_height);
        self.framebuffer_width = @intCast(fb_width);
        self.framebuffer_height = @intCast(fb_height);

        // Center window on primary monitor (only for windowed mode)
        if (!self.fullscreen) {
            const primary_monitor = c.glfwGetPrimaryMonitor();
            if (primary_monitor) |mon| {
                const vidmode = c.glfwGetVideoMode(mon);
                if (vidmode) |mode| {
                    const x = @divTrunc(mode.*.width - @as(c_int, @intCast(self.width)), 2);
                    const y = @divTrunc(mode.*.height - @as(c_int, @intCast(self.height)), 2);
                    c.glfwSetWindowPos(self.handle, x, y);
                }
            }
        }

        // Set up framebuffer resize callback
        c.glfwSetWindowUserPointer(self.handle, self);
        _ = c.glfwSetFramebufferSizeCallback(self.handle, framebufferSizeCallback);

        logger.info("Window created: {}x{} (framebuffer: {}x{})", .{
            self.width,
            self.height,
            self.framebuffer_width,
            self.framebuffer_height,
        });
    }

    fn framebufferSizeCallback(window: ?*c.GLFWwindow, width: c_int, height: c_int) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window)));
        self.framebuffer_width = @intCast(width);
        self.framebuffer_height = @intCast(height);
        self.framebuffer_resized = true;
    }

    pub fn destroy(self: *Self) void {
        if (self.handle) |h| {
            c.glfwDestroyWindow(h);
            self.handle = null;
            logger.info("Window destroyed", .{});
        }
    }

    pub fn shouldClose(self: *const Self) bool {
        if (self.handle) |h| {
            return c.glfwWindowShouldClose(h) == c.GLFW_TRUE;
        }
        return true;
    }

    pub fn setShouldClose(self: *Self, value: bool) void {
        if (self.handle) |h| {
            c.glfwSetWindowShouldClose(h, if (value) c.GLFW_TRUE else c.GLFW_FALSE);
        }
    }

    pub fn show(self: *Self) void {
        if (self.handle) |h| {
            c.glfwShowWindow(h);
        }
    }

    pub fn isKeyPressed(self: *const Self, key: c_int) bool {
        if (self.handle) |h| {
            return c.glfwGetKey(h, key) == c.GLFW_PRESS;
        }
        return false;
    }

    pub fn getHandle(self: *const Self) ?*c.GLFWwindow {
        return self.handle;
    }

    pub fn getWidth(self: *const Self) u32 {
        return self.width;
    }

    pub fn getHeight(self: *const Self) u32 {
        return self.height;
    }

    pub fn getFramebufferWidth(self: *const Self) u32 {
        return self.framebuffer_width;
    }

    pub fn getFramebufferHeight(self: *const Self) u32 {
        return self.framebuffer_height;
    }

    pub fn wasResized(self: *Self) bool {
        const resized = self.framebuffer_resized;
        self.framebuffer_resized = false;
        return resized;
    }

    pub fn waitIfMinimized(self: *Self) void {
        var width: c_int = 0;
        var height: c_int = 0;
        c.glfwGetFramebufferSize(self.handle, &width, &height);
        while (width == 0 or height == 0) {
            c.glfwGetFramebufferSize(self.handle, &width, &height);
            c.glfwWaitEvents();
        }
        self.framebuffer_width = @intCast(width);
        self.framebuffer_height = @intCast(height);
    }

    /// Create a Vulkan surface for this window
    pub fn createSurface(self: *const Self, instance: VkInstance) !VkSurfaceKHR {
        var surface: VkSurfaceKHR = null;
        const result = glfwCreateWindowSurface(instance, self.handle, null, &surface);
        if (result != VK_SUCCESS) {
            logger.err("Failed to create Vulkan surface: {}", .{result});
            return error.SurfaceCreationFailed;
        }
        logger.info("Vulkan surface created", .{});
        return surface;
    }
};

/// Initialize the GLFW backend system
/// Must be called before creating any windows
pub fn initBackend() !void {
    const logger = Logger.init("Window");

    _ = c.glfwSetErrorCallback(glfwErrorCallback);

    if (c.glfwInit() == c.GLFW_FALSE) {
        logger.err("Failed to initialize GLFW", .{});
        return error.GLFWInitFailed;
    }

    logger.info("GLFW initialized successfully", .{});
}

/// Terminate the GLFW backend system
pub fn terminateBackend() void {
    c.glfwTerminate();
    const logger = Logger.init("Window");
    logger.info("GLFW terminated", .{});
}

/// Check if Vulkan is supported
pub fn isVulkanSupported() bool {
    return c.glfwVulkanSupported() == c.GLFW_TRUE;
}

/// Get required Vulkan instance extensions for surface creation
pub fn getRequiredVulkanExtensions() ?struct { extensions: [*c][*c]const u8, count: u32 } {
    var count: u32 = 0;
    const extensions = c.glfwGetRequiredInstanceExtensions(&count);
    if (extensions == null) {
        return null;
    }
    return .{ .extensions = extensions, .count = count };
}

/// Poll for window events
pub fn pollEvents() void {
    c.glfwPollEvents();
}

fn glfwErrorCallback(error_code: c_int, description: [*c]const u8) callconv(.c) void {
    const logger = Logger.init("Window");
    const desc = std.mem.span(description);
    logger.err("GLFW Error {}: {s}", .{ error_code, desc });
}
