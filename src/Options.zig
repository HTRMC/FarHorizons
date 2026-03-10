const std = @import("std");
const glfw = @import("platform/glfw.zig");
const app_config = @import("app_config.zig");

const Io = std.Io;
const Dir = Io.Dir;
const sep = std.fs.path.sep_str;
const log = std.log.scoped(.Options);

pub const Options = @This();

// -- Video --
fov: f32 = 70.0,
render_distance: i32 = 16,
mouse_sensitivity: f32 = 0.003,
invert_y_mouse: bool = false,
third_person_crosshair: bool = false,

// -- Keybinds (resolved GLFW codes) --
bindings: [Action.count]InputCode = defaults,

/// Resolve which GLFW key/mouse code is bound to the given action.
pub fn key(self: *const Options, action: Action) c_int {
    return self.bindings[@intFromEnum(action)].code;
}

/// Whether the action is bound to a mouse button (vs keyboard key).
pub fn isMouse(self: *const Options, action: Action) bool {
    return self.bindings[@intFromEnum(action)].is_mouse;
}

/// Check if the given key event matches an action.
pub fn keyMatches(self: *const Options, action: Action, glfw_key: c_int) bool {
    const b = self.bindings[@intFromEnum(action)];
    return !b.is_mouse and b.code == glfw_key;
}

/// Check if a mouse button event matches an action.
pub fn mouseMatches(self: *const Options, action: Action, glfw_button: c_int) bool {
    const b = self.bindings[@intFromEnum(action)];
    return b.is_mouse and b.code == glfw_button;
}

/// Poll whether a keyboard-bound action is currently held.
pub fn isKeyHeld(self: *const Options, window: *glfw.Window, action: Action) bool {
    const b = self.bindings[@intFromEnum(action)];
    if (b.is_mouse) return false;
    return glfw.getKey(window, b.code) == glfw.GLFW_PRESS;
}

// ============================================================
// Actions
// ============================================================

pub const Action = enum(u8) {
    // Gameplay
    attack,
    use_item,
    pick_item,
    forward,
    back,
    left,
    right,
    jump,
    sneak,
    speed_up,
    speed_down,

    // Hotbar
    hotbar_1,
    hotbar_2,
    hotbar_3,
    hotbar_4,
    hotbar_5,
    hotbar_6,
    hotbar_7,
    hotbar_8,
    hotbar_9,

    // Inventory
    open_inventory,

    // UI / Debug
    toggle_third_person,
    toggle_debug_camera,
    toggle_hud,
    toggle_fullscreen,
    pause,
    debug_f3,
    debug_chunk_borders, // F3+G combo target
    debug_hitbox, // F3+B combo target
    debug_screen_f4,
    debug_screen_f5,
    overdraw_mode, // Shift+F4

    pub const count = @typeInfo(Action).@"enum".fields.len;

    pub fn name(self: Action) []const u8 {
        return @tagName(self);
    }

    pub fn hotbarSlot(self: Action) ?u8 {
        return switch (self) {
            .hotbar_1 => 0,
            .hotbar_2 => 1,
            .hotbar_3 => 2,
            .hotbar_4 => 3,
            .hotbar_5 => 4,
            .hotbar_6 => 5,
            .hotbar_7 => 6,
            .hotbar_8 => 7,
            .hotbar_9 => 8,
            else => null,
        };
    }

    pub fn fromHotbarSlot(slot: u8) ?Action {
        return switch (slot) {
            0 => .hotbar_1,
            1 => .hotbar_2,
            2 => .hotbar_3,
            3 => .hotbar_4,
            4 => .hotbar_5,
            5 => .hotbar_6,
            6 => .hotbar_7,
            7 => .hotbar_8,
            8 => .hotbar_9,
            else => null,
        };
    }

    pub fn displayName(self: Action) []const u8 {
        return switch (self) {
            .attack => "Attack",
            .use_item => "Use Item",
            .pick_item => "Pick Item",
            .forward => "Forward",
            .back => "Back",
            .left => "Left",
            .right => "Right",
            .jump => "Jump",
            .sneak => "Sneak",
            .speed_up => "Speed Up",
            .speed_down => "Speed Down",
            .hotbar_1 => "Hotbar 1",
            .hotbar_2 => "Hotbar 2",
            .hotbar_3 => "Hotbar 3",
            .hotbar_4 => "Hotbar 4",
            .hotbar_5 => "Hotbar 5",
            .hotbar_6 => "Hotbar 6",
            .hotbar_7 => "Hotbar 7",
            .hotbar_8 => "Hotbar 8",
            .hotbar_9 => "Hotbar 9",
            .open_inventory => "Inventory",
            .toggle_third_person => "Third Person",
            .toggle_debug_camera => "Debug Camera",
            .toggle_hud => "Toggle HUD",
            .toggle_fullscreen => "Fullscreen",
            .pause => "Pause",
            .debug_f3 => "Debug Info",
            .debug_chunk_borders => "Chunk Borders",
            .debug_hitbox => "Player Hitbox",
            .debug_screen_f4 => "Debug Screen 2",
            .debug_screen_f5 => "Debug Screen 3",
            .overdraw_mode => "Overdraw Mode",
        };
    }
};

/// Human-readable display name for an input code (for UI buttons).
pub fn inputDisplayName(code: InputCode) []const u8 {
    if (code.is_mouse) {
        if (code.code == glfw.GLFW_MOUSE_BUTTON_LEFT) return "Left Mouse";
        if (code.code == glfw.GLFW_MOUSE_BUTTON_RIGHT) return "Right Mouse";
        if (code.code == glfw.GLFW_MOUSE_BUTTON_MIDDLE) return "Middle Mouse";
        return "Mouse ?";
    }

    // Letters A-Z
    if (code.code >= 65 and code.code <= 90) {
        const names = [_][]const u8{
            "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
            "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
        };
        return names[@intCast(code.code - 65)];
    }

    // Digits 0-9
    if (code.code >= 48 and code.code <= 57) {
        const names = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" };
        return names[@intCast(code.code - 48)];
    }

    // Named keys
    const display_map = .{
        .{ glfw.GLFW_KEY_SPACE, "Space" },
        .{ glfw.GLFW_KEY_LEFT_SHIFT, "Left Shift" },
        .{ @as(c_int, 341), "Left Ctrl" },
        .{ @as(c_int, 344), "Right Shift" },
        .{ @as(c_int, 345), "Right Ctrl" },
        .{ glfw.GLFW_KEY_ESCAPE, "Escape" },
        .{ glfw.GLFW_KEY_ENTER, "Enter" },
        .{ glfw.GLFW_KEY_TAB, "Tab" },
        .{ glfw.GLFW_KEY_BACKSPACE, "Backspace" },
        .{ glfw.GLFW_KEY_DELETE, "Delete" },
        .{ glfw.GLFW_KEY_UP, "Up" },
        .{ glfw.GLFW_KEY_DOWN, "Down" },
        .{ glfw.GLFW_KEY_LEFT, "Left" },
        .{ glfw.GLFW_KEY_RIGHT, "Right" },
        .{ glfw.GLFW_KEY_MINUS, "Minus" },
        .{ glfw.GLFW_KEY_EQUAL, "Equal" },
        .{ glfw.GLFW_KEY_KP_ADD, "Numpad +" },
        .{ glfw.GLFW_KEY_KP_SUBTRACT, "Numpad -" },
        .{ glfw.GLFW_KEY_F1, "F1" },
        .{ @as(c_int, 291), "F2" },
        .{ glfw.GLFW_KEY_F3, "F3" },
        .{ glfw.GLFW_KEY_F4, "F4" },
        .{ glfw.GLFW_KEY_F5, "F5" },
        .{ glfw.GLFW_KEY_F6, "F6" },
        .{ glfw.GLFW_KEY_F7, "F7" },
        .{ @as(c_int, 297), "F8" },
        .{ @as(c_int, 298), "F9" },
        .{ @as(c_int, 299), "F10" },
        .{ glfw.GLFW_KEY_F11, "F11" },
        .{ @as(c_int, 301), "F12" },
        .{ glfw.GLFW_KEY_HOME, "Home" },
        .{ glfw.GLFW_KEY_END, "End" },
    };

    inline for (display_map) |entry| {
        if (code.code == entry[0]) return entry[1];
    }

    return "???";
}

// ============================================================
// Input code (key or mouse button)
// ============================================================

pub const InputCode = struct {
    code: c_int,
    is_mouse: bool = false,
};

// ============================================================
// Default bindings
// ============================================================

pub const defaults: [Action.count]InputCode = blk: {
    var b: [Action.count]InputCode = undefined;
    b[@intFromEnum(Action.attack)] = .{ .code = glfw.GLFW_MOUSE_BUTTON_LEFT, .is_mouse = true };
    b[@intFromEnum(Action.use_item)] = .{ .code = glfw.GLFW_MOUSE_BUTTON_RIGHT, .is_mouse = true };
    b[@intFromEnum(Action.pick_item)] = .{ .code = glfw.GLFW_MOUSE_BUTTON_MIDDLE, .is_mouse = true };
    b[@intFromEnum(Action.forward)] = .{ .code = glfw.GLFW_KEY_W };
    b[@intFromEnum(Action.back)] = .{ .code = glfw.GLFW_KEY_S };
    b[@intFromEnum(Action.left)] = .{ .code = glfw.GLFW_KEY_A };
    b[@intFromEnum(Action.right)] = .{ .code = glfw.GLFW_KEY_D };
    b[@intFromEnum(Action.jump)] = .{ .code = glfw.GLFW_KEY_SPACE };
    b[@intFromEnum(Action.sneak)] = .{ .code = glfw.GLFW_KEY_LEFT_SHIFT };
    b[@intFromEnum(Action.speed_up)] = .{ .code = glfw.GLFW_KEY_EQUAL };
    b[@intFromEnum(Action.speed_down)] = .{ .code = glfw.GLFW_KEY_MINUS };
    b[@intFromEnum(Action.hotbar_1)] = .{ .code = glfw.GLFW_KEY_1 };
    b[@intFromEnum(Action.hotbar_2)] = .{ .code = glfw.GLFW_KEY_2 };
    b[@intFromEnum(Action.hotbar_3)] = .{ .code = glfw.GLFW_KEY_3 };
    b[@intFromEnum(Action.hotbar_4)] = .{ .code = glfw.GLFW_KEY_4 };
    b[@intFromEnum(Action.hotbar_5)] = .{ .code = glfw.GLFW_KEY_5 };
    b[@intFromEnum(Action.hotbar_6)] = .{ .code = glfw.GLFW_KEY_6 };
    b[@intFromEnum(Action.hotbar_7)] = .{ .code = glfw.GLFW_KEY_7 };
    b[@intFromEnum(Action.hotbar_8)] = .{ .code = glfw.GLFW_KEY_8 };
    b[@intFromEnum(Action.hotbar_9)] = .{ .code = glfw.GLFW_KEY_9 };
    b[@intFromEnum(Action.open_inventory)] = .{ .code = 69 }; // E
    b[@intFromEnum(Action.toggle_third_person)] = .{ .code = glfw.GLFW_KEY_F5 };
    b[@intFromEnum(Action.toggle_debug_camera)] = .{ .code = glfw.GLFW_KEY_P };
    b[@intFromEnum(Action.toggle_hud)] = .{ .code = glfw.GLFW_KEY_F1 };
    b[@intFromEnum(Action.toggle_fullscreen)] = .{ .code = glfw.GLFW_KEY_F11 };
    b[@intFromEnum(Action.pause)] = .{ .code = glfw.GLFW_KEY_ESCAPE };
    b[@intFromEnum(Action.debug_f3)] = .{ .code = glfw.GLFW_KEY_F3 };
    b[@intFromEnum(Action.debug_chunk_borders)] = .{ .code = glfw.GLFW_KEY_G };
    b[@intFromEnum(Action.debug_hitbox)] = .{ .code = glfw.GLFW_KEY_B };
    b[@intFromEnum(Action.debug_screen_f4)] = .{ .code = glfw.GLFW_KEY_F4 };
    b[@intFromEnum(Action.debug_screen_f5)] = .{ .code = glfw.GLFW_KEY_F6 };
    b[@intFromEnum(Action.overdraw_mode)] = .{ .code = glfw.GLFW_KEY_F4 };
    break :blk b;
};

// ============================================================
// Load / Save
// ============================================================

pub fn load(allocator: std.mem.Allocator) Options {
    var opts = Options{};

    const path = getOptionsPath(allocator) catch return opts;
    defer allocator.free(path);

    const io = Io.Threaded.global_single_threaded.io();
    const data = Dir.readFileAlloc(.cwd(), io, path, allocator, .unlimited) catch {
        log.info("No options.json found, using defaults", .{});
        return opts;
    };
    defer allocator.free(data);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| {
        log.warn("Failed to parse options.json: {}", .{err});
        return opts;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return opts,
    };

    // Video settings
    if (root.get("fov")) |v| {
        if (asFloat(v)) |f| opts.fov = @floatCast(f);
    }
    if (root.get("renderDistance")) |v| {
        if (asInt(v)) |i| opts.render_distance = @intCast(std.math.clamp(i, 2, 64));
    }
    if (root.get("mouseSensitivity")) |v| {
        if (asFloat(v)) |f| opts.mouse_sensitivity = @floatCast(f);
    }
    if (root.get("invertYMouse")) |v| {
        if (v == .bool) opts.invert_y_mouse = v.bool;
    }
    if (root.get("thirdPersonCrosshair")) |v| {
        if (v == .bool) opts.third_person_crosshair = v.bool;
    }

    // Keybinds
    if (root.get("keybinds")) |kb_val| {
        if (kb_val == .object) {
            const kb = kb_val.object;
            inline for (@typeInfo(Action).@"enum".fields) |field| {
                if (kb.get(field.name)) |v| {
                    if (v == .string) {
                        if (parseKeyName(v.string)) |code| {
                            opts.bindings[field.value] = code;
                        } else {
                            log.warn("Unknown key name '{s}' for action '{s}'", .{ v.string, field.name });
                        }
                    }
                }
            }
        }
    }

    log.info("Loaded options.json", .{});
    return opts;
}

pub fn save(self: *const Options, allocator: std.mem.Allocator) void {
    const path = getOptionsPath(allocator) catch return;
    defer allocator.free(path);

    const io = Io.Threaded.global_single_threaded.io();
    const file = Dir.createFileAbsolute(io, path, .{}) catch |err| {
        log.warn("Failed to create options.json: {}", .{err});
        return;
    };
    defer file.close(io);

    var buf: [8192]u8 = undefined;
    var pos: usize = 0;

    pos += copy(buf[pos..], "{\n");

    // Settings
    pos += fmtLine(&buf, pos, "  \"fov\": {d:.1},\n", .{self.fov});
    pos += fmtLine(&buf, pos, "  \"renderDistance\": {d},\n", .{self.render_distance});
    pos += fmtLine(&buf, pos, "  \"mouseSensitivity\": {d:.6},\n", .{self.mouse_sensitivity});
    pos += fmtLine(&buf, pos, "  \"invertYMouse\": {s},\n", .{if (self.invert_y_mouse) "true" else "false"});
    pos += fmtLine(&buf, pos, "  \"thirdPersonCrosshair\": {s},\n", .{if (self.third_person_crosshair) "true" else "false"});

    // Keybinds
    pos += copy(buf[pos..], "\n  \"keybinds\": {\n");

    const fields = @typeInfo(Action).@"enum".fields;
    inline for (fields, 0..) |field, i| {
        const code = self.bindings[field.value];
        const key_str = keyCodeToName(code);
        pos += fmtLine(&buf, pos, "    \"{s}\": \"{s}\"", .{ field.name, key_str });
        if (i < fields.len - 1) {
            pos += copy(buf[pos..], ",\n");
        } else {
            pos += copy(buf[pos..], "\n");
        }
    }

    pos += copy(buf[pos..], "  }\n}\n");

    file.writePositionalAll(io, buf[0..pos], 0) catch |err| {
        log.warn("Failed to write options.json: {}", .{err});
        return;
    };
    log.info("Saved options.json", .{});
}

// ============================================================
// Key name ↔ GLFW code mapping
// ============================================================

fn parseKeyName(name_str: []const u8) ?InputCode {
    // Mouse buttons
    if (eql(name_str, "key.mouse.left")) return .{ .code = glfw.GLFW_MOUSE_BUTTON_LEFT, .is_mouse = true };
    if (eql(name_str, "key.mouse.right")) return .{ .code = glfw.GLFW_MOUSE_BUTTON_RIGHT, .is_mouse = true };
    if (eql(name_str, "key.mouse.middle")) return .{ .code = glfw.GLFW_MOUSE_BUTTON_MIDDLE, .is_mouse = true };

    // Must start with "key.keyboard."
    const prefix = "key.keyboard.";
    if (name_str.len <= prefix.len) return null;
    if (!std.mem.startsWith(u8, name_str, prefix)) return null;
    const suffix = name_str[prefix.len..];

    // Single character keys (a-z, 0-9)
    if (suffix.len == 1) {
        const ch = suffix[0];
        if (ch >= 'a' and ch <= 'z') return .{ .code = @as(c_int, ch - 'a') + 65 }; // GLFW_KEY_A = 65
        if (ch >= '0' and ch <= '9') return .{ .code = @as(c_int, ch - '0') + 48 }; // GLFW_KEY_0 = 48
    }

    // Named keys
    const key_map = .{
        .{ "space", glfw.GLFW_KEY_SPACE },
        .{ "left.shift", glfw.GLFW_KEY_LEFT_SHIFT },
        .{ "left.control", @as(c_int, 341) }, // GLFW_KEY_LEFT_CONTROL
        .{ "right.shift", @as(c_int, 344) }, // GLFW_KEY_RIGHT_SHIFT
        .{ "right.control", @as(c_int, 345) }, // GLFW_KEY_RIGHT_CONTROL
        .{ "escape", glfw.GLFW_KEY_ESCAPE },
        .{ "enter", glfw.GLFW_KEY_ENTER },
        .{ "tab", glfw.GLFW_KEY_TAB },
        .{ "backspace", glfw.GLFW_KEY_BACKSPACE },
        .{ "delete", glfw.GLFW_KEY_DELETE },
        .{ "up", glfw.GLFW_KEY_UP },
        .{ "down", glfw.GLFW_KEY_DOWN },
        .{ "left", glfw.GLFW_KEY_LEFT },
        .{ "right", glfw.GLFW_KEY_RIGHT },
        .{ "minus", glfw.GLFW_KEY_MINUS },
        .{ "equal", glfw.GLFW_KEY_EQUAL },
        .{ "keypad.add", glfw.GLFW_KEY_KP_ADD },
        .{ "keypad.subtract", glfw.GLFW_KEY_KP_SUBTRACT },
        .{ "f1", glfw.GLFW_KEY_F1 },
        .{ "f2", @as(c_int, 291) },
        .{ "f3", glfw.GLFW_KEY_F3 },
        .{ "f4", glfw.GLFW_KEY_F4 },
        .{ "f5", glfw.GLFW_KEY_F5 },
        .{ "f6", glfw.GLFW_KEY_F6 },
        .{ "f7", glfw.GLFW_KEY_F7 },
        .{ "f8", @as(c_int, 297) },
        .{ "f9", @as(c_int, 298) },
        .{ "f10", @as(c_int, 299) },
        .{ "f11", glfw.GLFW_KEY_F11 },
        .{ "f12", @as(c_int, 301) },
        .{ "home", glfw.GLFW_KEY_HOME },
        .{ "end", glfw.GLFW_KEY_END },
    };

    inline for (key_map) |entry| {
        if (eql(suffix, entry[0])) return .{ .code = entry[1] };
    }

    return null;
}

fn keyCodeToName(code: InputCode) []const u8 {
    // Mouse buttons
    if (code.is_mouse) {
        if (code.code == glfw.GLFW_MOUSE_BUTTON_LEFT) return "key.mouse.left";
        if (code.code == glfw.GLFW_MOUSE_BUTTON_RIGHT) return "key.mouse.right";
        if (code.code == glfw.GLFW_MOUSE_BUTTON_MIDDLE) return "key.mouse.middle";
        return "key.mouse.unknown";
    }

    // Letters A-Z (65-90)
    if (code.code >= 65 and code.code <= 90) {
        const letter_names = [_][]const u8{
            "key.keyboard.a", "key.keyboard.b", "key.keyboard.c", "key.keyboard.d",
            "key.keyboard.e", "key.keyboard.f", "key.keyboard.g", "key.keyboard.h",
            "key.keyboard.i", "key.keyboard.j", "key.keyboard.k", "key.keyboard.l",
            "key.keyboard.m", "key.keyboard.n", "key.keyboard.o", "key.keyboard.p",
            "key.keyboard.q", "key.keyboard.r", "key.keyboard.s", "key.keyboard.t",
            "key.keyboard.u", "key.keyboard.v", "key.keyboard.w", "key.keyboard.x",
            "key.keyboard.y", "key.keyboard.z",
        };
        return letter_names[@intCast(code.code - 65)];
    }

    // Digits 0-9 (48-57)
    if (code.code >= 48 and code.code <= 57) {
        const digit_names = [_][]const u8{
            "key.keyboard.0", "key.keyboard.1", "key.keyboard.2", "key.keyboard.3",
            "key.keyboard.4", "key.keyboard.5", "key.keyboard.6", "key.keyboard.7",
            "key.keyboard.8", "key.keyboard.9",
        };
        return digit_names[@intCast(code.code - 48)];
    }

    // Named keys
    const named_map = .{
        .{ glfw.GLFW_KEY_SPACE, "key.keyboard.space" },
        .{ glfw.GLFW_KEY_LEFT_SHIFT, "key.keyboard.left.shift" },
        .{ @as(c_int, 341), "key.keyboard.left.control" },
        .{ @as(c_int, 344), "key.keyboard.right.shift" },
        .{ @as(c_int, 345), "key.keyboard.right.control" },
        .{ glfw.GLFW_KEY_ESCAPE, "key.keyboard.escape" },
        .{ glfw.GLFW_KEY_ENTER, "key.keyboard.enter" },
        .{ glfw.GLFW_KEY_TAB, "key.keyboard.tab" },
        .{ glfw.GLFW_KEY_BACKSPACE, "key.keyboard.backspace" },
        .{ glfw.GLFW_KEY_DELETE, "key.keyboard.delete" },
        .{ glfw.GLFW_KEY_UP, "key.keyboard.up" },
        .{ glfw.GLFW_KEY_DOWN, "key.keyboard.down" },
        .{ glfw.GLFW_KEY_LEFT, "key.keyboard.left" },
        .{ glfw.GLFW_KEY_RIGHT, "key.keyboard.right" },
        .{ glfw.GLFW_KEY_MINUS, "key.keyboard.minus" },
        .{ glfw.GLFW_KEY_EQUAL, "key.keyboard.equal" },
        .{ glfw.GLFW_KEY_KP_ADD, "key.keyboard.keypad.add" },
        .{ glfw.GLFW_KEY_KP_SUBTRACT, "key.keyboard.keypad.subtract" },
        .{ glfw.GLFW_KEY_F1, "key.keyboard.f1" },
        .{ @as(c_int, 291), "key.keyboard.f2" },
        .{ glfw.GLFW_KEY_F3, "key.keyboard.f3" },
        .{ glfw.GLFW_KEY_F4, "key.keyboard.f4" },
        .{ glfw.GLFW_KEY_F5, "key.keyboard.f5" },
        .{ glfw.GLFW_KEY_F6, "key.keyboard.f6" },
        .{ glfw.GLFW_KEY_F7, "key.keyboard.f7" },
        .{ @as(c_int, 297), "key.keyboard.f8" },
        .{ @as(c_int, 298), "key.keyboard.f9" },
        .{ @as(c_int, 299), "key.keyboard.f10" },
        .{ glfw.GLFW_KEY_F11, "key.keyboard.f11" },
        .{ @as(c_int, 301), "key.keyboard.f12" },
        .{ glfw.GLFW_KEY_HOME, "key.keyboard.home" },
        .{ glfw.GLFW_KEY_END, "key.keyboard.end" },
    };

    inline for (named_map) |entry| {
        if (code.code == entry[0]) return entry[1];
    }

    return "key.keyboard.unknown";
}

// ============================================================
// Helpers
// ============================================================

fn getOptionsPath(allocator: std.mem.Allocator) ![]const u8 {
    const base = try app_config.getAppDataPath(allocator);
    defer allocator.free(base);
    return std.fmt.allocPrint(allocator, "{s}" ++ sep ++ "options.json", .{base});
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn asFloat(v: std.json.Value) ?f64 {
    return switch (v) {
        .float => v.float,
        .integer => @floatFromInt(v.integer),
        else => null,
    };
}

fn asInt(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => v.integer,
        .float => @intFromFloat(v.float),
        else => null,
    };
}

fn copy(dst: []u8, src: []const u8) usize {
    const len = @min(dst.len, src.len);
    @memcpy(dst[0..len], src[0..len]);
    return len;
}

fn fmtLine(buf: *[8192]u8, pos: usize, comptime fmt: []const u8, args: anytype) usize {
    const result = std.fmt.bufPrint(buf[pos..], fmt, args) catch return 0;
    return result.len;
}
