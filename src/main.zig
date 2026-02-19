const std = @import("std");
const Window = @import("platform/Window.zig").Window;
const Renderer = @import("renderer/Renderer.zig").Renderer;
const VulkanRenderer = @import("renderer/vulkan/VulkanRenderer.zig").VulkanRenderer;
const GameState = @import("GameState.zig");
const glfw = @import("platform/glfw.zig");
const tracy = @import("platform/tracy.zig");

const InputState = struct {
    scroll_delta: f32 = 0.0,
    window: *Window,
    framebuffer_resized: *bool,
};

fn scrollCallback(window: ?*glfw.Window, xoffset: f64, yoffset: f64) callconv(.c) void {
    _ = xoffset;
    const input_state = glfw.getWindowUserPointer(window.?, InputState) orelse return;
    input_state.scroll_delta += @floatCast(yoffset);
}

fn keyCallback(window: ?*glfw.Window, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
    _ = scancode;
    _ = mods;
    if (key == glfw.GLFW_KEY_F11 and action == glfw.GLFW_RELEASE) {
        const input_state = glfw.getWindowUserPointer(window.?, InputState) orelse return;
        input_state.window.toggleFullscreen();
    }
}

fn framebufferSizeCallback(window: ?*glfw.Window, width: c_int, height: c_int) callconv(.c) void {
    _ = width;
    _ = height;
    const input_state = glfw.getWindowUserPointer(window.?, InputState) orelse return;
    input_state.framebuffer_resized.* = true;
}

pub fn main() !void {
    tracy.waitForConnection();

    const tz = tracy.zone(@src(), "main");
    defer tz.end();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var window = try Window.init(.{
        .width = 1280,
        .height = 720,
        .title = "FarHorizons 0.0.0",
    });
    defer window.deinit();

    var game_state = GameState.init(1280, 720);

    var renderer = try Renderer.init(allocator, &window, &VulkanRenderer.vtable, @ptrCast(&game_state));
    defer renderer.deinit();

    const framebuffer_resized = renderer.getFramebufferResizedPtr();

    var input_state = InputState{
        .window = &window,
        .framebuffer_resized = framebuffer_resized,
    };
    glfw.setWindowUserPointer(window.handle, &input_state);
    glfw.setScrollCallback(window.handle, scrollCallback);
    glfw.setKeyCallback(window.handle, keyCallback);
    glfw.setFramebufferSizeCallback(window.handle, framebufferSizeCallback);

    std.log.info("Entering main loop...", .{});

    const rotation_speed: f32 = 2.0; // radians per second
    const zoom_speed: f32 = 5.0; // units per second
    var last_time = glfw.getTime();

    while (!window.shouldClose()) {
        window.pollEvents();

        const current_time = glfw.getTime();
        const delta_time: f32 = @floatCast(current_time - last_time);
        last_time = current_time;

        // Handle keyboard input for camera rotation
        var delta_azimuth: f32 = 0.0;
        var delta_elevation: f32 = 0.0;

        if (glfw.getKey(window.handle, glfw.GLFW_KEY_LEFT) == glfw.GLFW_PRESS) {
            delta_azimuth -= rotation_speed * delta_time;
        }
        if (glfw.getKey(window.handle, glfw.GLFW_KEY_RIGHT) == glfw.GLFW_PRESS) {
            delta_azimuth += rotation_speed * delta_time;
        }
        if (glfw.getKey(window.handle, glfw.GLFW_KEY_UP) == glfw.GLFW_PRESS) {
            delta_elevation += rotation_speed * delta_time;
        }
        if (glfw.getKey(window.handle, glfw.GLFW_KEY_DOWN) == glfw.GLFW_PRESS) {
            delta_elevation -= rotation_speed * delta_time;
        }

        if (delta_azimuth != 0.0 or delta_elevation != 0.0) {
            renderer.rotateCamera(delta_azimuth, delta_elevation);
        }

        // Handle scroll input for camera zoom
        if (input_state.scroll_delta != 0.0) {
            renderer.zoomCamera(-input_state.scroll_delta * zoom_speed);
            input_state.scroll_delta = 0.0;
        }

        try renderer.beginFrame();
        try renderer.render();
        try renderer.endFrame();

        tracy.frameMark();
    }

    std.log.info("Shutting down...", .{});
}
