const std = @import("std");
const Window = @import("platform/Window.zig").Window;
const Renderer = @import("renderer/Renderer.zig").Renderer;
const VulkanRenderer = @import("renderer/vulkan/VulkanRenderer.zig").VulkanRenderer;
const GameState = @import("GameState.zig");
const glfw = @import("platform/glfw.zig");
const tracy = @import("platform/tracy.zig");

const InputState = struct {
    window: *Window,
    framebuffer_resized: *bool,
    mouse_captured: bool = false,
    last_cursor_x: f64 = 0.0,
    last_cursor_y: f64 = 0.0,
    first_mouse: bool = true,
    move_speed: f32 = 20.0,
    scroll_speed_delta: f32 = 0.0,
};

fn scrollCallback(window: ?*glfw.Window, xoffset: f64, yoffset: f64) callconv(.c) void {
    _ = xoffset;
    const input_state = glfw.getWindowUserPointer(window.?, InputState) orelse return;
    input_state.scroll_speed_delta += @floatCast(yoffset);
}

fn keyCallback(window: ?*glfw.Window, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
    _ = scancode;
    _ = mods;
    const input_state = glfw.getWindowUserPointer(window.?, InputState) orelse return;

    if (key == glfw.GLFW_KEY_F11 and action == glfw.GLFW_RELEASE) {
        input_state.window.toggleFullscreen();
    }

    if (key == glfw.GLFW_KEY_ESCAPE and action == glfw.GLFW_PRESS and input_state.mouse_captured) {
        input_state.mouse_captured = false;
        input_state.first_mouse = true;
        glfw.setInputMode(window.?, glfw.GLFW_CURSOR, glfw.GLFW_CURSOR_NORMAL);
    }
}

fn mouseButtonCallback(window: ?*glfw.Window, button: c_int, action: c_int, mods: c_int) callconv(.c) void {
    _ = mods;
    if (button != glfw.GLFW_MOUSE_BUTTON_RIGHT) return;
    const input_state = glfw.getWindowUserPointer(window.?, InputState) orelse return;

    if (action == glfw.GLFW_PRESS and !input_state.mouse_captured) {
        input_state.mouse_captured = true;
        input_state.first_mouse = true;
        glfw.setInputMode(window.?, glfw.GLFW_CURSOR, glfw.GLFW_CURSOR_DISABLED);
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
    glfw.setMouseButtonCallback(window.handle, mouseButtonCallback);
    glfw.setFramebufferSizeCallback(window.handle, framebufferSizeCallback);

    std.log.info("Entering main loop...", .{});

    const mouse_sensitivity: f32 = 0.003;
    const min_speed: f32 = 1.0;
    const max_speed: f32 = 200.0;
    const speed_scroll_factor: f32 = 1.2;
    var last_time = glfw.getTime();

    while (!window.shouldClose()) {
        window.pollEvents();

        const current_time = glfw.getTime();
        const delta_time: f32 = @floatCast(current_time - last_time);
        last_time = current_time;

        // Adjust move speed via scroll
        if (input_state.scroll_speed_delta != 0.0) {
            if (input_state.scroll_speed_delta > 0.0) {
                input_state.move_speed *= speed_scroll_factor;
            } else {
                input_state.move_speed /= speed_scroll_factor;
            }
            input_state.move_speed = @max(min_speed, @min(max_speed, input_state.move_speed));
            input_state.scroll_speed_delta = 0.0;
        }

        // Mouse look
        if (input_state.mouse_captured) {
            var cursor_x: f64 = 0.0;
            var cursor_y: f64 = 0.0;
            glfw.getCursorPos(window.handle, &cursor_x, &cursor_y);

            if (input_state.first_mouse) {
                input_state.last_cursor_x = cursor_x;
                input_state.last_cursor_y = cursor_y;
                input_state.first_mouse = false;
            } else {
                const dx: f32 = @floatCast(cursor_x - input_state.last_cursor_x);
                const dy: f32 = @floatCast(cursor_y - input_state.last_cursor_y);
                input_state.last_cursor_x = cursor_x;
                input_state.last_cursor_y = cursor_y;

                game_state.camera.look(-dx * mouse_sensitivity, -dy * mouse_sensitivity);
            }
        }

        // WASD movement
        var forward_input: f32 = 0.0;
        var right_input: f32 = 0.0;
        var up_input: f32 = 0.0;

        if (glfw.getKey(window.handle, glfw.GLFW_KEY_W) == glfw.GLFW_PRESS) {
            forward_input += 1.0;
        }
        if (glfw.getKey(window.handle, glfw.GLFW_KEY_S) == glfw.GLFW_PRESS) {
            forward_input -= 1.0;
        }
        if (glfw.getKey(window.handle, glfw.GLFW_KEY_D) == glfw.GLFW_PRESS) {
            right_input += 1.0;
        }
        if (glfw.getKey(window.handle, glfw.GLFW_KEY_A) == glfw.GLFW_PRESS) {
            right_input -= 1.0;
        }
        if (glfw.getKey(window.handle, glfw.GLFW_KEY_SPACE) == glfw.GLFW_PRESS) {
            up_input += 1.0;
        }
        if (glfw.getKey(window.handle, glfw.GLFW_KEY_LEFT_SHIFT) == glfw.GLFW_PRESS) {
            up_input -= 1.0;
        }

        if (forward_input != 0.0 or right_input != 0.0 or up_input != 0.0) {
            const speed = input_state.move_speed * delta_time;
            game_state.camera.move(forward_input * speed, right_input * speed, up_input * speed);
        }

        try renderer.beginFrame();
        try renderer.render();
        try renderer.endFrame();

        tracy.frameMark();
    }

    std.log.info("Shutting down...", .{});
}
