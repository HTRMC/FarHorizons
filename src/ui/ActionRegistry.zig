const std = @import("std");
const hashId = @import("WidgetTree.zig").hashId;

const log = std.log.scoped(.UI);

pub const ActionFn = *const fn (ctx: ?*anyopaque) void;

const MAX_ACTIONS = 64;

const Entry = struct {
    hash: u32 = 0,
    func: ?ActionFn = null,
    ctx: ?*anyopaque = null,
    active: bool = false,
};

pub const ActionRegistry = struct {
    entries: [MAX_ACTIONS]Entry = [_]Entry{.{}} ** MAX_ACTIONS,
    count: u8 = 0,

    pub fn register(self: *ActionRegistry, name: []const u8, func: ActionFn, ctx: ?*anyopaque) void {
        const hash = hashId(name);
        if (hash == 0) return;

        // Check for existing entry with same hash (update it)
        for (&self.entries) |*e| {
            if (e.active and e.hash == hash) {
                e.func = func;
                e.ctx = ctx;
                return;
            }
        }

        // Find empty slot
        for (&self.entries) |*e| {
            if (!e.active) {
                e.* = .{
                    .hash = hash,
                    .func = func,
                    .ctx = ctx,
                    .active = true,
                };
                self.count += 1;
                return;
            }
        }

        log.warn("ActionRegistry full, cannot register '{s}'", .{name});
    }

    pub fn dispatch(self: *const ActionRegistry, name: []const u8) bool {
        const hash = hashId(name);
        if (hash == 0) return false;

        for (&self.entries) |*e| {
            if (e.active and e.hash == hash) {
                if (e.func) |f| {
                    f(e.ctx);
                    return true;
                }
            }
        }
        return false;
    }

    pub fn unregister(self: *ActionRegistry, name: []const u8) void {
        const hash = hashId(name);
        if (hash == 0) return;

        for (&self.entries) |*e| {
            if (e.active and e.hash == hash) {
                e.active = false;
                e.func = null;
                e.ctx = null;
                self.count -= 1;
                return;
            }
        }
    }

    pub fn clear(self: *ActionRegistry) void {
        self.entries = [_]Entry{.{}} ** MAX_ACTIONS;
        self.count = 0;
    }
};

// ── Tests ──

test "register and dispatch action" {
    var registry = ActionRegistry{};

    var called = false;
    const callback = struct {
        fn cb(ctx: ?*anyopaque) void {
            const ptr: *bool = @ptrCast(@alignCast(ctx.?));
            ptr.* = true;
        }
    }.cb;

    registry.register("test_action", callback, @ptrCast(&called));
    try std.testing.expect(registry.dispatch("test_action"));
    try std.testing.expect(called);
}

test "dispatch unknown action returns false" {
    const registry = ActionRegistry{};
    try std.testing.expect(!registry.dispatch("nonexistent"));
}

test "unregister action" {
    var registry = ActionRegistry{};

    const noop = struct {
        fn cb(_: ?*anyopaque) void {}
    }.cb;

    registry.register("removable", noop, null);
    try std.testing.expect(registry.dispatch("removable"));

    registry.unregister("removable");
    try std.testing.expect(!registry.dispatch("removable"));
}
