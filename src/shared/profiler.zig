/// Profiler - Tracy integration wrapper
///
/// Provides a consistent profiling interface that compiles to no-ops when Tracy is disabled.
/// Build with `-Dtracy=true` to enable Tracy profiling.
///
/// Usage:
///   const profiler = @import("profiler.zig");
///
///   fn myFunction() void {
///       const zone = profiler.trace(@src());
///       defer zone.end();
///       // ... function body
///   }
///
///   // In main loop:
///   profiler.frameMark();

const std = @import("std");
const build_options = @import("build_options");

/// Whether Tracy profiling is enabled at compile time
pub const enabled = build_options.tracy_enabled;

// Conditional import of Tracy C API
const c = if (enabled) @cImport({
    @cDefine("TRACY_ENABLE", "1");
    @cInclude("tracy/TracyC.h");
}) else struct {};

/// Source location data for Tracy zones
pub const SourceLocationData = extern struct {
    name: ?[*:0]const u8,
    function: [*:0]const u8,
    file: [*:0]const u8,
    line: u32,
    color: u32,
};

/// A profiling zone that measures execution time
pub const Zone = if (enabled)
    extern struct {
        id: u32,
        active: i32,

        const Self = @This();

        /// End the profiling zone
        pub inline fn end(self: Self) void {
            c.___tracy_emit_zone_end(.{ .id = self.id, .active = self.active });
        }

        /// Set zone name (displayed in profiler)
        pub inline fn setName(self: Self, name: []const u8) void {
            c.___tracy_emit_zone_name(.{ .id = self.id, .active = self.active }, name.ptr, name.len);
        }

        /// Set zone text (additional info displayed in profiler)
        pub inline fn setText(self: Self, text: []const u8) void {
            c.___tracy_emit_zone_text(.{ .id = self.id, .active = self.active }, text.ptr, text.len);
        }

        /// Set zone color (RRGGBB format)
        pub inline fn setColor(self: Self, color: u32) void {
            c.___tracy_emit_zone_color(.{ .id = self.id, .active = self.active }, color);
        }

        /// Set zone value (numeric value displayed in profiler)
        pub inline fn setValue(self: Self, value: u64) void {
            c.___tracy_emit_zone_value(.{ .id = self.id, .active = self.active }, value);
        }
    }
else
    struct {
        const Self = @This();

        pub inline fn end(self: Self) void {
            _ = self;
        }

        pub inline fn setName(self: Self, name: []const u8) void {
            _ = self;
            _ = name;
        }

        pub inline fn setText(self: Self, text: []const u8) void {
            _ = self;
            _ = text;
        }

        pub inline fn setColor(self: Self, color: u32) void {
            _ = self;
            _ = color;
        }

        pub inline fn setValue(self: Self, value: u64) void {
            _ = self;
            _ = value;
        }
    };

/// Start a profiling zone at the given source location
pub inline fn trace(comptime src: std.builtin.SourceLocation) Zone {
    if (enabled) {
        const loc = comptime SourceLocationData{
            .name = null,
            .function = src.fn_name.ptr,
            .file = src.file.ptr,
            .line = src.line,
            .color = 0,
        };
        const ctx = c.___tracy_emit_zone_begin(@ptrCast(&loc), 1);
        return .{ .id = ctx.id, .active = ctx.active };
    }
    return .{};
}

/// Start a named profiling zone
pub inline fn traceNamed(comptime name: [:0]const u8) Zone {
    if (enabled) {
        const loc = comptime SourceLocationData{
            .name = name.ptr,
            .function = "",
            .file = "",
            .line = 0,
            .color = 0,
        };
        const ctx = c.___tracy_emit_zone_begin(@ptrCast(&loc), 1);
        return .{ .id = ctx.id, .active = ctx.active };
    }
    return .{};
}

/// Mark the end of a frame (call once per frame in main loop)
pub inline fn frameMark() void {
    if (enabled) {
        c.___tracy_emit_frame_mark(null);
    }
}

/// Mark the end of a named frame (for secondary frame sets like "Physics" or "Network")
pub inline fn frameMarkNamed(comptime name: [:0]const u8) void {
    if (enabled) {
        c.___tracy_emit_frame_mark(name.ptr);
    }
}

/// Log a message to Tracy timeline
pub inline fn message(msg: []const u8) void {
    if (enabled) {
        c.___tracy_emit_message(msg.ptr, msg.len, 0);
    }
}

/// Log a message with color to Tracy timeline
pub inline fn messageColor(msg: []const u8, color: u32) void {
    if (enabled) {
        c.___tracy_emit_messageC(msg.ptr, msg.len, color, 0);
    }
}

/// Plot a double value on Tracy timeline
pub inline fn plot(comptime name: [:0]const u8, val: f64) void {
    if (enabled) {
        c.___tracy_emit_plot(name.ptr, val);
    }
}

/// Plot a float value on Tracy timeline
pub inline fn plotFloat(comptime name: [:0]const u8, val: f32) void {
    if (enabled) {
        c.___tracy_emit_plot_float(name.ptr, val);
    }
}

/// Plot an integer value on Tracy timeline
pub inline fn plotInt(comptime name: [:0]const u8, val: i64) void {
    if (enabled) {
        c.___tracy_emit_plot_int(name.ptr, val);
    }
}

/// Set the current thread name (displayed in profiler)
pub inline fn setThreadName(comptime name: [:0]const u8) void {
    if (enabled) {
        c.___tracy_set_thread_name(name.ptr);
    }
}

/// Check if a profiler is connected
pub inline fn isConnected() bool {
    if (enabled) {
        return c.___tracy_connected() != 0;
    }
    return false;
}

// =============================================================================
// Memory Profiling
// =============================================================================

/// Report a memory allocation to Tracy
pub inline fn alloc(ptr: ?*anyopaque, size: usize) void {
    if (enabled) {
        c.___tracy_emit_memory_alloc(ptr, size, 0);
    }
}

/// Report a memory allocation with name to Tracy
pub inline fn allocNamed(ptr: ?*anyopaque, size: usize, comptime name: [:0]const u8) void {
    if (enabled) {
        c.___tracy_emit_memory_alloc_named(ptr, size, 0, name.ptr);
    }
}

/// Report a memory free to Tracy
pub inline fn free(ptr: ?*anyopaque) void {
    if (enabled) {
        c.___tracy_emit_memory_free(ptr, 0);
    }
}

/// Report a memory free with name to Tracy
pub inline fn freeNamed(ptr: ?*anyopaque, comptime name: [:0]const u8) void {
    if (enabled) {
        c.___tracy_emit_memory_free_named(ptr, 0, name.ptr);
    }
}

/// A wrapper allocator that reports all allocations to Tracy
/// Use this to wrap your main allocator for memory profiling
pub fn TracyAllocator(comptime name: ?[:0]const u8) type {
    return struct {
        parent_allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(parent: std.mem.Allocator) Self {
            return .{ .parent_allocator = parent };
        }

        pub fn allocator(self: *Self) std.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = allocFn,
                    .resize = resizeFn,
                    .remap = remapFn,
                    .free = freeFn,
                },
            };
        }

        fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const result = self.parent_allocator.rawAlloc(len, alignment, ret_addr);
            if (enabled and result != null) {
                if (name) |n| {
                    c.___tracy_emit_memory_alloc_named(result, len, 0, n.ptr);
                } else {
                    c.___tracy_emit_memory_alloc(result, len, 0);
                }
            }
            return result;
        }

        fn resizeFn(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.parent_allocator.rawResize(buf, alignment, new_len, ret_addr)) {
                if (enabled) {
                    // Tracy doesn't have a resize, so report as free + alloc
                    if (name) |n| {
                        c.___tracy_emit_memory_free_named(buf.ptr, 0, n.ptr);
                        c.___tracy_emit_memory_alloc_named(buf.ptr, new_len, 0, n.ptr);
                    } else {
                        c.___tracy_emit_memory_free(buf.ptr, 0);
                        c.___tracy_emit_memory_alloc(buf.ptr, new_len, 0);
                    }
                }
                return true;
            }
            return false;
        }

        fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const old_ptr = memory.ptr;
            const result = self.parent_allocator.rawRemap(memory, alignment, new_len, ret_addr);
            if (enabled) {
                if (result) |new_ptr| {
                    // Successful remap - report free of old, alloc of new
                    if (name) |n| {
                        c.___tracy_emit_memory_free_named(old_ptr, 0, n.ptr);
                        c.___tracy_emit_memory_alloc_named(new_ptr, new_len, 0, n.ptr);
                    } else {
                        c.___tracy_emit_memory_free(old_ptr, 0);
                        c.___tracy_emit_memory_alloc(new_ptr, new_len, 0);
                    }
                }
            }
            return result;
        }

        fn freeFn(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (enabled) {
                if (name) |n| {
                    c.___tracy_emit_memory_free_named(buf.ptr, 0, n.ptr);
                } else {
                    c.___tracy_emit_memory_free(buf.ptr, 0);
                }
            }
            self.parent_allocator.rawFree(buf, alignment, ret_addr);
        }
    };
}
