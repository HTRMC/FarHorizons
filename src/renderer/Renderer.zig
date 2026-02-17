const std = @import("std");
const Window = @import("../platform/Window.zig").Window;

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    impl: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        init: *const fn (allocator: std.mem.Allocator, window: *const Window) anyerror!*anyopaque,
        deinit: *const fn (self: *anyopaque) void,
        begin_frame: *const fn (self: *anyopaque) anyerror!void,
        end_frame: *const fn (self: *anyopaque) anyerror!void,
        render: *const fn (self: *anyopaque) anyerror!void,
        rotate_camera: *const fn (self: *anyopaque, delta_azimuth: f32, delta_elevation: f32) void,
        zoom_camera: *const fn (self: *anyopaque, delta_distance: f32) void,
    };

    pub fn init(allocator: std.mem.Allocator, window: *const Window, backend: *const VTable) !Renderer {
        const impl = try backend.init(allocator, window);
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

    pub fn rotateCamera(self: *Renderer, delta_azimuth: f32, delta_elevation: f32) void {
        self.vtable.rotate_camera(self.impl, delta_azimuth, delta_elevation);
    }

    pub fn zoomCamera(self: *Renderer, delta_distance: f32) void {
        self.vtable.zoom_camera(self.impl, delta_distance);
    }
};
