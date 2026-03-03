const std = @import("std");
const Io = std.Io;

/// LightWorker is stubbed for Phase 1 (no light computation).
/// Will be rewritten in Phase 4 with per-chunk lighting.
pub const LightWorker = struct {
    thread: ?std.Thread,
    shutdown: std.atomic.Value(bool),

    pub fn initInPlace(self: *LightWorker) void {
        self.* = .{
            .thread = null,
            .shutdown = std.atomic.Value(bool).init(false),
        };
    }

    pub fn start(self: *LightWorker) void {
        _ = self;
    }

    pub fn stop(self: *LightWorker) void {
        _ = self;
    }
};
