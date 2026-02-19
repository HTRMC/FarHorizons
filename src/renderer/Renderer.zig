const std = @import("std");
const Window = @import("../platform/Window.zig").Window;

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    impl: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        init: *const fn (allocator: std.mem.Allocator, window: *const Window, user_data: ?*anyopaque) anyerror!*anyopaque,
        deinit: *const fn (self: *anyopaque) void,
        begin_frame: *const fn (self: *anyopaque) anyerror!void,
        end_frame: *const fn (self: *anyopaque) anyerror!void,
        render: *const fn (self: *anyopaque) anyerror!void,
        get_framebuffer_resized_ptr: *const fn (self: *anyopaque) *bool,
    };

    pub fn init(allocator: std.mem.Allocator, window: *const Window, backend: *const VTable, user_data: ?*anyopaque) !Renderer {
        const impl = try backend.init(allocator, window, user_data);
        return Renderer{
            .allocator = allocator,
            .impl = impl,
            .vtable = backend,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.vtable.deinit(self.impl);
    }

    pub fn beginFrame(self: *Renderer) !void {
        return self.vtable.begin_frame(self.impl);
    }

    pub fn endFrame(self: *Renderer) !void {
        return self.vtable.end_frame(self.impl);
    }

    pub fn render(self: *Renderer) !void {
        return self.vtable.render(self.impl);
    }

    pub fn getFramebufferResizedPtr(self: *Renderer) *bool {
        return self.vtable.get_framebuffer_resized_ptr(self.impl);
    }
};
