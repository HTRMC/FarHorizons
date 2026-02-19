const std = @import("std");
const build_options = @import("build_options");

pub const enabled = build_options.tracy_enabled;

const c = if (enabled) @cImport({
    @cDefine("TRACY_ENABLE", "");
    @cInclude("tracy/TracyC.h");
}) else struct {};

pub const Zone = struct {
    ctx: if (enabled) c.TracyCZoneCtx else void,

    pub inline fn end(self: Zone) void {
        if (enabled) c.___tracy_emit_zone_end(self.ctx);
    }

    pub inline fn text(self: Zone, txt: []const u8) void {
        if (enabled) c.___tracy_emit_zone_text(self.ctx, txt.ptr, txt.len);
    }
};

pub inline fn zone(comptime src: std.builtin.SourceLocation, comptime name: ?[*:0]const u8) Zone {
    if (enabled) {
        const loc: *const c.struct____tracy_source_location_data = &.{
            .name = name,
            .function = src.fn_name.ptr,
            .file = src.file.ptr,
            .line = src.line,
            .color = 0,
        };
        return .{ .ctx = c.___tracy_emit_zone_begin(loc, 1) };
    }
    return .{ .ctx = {} };
}

pub inline fn frameMark() void {
    if (enabled) c.___tracy_emit_frame_mark(null);
}

pub inline fn message(txt: []const u8) void {
    if (enabled) c.___tracy_emit_message(txt.ptr, txt.len, 0);
}

pub inline fn connected() bool {
    if (enabled) return c.___tracy_connected() != 0;
    return false;
}

/// Spin-waits until Tracy profiler connects. Call at start of main()
/// so early startup zones are captured.
pub fn waitForConnection() void {
    if (!enabled) return;
    std.log.info("Waiting for Tracy profiler to connect...", .{});
    while (c.___tracy_connected() == 0) {}
    std.log.info("Tracy connected", .{});
}
