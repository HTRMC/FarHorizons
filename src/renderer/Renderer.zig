const std = @import("std");

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    impl: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        init: *const fn (allocator: std.mem.Allocator) anyerror!*anyopaque,
        deinit: *const fn (self: *anyopaque) void,
        begin_frame: *const fn (self: *anyopaque) anyerror!void,
        end_frame: *const fn (self: *anyopaque) anyerror!void,
        render: *const fn (self: *anyopaque) anyerror!void,
    };

    pub fn init(allocator: std.mem.Allocator, backend: *const VTable) !Renderer {
        const impl = try backend.init(allocator);
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
};
