const std = @import("std");
const Window = @import("platform/Window.zig").Window;
const Renderer = @import("renderer/Renderer.zig").Renderer;
const VulkanRenderer = @import("renderer/vulkan/VulkanRenderer.zig").VulkanRenderer;
const GameState = @import("GameState.zig");
const MenuController = @import("ui/MenuController.zig").MenuController;
const UiManager = @import("ui/UiManager.zig").UiManager;
const glfw = @import("platform/glfw.zig");
const tracy = @import("platform/tracy.zig");
const Logger = @import("Logger.zig");
const app_config = @import("app_config.zig");

var file_logger_instance: ?*Logger.FileLogger = null;

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

    if (file_logger_instance) |logger| {
        logger.push(file_buf[0..pos]);
    }

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
        glfw.GLFW_KEY_4 => "4",
        glfw.GLFW_KEY_5 => "5",
        glfw.GLFW_KEY_6 => "6",
        glfw.GLFW_KEY_7 => "7",
        glfw.GLFW_KEY_8 => "8",
        glfw.GLFW_KEY_9 => "9",
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
    menu_ctrl: *MenuController,
    ui_manager: *UiManager,
    mouse_captured: bool = false,
    last_cursor_x: f64 = 0.0,
    last_cursor_y: f64 = 0.0,
    first_mouse: bool = true,
    move_speed: f32 = 20.0,
    last_space_press_time: f64 = 0.0,
    space_was_held: bool = false,
    mode_toggle_requested: bool = false,
    debug_toggle_requested: bool = false,
    overdraw_toggle_requested: bool = false,
    lod_switch_requested: ?u8 = null,
    hotbar_scroll_delta: f32 = 0.0,
    hotbar_slot_requested: ?u8 = null,
};

fn cursorPosCallback(window: ?*glfw.Window, xpos: f64, ypos: f64) callconv(.c) void {
    const input_state = glfw.getWindowUserPointer(window.?, InputState) orelse return;
    if (input_state.mouse_captured) return;
    const scale: f64 = input_state.ui_manager.ui_scale;
    _ = input_state.ui_manager.handleMouseMove(@floatCast(xpos / scale), @floatCast(ypos / scale));
}

fn scrollCallback(window: ?*glfw.Window, xoffset: f64, yoffset: f64) callconv(.c) void {
    const input_state = glfw.getWindowUserPointer(window.?, InputState) orelse return;

    if (!input_state.mouse_captured) {
        if (input_state.ui_manager.handleScroll(
            input_state.ui_manager.last_mouse_x,
            input_state.ui_manager.last_mouse_y,
            @floatCast(xoffset),
            @floatCast(yoffset),
        )) return;
    }

    if (input_state.menu_ctrl.app_state != .playing) return;
    if (input_state.mouse_captured) {
        input_log.debug("Scroll y={d:.1} (hotbar)", .{yoffset});
        input_state.hotbar_scroll_delta += @floatCast(yoffset);
    }
}

fn keyCallback(window: ?*glfw.Window, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
    _ = scancode;
    const input_state = glfw.getWindowUserPointer(window.?, InputState) orelse return;
    input_log.debug("Key {s} {s}", .{ keyName(key), actionName(action) });

    if (key == glfw.GLFW_KEY_F11 and action == glfw.GLFW_RELEASE) {
        input_state.window.toggleFullscreen();
    }

    switch (input_state.menu_ctrl.app_state) {
        .pause_menu => {
            if (key == glfw.GLFW_KEY_ESCAPE and action == glfw.GLFW_PRESS) {
                input_state.menu_ctrl.hidePauseMenu();
                input_state.menu_ctrl.action = .resume_game;
                return;
            }
            _ = input_state.ui_manager.handleKey(key, action, mods);
        },
        .title_menu, .singleplayer_menu => {
            _ = input_state.ui_manager.handleKey(key, action, mods);
        },
        .playing => {
            if (key == glfw.GLFW_KEY_ESCAPE and action == glfw.GLFW_PRESS) {
                input_state.menu_ctrl.showPauseMenu();
                input_state.mouse_captured = false;
                input_state.first_mouse = true;
                glfw.setInputMode(window.?, glfw.GLFW_CURSOR, glfw.GLFW_CURSOR_NORMAL);
                var win_w: c_int = 0;
                var win_h: c_int = 0;
                glfw.getWindowSize(window.?, &win_w, &win_h);
                glfw.setCursorPos(window.?, @as(f64, @floatFromInt(win_w)) / 2.0, @as(f64, @floatFromInt(win_h)) / 2.0);
                return;
            }

            if (key == glfw.GLFW_KEY_P and action == glfw.GLFW_PRESS) {
                input_state.debug_toggle_requested = true;
            }

            if (key == glfw.GLFW_KEY_F4 and action == glfw.GLFW_PRESS) {
                input_state.overdraw_toggle_requested = true;
            }

            if (action == glfw.GLFW_PRESS) {
                const ctrl = (mods & glfw.GLFW_MOD_CONTROL) != 0;
                if (ctrl) {
                    if (key == glfw.GLFW_KEY_1) input_state.lod_switch_requested = 0;
                    if (key == glfw.GLFW_KEY_2) input_state.lod_switch_requested = 1;
                    if (key == glfw.GLFW_KEY_3) input_state.lod_switch_requested = 2;
                    if (key == glfw.GLFW_KEY_4) input_state.lod_switch_requested = 3;
                    if (key == glfw.GLFW_KEY_5) input_state.lod_switch_requested = 4;
                } else {
                    if (key == glfw.GLFW_KEY_1) input_state.hotbar_slot_requested = 0;
                    if (key == glfw.GLFW_KEY_2) input_state.hotbar_slot_requested = 1;
                    if (key == glfw.GLFW_KEY_3) input_state.hotbar_slot_requested = 2;
                    if (key == glfw.GLFW_KEY_4) input_state.hotbar_slot_requested = 3;
                    if (key == glfw.GLFW_KEY_5) input_state.hotbar_slot_requested = 4;
                    if (key == glfw.GLFW_KEY_6) input_state.hotbar_slot_requested = 5;
                    if (key == glfw.GLFW_KEY_7) input_state.hotbar_slot_requested = 6;
                    if (key == glfw.GLFW_KEY_8) input_state.hotbar_slot_requested = 7;
                    if (key == glfw.GLFW_KEY_9) input_state.hotbar_slot_requested = 8;
                }
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
        },
    }
}

fn charCallback(window: ?*glfw.Window, codepoint: c_uint) callconv(.c) void {
    const input_state = glfw.getWindowUserPointer(window.?, InputState) orelse return;
    _ = input_state.ui_manager.handleChar(codepoint);
}

fn mouseButtonCallback(window: ?*glfw.Window, button: c_int, action: c_int, mods: c_int) callconv(.c) void {
    _ = mods;
    const input_state = glfw.getWindowUserPointer(window.?, InputState) orelse return;

    if (!input_state.mouse_captured) {
        var mx: f64 = 0;
        var my: f64 = 0;
        glfw.getCursorPos(window.?, &mx, &my);
        const scale: f64 = input_state.ui_manager.ui_scale;
        if (input_state.ui_manager.handleMouseButton(button, action, @floatCast(mx / scale), @floatCast(my / scale))) return;
    }

    if (input_state.menu_ctrl.app_state != .playing) return;

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

    var renderer = try Renderer.init(allocator, &window, &VulkanRenderer.vtable, null);
    defer renderer.deinit();

    const framebuffer_resized = renderer.getFramebufferResizedPtr();

    const ui_manager = try allocator.create(UiManager);
    defer allocator.destroy(ui_manager);
    ui_manager.* = .{};
    renderer.setUiManager(@ptrCast(ui_manager));

    var menu_ctrl = MenuController.init(ui_manager, allocator);
    menu_ctrl.registerActions();

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
        .menu_ctrl = &menu_ctrl,
        .ui_manager = ui_manager,
    };
    glfw.setWindowUserPointer(window.handle, &input_state);
    glfw.setCursorPosCallback(window.handle, cursorPosCallback);
    glfw.setScrollCallback(window.handle, scrollCallback);
    glfw.setKeyCallback(window.handle, keyCallback);
    glfw.setCharCallback(window.handle, charCallback);
    glfw.setMouseButtonCallback(window.handle, mouseButtonCallback);
    glfw.setFramebufferSizeCallback(window.handle, framebufferSizeCallback);

    std.log.info("Entering main loop...", .{});

    const mouse_sensitivity: f32 = 0.003;
    var last_time = glfw.getTime();
    var tick_accumulator: f32 = 0.0;

    while (!window.shouldClose()) {
        window.pollEvents();

        const current_time = glfw.getTime();
        const delta_time: f32 = @floatCast(current_time - last_time);
        last_time = current_time;

        if (menu_ctrl.action) |action| {
            menu_ctrl.action = null;
            switch (action) {
                .load_world, .create_world => {
                    const world_name = if (action == .create_world)
                        menu_ctrl.getInputName()
                    else
                        menu_ctrl.getSelectedWorldName();

                    if (world_name.len > 0) {
                        game_state = GameState.init(allocator, 1280, 720, world_name) catch |err| blk: {
                            std.log.err("Failed to load world '{s}': {}", .{ world_name, err });
                            break :blk null;
                        };
                        if (game_state) |*gs| {
                            renderer.setGameState(@ptrCast(gs));
                            input_state.game_state = gs;
                            menu_ctrl.hideTitleMenu();
                            const vk_impl: *VulkanRenderer = @ptrCast(@alignCast(renderer.impl));
                            menu_ctrl.loadHud(&vk_impl.render_state.ui_renderer);
                            menu_ctrl.app_state = .playing;
                            input_state.mouse_captured = true;
                            input_state.first_mouse = true;
                            glfw.setInputMode(window.handle, glfw.GLFW_CURSOR, glfw.GLFW_CURSOR_DISABLED);
                            tick_accumulator = 0.0;
                        }
                    }
                },
                .delete_world => {
                    const name = menu_ctrl.getSelectedWorldName();
                    if (name.len > 0) {
                        app_config.deleteWorld(allocator, name) catch |err| {
                            std.log.err("Failed to delete world '{s}': {}", .{ name, err });
                        };
                        menu_ctrl.refreshWorldList();
                    }
                },
                .resume_game => {
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
                    menu_ctrl.showTitleMenu();
                },
                .quit => {
                    break;
                },
            }
        }

        if (menu_ctrl.app_state == .playing) {
            if (game_state) |*gs| {
                if (input_state.hotbar_scroll_delta != 0.0) {
                    const delta: i32 = if (input_state.hotbar_scroll_delta < 0.0) @as(i32, 1) else @as(i32, -1);
                    const current: i32 = @intCast(gs.selected_slot);
                    gs.selected_slot = @intCast(@mod(current + delta + GameState.HOTBAR_SIZE, GameState.HOTBAR_SIZE));
                    input_state.hotbar_scroll_delta = 0.0;
                }

                if (input_state.hotbar_slot_requested) |slot| {
                    gs.selected_slot = slot;
                    input_state.hotbar_slot_requested = null;
                }

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

                if (input_state.debug_toggle_requested) {
                    input_state.debug_toggle_requested = false;
                    gs.toggleDebugCamera();
                }

                if (input_state.overdraw_toggle_requested) {
                    input_state.overdraw_toggle_requested = false;
                    gs.overdraw_mode = !gs.overdraw_mode;
                }

                if (input_state.lod_switch_requested) |lod| {
                    input_state.lod_switch_requested = null;
                    gs.switchLod(lod);
                }

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
                    const speed = input_state.move_speed * delta_time;
                    gs.camera.move(forward_input * speed, right_input * speed, up_input * speed);
                } else {
                    if (input_state.mode_toggle_requested) {
                        input_state.mode_toggle_requested = false;
                        gs.toggleMode();
                    }

                    gs.input_move = .{ forward_input, up_input, right_input };

                    const space_held = glfw.getKey(window.handle, glfw.GLFW_KEY_SPACE) == glfw.GLFW_PRESS;
                    if (space_held and !input_state.space_was_held) {
                        gs.jump_requested = true;
                    }
                    input_state.space_was_held = space_held;

                    tick_accumulator += delta_time;
                    if (tick_accumulator > MAX_ACCUMULATOR) tick_accumulator = MAX_ACCUMULATOR;

                    while (tick_accumulator >= GameState.TICK_INTERVAL) {
                        gs.fixedUpdate(input_state.move_speed);
                        tick_accumulator -= GameState.TICK_INTERVAL;
                    }

                    const alpha = tick_accumulator / GameState.TICK_INTERVAL;
                    gs.interpolateForRender(alpha);
                }

                if (gs.storage) |s| {
                    s.tick();
                }

                menu_ctrl.updateHud(gs);
            }
        }

        ui_manager.tickCursorBlink();

        try renderer.beginFrame();
        try renderer.render();
        try renderer.endFrame();

        if (menu_ctrl.app_state == .playing) {
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
