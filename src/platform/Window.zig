const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw.zig");
const vk = @import("volk.zig");
const tracy = @import("tracy.zig");

const win32 = if (builtin.os.tag == .windows) struct {
    const HWND = *opaque {};
    const HKEY = *align(1) opaque {};
    const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
    const KEY_READ: u32 = 0x20019;
    const DWMWA_USE_IMMERSIVE_DARK_MODE: u32 = 20;

    extern "dwmapi" fn DwmSetWindowAttribute(hwnd: HWND, attr: u32, pv: *const anyopaque, cb: u32) callconv(.c) c_long;
    extern fn glfwGetWin32Window(window: *glfw.Window) callconv(.c) ?HWND;
    extern "advapi32" fn RegOpenKeyExW(hKey: HKEY, lpSubKey: [*:0]const u16, ulOptions: u32, samDesired: u32, phkResult: *HKEY) callconv(.c) c_long;
    extern "advapi32" fn RegQueryValueExW(hKey: HKEY, lpValueName: [*:0]const u16, lpReserved: ?*u32, lpType: ?*u32, lpData: ?[*]u8, lpcbData: ?*u32) callconv(.c) c_long;
    extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.c) c_long;

    fn applySystemTheme(window_handle: *glfw.Window) void {
        const hwnd = glfwGetWin32Window(window_handle) orelse return;
        var use_dark: c_int = if (isSystemDarkMode()) 1 else 0;
        _ = DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, @ptrCast(&use_dark), @sizeOf(c_int));
    }

    fn isSystemDarkMode() bool {
        const sub_key = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize");
        const value_name = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");

        var hkey: HKEY = undefined;
        if (RegOpenKeyExW(HKEY_CURRENT_USER, sub_key, 0, KEY_READ, &hkey) != 0) return false;
        defer _ = RegCloseKey(hkey);

        var value: u32 = 1;
        var size: u32 = @sizeOf(u32);
        if (RegQueryValueExW(hkey, value_name, null, null, std.mem.asBytes(&value), &size) != 0) return false;

        return value == 0;
    }
} else struct {};

var glfw_init_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

pub const Window = struct {
    handle: *glfw.Window,
    windowed_x: c_int = 0,
    windowed_y: c_int = 0,
    windowed_width: c_int = 0,
    windowed_height: c_int = 0,

    pub const Config = struct {
        width: u32 = 1280,
        height: u32 = 720,
        title: [:0]const u8 = "FarHorizons",
    };

    pub fn init(config: Config) !Window {
        const tz = tracy.zone(@src(), "Window.init");
        defer tz.end();

        const prev_count = glfw_init_count.fetchAdd(1, .monotonic);
        errdefer _ = glfw_init_count.fetchSub(1, .monotonic);

        if (prev_count == 0) {
            try glfw.init();
            std.log.info("GLFW initialized", .{});
        }

        glfw.windowHint(glfw.GLFW_CLIENT_API, glfw.GLFW_NO_API);
        glfw.windowHint(glfw.GLFW_RESIZABLE, glfw.GLFW_TRUE);

        const handle = try glfw.createWindow(
            std.math.cast(c_int, config.width) orelse unreachable,
            std.math.cast(c_int, config.height) orelse unreachable,
            config.title.ptr,
            null,
            null,
        );

        std.log.info("Window created: {s} ({}x{})", .{ config.title, config.width, config.height });

        if (comptime builtin.os.tag == .windows) {
            win32.applySystemTheme(handle);
        }

        return Window{ .handle = handle };
    }

    pub fn deinit(self: *Window) void {
        const tz = tracy.zone(@src(), "Window.deinit");
        defer tz.end();

        glfw.destroyWindow(self.handle);
        std.log.info("Window destroyed", .{});

        const prev_count = glfw_init_count.fetchSub(1, .monotonic);
        if (prev_count == 1) {
            glfw.terminate();
            std.log.info("GLFW terminated", .{});
        }
    }

    pub fn shouldClose(self: *const Window) bool {
        return glfw.windowShouldClose(self.handle) == glfw.GLFW_TRUE;
    }

    pub fn pollEvents(_: *Window) void {
        glfw.pollEvents();
    }

    pub fn getFramebufferSize(self: *const Window) struct { width: u32, height: u32 } {
        var width: c_int = 0;
        var height: c_int = 0;
        glfw.getFramebufferSize(self.handle, &width, &height);
        return .{ .width = std.math.cast(u32, width) orelse unreachable, .height = std.math.cast(u32, height) orelse unreachable };
    }

    pub fn createSurface(self: *const Window, instance: anytype, allocator: ?*const anyopaque) !vk.VkSurfaceKHR {
        const tz = tracy.zone(@src(), "createSurface");
        defer tz.end();

        var surface: vk.VkSurfaceKHR = null;
        try glfw.createWindowSurface(instance, self.handle, allocator, &surface);
        return surface;
    }

    pub fn toggleFullscreen(self: *Window) void {
        if (glfw.getWindowMonitor(self.handle) == null) {
            // Currently windowed -> go fullscreen
            glfw.getWindowPos(self.handle, &self.windowed_x, &self.windowed_y);
            glfw.getWindowSize(self.handle, &self.windowed_width, &self.windowed_height);

            const monitor = glfw.getPrimaryMonitor() orelse return;
            const mode = glfw.getVideoMode(monitor);
            glfw.setWindowMonitor(self.handle, monitor, 0, 0, mode.width, mode.height, mode.refreshRate);
        } else {
            // Currently fullscreen -> go windowed
            glfw.setWindowMonitor(
                self.handle,
                null,
                self.windowed_x,
                self.windowed_y,
                self.windowed_width,
                self.windowed_height,
                0,
            );
        }
    }

    pub const Extensions = struct {
        names: [*]const [*:0]const u8,
        count: u32,
    };

    pub fn getRequiredExtensions() Extensions {
        var count: u32 = 0;
        const names = glfw.getRequiredInstanceExtensions(&count) orelse unreachable;
        return .{ .names = names, .count = count };
    }
};
