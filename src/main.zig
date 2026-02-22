const std = @import("std");
const Window = @import("platform/Window.zig").Window;
const Renderer = @import("renderer/Renderer.zig").Renderer;
const VulkanRenderer = @import("renderer/vulkan/VulkanRenderer.zig").VulkanRenderer;
const GameState = @import("GameState.zig");
const glfw = @import("platform/glfw.zig");
const tracy = @import("platform/tracy.zig");

const DOUBLE_TAP_THRESHOLD: f64 = 0.35;
const MAX_ACCUMULATOR: f32 = 0.25;

const InputState = struct {
    window: *Window,
    framebuffer_resized: *bool,
    game_state: *GameState,
    mouse_captured: bool = false,
    last_cursor_x: f64 = 0.0,
    last_cursor_y: f64 = 0.0,
    first_mouse: bool = true,
    move_speed: f32 = 20.0,
    scroll_speed_delta: f32 = 0.0,
    last_space_press_time: f64 = 0.0,
    mode_toggle_requested: bool = false,
    debug_toggle_requested: bool = false,
    overdraw_toggle_requested: bool = false,
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

    if (key == glfw.GLFW_KEY_P and action == glfw.GLFW_PRESS) {
        input_state.debug_toggle_requested = true;
    }

    if (key == glfw.GLFW_KEY_F4 and action == glfw.GLFW_PRESS) {
        input_state.overdraw_toggle_requested = true;
    }

    if (key == glfw.GLFW_KEY_SPACE and action == glfw.GLFW_PRESS) {
        const now = glfw.getTime();
        if (now - input_state.last_space_press_time < DOUBLE_TAP_THRESHOLD) {
            input_state.mode_toggle_requested = true;
            input_state.last_space_press_time = 0.0;
        } else {
            input_state.last_space_press_time = now;
        }
    }
}

fn mouseButtonCallback(window: ?*glfw.Window, button: c_int, action: c_int, mods: c_int) callconv(.c) void {
    _ = mods;
    if (action != glfw.GLFW_PRESS) return;
    const input_state = glfw.getWindowUserPointer(window.?, InputState) orelse return;

    if (button == glfw.GLFW_MOUSE_BUTTON_LEFT and input_state.mouse_captured) {
        if (!input_state.game_state.debug_camera_active) {
            input_state.game_state.breakBlock();
        }
    } else if (button == glfw.GLFW_MOUSE_BUTTON_RIGHT) {
        if (!input_state.mouse_captured) {
            input_state.mouse_captured = true;
            input_state.first_mouse = true;
            glfw.setInputMode(window.?, glfw.GLFW_CURSOR, glfw.GLFW_CURSOR_DISABLED);
        } else if (!input_state.game_state.debug_camera_active) {
            input_state.game_state.placeBlock();
        }
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

    var game_state = try GameState.init(allocator, 1280, 720);
    defer game_state.deinit();

    var renderer = try Renderer.init(allocator, &window, &VulkanRenderer.vtable, @ptrCast(&game_state));
    defer renderer.deinit();

    const framebuffer_resized = renderer.getFramebufferResizedPtr();

    var input_state = InputState{
        .window = &window,
        .framebuffer_resized = framebuffer_resized,
        .game_state = &game_state,
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
    var tick_accumulator: f32 = 0.0;

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

        // Mouse look (per-frame, not tick-rate limited)
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

        // Consume debug camera toggle
        if (input_state.debug_toggle_requested) {
            input_state.debug_toggle_requested = false;
            game_state.toggleDebugCamera();
        }

        // Consume overdraw toggle
        if (input_state.overdraw_toggle_requested) {
            input_state.overdraw_toggle_requested = false;
            game_state.overdraw_mode = !game_state.overdraw_mode;
        }

        // Buffer movement input (read once per frame, consumed by ticks)
        var forward_input: f32 = 0.0;
        var right_input: f32 = 0.0;
        var up_input: f32 = 0.0;

        if (glfw.getKey(window.handle, glfw.GLFW_KEY_W) == glfw.GLFW_PRESS) forward_input += 1.0;
        if (glfw.getKey(window.handle, glfw.GLFW_KEY_S) == glfw.GLFW_PRESS) forward_input -= 1.0;
        if (glfw.getKey(window.handle, glfw.GLFW_KEY_D) == glfw.GLFW_PRESS) right_input += 1.0;
        if (glfw.getKey(window.handle, glfw.GLFW_KEY_A) == glfw.GLFW_PRESS) right_input -= 1.0;
        if (glfw.getKey(window.handle, glfw.GLFW_KEY_SPACE) == glfw.GLFW_PRESS) up_input += 1.0;
        if (glfw.getKey(window.handle, glfw.GLFW_KEY_LEFT_SHIFT) == glfw.GLFW_PRESS) up_input -= 1.0;

        if (game_state.debug_camera_active) {
            // Debug camera: free-fly movement applied directly per-frame
            const speed = input_state.move_speed * delta_time;
            game_state.camera.move(forward_input * speed, right_input * speed, up_input * speed);
        } else {
            // Consume mode toggle
            if (input_state.mode_toggle_requested) {
                input_state.mode_toggle_requested = false;
                game_state.toggleMode();
            }

            game_state.input_move = .{ forward_input, up_input, right_input };

            if (glfw.getKey(window.handle, glfw.GLFW_KEY_SPACE) == glfw.GLFW_PRESS) {
                game_state.jump_requested = true;
            }

            // Fixed timestep accumulator
            tick_accumulator += delta_time;
            if (tick_accumulator > MAX_ACCUMULATOR) tick_accumulator = MAX_ACCUMULATOR;

            while (tick_accumulator >= GameState.TICK_INTERVAL) {
                game_state.fixedUpdate(input_state.move_speed);
                tick_accumulator -= GameState.TICK_INTERVAL;
            }

            // Interpolate for smooth rendering
            const alpha = tick_accumulator / GameState.TICK_INTERVAL;
            game_state.interpolateForRender(alpha);
        }

        try renderer.beginFrame();
        try renderer.render();
        try renderer.endFrame();

        if (!game_state.debug_camera_active) {
            game_state.restoreAfterRender();
        }

        tracy.frameMark();
    }

    std.log.info("Shutting down...", .{});
}
