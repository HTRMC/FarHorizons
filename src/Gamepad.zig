const std = @import("std");
const c = @import("platform/c.zig").c;

const Gamepad = @This();

const log = std.log.scoped(.Gamepad);

pub const STICK_DEADZONE: f32 = 0.15;
pub const TRIGGER_DEADZONE: f32 = 0.1;

/// Gamepad look sensitivity (radians per second at full deflection).
pub const LOOK_SPEED: f32 = 3.0;

pub const ControllerType = enum {
    xbox,
    playstation,
    nintendo,
    unknown,

    /// Return the display label for a face button on this controller type.
    pub fn buttonLabel(self: ControllerType, btn: Button) []const u8 {
        return switch (self) {
            .playstation => switch (btn) {
                .a => "X",
                .b => "O",
                .x => "[]",
                .y => "/\\",
                .left_bumper => "L1",
                .right_bumper => "R1",
                .back => "Select",
                .start => "Options",
                .guide => "PS",
                .left_thumb => "L3",
                .right_thumb => "R3",
                .dpad_up => "Up",
                .dpad_right => "Right",
                .dpad_down => "Down",
                .dpad_left => "Left",
            },
            .nintendo => switch (btn) {
                .a => "B",
                .b => "A",
                .x => "Y",
                .y => "X",
                .left_bumper => "L",
                .right_bumper => "R",
                .back => "-",
                .start => "+",
                .guide => "Home",
                .left_thumb => "LS",
                .right_thumb => "RS",
                .dpad_up => "Up",
                .dpad_right => "Right",
                .dpad_down => "Down",
                .dpad_left => "Left",
            },
            else => switch (btn) {
                .a => "A",
                .b => "B",
                .x => "X",
                .y => "Y",
                .left_bumper => "LB",
                .right_bumper => "RB",
                .back => "Back",
                .start => "Menu",
                .guide => "Xbox",
                .left_thumb => "LS",
                .right_thumb => "RS",
                .dpad_up => "Up",
                .dpad_right => "Right",
                .dpad_down => "Down",
                .dpad_left => "Left",
            },
        };
    }

    pub fn triggerLabel(self: ControllerType, left: bool) []const u8 {
        return switch (self) {
            .playstation => if (left) "L2" else "R2",
            .nintendo => if (left) "ZL" else "ZR",
            else => if (left) "LT" else "RT",
        };
    }

    pub fn stickLabel(self: ControllerType) []const u8 {
        return switch (self) {
            .playstation => "Stick",
            else => "Stick",
        };
    }
};

pub const Button = enum(u5) {
    a = c.GLFW_GAMEPAD_BUTTON_A,
    b = c.GLFW_GAMEPAD_BUTTON_B,
    x = c.GLFW_GAMEPAD_BUTTON_X,
    y = c.GLFW_GAMEPAD_BUTTON_Y,
    left_bumper = c.GLFW_GAMEPAD_BUTTON_LEFT_BUMPER,
    right_bumper = c.GLFW_GAMEPAD_BUTTON_RIGHT_BUMPER,
    back = c.GLFW_GAMEPAD_BUTTON_BACK,
    start = c.GLFW_GAMEPAD_BUTTON_START,
    guide = c.GLFW_GAMEPAD_BUTTON_GUIDE,
    left_thumb = c.GLFW_GAMEPAD_BUTTON_LEFT_THUMB,
    right_thumb = c.GLFW_GAMEPAD_BUTTON_RIGHT_THUMB,
    dpad_up = c.GLFW_GAMEPAD_BUTTON_DPAD_UP,
    dpad_right = c.GLFW_GAMEPAD_BUTTON_DPAD_RIGHT,
    dpad_down = c.GLFW_GAMEPAD_BUTTON_DPAD_DOWN,
    dpad_left = c.GLFW_GAMEPAD_BUTTON_DPAD_LEFT,

    pub const count = @typeInfo(Button).@"enum".fields.len;
};

/// Joystick ID of the connected gamepad, or null.
jid: ?c_int = null,
controller_type: ControllerType = .unknown,

// Stick axes after deadzone
left_x: f32 = 0,
left_y: f32 = 0,
right_x: f32 = 0,
right_y: f32 = 0,
prev_left_x: f32 = 0,
prev_left_y: f32 = 0,

// Triggers (0..1 after deadzone)
left_trigger: f32 = 0,
right_trigger: f32 = 0,
prev_left_trigger: f32 = 0,
prev_right_trigger: f32 = 0,

// Button state: current frame + previous frame (for edge detection)
buttons: u16 = 0,
prev_buttons: u16 = 0,

/// Scan for an already-connected gamepad and log its name.
pub fn init(self: *Gamepad) void {
    var jid: c_int = c.GLFW_JOYSTICK_1;
    while (jid <= c.GLFW_JOYSTICK_LAST) : (jid += 1) {
        if (c.glfwJoystickIsGamepad(jid) == c.GLFW_TRUE) {
            const name = c.glfwGetGamepadName(jid);
            self.controller_type = detectControllerType(jid);
            if (name != null) {
                log.info("Gamepad detected: {s} (type: {s})", .{ name, @tagName(self.controller_type) });
            } else {
                log.info("Gamepad detected: (unknown)", .{});
            }
            self.jid = jid;
            return;
        }
    }
    log.info("No gamepad detected", .{});
}

fn detectControllerType(jid: c_int) ControllerType {
    const name_ptr = c.glfwGetGamepadName(jid);
    if (name_ptr == null) return .unknown;
    const name = std.mem.span(name_ptr);

    // PlayStation: "PS3", "PS4", "PS5", "DualShock", "DualSense", "Wireless Controller" (PS4 default)
    if (containsIgnoreCase(name, "PS3") or
        containsIgnoreCase(name, "PS4") or
        containsIgnoreCase(name, "PS5") or
        containsIgnoreCase(name, "DualShock") or
        containsIgnoreCase(name, "DualSense") or
        std.mem.eql(u8, name, "Wireless Controller"))
        return .playstation;

    // Nintendo: "Pro Controller", "Joy-Con", "Nintendo"
    if (containsIgnoreCase(name, "Nintendo") or
        containsIgnoreCase(name, "Pro Controller") or
        containsIgnoreCase(name, "Joy-Con"))
        return .nintendo;

    // Xbox: "Xbox", "X-Box", "xinput"
    if (containsIgnoreCase(name, "Xbox") or
        containsIgnoreCase(name, "X-Box") or
        containsIgnoreCase(name, "xinput"))
        return .xbox;

    // Also check GUID — Sony vendor ID is 054c
    const guid_ptr = c.glfwGetJoystickGUID(jid);
    if (guid_ptr != null) {
        const guid = std.mem.span(guid_ptr);
        // SDL GUID format: bustype(4) vendor(4) product(4) version(4) ...
        // Vendor bytes are at positions 8..12 (but byte-swapped in SDL format)
        if (guid.len >= 12) {
            // Sony vendor: 4c05 in SDL byte-swapped format = 054c
            if (std.mem.startsWith(u8, guid[8..12], "4c05"))
                return .playstation;
            // Nintendo vendor: 7e05 = 057e
            if (std.mem.startsWith(u8, guid[8..12], "7e05"))
                return .nintendo;
            // Microsoft vendor: 5e04 = 045e
            if (std.mem.startsWith(u8, guid[8..12], "5e04"))
                return .xbox;
        }
    }

    return .unknown;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

/// Returns true if a gamepad is connected.
pub fn connected(self: *const Gamepad) bool {
    return self.jid != null;
}

/// Returns true on the frame a button was first pressed.
pub fn pressed(self: *const Gamepad, btn: Button) bool {
    const mask = @as(u16, 1) << @as(u4, @intCast(@intFromEnum(btn)));
    return (self.buttons & mask) != 0 and (self.prev_buttons & mask) == 0;
}

/// Returns true while a button is held.
pub fn held(self: *const Gamepad, btn: Button) bool {
    const mask = @as(u16, 1) << @as(u4, @intCast(@intFromEnum(btn)));
    return (self.buttons & mask) != 0;
}

pub const NavDir = enum { up, down, left, right };

const STICK_NAV_THRESHOLD: f32 = 0.6;

/// Returns true on the frame the left stick crosses the nav threshold in a direction.
pub fn stickNavPressed(self: *const Gamepad, dir: NavDir) bool {
    return switch (dir) {
        .left => self.left_x <= -STICK_NAV_THRESHOLD and self.prev_left_x > -STICK_NAV_THRESHOLD,
        .right => self.left_x >= STICK_NAV_THRESHOLD and self.prev_left_x < STICK_NAV_THRESHOLD,
        .up => self.left_y <= -STICK_NAV_THRESHOLD and self.prev_left_y > -STICK_NAV_THRESHOLD,
        .down => self.left_y >= STICK_NAV_THRESHOLD and self.prev_left_y < STICK_NAV_THRESHOLD,
    };
}

/// Returns true on the frame the left trigger crosses the threshold.
pub fn leftTriggerPressed(self: *const Gamepad) bool {
    return self.left_trigger >= 0.5 and self.prev_left_trigger < 0.5;
}

/// Returns true on the frame the right trigger crosses the threshold.
pub fn rightTriggerPressed(self: *const Gamepad) bool {
    return self.right_trigger >= 0.5 and self.prev_right_trigger < 0.5;
}

/// Poll GLFW for the first connected gamepad and update state.
pub fn poll(self: *Gamepad) void {
    self.prev_buttons = self.buttons;
    self.prev_left_x = self.left_x;
    self.prev_left_y = self.left_y;
    self.prev_left_trigger = self.left_trigger;
    self.prev_right_trigger = self.right_trigger;

    // Check cached jid first; only scan all slots if it's stale
    var jid: c_int = undefined;
    var found = false;
    if (self.jid) |cached| {
        if (c.glfwJoystickIsGamepad(cached) == c.GLFW_TRUE) {
            jid = cached;
            found = true;
        }
    }
    if (!found) {
        jid = c.GLFW_JOYSTICK_1;
        while (jid <= c.GLFW_JOYSTICK_LAST) : (jid += 1) {
            if (c.glfwJoystickIsGamepad(jid) == c.GLFW_TRUE) {
                found = true;
                break;
            }
        }
    }

    if (!found) {
        if (self.jid != null) {
            log.info("Gamepad disconnected", .{});
            self.controller_type = .unknown;
        }
        self.jid = null;
        self.buttons = 0;
        self.left_x = 0;
        self.left_y = 0;
        self.right_x = 0;
        self.right_y = 0;
        self.left_trigger = 0;
        self.right_trigger = 0;
        return;
    }

    if (self.jid == null or self.jid.? != jid) {
        self.controller_type = detectControllerType(jid);
        const name = c.glfwGetGamepadName(jid);
        if (name != null) {
            log.info("Gamepad connected: {s} (type: {s})", .{ name, @tagName(self.controller_type) });
        } else {
            log.info("Gamepad connected: (unknown)", .{});
        }
    }
    self.jid = jid;

    var state: c.GLFWgamepadstate = undefined;
    if (c.glfwGetGamepadState(jid, &state) != c.GLFW_TRUE) {
        self.buttons = 0;
        return;
    }

    // Buttons
    var btns: u16 = 0;
    for (0..Button.count) |i| {
        if (state.buttons[i] == c.GLFW_PRESS) {
            btns |= @as(u16, 1) << @as(u4, @intCast(i));
        }
    }
    self.buttons = btns;

    // Sticks
    self.left_x = applyDeadzone(state.axes[c.GLFW_GAMEPAD_AXIS_LEFT_X], STICK_DEADZONE);
    self.left_y = applyDeadzone(state.axes[c.GLFW_GAMEPAD_AXIS_LEFT_Y], STICK_DEADZONE);
    self.right_x = applyDeadzone(state.axes[c.GLFW_GAMEPAD_AXIS_RIGHT_X], STICK_DEADZONE);
    self.right_y = applyDeadzone(state.axes[c.GLFW_GAMEPAD_AXIS_RIGHT_Y], STICK_DEADZONE);

    // Triggers: GLFW reports -1..1, remap to 0..1
    const raw_lt = (state.axes[c.GLFW_GAMEPAD_AXIS_LEFT_TRIGGER] + 1.0) * 0.5;
    const raw_rt = (state.axes[c.GLFW_GAMEPAD_AXIS_RIGHT_TRIGGER] + 1.0) * 0.5;
    self.left_trigger = if (raw_lt > TRIGGER_DEADZONE) raw_lt else 0;
    self.right_trigger = if (raw_rt > TRIGGER_DEADZONE) raw_rt else 0;
}

/// Apply deadzone with smooth rescaling so there's no jump at the edge.
fn applyDeadzone(value: f32, deadzone: f32) f32 {
    const abs = @abs(value);
    if (abs < deadzone) return 0;
    const sign: f32 = if (value < 0) -1.0 else 1.0;
    return sign * (abs - deadzone) / (1.0 - deadzone);
}
