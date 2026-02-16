const std = @import("std");
const glfw = @import("glfw");

pub const Window = struct {
    handle: *glfw.Window,

    pub const Config = struct {
        width: u32 = 1280,
        height: u32 = 720,
        title: [:0]const u8 = "FarHorizons",
    };

    pub fn init(config: Config) !Window {
        if (glfw.init() == glfw.GLFW_FALSE) {
            return error.GLFWInitFailed;
        }

        glfw.windowHint(glfw.GLFW_CLIENT_API, glfw.GLFW_NO_API);
        glfw.windowHint(glfw.GLFW_RESIZABLE, glfw.GLFW_TRUE);

        const handle = glfw.createWindow(
            @intCast(config.width),
            @intCast(config.height),
            config.title.ptr,
            null,
            null,
        ) orelse return error.WindowCreationFailed;

        std.log.info("Window created: {s} ({}x{})", .{ config.title, config.width, config.height });

        return Window{ .handle = handle };
    }

    pub fn deinit(self: *Window) void {
        glfw.destroyWindow(self.handle);
        glfw.terminate();
        std.log.info("Window destroyed", .{});
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
};
