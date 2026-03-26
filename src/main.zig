const std = @import("std");
const Window = @import("platform/Window.zig").Window;
const Renderer = @import("renderer/Renderer.zig").Renderer;
const VulkanRenderer = @import("renderer/vulkan/VulkanRenderer.zig").VulkanRenderer;
const GameState = @import("world/GameState.zig");
const InventoryOps = GameState.InventoryOps;
const BlockOps = @import("world/BlockOps.zig");
const PlayerActions = @import("world/entity/PlayerActions.zig");
const PlayerMovement = @import("world/entity/PlayerMovement.zig");
const ChunkManagement = @import("world/ChunkManagement.zig");
const WorldState = @import("world/WorldState.zig");
const MenuController = @import("ui/MenuController.zig").MenuController;
const UiManager = @import("ui/UiManager.zig").UiManager;
const Focus = @import("ui/Focus.zig");
const glfw = @import("platform/glfw.zig");
const tracy = @import("platform/tracy.zig");
const Logger = @import("platform/Logger.zig");
const app_config = @import("app_config.zig");
const Options = @import("Options.zig");
const Gamepad = @import("platform/Gamepad.zig");
const Item = @import("world/item/Item.zig");

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
    extern "c" fn localtime_r(timer: *const i64, result: *Tm) ?*Tm;
    extern "c" fn _localtime64_s(result: *Tm, timer: *const i64) c_int;

    fn localtime(timer: *const i64, result: *Tm) ?*const Tm {
        if (@import("builtin").os.tag == .windows) {
            return if (_localtime64_s(result, timer) == 0) result else null;
        } else {
            return localtime_r(timer, result);
        }
    }
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
    var local_buf: c_time.Tm = undefined;
    const tm = c_time.localtime(&t, &local_buf);

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
        glfw.GLFW_KEY_F3 => "F3",
        glfw.GLFW_KEY_F4 => "F4",
        glfw.GLFW_KEY_F5 => "F5",
        glfw.GLFW_KEY_F6 => "F6",
        glfw.GLFW_KEY_F7 => "F7",
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
const MAX_ACCUMULATOR: f32 = 0.5;

const InputState = struct {
    window: *Window,
    framebuffer_resized: *bool,
    game_state: ?*GameState = null,
    menu_ctrl: *MenuController,
    ui_manager: *UiManager,
    options: *Options,
    mouse_captured: bool = false,
    last_cursor_x: f64 = 0.0,
    last_cursor_y: f64 = 0.0,
    first_mouse: bool = true,
    move_speed: f32 = 20.0,
    last_space_press_time: f64 = 0.0,
    space_was_held: bool = false,
    mode_toggle_requested: bool = false,
    gamemode_toggle_requested: bool = false,
    debug_toggle_requested: bool = false,
    overdraw_toggle_requested: bool = false,
    chunk_borders_toggle_requested: bool = false,
    hitbox_toggle_requested: bool = false,
    ui_toggle_requested: bool = false,
    f3_held: bool = false,
    f3_consumed: bool = false,
    debug_screen_toggle: ?u3 = null,
    drop_key_held: bool = false,
    drop_key_ctrl: bool = false,
    drop_cooldown: u8 = 0,
    hotbar_scroll_delta: f32 = 0.0,
    hotbar_slot_requested: ?u8 = null,
    gamepad: Gamepad = .{},
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
    const opts = input_state.options;
    input_log.debug("Key {s} {s}", .{ keyName(key), actionName(action) });

    // Rebinding: capture next key press
    if (input_state.menu_ctrl.rebinding_action != null and action == glfw.GLFW_PRESS) {
        if (key == glfw.GLFW_KEY_ESCAPE) {
            input_state.menu_ctrl.cancelRebind();
        } else {
            input_state.menu_ctrl.handleRebindKey(.{ .code = key, .is_mouse = false });
        }
        return;
    }

    if (opts.keyMatches(.toggle_fullscreen, key) and action == glfw.GLFW_RELEASE) {
        input_state.window.toggleFullscreen();
    }

    switch (input_state.menu_ctrl.app_state) {
        .pause_menu => {
            if (opts.keyMatches(.pause, key) and action == glfw.GLFW_PRESS) {
                input_state.menu_ctrl.hidePauseMenu();
                input_state.menu_ctrl.action = .resume_game;
                return;
            }
            _ = input_state.ui_manager.handleKey(key, action, mods);
        },
        .title_menu => {
            _ = input_state.ui_manager.handleKey(key, action, mods);
        },
        .singleplayer_menu => {
            const consumed = input_state.ui_manager.handleKey(key, action, mods);
            if (!consumed and key == glfw.GLFW_KEY_ESCAPE and action == glfw.GLFW_PRESS) {
                input_state.menu_ctrl.transitionTo(.title_menu);
            }
            if (!consumed and key == glfw.GLFW_KEY_DELETE and action == glfw.GLFW_PRESS) {
                input_state.menu_ctrl.showDeleteConfirm();
            }
        },
        .multiplayer_menu => {
            const consumed = input_state.ui_manager.handleKey(key, action, mods);
            if (!consumed and key == glfw.GLFW_KEY_ESCAPE and action == glfw.GLFW_PRESS) {
                input_state.menu_ctrl.transitionTo(.title_menu);
            }
        },
        .create_world, .edit_world => {
            const consumed = input_state.ui_manager.handleKey(key, action, mods);
            if (!consumed and key == glfw.GLFW_KEY_ESCAPE and action == glfw.GLFW_PRESS) {
                input_state.menu_ctrl.transitionTo(.singleplayer_menu);
            }
        },
        .controls_title => {
            if (key == glfw.GLFW_KEY_ESCAPE and action == glfw.GLFW_PRESS) {
                input_state.menu_ctrl.cancelRebind();
                input_state.menu_ctrl.transitionTo(.title_menu);
                return;
            }
            _ = input_state.ui_manager.handleKey(key, action, mods);
        },
        .controls_pause => {
            if (key == glfw.GLFW_KEY_ESCAPE and action == glfw.GLFW_PRESS) {
                input_state.menu_ctrl.cancelRebind();
                input_state.menu_ctrl.transitionTo(.pause_menu);
                return;
            }
            _ = input_state.ui_manager.handleKey(key, action, mods);
        },
        .crafting => {
            if (opts.keyMatches(.pause, key) and action == glfw.GLFW_PRESS) {
                input_state.menu_ctrl.hideCrafting();
                captureMouse(input_state);
                return;
            }
        },
        .inventory => {
            if ((opts.keyMatches(.open_inventory, key) or opts.keyMatches(.pause, key)) and action == glfw.GLFW_PRESS) {
                input_state.menu_ctrl.hideInventory(input_state.game_state);
                captureMouse(input_state);
                return;
            }
            // Track drop key held state for tick-based dropping
            if (opts.keyMatches(.drop_item, key)) {
                input_state.drop_key_held = (action == glfw.GLFW_PRESS or action == glfw.GLFW_REPEAT);
                input_state.drop_key_ctrl = (mods & glfw.GLFW_MOD_CONTROL) != 0;
            }
        },
        .playing => {
            if (opts.keyMatches(.pause, key) and action == glfw.GLFW_PRESS) {
                resetAttackState(input_state);
                input_state.menu_ctrl.showPauseMenu();
                uncaptureMouse(input_state);
                return;
            }

            if (opts.keyMatches(.open_inventory, key) and action == glfw.GLFW_PRESS) {
                resetAttackState(input_state);
                if (input_state.game_state) |state| input_state.menu_ctrl.showInventory(state);
                uncaptureMouse(input_state);
                return;
            }

            // Track drop key held state for tick-based dropping
            if (opts.keyMatches(.drop_item, key)) {
                input_state.drop_key_held = (action == glfw.GLFW_PRESS or action == glfw.GLFW_REPEAT);
                input_state.drop_key_ctrl = (mods & glfw.GLFW_MOD_CONTROL) != 0;
            }

            if (opts.keyMatches(.toggle_debug_camera, key) and action == glfw.GLFW_PRESS) {
                input_state.debug_toggle_requested = true;
            }

            if (opts.keyMatches(.toggle_third_person, key) and action == glfw.GLFW_PRESS) {
                if (input_state.game_state) |state| {
                    state.third_person = !state.third_person;
                }
            }

            // F3 held state tracking
            if (opts.keyMatches(.debug_f3, key)) {
                if (action == glfw.GLFW_PRESS) {
                    input_state.f3_held = true;
                    input_state.f3_consumed = false;
                } else if (action == glfw.GLFW_RELEASE) {
                    if (!input_state.f3_consumed) {
                        input_state.debug_screen_toggle = 0;
                    }
                    input_state.f3_held = false;
                }
            }

            if (action == glfw.GLFW_PRESS) {
                const shift = (mods & glfw.GLFW_MOD_SHIFT) != 0;

                if (opts.keyMatches(.toggle_hud, key)) {
                    input_state.ui_toggle_requested = true;
                }

                // F3+combo: chunk borders / hitbox
                if (opts.keyMatches(.debug_chunk_borders, key) and input_state.f3_held) {
                    input_state.chunk_borders_toggle_requested = true;
                    input_state.f3_consumed = true;
                }
                if (opts.keyMatches(.debug_hitbox, key) and input_state.f3_held) {
                    input_state.hitbox_toggle_requested = true;
                    input_state.f3_consumed = true;
                }

                if (opts.keyMatches(.debug_screen_f4, key) and input_state.f3_held) {
                    input_state.gamemode_toggle_requested = true;
                    input_state.f3_consumed = true;
                } else if (opts.keyMatches(.debug_screen_f4, key) and shift) {
                    input_state.overdraw_toggle_requested = true;
                } else if (opts.keyMatches(.debug_screen_f4, key) and !shift) {
                    input_state.debug_screen_toggle = 1;
                }
                if (opts.keyMatches(.debug_screen_f5, key)) input_state.debug_screen_toggle = 2;
            }

            // Hotbar slot selection
            if (action == glfw.GLFW_PRESS) {
                inline for (@typeInfo(Options.Action).@"enum".fields) |field| {
                    const act: Options.Action = @enumFromInt(field.value);
                    if (act.hotbarSlot()) |slot| {
                        if (opts.keyMatches(act, key)) {
                            input_state.hotbar_slot_requested = slot;
                        }
                    }
                }
            }

            if (opts.keyMatches(.speed_up, key) and (action == glfw.GLFW_PRESS or action == glfw.GLFW_REPEAT)) {
                input_state.move_speed = @min(input_state.move_speed * 1.25, 500.0);
                input_log.info("Fly speed: {d:.1}", .{input_state.move_speed});
            }
            if (opts.keyMatches(.speed_down, key) and (action == glfw.GLFW_PRESS or action == glfw.GLFW_REPEAT)) {
                input_state.move_speed = @max(input_state.move_speed / 1.25, 1.0);
                input_log.info("Fly speed: {d:.1}", .{input_state.move_speed});
            }

            if (opts.keyMatches(.jump, key) and action == glfw.GLFW_PRESS) {
                const now = glfw.getTime();
                if (now - input_state.last_space_press_time < DOUBLE_TAP_THRESHOLD) {
                    input_state.mode_toggle_requested = true;
                    input_state.last_space_press_time = 0.0;
                } else {
                    input_state.last_space_press_time = now;
                }
            }
        },
        .loading => {},
        .saving => {},
    }
}

fn charCallback(window: ?*glfw.Window, codepoint: c_uint) callconv(.c) void {
    const input_state = glfw.getWindowUserPointer(window.?, InputState) orelse return;
    _ = input_state.ui_manager.handleChar(codepoint);
}

fn mouseButtonCallback(window: ?*glfw.Window, button: c_int, action: c_int, mods: c_int) callconv(.c) void {
    const input_state = glfw.getWindowUserPointer(window.?, InputState) orelse return;

    // Rebinding: capture mouse button
    if (input_state.menu_ctrl.rebinding_action != null and action == glfw.GLFW_PRESS) {
        input_state.menu_ctrl.handleRebindKey(.{ .code = button, .is_mouse = true });
        return;
    }

    if (!input_state.mouse_captured) {
        var mx: f64 = 0;
        var my: f64 = 0;
        glfw.getCursorPos(window.?, &mx, &my);
        const scale: f64 = input_state.ui_manager.ui_scale;
        if (input_state.ui_manager.handleMouseButton(button, action, mods, @floatCast(mx / scale), @floatCast(my / scale))) return;
    }

    if (input_state.menu_ctrl.app_state != .playing) return;

    input_log.debug("Mouse {s} {s}", .{ mouseButtonName(button), actionName(action) });

    const state = input_state.game_state orelse return;
    const opts = input_state.options;

    // Handle attack button held/released for hold-to-break
    if (opts.mouseMatches(.attack, button) and input_state.mouse_captured and !state.debug_camera_active) {
        if (action == glfw.GLFW_PRESS) {
            if (!PlayerActions.attackEntity(state)) {
                state.combat.attack_held = true;
                state.swing_requested = true;
                // Creative: instant break on press (no item drop)
                if (state.game_mode == .creative) {
                    BlockOps.breakBlockNoDrop(state);
                }
            }
        } else if (action == glfw.GLFW_RELEASE) {
            state.combat.attack_held = false;
            state.combat.break_progress = 0;
            state.combat.breaking_pos = null;
        }
        return;
    }

    if (action != glfw.GLFW_PRESS) return;

    if (opts.mouseMatches(.pick_item, button) and input_state.mouse_captured) {
        if (!state.debug_camera_active) {
            BlockOps.pickBlock(state);
        }
    } else if (opts.mouseMatches(.use_item, button)) {
        if (!input_state.mouse_captured) {
            captureMouse(input_state);
        } else if (!state.debug_camera_active) {
            BlockOps.placeBlock(state);
        }
    }
}

fn framebufferSizeCallback(window: ?*glfw.Window, width: c_int, height: c_int) callconv(.c) void {
    _ = width;
    _ = height;
    const input_state = glfw.getWindowUserPointer(window.?, InputState) orelse return;
    input_state.framebuffer_resized.* = true;
}

fn captureMouse(input_state: *InputState) void {
    input_state.mouse_captured = true;
    input_state.first_mouse = true;
    glfw.setInputMode(input_state.window.handle, glfw.GLFW_CURSOR, glfw.GLFW_CURSOR_DISABLED);
    if (input_state.options.raw_mouse_input and glfw.rawMouseMotionSupported()) {
        glfw.setInputMode(input_state.window.handle, glfw.GLFW_RAW_MOUSE_MOTION, glfw.GLFW_TRUE);
    }
}

fn resetAttackState(input_state: *InputState) void {
    if (input_state.game_state) |state| {
        state.combat.attack_held = false;
        state.combat.break_progress = 0;
        state.combat.breaking_pos = null;
    }
}

fn uncaptureMouse(input_state: *InputState) void {
    input_state.mouse_captured = false;
    input_state.first_mouse = true;
    glfw.setInputMode(input_state.window.handle, glfw.GLFW_CURSOR, glfw.GLFW_CURSOR_NORMAL);
    var win_w: c_int = 0;
    var win_h: c_int = 0;
    glfw.getWindowSize(input_state.window.handle, &win_w, &win_h);
    glfw.setCursorPos(input_state.window.handle, @as(f64, @floatFromInt(win_w)) / 2.0, @as(f64, @floatFromInt(win_h)) / 2.0);
}

fn processGamepadInput(input_state: *InputState) void {
    const gp = &input_state.gamepad;
    if (!gp.connected()) return;

    switch (input_state.menu_ctrl.app_state) {
        .playing => {
            // Start → pause
            if (gp.pressed(.start)) {
                resetAttackState(input_state);
                input_state.menu_ctrl.showPauseMenu();
                uncaptureMouse(input_state);
                return;
            }

            // Y → inventory
            if (gp.pressed(.y)) {
                resetAttackState(input_state);
                if (input_state.game_state) |state| input_state.menu_ctrl.showInventory(state);
                uncaptureMouse(input_state);
                return;
            }

            const state = input_state.game_state orelse return;

            // Triggers → place / attack
            if (gp.leftTriggerPressed()) {
                if (!state.debug_camera_active) BlockOps.placeBlock(state);
            }
            if (!state.debug_camera_active) {
                // Track right trigger held for hold-to-break
                state.combat.attack_held = gp.right_trigger >= 0.5;
                if (gp.rightTriggerPressed()) {
                    state.swing_requested = true;
                    if (state.game_mode == .creative) {
                        BlockOps.breakBlockNoDrop(state);
                    }
                }
            }

            // Bumpers → hotbar scroll
            if (gp.pressed(.right_bumper)) {
                input_state.hotbar_scroll_delta -= 1.0;
            }
            if (gp.pressed(.left_bumper)) {
                input_state.hotbar_scroll_delta += 1.0;
            }

            // X → pick block
            if (gp.pressed(.x)) {
                if (!state.debug_camera_active) BlockOps.pickBlock(state);
            }

            // D-pad up/down → speed adjust (debug camera)
            if (gp.pressed(.dpad_up)) {
                input_state.move_speed = @min(input_state.move_speed * 1.25, 500.0);
            }
            if (gp.pressed(.dpad_down)) {
                input_state.move_speed = @max(input_state.move_speed / 1.25, 1.0);
            }

            // Left thumb (L3) → toggle debug camera
            if (gp.pressed(.left_thumb)) {
                input_state.debug_toggle_requested = true;
            }

            // A double-tap → mode toggle (flying/walking)
            if (gp.pressed(.a)) {
                const now = glfw.getTime();
                if (now - input_state.last_space_press_time < DOUBLE_TAP_THRESHOLD) {
                    input_state.mode_toggle_requested = true;
                    input_state.last_space_press_time = 0.0;
                } else {
                    input_state.last_space_press_time = now;
                }
            }
        },
        .pause_menu => {
            gamepadNavigateUi(input_state);
            // Start or B → resume
            if (gp.pressed(.start) or gp.pressed(.b)) {
                input_state.menu_ctrl.hidePauseMenu();
                input_state.menu_ctrl.action = .resume_game;
            }
        },
        .crafting => {
            gamepadNavigateUi(input_state);
            if (gp.pressed(.b)) {
                input_state.menu_ctrl.hideCrafting();
                captureMouse(input_state);
            }
        },
        .inventory => {
            gamepadNavigateUi(input_state);
            // Y or B → close inventory
            if (gp.pressed(.y) or gp.pressed(.b)) {
                input_state.menu_ctrl.hideInventory(input_state.game_state);
                captureMouse(input_state);
            }
        },
        .title_menu => {
            gamepadNavigateUi(input_state);
        },
        .singleplayer_menu, .multiplayer_menu => {
            gamepadNavigateUi(input_state);
            if (gp.pressed(.b)) {
                input_state.menu_ctrl.transitionTo(.title_menu);
            }
        },
        .create_world, .edit_world => {
            gamepadNavigateUi(input_state);
            if (gp.pressed(.b)) {
                input_state.menu_ctrl.transitionTo(.singleplayer_menu);
            }
        },
        .controls_title => {
            gamepadNavigateUi(input_state);
            if (gp.pressed(.b)) {
                input_state.menu_ctrl.cancelRebind();
                input_state.menu_ctrl.transitionTo(.title_menu);
            }
        },
        .controls_pause => {
            gamepadNavigateUi(input_state);
            if (gp.pressed(.b)) {
                input_state.menu_ctrl.cancelRebind();
                input_state.menu_ctrl.transitionTo(.pause_menu);
            }
        },
        else => {},
    }
}

/// Translate gamepad buttons into UI navigation events.
fn gamepadNavigateUi(input_state: *InputState) void {
    const gp = &input_state.gamepad;
    const ui = input_state.ui_manager;
    const tree = ui.topTree() orelse return;

    // D-pad or left stick → spatial focus navigation
    const nav_left = gp.pressed(.dpad_left) or gp.stickNavPressed(.left);
    const nav_right = gp.pressed(.dpad_right) or gp.stickNavPressed(.right);
    const nav_up = gp.pressed(.dpad_up) or gp.stickNavPressed(.up);
    const nav_down = gp.pressed(.dpad_down) or gp.stickNavPressed(.down);

    // Try slider/dropdown adjust first for left/right on the focused widget
    if (nav_left) {
        if (!ui.handleKey(glfw.GLFW_KEY_LEFT, glfw.GLFW_PRESS, 0))
            Focus.navigateSpatial(tree, .left);
    }
    if (nav_right) {
        if (!ui.handleKey(glfw.GLFW_KEY_RIGHT, glfw.GLFW_PRESS, 0))
            Focus.navigateSpatial(tree, .right);
    }
    if (nav_up) {
        Focus.navigateSpatial(tree, .up);
    }
    if (nav_down) {
        Focus.navigateSpatial(tree, .down);
    }

    // A → confirm (Enter)
    if (gp.pressed(.a)) {
        _ = ui.handleKey(glfw.GLFW_KEY_ENTER, glfw.GLFW_PRESS, 0);
    }
}

fn saveWorkerFn(game_state: *GameState, done: *std.atomic.Value(bool)) void {
    game_state.save();
    done.store(true, .release);
}

pub fn main() !void {
    tracy.waitForConnection();

    const tz = tracy.zone(@src(), "main");
    defer tz.end();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Ensure base app data directory exists before any subsystem tries to use it
    {
        const base_path = app_config.getAppDataPath(allocator) catch null;
        if (base_path) |p| {
            const io = std.Io.Threaded.global_single_threaded.io();
            std.Io.Dir.createDirAbsolute(io, p, .default_file) catch {};
            allocator.free(p);
        }
    }

    // Register network protocols
    const network = @import("network/network.zig");
    network.protocols.registerAll();

    // ── Parse CLI args for headless server mode ──
    const cli = parseCliArgs(allocator);
    if (cli.headless) {
        return runHeadlessServer(allocator, cli);
    }

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
        .title = "FarHorizons 0.1.0",
    });
    defer window.deinit();

    var renderer = try Renderer.init(allocator, &window, &VulkanRenderer.vtable, null);
    defer renderer.deinit();

    const framebuffer_resized = renderer.getFramebufferResizedPtr();

    const ui_manager = try allocator.create(UiManager);
    defer allocator.destroy(ui_manager);
    ui_manager.* = .{ .glfw_window = window.handle };
    renderer.setUiManager(@ptrCast(ui_manager));

    var options = Options.load(allocator);

    var menu_ctrl = MenuController.init(ui_manager, allocator);
    menu_ctrl.registerActions();
    menu_ctrl.options = &options;

    var game_state: ?GameState = null;
    var integrated_server: ?*@import("server/Server.zig").Server = null;
    var client_net: ?*ClientNetState = null;
    var save_thread: ?std.Thread = null;
    var save_done = std.atomic.Value(bool).init(false);
    defer {
        const tz2 = tracy.zone(@src(), "shutdown.cleanup");
        defer tz2.end();
        if (save_thread) |t| {
            const tz3 = tracy.zone(@src(), "shutdown.joinSave");
            defer tz3.end();
            t.join();
            save_thread = null;
        }
        if (game_state) |*state| {
            if (save_done.load(.acquire)) {
                // Save thread already ran — skip redundant save
            } else {
                state.save();
            }
            {
                const tz3 = tracy.zone(@src(), "shutdown.setGameState");
                defer tz3.end();
                renderer.setGameState(null);
            }
            state.deinit();
        }
        if (client_net) |cn| {
            cn.deinit();
            client_net = null;
        }
        if (integrated_server) |srv| {
            srv.deinit();
            integrated_server = null;
        }
    }

    var input_state = InputState{
        .window = &window,
        .framebuffer_resized = framebuffer_resized,
        .game_state = null,
        .menu_ctrl = &menu_ctrl,
        .ui_manager = ui_manager,
        .options = &options,
    };
    glfw.setWindowUserPointer(window.handle, &input_state);
    glfw.setCursorPosCallback(window.handle, cursorPosCallback);
    glfw.setScrollCallback(window.handle, scrollCallback);
    glfw.setKeyCallback(window.handle, keyCallback);
    glfw.setCharCallback(window.handle, charCallback);
    glfw.setMouseButtonCallback(window.handle, mouseButtonCallback);
    glfw.setFramebufferSizeCallback(window.handle, framebufferSizeCallback);

    input_state.gamepad.init();

    std.log.info("Entering main loop...", .{});

    var last_time = glfw.getTime();
    var tick_accumulator: f32 = 0.0;

    while (!window.shouldClose()) {
        window.pollEvents();
        input_state.gamepad.poll();
        processGamepadInput(&input_state);

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

                    const world_type_override: ?WorldState.WorldType = if (action == .create_world) menu_ctrl.selected_world_type else null;
                    const game_mode_override: ?GameState.GameMode = if (action == .create_world) menu_ctrl.selected_game_mode else null;

                    // Write seed before Storage.init so it gets loaded instead of generated
                    if (action == .create_world) {
                        if (menu_ctrl.getInputSeed()) |seed| {
                            app_config.saveSeed(allocator, world_name, seed);
                        }
                    }

                    if (world_name.len > 0) {
                        // If not connecting to remote server, start integrated server
                        if (cli.connect == null) {
                            const Server = @import("server/Server.zig").Server;
                            integrated_server = Server.init(allocator, world_name, Server.DEFAULT_PORT) catch |err| blk: {
                                std.log.warn("Integrated server failed to start: {s} (singleplayer continues without it)", .{@errorName(err)});
                                break :blk null;
                            };
                            if (integrated_server) |srv| srv.startBackground();
                        }

                        game_state = GameState.init(allocator, 1280, 720, world_name, world_type_override, game_mode_override) catch |err| blk: {
                            std.log.err("Failed to load world '{s}': {}", .{ world_name, err });
                            break :blk null;
                        };
                        if (game_state) |*state| {
                            // If connecting to remote server, set up network
                            if (cli.connect) |addr| {
                                client_net = ClientNetState.connectToServer(allocator, addr) catch |err| blk: {
                                    std.log.err("Failed to connect to server '{s}': {s}", .{ addr, @errorName(err) });
                                    break :blk null;
                                };
                                if (client_net != null) {
                                    ClientNetState.setGameState(state);
                                }
                            }

                            state.third_person_crosshair = options.third_person_crosshair;
                            renderer.setGameState(@ptrCast(state));
                            input_state.game_state = state;
                            menu_ctrl.hideTitleMenu();
                            const vk_impl: *VulkanRenderer = @ptrCast(@alignCast(renderer.impl));
                            menu_ctrl.loadHud(&vk_impl.render_state.ui_renderer);
                            menu_ctrl.app_state = .loading;
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
                .backup_world => {
                    const name = menu_ctrl.getSelectedWorldName();
                    if (name.len > 0) {
                        app_config.backupWorld(allocator, name) catch |err| {
                            std.log.err("Failed to backup world '{s}': {}", .{ name, err });
                        };
                        menu_ctrl.refreshWorldList();
                    }
                },
                .edit_world => {
                    const folder = menu_ctrl.getEditWorldOriginalName();
                    const new_display = menu_ctrl.getEditWorldNewName();
                    if (folder.len > 0 and new_display.len > 0) {
                        app_config.saveDisplayName(allocator, folder, new_display);
                        app_config.saveWorldGameMode(allocator, folder, menu_ctrl.edit_game_mode);
                    }
                    menu_ctrl.transitionTo(.singleplayer_menu);
                },
                .connect_to_server => {
                    const addr = menu_ctrl.getConnectAddress();
                    if (addr.len > 0) {
                        // Use "remote" as the local world name for multiplayer cache
                        const world_name = "remote";

                        game_state = GameState.init(allocator, 1280, 720, world_name, null, null) catch |err| blk: {
                            std.log.err("Failed to init game state for multiplayer: {}", .{err});
                            break :blk null;
                        };
                        if (game_state) |*state| {
                            client_net = ClientNetState.connectToServer(allocator, addr) catch |err| blk: {
                                std.log.err("Failed to connect to server '{s}': {s}", .{ addr, @errorName(err) });
                                break :blk null;
                            };
                            if (client_net != null) {
                                ClientNetState.setGameState(state);
                            }

                            state.third_person_crosshair = options.third_person_crosshair;
                            renderer.setGameState(@ptrCast(state));
                            input_state.game_state = state;
                            menu_ctrl.hideTitleMenu();
                            const vk_impl: *VulkanRenderer = @ptrCast(@alignCast(renderer.impl));
                            menu_ctrl.loadHud(&vk_impl.render_state.ui_renderer);
                            menu_ctrl.app_state = .loading;
                            tick_accumulator = 0.0;
                        }
                    }
                },
                .resume_game => {
                    captureMouse(&input_state);
                },
                .return_to_title => {
                    const rtt_tz = tracy.zone(@src(), "returnToTitle");
                    defer rtt_tz.end();
                    if (game_state) |*state| {
                        // Shutdown order matters to avoid deadlocks:
                        // 1. Stop the IO pipeline first — its workers hold exclusive
                        //    rw_locks on region files for batch saves. If the ThreadPool
                        //    is stopped first, its workers get starved trying to acquire
                        //    shared rw_locks for chunk reads, causing pool.stop() to hang.
                        // 2. Stop the integrated server — prevents its storage.tick()
                        //    from submitting new batch saves and contending on disk I/O.
                        // 3. Stop the renderer/ThreadPool — workers can now complete
                        //    their reads uncontested since no exclusive locks are held.
                        // 4. Save the world.
                        if (state.streaming.storage) |s| {
                            const iotz = tracy.zone(@src(), "returnToTitle.stopIoPipeline");
                            defer iotz.end();
                            s.io_pipeline.stop();
                        }
                        if (integrated_server) |srv| {
                            const sstz = tracy.zone(@src(), "returnToTitle.stopServer");
                            defer sstz.end();
                            srv.deinit();
                            integrated_server = null;
                        }
                        if (client_net) |cn| {
                            cn.deinit();
                            client_net = null;
                        }
                        {
                            const stz = tracy.zone(@src(), "returnToTitle.stopRendererPipeline");
                            defer stz.end();
                            renderer.setGameState(null);
                        }
                        save_done.store(false, .release);
                        save_thread = std.Thread.spawn(.{}, saveWorkerFn, .{ state, &save_done }) catch null;
                        if (save_thread != null) {
                            // Save runs in background — main loop stays alive
                            input_state.game_state = null;
                            uncaptureMouse(&input_state);
                            if (menu_ctrl.app_state == .pause_menu) {
                                menu_ctrl.ui_manager.removeTopScreen();
                            }
                            menu_ctrl.app_state = .saving;
                        } else {
                            // Fallback: synchronous save
                            state.save();
                            renderer.setGameState(null);
                            input_state.game_state = null;
                            state.deinit();
                            game_state = null;
                            menu_ctrl.showTitleMenu();
                        }
                    } else {
                        menu_ctrl.showTitleMenu();
                    }
                },
                .quit => {
                    break;
                },
            }
        }

        // While saving, keep draining the chunk streamer output queue so worker
        // threads don't block on backpressure (which can stall the save thread).
        if (menu_ctrl.app_state == .saving) {
            if (game_state) |*state| {
                const CS = GameState.ChunkStreamer;
                var discard_buf: [CS.MAX_OUTPUT]CS.LoadResult = undefined;
                const n = state.streaming.streamer.drainOutput(&discard_buf);
                for (discard_buf[0..n]) |result| {
                    state.chunk_pool.release(result.chunk);
                }
            }
        }

        // Check if background save completed
        if (menu_ctrl.app_state == .saving and save_done.load(.acquire)) {
            const save_tz = tracy.zone(@src(), "saveDone.cleanup");
            defer save_tz.end();
            if (save_thread) |t| {
                const jtz = tracy.zone(@src(), "saveDone.joinThread");
                defer jtz.end();
                t.join();
                save_thread = null;
            }
            // renderer.setGameState(null) already called in return_to_title handler
            if (game_state) |*state| {
                state.deinit();
            }
            game_state = null;
            // Network and integrated server already stopped in return_to_title handler.
            // Guard in case of edge cases where they weren't cleaned up yet.
            if (client_net) |cn| {
                cn.deinit();
                client_net = null;
            }
            if (integrated_server) |srv| {
                srv.deinit();
                integrated_server = null;
            }
            menu_ctrl.showTitleMenu();
        }

        // Loading → playing transition: tick world until initial chunks are ready
        if (menu_ctrl.app_state == .loading) {
            if (game_state) |*state| {
                ChunkManagement.worldTick(state);
                state.streaming.world_tick_pending = true;
                if (state.streaming.initial_load_ready) {
                    menu_ctrl.app_state = .playing;
                    captureMouse(&input_state);
                }
            }
        }

        var update_start: f64 = 0;

        if (menu_ctrl.app_state == .playing) {
            update_start = glfw.getTime();
            if (game_state) |*state| {
                if (input_state.hotbar_scroll_delta != 0.0) {
                    const delta: i32 = if (input_state.hotbar_scroll_delta < 0.0) @as(i32, 1) else @as(i32, -1);
                    const current: i32 = @intCast(state.inv.selected_slot);
                    state.inv.selected_slot = @intCast(@mod(current + delta + GameState.HOTBAR_SIZE, GameState.HOTBAR_SIZE));
                    input_state.hotbar_scroll_delta = 0.0;
                }

                if (input_state.hotbar_slot_requested) |slot| {
                    state.inv.selected_slot = slot;
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

                        const ss: f32 = options.mouse_sensitivity * 0.6 + 0.2;
                        const sens: f32 = ss * ss * ss * 8.0;
                        state.camera.look(-dx * sens * 0.15, -dy * sens * 0.15);
                    }
                }

                // Gamepad right stick → camera look
                if (input_state.gamepad.connected()) {
                    const gpx = input_state.gamepad.right_x;
                    const gpy = input_state.gamepad.right_y;
                    if (gpx != 0 or gpy != 0) {
                        state.camera.look(-gpx * Gamepad.LOOK_SPEED * delta_time, -gpy * Gamepad.LOOK_SPEED * delta_time);
                    }
                }

                if (input_state.debug_toggle_requested) {
                    input_state.debug_toggle_requested = false;
                    state.toggleDebugCamera();
                }

                if (input_state.overdraw_toggle_requested) {
                    input_state.overdraw_toggle_requested = false;
                    state.overdraw_mode = !state.overdraw_mode;
                }

                if (input_state.chunk_borders_toggle_requested) {
                    input_state.chunk_borders_toggle_requested = false;
                    state.show_chunk_borders = !state.show_chunk_borders;
                }

                if (input_state.hitbox_toggle_requested) {
                    input_state.hitbox_toggle_requested = false;
                    state.show_hitbox = !state.show_hitbox;
                }

                if (input_state.ui_toggle_requested) {
                    input_state.ui_toggle_requested = false;
                    state.show_ui = !state.show_ui;
                }

                if (input_state.gamemode_toggle_requested) {
                    input_state.gamemode_toggle_requested = false;
                    switch (state.game_mode) {
                        .creative => {
                            // Creative → Survival: force walking mode first (while still creative, so toggleMode allows it)
                            if (state.mode == .flying) PlayerMovement.toggleMode(state);
                            state.game_mode = .survival;
                        },
                        .survival => {
                            state.game_mode = .creative;
                            state.combat.health = state.combat.max_health;
                            state.combat.air_supply = state.combat.max_air;
                        },
                    }
                }

                if (input_state.debug_screen_toggle) |bit| {
                    input_state.debug_screen_toggle = null;
                    state.debug_screens ^= @as(u8, 1) << bit;
                }

                state.delta_time = delta_time;

                var forward_input: f32 = 0.0;
                var right_input: f32 = 0.0;
                var up_input: f32 = 0.0;

                if (options.isKeyHeld(window.handle, .forward)) forward_input += 1.0;
                if (options.isKeyHeld(window.handle, .back)) forward_input -= 1.0;
                if (options.isKeyHeld(window.handle, .right)) right_input += 1.0;
                if (options.isKeyHeld(window.handle, .left)) right_input -= 1.0;
                if (options.isKeyHeld(window.handle, .jump)) up_input += 1.0;
                if (options.isKeyHeld(window.handle, .sneak)) up_input -= 1.0;

                // Merge gamepad stick input (left stick = movement)
                const gp = &input_state.gamepad;
                if (gp.connected()) {
                    forward_input = std.math.clamp(forward_input - gp.left_y, -1.0, 1.0);
                    right_input = std.math.clamp(right_input + gp.left_x, -1.0, 1.0);
                    if (gp.held(.a)) up_input = std.math.clamp(up_input + 1.0, -1.0, 1.0);
                    if (gp.held(.b)) up_input = std.math.clamp(up_input - 1.0, -1.0, 1.0);
                }

                if (state.debug_camera_active) {
                    const speed = input_state.move_speed * delta_time;
                    state.camera.move(forward_input * speed, right_input * speed, up_input * speed);
                } else {
                    if (input_state.mode_toggle_requested) {
                        input_state.mode_toggle_requested = false;
                        PlayerMovement.toggleMode(state);
                    }

                    state.input_move = .{ forward_input, up_input, right_input };

                    const space_held = options.isKeyHeld(window.handle, .jump) or input_state.gamepad.held(.a);
                    state.jump_requested = space_held;
                    input_state.space_was_held = space_held;

                    tick_accumulator += delta_time;
                    if (tick_accumulator > MAX_ACCUMULATOR) tick_accumulator = MAX_ACCUMULATOR;

                    while (tick_accumulator >= GameState.TICK_INTERVAL) {
                        // Poll drop key with cooldown (~50ms: every other tick at 30Hz)
                        if (input_state.drop_cooldown > 0) {
                            input_state.drop_cooldown -= 1;
                        } else if (input_state.drop_key_held and !state.debug_camera_active) {
                            InventoryOps.dropFromSlot(state, state.inv.selected_slot, input_state.drop_key_ctrl);
                            input_state.drop_cooldown = 1;
                        }
                        state.fixedUpdate(input_state.move_speed);

                        // Send position to server if connected
                        if (client_net) |cn| {
                            const cam = state.camera;
                            cn.sendPosition(
                                .{ cam.position.x, cam.position.y, cam.position.z },
                                .{ 0, 0, 0 },
                                .{ cam.pitch, cam.yaw, 0 },
                            );
                        }

                        tick_accumulator -= GameState.TICK_INTERVAL;
                    }

                    const alpha = tick_accumulator / GameState.TICK_INTERVAL;
                    state.interpolateForRender(alpha);
                }

                menu_ctrl.updateHud(state, &input_state.gamepad);
            }
        }

        // Update inventory (must run when app_state is .inventory, not .playing)
        if (menu_ctrl.app_state == .inventory) {
            if (game_state) |*state| {
                // Keep the world ticking while inventory is open
                state.input_move = .{ 0, 0, 0 };
                state.jump_requested = false;
                tick_accumulator += delta_time;
                if (tick_accumulator > MAX_ACCUMULATOR) tick_accumulator = MAX_ACCUMULATOR;
                while (tick_accumulator >= GameState.TICK_INTERVAL) {
                    // Poll drop key with cooldown (~50ms: every other tick at 30Hz)
                    if (input_state.drop_cooldown > 0) {
                        input_state.drop_cooldown -= 1;
                    } else if (input_state.drop_key_held) {
                        if (menu_ctrl.hoveredSlot()) |slot| {
                            InventoryOps.dropFromSlot(state, slot, input_state.drop_key_ctrl);
                            input_state.drop_cooldown = 1;
                        }
                    }
                    state.fixedUpdate(input_state.move_speed);
                    tick_accumulator -= GameState.TICK_INTERVAL;
                }
                const alpha = tick_accumulator / GameState.TICK_INTERVAL;
                state.interpolateForRender(alpha);

                menu_ctrl.updateInventory(state);
                menu_ctrl.updateHud(state, &input_state.gamepad);
            }
        }

        // Update crafting screen
        if (menu_ctrl.app_state == .crafting) {
            if (game_state) |*state| {
                // Keep the world ticking while crafting is open
                state.input_move = .{ 0, 0, 0 };
                state.jump_requested = false;
                tick_accumulator += delta_time;
                if (tick_accumulator > MAX_ACCUMULATOR) tick_accumulator = MAX_ACCUMULATOR;
                while (tick_accumulator >= GameState.TICK_INTERVAL) {
                    state.fixedUpdate(input_state.move_speed);
                    tick_accumulator -= GameState.TICK_INTERVAL;
                }
                const alpha = tick_accumulator / GameState.TICK_INTERVAL;
                state.interpolateForRender(alpha);

                menu_ctrl.updateCrafting(state);
                menu_ctrl.updateHud(state, &input_state.gamepad);
            }
        }

        // Poll workbench request after game tick
        if (menu_ctrl.app_state == .playing) {
            if (game_state) |*state| {
                if (state.inv.open_workbench_requested) {
                    state.inv.open_workbench_requested = false;
                    resetAttackState(&input_state);
                    menu_ctrl.showCrafting(state, .workbench);
                    uncaptureMouse(&input_state);
                }
            }
        }

        // Sync options → game state
        if (game_state) |*state| {
            state.third_person_crosshair = options.third_person_crosshair;
            state.camera.fov = std.math.degreesToRadians(options.fov);
        }

        // Sync entity renderer with inventory viewport + third person
        {
            const vk_impl: *VulkanRenderer = @ptrCast(@alignCast(renderer.impl));
            const er = &vk_impl.render_state.entity_renderer;
            er.visible = menu_ctrl.entity_visible;
            er.viewport_x = menu_ctrl.entity_viewport[0];
            er.viewport_y = menu_ctrl.entity_viewport[1];
            er.viewport_w = menu_ctrl.entity_viewport[2];
            er.viewport_h = menu_ctrl.entity_viewport[3];
            er.rotation_y = menu_ctrl.player_rotation;
            if (game_state) |*state| {
                er.world_visible = state.third_person;
                er.world_pos = state.entities.render_pos[GameState.Entity.PLAYER];
                er.world_yaw = state.camera.yaw;
            } else {
                er.world_visible = false;
            }

            // Sync hand renderer with held block + all hand animations
            const hr = &vk_impl.render_state.hand_renderer;
            if (game_state) |*state| {
                hr.setPendingBlock(state.playerInv().hotbar[state.inv.selected_slot].block);
                if (state.swing_requested) {
                    hr.triggerSwing();
                    state.swing_requested = false;
                }
                // Continuous swing while mining in survival
                if (state.game_mode == .survival and state.combat.attack_held and state.combat.breaking_pos != null and !hr.is_swinging) {
                    hr.triggerSwing();
                }
                const P = GameState.Entity.PLAYER;
                const vel = state.entities.vel[P];
                const hspeed = @sqrt(vel[0] * vel[0] + vel[2] * vel[2]);
                const flags = state.entities.flags[P];
                const held_item = state.playerInv().hotbar[state.inv.selected_slot].block;
                const tool_info = Item.toolFromId(held_item);
                hr.updateAnimations(
                    delta_time,
                    hspeed,
                    vel[1],
                    flags.on_ground,
                    state.camera.pitch,
                    state.camera.yaw,
                    flags.on_ladder,
                    flags.in_water,
                    options.isKeyHeld(window.handle, .sneak),
                    if (tool_info) |t| t.tool_type else null,
                    if (tool_info) |t| t.tier else null,
                    state.inv.selected_slot,
                );
            } else {
                hr.setPendingBlock(WorldState.BlockState.defaultState(.air));
            }
        }

        // Tick animated textures ( 20Hz frame advancement)
        {
            const vk_impl: *VulkanRenderer = @ptrCast(@alignCast(renderer.impl));
            vk_impl.render_state.world_renderer.texture_manager.tickAnimations(delta_time);
        }

        ui_manager.tickCursorBlink(delta_time);

        if (menu_ctrl.app_state == .playing) {
            if (game_state) |*state| {
                state.frame_timing.update_ms = @floatCast((glfw.getTime() - update_start) * 1000.0);
            }
        }

        const render_start = glfw.getTime();
        try renderer.beginFrame();
        try renderer.render();
        try renderer.endFrame();

        if (menu_ctrl.app_state == .playing) {
            if (game_state) |*state| {
                state.frame_timing.render_ms = @floatCast((glfw.getTime() - render_start) * 1000.0);
                state.frame_timing.frame_ms = delta_time * 1000.0;
                state.frame_timing.smooth(delta_time);
                if (!state.debug_camera_active) {
                    state.restoreAfterRender();
                }
            }
        }

        tracy.frameMark();
    }

    {
        const tz2 = tracy.zone(@src(), "postLoop.optionsSave");
        defer tz2.end();
        options.save(allocator);
    }
    std.log.info("Shutting down...", .{});
}

// ─── CLI args and headless server ───

const CliArgs = struct {
    headless: bool = false,
    world_name: []const u8 = "world",
    port: u16 = @import("server/Server.zig").Server.DEFAULT_PORT,
    connect: ?[]const u8 = null, // ip:port to connect to as client
};

fn parseCliArgs(_: std.mem.Allocator) CliArgs {
    var result = CliArgs{};
    // Check environment variables for configuration.
    // Server: $env:FH_HEADLESS="1"; $env:FH_WORLD="myworld"; $env:FH_PORT="7777"
    // Client: $env:FH_CONNECT="127.0.0.1:7777"
    const c_getenv = std.c.getenv;
    if (c_getenv("FH_HEADLESS")) |_| {
        result.headless = true;
    }
    if (c_getenv("FH_WORLD")) |val| {
        result.world_name = std.mem.span(val);
    }
    if (c_getenv("FH_PORT")) |val| {
        result.port = std.fmt.parseInt(u16, std.mem.span(val), 10) catch result.port;
    }
    if (c_getenv("FH_CONNECT")) |val| {
        result.connect = std.mem.span(val);
    }
    return result;
}

fn runHeadlessServer(allocator: std.mem.Allocator, cli: CliArgs) !void {
    const Server = @import("server/Server.zig").Server;
    std.log.info("Starting headless server: world='{s}', port={}", .{ cli.world_name, cli.port });

    const server = Server.init(allocator, cli.world_name, cli.port) catch |err| {
        std.log.err("Failed to start server: {s}", .{@errorName(err)});
        return err;
    };
    defer server.deinit();

    // Run server on main thread (blocks until stopped)
    server.run();
}

/// Client-side network state for connecting to a remote server.
const ClientNetState = struct {
    const network = @import("network/network.zig");

    conn_manager: network.ConnectionManager,
    conn: *network.Connection,
    allocator: std.mem.Allocator,

    fn connectToServer(allocator: std.mem.Allocator, addr_str: []const u8) !*ClientNetState {
        const self = try allocator.create(ClientNetState);
        errdefer allocator.destroy(self);

        // Parse ip:port
        var ip_str: []const u8 = addr_str;
        var port: u16 = @import("server/Server.zig").Server.DEFAULT_PORT;
        if (std.mem.indexOfScalar(u8, addr_str, ':')) |colon| {
            ip_str = addr_str[0..colon];
            port = std.fmt.parseInt(u16, addr_str[colon + 1 ..], 10) catch port;
        }

        const ip = try network.Socket.resolveIp(ip_str);
        const remote = network.Address.fromIpPort(ip, port);

        self.conn_manager = try network.ConnectionManager.init(allocator, 0); // bind any port
        self.allocator = allocator;

        self.conn = try allocator.create(network.Connection);
        self.conn.* = network.Connection.init(allocator, remote, false);
        self.conn.state.store(.connected, .release); // skip handshake for now
        self.conn_manager.addConnection(self.conn);
        self.conn_manager.start();

        // Send initial handshake so server learns our address
        const handshake = @import("network/protocols/handshake.zig");
        handshake.sendClientHello(self.conn, self.conn_manager.socket, "Player");

        std.log.info("Connected to server at {}", .{remote});
        return self;
    }

    fn setGameState(state: *@import("world/GameState.zig")) void {
        @import("network/protocols/chunk_transmission.zig").client_game_state = state;
        @import("network/protocols/block_update.zig").client_game_state = state;
        @import("network/protocols/player_position.zig").client_game_state = state;
    }

    fn clearGameState() void {
        @import("network/protocols/chunk_transmission.zig").client_game_state = null;
        @import("network/protocols/block_update.zig").client_game_state = null;
        @import("network/protocols/player_position.zig").client_game_state = null;
    }

    fn sendPosition(self: *ClientNetState, pos: [3]f64, vel: [3]f64, rotation: [3]f32) void {
        @import("network/protocols/player_position.zig").sendPosition(
            self.conn,
            self.conn_manager.socket,
            pos,
            vel,
            rotation,
        );
    }

    fn deinit(self: *ClientNetState) void {
        clearGameState();
        self.conn_manager.deinit();
        self.conn.deinit();
        self.allocator.destroy(self.conn);
        self.allocator.destroy(self);
    }
};

comptime {
    if (@import("builtin").is_test) {
        _ = @import("world/WorldState.zig");
        _ = @import("world/TerrainGen.zig");
        _ = @import("world/LightEngine.zig");
        _ = @import("world/SurfaceHeightMap.zig");
        _ = @import("network/protocol.zig");
    }
}
