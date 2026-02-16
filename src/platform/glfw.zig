const std = @import("std");
const c = @import("c.zig").c;
const vk = @import("volk.zig");

// Re-export types
pub const Window = c.GLFWwindow;
pub const Monitor = c.GLFWmonitor;
pub const VidMode = c.GLFWvidmode;

// Re-export constants
pub const GLFW_CLIENT_API = c.GLFW_CLIENT_API;
pub const GLFW_NO_API = c.GLFW_NO_API;
pub const GLFW_RESIZABLE = c.GLFW_RESIZABLE;
pub const GLFW_VISIBLE = c.GLFW_VISIBLE;
pub const GLFW_DECORATED = c.GLFW_DECORATED;
pub const GLFW_FOCUSED = c.GLFW_FOCUSED;
pub const GLFW_MAXIMIZED = c.GLFW_MAXIMIZED;
pub const GLFW_TRUE = c.GLFW_TRUE;
pub const GLFW_FALSE = c.GLFW_FALSE;

// Error type
pub const GlfwError = error{
    InitFailed,
    WindowCreationFailed,
    SurfaceCreationFailed,
};

// Safe GLFW function wrappers
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

pub fn setKeyCallback(window: *Window, callback: ?*const fn (?*Window, c_int, c_int, c_int, c_int) callconv(.C) void) void {
    _ = c.glfwSetKeyCallback(window, callback);
}

pub fn setFramebufferSizeCallback(window: *Window, callback: ?*const fn (?*Window, c_int, c_int) callconv(.C) void) void {
    _ = c.glfwSetFramebufferSizeCallback(window, callback);
}

pub fn setWindowUserPointer(window: *Window, pointer: ?*anyopaque) void {
    c.glfwSetWindowUserPointer(window, pointer);
}

pub fn getWindowUserPointer(window: *Window) ?*anyopaque {
    return c.glfwGetWindowUserPointer(window);
}

pub fn getRequiredInstanceExtensions(count: *u32) ?[*]const [*:0]const u8 {
    // Returns null if GLFW is not initialized
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
