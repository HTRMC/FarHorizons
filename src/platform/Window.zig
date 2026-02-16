const std = @import("std");
const glfw = @import("glfw.zig");
const vk = @import("volk.zig");

var glfw_init_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

pub const Window = struct {
    handle: *glfw.Window,

    pub const Config = struct {
        width: u32 = 1280,
        height: u32 = 720,
        title: [:0]const u8 = "FarHorizons",
    };

    pub fn init(config: Config) !Window {
        const prev_count = glfw_init_count.fetchAdd(1, .monotonic);
        errdefer _ = glfw_init_count.fetchSub(1, .monotonic);

        if (prev_count == 0) {
            try glfw.init();
            std.log.info("GLFW initialized", .{});
        }

        glfw.windowHint(glfw.GLFW_CLIENT_API, glfw.GLFW_NO_API);
        glfw.windowHint(glfw.GLFW_RESIZABLE, glfw.GLFW_TRUE);

        const handle = try glfw.createWindow(
            @intCast(config.width),
            @intCast(config.height),
            config.title.ptr,
            null,
            null,
        );

        std.log.info("Window created: {s} ({}x{})", .{ config.title, config.width, config.height });

        return Window{ .handle = handle };
    }

    pub fn deinit(self: *Window) void {
        glfw.destroyWindow(self.handle);
        std.log.info("Window destroyed", .{});

        const prev_count = glfw_init_count.fetchSub(1, .monotonic);
        if (prev_count == 1) {
            glfw.terminate();
            std.log.info("GLFW terminated", .{});
        }
    }

    pub fn shouldClose(self: *const Window) bool {
        return glfw.windowShouldClose(self.handle) == glfw.GLFW_TRUE;
    }

    pub fn pollEvents(_: *Window) void {
        glfw.pollEvents();
    }

    pub fn getFramebufferSize(self: *const Window) struct { width: u32, height: u32 } {
        var width: c_int = 0;
        var height: c_int = 0;
        glfw.getFramebufferSize(self.handle, &width, &height);
        return .{ .width = @intCast(width), .height = @intCast(height) };
    }

    pub fn createSurface(self: *const Window, instance: anytype, allocator: ?*const anyopaque) !vk.VkSurfaceKHR {
        var surface: vk.VkSurfaceKHR = null;
        try glfw.createWindowSurface(instance, self.handle, allocator, &surface);
        return surface;
    }

    pub fn getRequiredExtensions() [*]const [*:0]const u8 {
        var count: u32 = 0;
        // Safe: called after GLFW init in VulkanRenderer
        return glfw.getRequiredInstanceExtensions(&count) orelse unreachable;
    }
};
