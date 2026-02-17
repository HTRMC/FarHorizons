const std = @import("std");
const glfw = @import("glfw.zig");
const vk = @import("volk.zig");

var glfw_init_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

pub const Window = struct {
    handle: *glfw.Window,
    windowed_x: c_int = 0,
    windowed_y: c_int = 0,
    windowed_width: c_int = 0,
    windowed_height: c_int = 0,

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
            std.math.cast(c_int, config.width) orelse unreachable,
            std.math.cast(c_int, config.height) orelse unreachable,
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
        return .{ .width = std.math.cast(u32, width) orelse unreachable, .height = std.math.cast(u32, height) orelse unreachable };
    }

    pub fn createSurface(self: *const Window, instance: anytype, allocator: ?*const anyopaque) !vk.VkSurfaceKHR {
        var surface: vk.VkSurfaceKHR = null;
        try glfw.createWindowSurface(instance, self.handle, allocator, &surface);
        return surface;
    }

    pub fn toggleFullscreen(self: *Window) void {
        if (glfw.getWindowMonitor(self.handle) == null) {
            // Currently windowed -> go fullscreen
            glfw.getWindowPos(self.handle, &self.windowed_x, &self.windowed_y);
            glfw.getWindowSize(self.handle, &self.windowed_width, &self.windowed_height);

            const monitor = glfw.getPrimaryMonitor() orelse return;
            const mode = glfw.getVideoMode(monitor);
            glfw.setWindowMonitor(self.handle, monitor, 0, 0, mode.width, mode.height, mode.refreshRate);
        } else {
            // Currently fullscreen -> go windowed
            glfw.setWindowMonitor(
                self.handle,
                null,
                self.windowed_x,
                self.windowed_y,
                self.windowed_width,
                self.windowed_height,
                0,
            );
        }
    }

    pub const Extensions = struct {
        names: [*]const [*:0]const u8,
        count: u32,
    };

    pub fn getRequiredExtensions() Extensions {
        var count: u32 = 0;
        const names = glfw.getRequiredInstanceExtensions(&count) orelse unreachable;
        return .{ .names = names, .count = count };
    }
};
