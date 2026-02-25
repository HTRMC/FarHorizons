const std = @import("std");
const Window = @import("platform/Window.zig").Window;
const Renderer = @import("renderer/Renderer.zig").Renderer;
const VulkanRenderer = @import("renderer/vulkan/VulkanRenderer.zig").VulkanRenderer;
const GameState = @import("GameState.zig");
const Menu = @import("ui/Menu.zig").Menu;
const UiManager = @import("ui/UiManager.zig").UiManager;
const glfw = @import("platform/glfw.zig");
const tracy = @import("platform/tracy.zig");
const Logger = @import("Logger.zig");
const app_config = @import("app_config.zig");

var file_logger_instance: ?*Logger.FileLogger = null;

// C time bindings for local time in log output
const c_time = struct {
    const Tm = extern struct {
        tm_sec: c_int,
        tm_min: c_int,
        tm_hour: c_int,
        tm_mday: c_int,
        tm_mon: c_int,
        tm_year: c_int,
        tm_wday: c_int,
        tm_yday: c_int,
        tm_isdst: c_int,
    };
    extern "c" fn time(timer: ?*i64) i64;
    extern "c" fn localtime(timer: *const i64) ?*const Tm;
};

pub const std_options: std.Options = .{
    .logFn = logFn,
};

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_text = comptime switch (level) {
        .err => "ERROR",
        .warn => "WARN",
        .info => "INFO",
        .debug => "DEBUG",
    };
    const scope_name = comptime if (scope == .default) "Main" else @tagName(scope);

    var t = c_time.time(null);
    const tm = c_time.localtime(&t);

    // Format plain text into stack buffer for file logger
    var file_buf: [4096]u8 = undefined;
    var pos: usize = 0;

    if (tm) |local| {
        const header = std.fmt.bufPrint(file_buf[pos..], "[{d:0>2}:{d:0>2}:{d:0>2}] [{s}/{s}]: ", .{
            @as(u32, @intCast(local.tm_hour)),
            @as(u32, @intCast(local.tm_min)),
            @as(u32, @intCast(local.tm_sec)),
            scope_name,
            level_text,
        }) catch "";
        pos += header.len;
    } else {
        const header = std.fmt.bufPrint(file_buf[pos..], "[??:??:??] [{s}/{s}]: ", .{
            scope_name, level_text,
        }) catch "";
        pos += header.len;
    }

    const msg = std.fmt.bufPrint(file_buf[pos..], format ++ "\n", args) catch blk: {
        const truncated = "[truncated]\n";
        if (file_buf.len - pos >= truncated.len) {
            @memcpy(file_buf[pos..][0..truncated.len], truncated);
            break :blk file_buf[pos..][0..truncated.len];
        }
        break :blk "";
    };
    pos += msg.len;

    // Push to file logger if active
    if (file_logger_instance) |logger| {
        logger.push(file_buf[0..pos]);
    }

    // Write to stderr with colors
    const level_color: std.Io.Terminal.Color = switch (level) {
        .err => .red,
        .warn => .yellow,
        .info => .green,
        .debug => .magenta,
    };

    var buf: [64]u8 = undefined;
    const stderr = std.debug.lockStderr(&buf);
    defer std.debug.unlockStderr();
    const term = stderr.terminal();
    const writer = term.writer;

    if (tm) |local| {
        writer.print("[{d:0>2}:{d:0>2}:{d:0>2}] [", .{
            @as(u32, @intCast(local.tm_hour)),
            @as(u32, @intCast(local.tm_min)),
            @as(u32, @intCast(local.tm_sec)),
        }) catch {};
    } else {
        writer.writeAll("[??:??:??] [") catch {};
    }
    writer.print("{s}/", .{scope_name}) catch {};
    term.setColor(level_color) catch {};
    term.setColor(.bold) catch {};
    writer.writeAll(level_text) catch {};
    term.setColor(.reset) catch {};
    writer.writeAll("]: ") catch {};
    writer.print(format ++ "\n", args) catch {};
}

const input_log = std.log.scoped(.Input);

fn keyName(key: c_int) []const u8 {
    return switch (key) {
        glfw.GLFW_KEY_1 => "1",
        glfw.GLFW_KEY_2 => "2",
        glfw.GLFW_KEY_3 => "3",
        glfw.GLFW_KEY_W => "W",
        glfw.GLFW_KEY_A => "A",
        glfw.GLFW_KEY_S => "S",
        glfw.GLFW_KEY_D => "D",
        glfw.GLFW_KEY_N => "N",
        glfw.GLFW_KEY_Y => "Y",
        glfw.GLFW_KEY_SPACE => "Space",
        glfw.GLFW_KEY_LEFT_SHIFT => "LShift",
        glfw.GLFW_KEY_ESCAPE => "Escape",
        glfw.GLFW_KEY_ENTER => "Enter",
        glfw.GLFW_KEY_BACKSPACE => "Backspace",
        glfw.GLFW_KEY_DELETE => "Delete",
        glfw.GLFW_KEY_P => "P",
        glfw.GLFW_KEY_F4 => "F4",
        glfw.GLFW_KEY_F11 => "F11",
        glfw.GLFW_KEY_UP => "Up",
        glfw.GLFW_KEY_DOWN => "Down",
        glfw.GLFW_KEY_LEFT => "Left",
        glfw.GLFW_KEY_RIGHT => "Right",
        else => "Unknown",
    };
}

fn actionName(action: c_int) []const u8 {
    return switch (action) {
        glfw.GLFW_PRESS => "PRESS",
        glfw.GLFW_RELEASE => "RELEASE",
        glfw.GLFW_REPEAT => "REPEAT",
        else => "UNKNOWN",
    };
}

fn mouseButtonName(button: c_int) []const u8 {
    return switch (button) {
        glfw.GLFW_MOUSE_BUTTON_LEFT => "Left",
        glfw.GLFW_MOUSE_BUTTON_RIGHT => "Right",
        else => "Unknown",
    };
}

const DOUBLE_TAP_THRESHOLD: f64 = 0.35;
const MAX_ACCUMULATOR: f32 = 0.25;

const InputState = struct {
    window: *Window,
    framebuffer_resized: *bool,
    game_state: ?*GameState = null,
    menu: *Menu,
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
    lod_switch_requested: ?u8 = null,
};

fn scrollCallback(window: ?*glfw.Window, xoffset: f64, yoffset: f64) callconv(.c) void {
    _ = xoffset;
    const input_state = glfw.getWindowUserPointer(window.?, InputState) orelse return;
    if (input_state.menu.app_state != .playing) return;
    input_log.debug("Scroll y={d:.1}", .{yoffset});
    input_state.scroll_speed_delta += @floatCast(yoffset);
}

fn keyCallback(window: ?*glfw.Window, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
    _ = scancode;
    _ = mods;
    const input_state = glfw.getWindowUserPointer(window.?, InputState) orelse return;
    input_log.debug("Key {s} {s}", .{ keyName(key), actionName(action) });

    if (key == glfw.GLFW_KEY_F11 and action == glfw.GLFW_RELEASE) {
        input_state.window.toggleFullscreen();
    }

    switch (input_state.menu.app_state) {
        .title_menu, .pause_menu => {
            input_state.menu.handleKey(key, action);
        },
        .playing => {
            // ESC opens pause menu
            if (key == glfw.GLFW_KEY_ESCAPE and action == glfw.GLFW_PRESS) {
                input_state.menu.app_state = .pause_menu;
                input_state.menu.pause_selection = 0;
                input_state.mouse_captured = false;
                input_state.first_mouse = true;
                glfw.setInputMode(window.?, glfw.GLFW_CURSOR, glfw.GLFW_CURSOR_NORMAL);
                return;
            }

            if (key == glfw.GLFW_KEY_P and action == glfw.GLFW_PRESS) {
                input_state.debug_toggle_requested = true;
            }

            if (key == glfw.GLFW_KEY_F4 and action == glfw.GLFW_PRESS) {
                input_state.overdraw_toggle_requested = true;
            }

            if (key == glfw.GLFW_KEY_1 and action == glfw.GLFW_PRESS) input_state.lod_switch_requested = 0;
            if (key == glfw.GLFW_KEY_2 and action == glfw.GLFW_PRESS) input_state.lod_switch_requested = 1;
            if (key == glfw.GLFW_KEY_3 and action == glfw.GLFW_PRESS) input_state.lod_switch_requested = 2;
            if (key == glfw.GLFW_KEY_4 and action == glfw.GLFW_PRESS) input_state.lod_switch_requested = 3;
            if (key == glfw.GLFW_KEY_5 and action == glfw.GLFW_PRESS) input_state.lod_switch_requested = 4;

            if (key == glfw.GLFW_KEY_SPACE and action == glfw.GLFW_PRESS) {
                const now = glfw.getTime();
                if (now - input_state.last_space_press_time < DOUBLE_TAP_THRESHOLD) {
                    input_state.mode_toggle_requested = true;
                    input_state.last_space_press_time = 0.0;
                } else {
                    input_state.last_space_press_time = now;
                }
            }
        },
    }
}

fn charCallback(window: ?*glfw.Window, codepoint: c_uint) callconv(.c) void {
    const input_state = glfw.getWindowUserPointer(window.?, InputState) orelse return;
    input_state.menu.handleChar(codepoint);
}

fn mouseButtonCallback(window: ?*glfw.Window, button: c_int, action: c_int, mods: c_int) callconv(.c) void {
    _ = mods;
    const input_state = glfw.getWindowUserPointer(window.?, InputState) orelse return;
    if (input_state.menu.app_state != .playing) return;

    input_log.debug("Mouse {s} {s}", .{ mouseButtonName(button), actionName(action) });
    if (action != glfw.GLFW_PRESS) return;

    const gs = input_state.game_state orelse return;

    if (button == glfw.GLFW_MOUSE_BUTTON_LEFT and input_state.mouse_captured) {
        if (!gs.debug_camera_active and gs.current_lod == 0) {
            gs.breakBlock();
        }
    } else if (button == glfw.GLFW_MOUSE_BUTTON_RIGHT) {
        if (!input_state.mouse_captured) {
            input_state.mouse_captured = true;
            input_state.first_mouse = true;
            glfw.setInputMode(window.?, glfw.GLFW_CURSOR, glfw.GLFW_CURSOR_DISABLED);
        } else if (!gs.debug_camera_active and gs.current_lod == 0) {
            gs.placeBlock();
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

    // Initialize file logger early so all subsequent logs are captured
    const file_logger = Logger.FileLogger.init(allocator) catch null;
    if (file_logger) |fl| {
        file_logger_instance = fl;
    }
    defer {
        file_logger_instance = null;
        if (file_logger) |fl| {
            fl.deinit();
        }
    }

    var window = try Window.init(.{
        .width = 1280,
        .height = 720,
        .title = "FarHorizons 0.0.0",
    });
    defer window.deinit();

    // Initialize menu
    var menu = Menu.init();
    menu.refreshWorldList(allocator);

    // Initialize renderer with no game state (title screen)
    var renderer = try Renderer.init(allocator, &window, &VulkanRenderer.vtable, @ptrCast(&menu));
    defer renderer.deinit();

    const framebuffer_resized = renderer.getFramebufferResizedPtr();

    // Initialize UI system (heap-allocated due to large widget arrays)
    const ui_manager = try allocator.create(UiManager);
    defer allocator.destroy(ui_manager);
    ui_manager.* = .{};
    ui_manager.buildTestScreen();
    renderer.setUiManager(@ptrCast(ui_manager));

    // Game state (created on demand when a world is loaded)
    var game_state: ?GameState = null;
    defer {
        if (game_state) |*gs| {
            gs.save();
            gs.deinit();
        }
    }

    var input_state = InputState{
        .window = &window,
        .framebuffer_resized = framebuffer_resized,
        .game_state = null,
        .menu = &menu,
    };
    glfw.setWindowUserPointer(window.handle, &input_state);
    glfw.setScrollCallback(window.handle, scrollCallback);
    glfw.setKeyCallback(window.handle, keyCallback);
    glfw.setCharCallback(window.handle, charCallback);
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

        // Process menu actions
        if (menu.action) |action| {
            menu.action = null;
            switch (action) {
                .load_world, .create_world => {
                    const world_name = if (action == .create_world)
                        menu.getInputName()
                    else
                        menu.getSelectedWorldName();

                    if (world_name.len > 0) {
                        game_state = GameState.init(allocator, 1280, 720, world_name) catch |err| blk: {
                            std.log.err("Failed to load world '{s}': {}", .{ world_name, err });
                            break :blk null;
                        };
                        if (game_state) |*gs| {
                            renderer.setGameState(@ptrCast(gs));
                            input_state.game_state = gs;
                            menu.app_state = .playing;
                            input_state.mouse_captured = true;
                            input_state.first_mouse = true;
                            glfw.setInputMode(window.handle, glfw.GLFW_CURSOR, glfw.GLFW_CURSOR_DISABLED);
                            tick_accumulator = 0.0;
                        }
                    }
                },
                .delete_world => {
                    const name = menu.getSelectedWorldName();
                    if (name.len > 0) {
                        app_config.deleteWorld(allocator, name) catch |err| {
                            std.log.err("Failed to delete world '{s}': {}", .{ name, err });
                        };
                        menu.refreshWorldList(allocator);
                    }
                },
                .resume_game => {
                    menu.app_state = .playing;
                    input_state.mouse_captured = true;
                    input_state.first_mouse = true;
                    glfw.setInputMode(window.handle, glfw.GLFW_CURSOR, glfw.GLFW_CURSOR_DISABLED);
                },
                .return_to_title => {
                    if (game_state) |*gs| {
                        gs.save();
                        renderer.setGameState(null);
                        input_state.game_state = null;
                        gs.deinit();
                        game_state = null;
                    }
                    menu.refreshWorldList(allocator);
                    menu.app_state = .title_menu;
                },
                .quit => {
                    break;
                },
            }
        }

        // Game update (only when playing)
        if (menu.app_state == .playing) {
            if (game_state) |*gs| {
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

                        gs.camera.look(-dx * mouse_sensitivity, -dy * mouse_sensitivity);
                    }
                }

                // Consume debug camera toggle
                if (input_state.debug_toggle_requested) {
                    input_state.debug_toggle_requested = false;
                    gs.toggleDebugCamera();
                }

                // Consume overdraw toggle
                if (input_state.overdraw_toggle_requested) {
                    input_state.overdraw_toggle_requested = false;
                    gs.overdraw_mode = !gs.overdraw_mode;
                }

                // Consume LOD switch
                if (input_state.lod_switch_requested) |lod| {
                    input_state.lod_switch_requested = null;
                    gs.switchLod(lod);
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

                if (gs.debug_camera_active) {
                    // Debug camera: free-fly movement applied directly per-frame
                    const speed = input_state.move_speed * delta_time;
                    gs.camera.move(forward_input * speed, right_input * speed, up_input * speed);
                } else {
                    // Consume mode toggle
                    if (input_state.mode_toggle_requested) {
                        input_state.mode_toggle_requested = false;
                        gs.toggleMode();
                    }

                    gs.input_move = .{ forward_input, up_input, right_input };

                    if (glfw.getKey(window.handle, glfw.GLFW_KEY_SPACE) == glfw.GLFW_PRESS) {
                        gs.jump_requested = true;
                    }

                    // Fixed timestep accumulator
                    tick_accumulator += delta_time;
                    if (tick_accumulator > MAX_ACCUMULATOR) tick_accumulator = MAX_ACCUMULATOR;

                    while (tick_accumulator >= GameState.TICK_INTERVAL) {
                        gs.fixedUpdate(input_state.move_speed);
                        tick_accumulator -= GameState.TICK_INTERVAL;
                    }

                    // Interpolate for smooth rendering
                    const alpha = tick_accumulator / GameState.TICK_INTERVAL;
                    gs.interpolateForRender(alpha);
                }

                // Run save scheduler (every frame, time-based urgency handles rate)
                if (gs.storage) |s| {
                    s.tick();
                }
            }
        }

        // Render (always — works in all states)
        try renderer.beginFrame();
        try renderer.render();
        try renderer.endFrame();

        if (menu.app_state == .playing) {
            if (game_state) |*gs| {
                if (!gs.debug_camera_active) {
                    gs.restoreAfterRender();
                }
            }
        }

        tracy.frameMark();
    }

    std.log.info("Shutting down...", .{});
}
