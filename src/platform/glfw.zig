const std = @import("std");
const c = @import("c.zig").c;
const vk = @import("volk.zig");

pub const Window = c.GLFWwindow;
pub const Monitor = c.GLFWmonitor;
pub const VidMode = c.GLFWvidmode;

pub const GLFW_CLIENT_API = c.GLFW_CLIENT_API;
pub const GLFW_NO_API = c.GLFW_NO_API;
pub const GLFW_RESIZABLE = c.GLFW_RESIZABLE;
pub const GLFW_VISIBLE = c.GLFW_VISIBLE;
pub const GLFW_DECORATED = c.GLFW_DECORATED;
pub const GLFW_FOCUSED = c.GLFW_FOCUSED;
pub const GLFW_MAXIMIZED = c.GLFW_MAXIMIZED;
pub const GLFW_TRUE = c.GLFW_TRUE;
pub const GLFW_FALSE = c.GLFW_FALSE;

pub const GLFW_KEY_W = c.GLFW_KEY_W;
pub const GLFW_KEY_A = c.GLFW_KEY_A;
pub const GLFW_KEY_S = c.GLFW_KEY_S;
pub const GLFW_KEY_D = c.GLFW_KEY_D;
pub const GLFW_KEY_SPACE = c.GLFW_KEY_SPACE;
pub const GLFW_KEY_LEFT_SHIFT = c.GLFW_KEY_LEFT_SHIFT;
pub const GLFW_KEY_ESCAPE = c.GLFW_KEY_ESCAPE;
pub const GLFW_KEY_UP = c.GLFW_KEY_UP;
pub const GLFW_KEY_DOWN = c.GLFW_KEY_DOWN;
pub const GLFW_KEY_LEFT = c.GLFW_KEY_LEFT;
pub const GLFW_KEY_RIGHT = c.GLFW_KEY_RIGHT;
pub const GLFW_KEY_1 = c.GLFW_KEY_1;
pub const GLFW_KEY_2 = c.GLFW_KEY_2;
pub const GLFW_KEY_3 = c.GLFW_KEY_3;
pub const GLFW_KEY_4 = c.GLFW_KEY_4;
pub const GLFW_KEY_5 = c.GLFW_KEY_5;
pub const GLFW_KEY_6 = c.GLFW_KEY_6;
pub const GLFW_KEY_7 = c.GLFW_KEY_7;
pub const GLFW_KEY_8 = c.GLFW_KEY_8;
pub const GLFW_KEY_9 = c.GLFW_KEY_9;
pub const GLFW_KEY_N = c.GLFW_KEY_N;
pub const GLFW_KEY_P = c.GLFW_KEY_P;
pub const GLFW_KEY_Y = c.GLFW_KEY_Y;
pub const GLFW_KEY_ENTER = c.GLFW_KEY_ENTER;
pub const GLFW_KEY_BACKSPACE = c.GLFW_KEY_BACKSPACE;
pub const GLFW_KEY_DELETE = c.GLFW_KEY_DELETE;
pub const GLFW_KEY_F4 = c.GLFW_KEY_F4;
pub const GLFW_KEY_F11 = c.GLFW_KEY_F11;
pub const GLFW_PRESS = c.GLFW_PRESS;
pub const GLFW_RELEASE = c.GLFW_RELEASE;
pub const GLFW_REPEAT = c.GLFW_REPEAT;

pub const GLFW_MOUSE_BUTTON_LEFT = c.GLFW_MOUSE_BUTTON_LEFT;
pub const GLFW_MOUSE_BUTTON_RIGHT = c.GLFW_MOUSE_BUTTON_RIGHT;
pub const GLFW_CURSOR = c.GLFW_CURSOR;
pub const GLFW_CURSOR_DISABLED = c.GLFW_CURSOR_DISABLED;
pub const GLFW_CURSOR_NORMAL = c.GLFW_CURSOR_NORMAL;
pub const GLFW_MOUSE_BUTTON_MIDDLE = c.GLFW_MOUSE_BUTTON_MIDDLE;

pub const GLFW_KEY_TAB = c.GLFW_KEY_TAB;
pub const GLFW_KEY_HOME = c.GLFW_KEY_HOME;
pub const GLFW_KEY_END = c.GLFW_KEY_END;
pub const GLFW_MOD_SHIFT = c.GLFW_MOD_SHIFT;
pub const GLFW_MOD_CONTROL = c.GLFW_MOD_CONTROL;

pub const GlfwError = error{
    InitFailed,
    WindowCreationFailed,
    SurfaceCreationFailed,
};

pub fn init() GlfwError!void {
    if (c.glfwInit() == GLFW_FALSE) {
        return error.InitFailed;
    }
}

pub fn terminate() void {
    c.glfwTerminate();
}

pub fn windowHint(hint: c_int, value: c_int) void {
    c.glfwWindowHint(hint, value);
}

pub fn createWindow(
    width: c_int,
    height: c_int,
    title: [*:0]const u8,
    monitor: ?*Monitor,
    share: ?*Window,
) GlfwError!*Window {
    return c.glfwCreateWindow(width, height, title, monitor, share) orelse error.WindowCreationFailed;
}

pub fn destroyWindow(window: *Window) void {
    c.glfwDestroyWindow(window);
}

pub fn windowShouldClose(window: *Window) c_int {
    return c.glfwWindowShouldClose(window);
}

pub fn setWindowShouldClose(window: *Window, value: c_int) void {
    c.glfwSetWindowShouldClose(window, value);
}

pub fn pollEvents() void {
    c.glfwPollEvents();
}

pub fn waitEvents() void {
    c.glfwWaitEvents();
}

pub fn getFramebufferSize(window: *Window, width: *c_int, height: *c_int) void {
    c.glfwGetFramebufferSize(window, width, height);
}

pub fn getKey(window: *Window, key: c_int) c_int {
    return c.glfwGetKey(window, key);
}

pub fn setKeyCallback(window: *Window, callback: ?*const fn (?*Window, c_int, c_int, c_int, c_int) callconv(.c) void) void {
    _ = c.glfwSetKeyCallback(window, callback);
}

pub fn setFramebufferSizeCallback(window: *Window, callback: ?*const fn (?*Window, c_int, c_int) callconv(.c) void) void {
    _ = c.glfwSetFramebufferSizeCallback(window, callback);
}

pub fn setWindowUserPointer(window: *Window, pointer: anytype) void {
    c.glfwSetWindowUserPointer(window, pointer);
}

pub fn getWindowUserPointer(window: *Window, comptime T: type) ?*T {
    const ptr = c.glfwGetWindowUserPointer(window) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

pub fn setScrollCallback(window: *Window, callback: ?*const fn (?*Window, f64, f64) callconv(.c) void) void {
    _ = c.glfwSetScrollCallback(window, callback);
}

pub fn setCharCallback(window: *Window, callback: ?*const fn (?*Window, c_uint) callconv(.c) void) void {
    _ = c.glfwSetCharCallback(window, callback);
}

pub fn setMouseButtonCallback(window: *Window, callback: ?*const fn (?*Window, c_int, c_int, c_int) callconv(.c) void) void {
    _ = c.glfwSetMouseButtonCallback(window, callback);
}

pub fn setCursorPosCallback(window: *Window, callback: ?*const fn (?*Window, f64, f64) callconv(.c) void) void {
    _ = c.glfwSetCursorPosCallback(window, callback);
}

pub fn getCursorPos(window: *Window, xpos: *f64, ypos: *f64) void {
    c.glfwGetCursorPos(window, xpos, ypos);
}

pub fn setCursorPos(window: *Window, xpos: f64, ypos: f64) void {
    c.glfwSetCursorPos(window, xpos, ypos);
}

pub fn setInputMode(window: *Window, mode: c_int, value: c_int) void {
    c.glfwSetInputMode(window, mode, value);
}

pub fn getPrimaryMonitor() ?*Monitor {
    return c.glfwGetPrimaryMonitor();
}

pub fn getVideoMode(monitor: *Monitor) *const VidMode {
    return c.glfwGetVideoMode(monitor);
}

pub fn setWindowMonitor(
    window: *Window,
    monitor: ?*Monitor,
    xpos: c_int,
    ypos: c_int,
    width: c_int,
    height: c_int,
    refresh_rate: c_int,
) void {
    c.glfwSetWindowMonitor(window, monitor, xpos, ypos, width, height, refresh_rate);
}

pub fn getWindowMonitor(window: *Window) ?*Monitor {
    return c.glfwGetWindowMonitor(window);
}

pub fn getWindowPos(window: *Window, xpos: *c_int, ypos: *c_int) void {
    c.glfwGetWindowPos(window, xpos, ypos);
}

pub fn getWindowSize(window: *Window, width: *c_int, height: *c_int) void {
    c.glfwGetWindowSize(window, width, height);
}

pub fn getTime() f64 {
    return c.glfwGetTime();
}

pub fn getRequiredInstanceExtensions(count: *u32) ?[*]const [*:0]const u8 {
    const extensions = c.glfwGetRequiredInstanceExtensions(count);
    if (extensions == null) return null;
    return @ptrCast(extensions);
}

pub fn createWindowSurface(
    instance: anytype,
    window: *Window,
    allocator: ?*const anyopaque,
    surface: *vk.VkSurfaceKHR,
) GlfwError!void {
    const result = c.glfwCreateWindowSurface(instance, window, @ptrCast(@alignCast(allocator)), surface);
    if (result != vk.VK_SUCCESS) {
        return error.SurfaceCreationFailed;
    }
}
