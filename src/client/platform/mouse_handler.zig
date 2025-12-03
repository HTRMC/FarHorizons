// Mouse handler - mirrors Minecraft's MouseHandler

const std = @import("std");
const glfw = @import("glfw");
const c = glfw.c;
const shared = @import("shared");
const Logger = shared.Logger;
const Window = @import("window.zig").Window;
const InputConstants = @import("input_constants.zig");

pub const MouseHandler = struct {
    const Self = @This();
    const logger = Logger.init("MouseHandler");

    window: *Window,

    // Mouse position
    xpos: f64 = 0,
    ypos: f64 = 0,

    // Mouse button states
    is_left_pressed: bool = false,
    is_right_pressed: bool = false,
    is_middle_pressed: bool = false,

    // Mouse grab state
    mouse_grabbed: bool = false,
    ignore_first_move: bool = true,

    // Accumulated mouse movement (for camera control)
    accumulated_dx: f64 = 0,
    accumulated_dy: f64 = 0,

    // Sensitivity settings
    sensitivity: f64 = 0.5,

    pub fn init(window: *Window) Self {
        return .{
            .window = window,
        };
    }

    pub fn setup(self: *Self) void {
        const handle = self.window.getHandle() orelse return;

        // Register self with window (window's user pointer is already set to window)
        self.window.setMouseHandler(self);

        // Set up mouse callbacks
        _ = c.glfwSetCursorPosCallback(handle, cursorPosCallback);
        _ = c.glfwSetMouseButtonCallback(handle, mouseButtonCallback);
        _ = c.glfwSetScrollCallback(handle, scrollCallback);

        // Get initial cursor position
        c.glfwGetCursorPos(handle, &self.xpos, &self.ypos);

        logger.info("Mouse handler initialized", .{});
    }

    fn cursorPosCallback(window: ?*c.GLFWwindow, xpos: f64, ypos: f64) callconv(.c) void {
        const self = getHandler(window) orelse return;

        if (self.ignore_first_move) {
            self.xpos = xpos;
            self.ypos = ypos;
            self.ignore_first_move = false;
            return;
        }

        // Accumulate mouse movement
        self.accumulated_dx += xpos - self.xpos;
        self.accumulated_dy += ypos - self.ypos;

        self.xpos = xpos;
        self.ypos = ypos;
    }

    fn mouseButtonCallback(window: ?*c.GLFWwindow, button: c_int, action: c_int, _: c_int) callconv(.c) void {
        const self = getHandler(window) orelse return;
        const pressed = action == InputConstants.PRESS;

        // Update button states
        switch (button) {
            InputConstants.MOUSE_BUTTON_LEFT => {
                self.is_left_pressed = pressed;
                // Grab mouse on left click when not grabbed (like Minecraft)
                if (pressed and !self.mouse_grabbed) {
                    self.grabMouse();
                }
            },
            InputConstants.MOUSE_BUTTON_RIGHT => self.is_right_pressed = pressed,
            InputConstants.MOUSE_BUTTON_MIDDLE => self.is_middle_pressed = pressed,
            else => {},
        }
    }

    fn scrollCallback(_: ?*c.GLFWwindow, _: f64, _: f64) callconv(.c) void {
        // TODO: Handle scroll events (hotbar selection, zoom, etc.)
    }

    fn getHandler(glfw_window: ?*c.GLFWwindow) ?*Self {
        if (glfw_window == null) return null;
        const ptr = c.glfwGetWindowUserPointer(glfw_window);
        if (ptr == null) return null;
        // User pointer is the Window, get MouseHandler from it
        const win: *Window = @ptrCast(@alignCast(ptr));
        return win.getMouseHandler();
    }

    /// Grab the mouse cursor (hide and lock to window center)
    pub fn grabMouse(self: *Self) void {
        if (self.mouse_grabbed) return;

        const handle = self.window.getHandle() orelse return;

        // Check if window is focused
        if (c.glfwGetWindowAttrib(handle, c.GLFW_FOCUSED) != c.GLFW_TRUE) {
            return;
        }

        self.mouse_grabbed = true;

        // IMPORTANT: Set ignore_first_move BEFORE any cursor operations
        // to prevent camera jump when callbacks fire during glfwSetCursorPos
        self.ignore_first_move = true;

        // Clear any accumulated movement from before grab
        self.accumulated_dx = 0;
        self.accumulated_dy = 0;

        // Center cursor position before grabbing
        const center_x: f64 = @as(f64, @floatFromInt(self.window.getFramebufferWidth())) / 2.0;
        const center_y: f64 = @as(f64, @floatFromInt(self.window.getFramebufferHeight())) / 2.0;
        self.xpos = center_x;
        self.ypos = center_y;

        // Set cursor position and disable cursor
        c.glfwSetCursorPos(handle, center_x, center_y);
        c.glfwSetInputMode(handle, InputConstants.CURSOR, InputConstants.CURSOR_DISABLED);

        // Enable raw mouse motion if supported
        if (c.glfwRawMouseMotionSupported() == c.GLFW_TRUE) {
            c.glfwSetInputMode(handle, InputConstants.RAW_MOUSE_MOTION, c.GLFW_TRUE);
        }

        logger.info("Mouse grabbed", .{});
    }

    /// Release the mouse cursor (show and unlock)
    pub fn releaseMouse(self: *Self) void {
        if (!self.mouse_grabbed) return;

        const handle = self.window.getHandle() orelse return;

        self.mouse_grabbed = false;

        // Center cursor position before releasing
        const center_x: f64 = @as(f64, @floatFromInt(self.window.getFramebufferWidth())) / 2.0;
        const center_y: f64 = @as(f64, @floatFromInt(self.window.getFramebufferHeight())) / 2.0;
        self.xpos = center_x;
        self.ypos = center_y;

        // Set cursor position and enable cursor
        c.glfwSetCursorPos(handle, center_x, center_y);
        c.glfwSetInputMode(handle, InputConstants.CURSOR, InputConstants.CURSOR_NORMAL);

        // Disable raw mouse motion
        if (c.glfwRawMouseMotionSupported() == c.GLFW_TRUE) {
            c.glfwSetInputMode(handle, InputConstants.RAW_MOUSE_MOTION, c.GLFW_FALSE);
        }

        logger.info("Mouse released", .{});
    }

    /// Toggle mouse grab state
    pub fn toggleGrab(self: *Self) void {
        if (self.mouse_grabbed) {
            self.releaseMouse();
        } else {
            self.grabMouse();
        }
    }

    /// Get accumulated mouse movement and reset accumulators
    /// Returns delta X and Y for camera rotation
    pub fn getAccumulatedMovement(self: *Self) struct { dx: f64, dy: f64 } {
        const dx = self.accumulated_dx;
        const dy = self.accumulated_dy;
        self.accumulated_dx = 0;
        self.accumulated_dy = 0;
        return .{ .dx = dx, .dy = dy };
    }

    /// Calculate camera rotation from accumulated movement
    /// Uses Minecraft's exact sensitivity formula:
    /// 1. ss = sensitivity * 0.6 + 0.2 (transforms 0-1 slider to 0.2-0.8 range)
    /// 2. sensitivityMod = ss³ (non-linear curve for fine control at low sens)
    /// 3. sens = sensitivityMod * 8.0 (final multiplier)
    /// 4. rotation = delta * sens * 0.15 (convert to degrees)
    pub fn getCameraRotation(self: *Self) struct { yaw: f64, pitch: f64 } {
        const movement = self.getAccumulatedMovement();

        // Apply Minecraft's sensitivity formula
        const ss = self.sensitivity * 0.6 + 0.2;
        const sensitivity_mod = ss * ss * ss;
        const sens = sensitivity_mod * 8.0;

        // Apply to mouse delta, then multiply by 0.15 to convert to rotation degrees
        // (Minecraft does this in Entity.turn())
        return .{
            .yaw = -movement.dx * sens * 0.15, // Negate: mouse right = look right
            .pitch = movement.dy * sens * 0.15,
        };
    }

    pub fn isMouseGrabbed(self: *const Self) bool {
        return self.mouse_grabbed;
    }

    pub fn isLeftPressed(self: *const Self) bool {
        return self.is_left_pressed;
    }

    pub fn isRightPressed(self: *const Self) bool {
        return self.is_right_pressed;
    }

    pub fn isMiddlePressed(self: *const Self) bool {
        return self.is_middle_pressed;
    }

    pub fn getXPos(self: *const Self) f64 {
        return self.xpos;
    }

    pub fn getYPos(self: *const Self) f64 {
        return self.ypos;
    }

    pub fn setSensitivity(self: *Self, sensitivity: f64) void {
        self.sensitivity = std.math.clamp(sensitivity, 0.0, 1.0);
    }
};
