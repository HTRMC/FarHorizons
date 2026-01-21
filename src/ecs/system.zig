const std = @import("std");

/// System execution phases
/// Systems run in phase order, with all systems in a phase completing before the next phase starts
pub const Phase = enum(u8) {
    /// Pre-update phase: input processing, state preparation
    pre_update = 0,
    /// Main update phase: AI, physics, game logic
    update = 1,
    /// Post-update phase: cleanup, state synchronization
    post_update = 2,
    /// Render preparation phase: prepare data for rendering
    render_prep = 3,
};

/// A system function that operates on a World
pub const SystemFn = *const fn (*anyopaque) void;

/// A registered system with metadata
pub const SystemEntry = struct {
    name: []const u8,
    func: SystemFn,
    phase: Phase,
    priority: i32, // Lower runs first within phase
    enabled: bool,
};

/// Manages system registration and execution
pub const SystemScheduler = struct {
    const Self = @This();
    const MAX_SYSTEMS = 64;

    systems: [MAX_SYSTEMS]SystemEntry,
    system_count: usize,
    sorted: bool,

    /// Context pointer passed to all systems (typically the World)
    context: *anyopaque,

    pub fn init(context: *anyopaque) Self {
        return .{
            .systems = undefined,
            .system_count = 0,
            .sorted = true,
            .context = context,
        };
    }

    /// Register a system to run in the given phase
    pub fn addSystem(
        self: *Self,
        name: []const u8,
        func: SystemFn,
        phase: Phase,
        priority: i32,
    ) !void {
        if (self.system_count >= MAX_SYSTEMS) {
            return error.TooManySystems;
        }

        self.systems[self.system_count] = .{
            .name = name,
            .func = func,
            .phase = phase,
            .priority = priority,
            .enabled = true,
        };
        self.system_count += 1;
        self.sorted = false;
    }

    /// Enable or disable a system by name
    pub fn setSystemEnabled(self: *Self, name: []const u8, enabled: bool) bool {
        for (self.systems[0..self.system_count]) |*system| {
            if (std.mem.eql(u8, system.name, name)) {
                system.enabled = enabled;
                return true;
            }
        }
        return false;
    }

    /// Sort systems by phase and priority
    fn sortSystems(self: *Self) void {
        if (self.sorted) return;

        std.mem.sort(
            SystemEntry,
            self.systems[0..self.system_count],
            {},
            struct {
                fn lessThan(_: void, a: SystemEntry, b: SystemEntry) bool {
                    if (@intFromEnum(a.phase) != @intFromEnum(b.phase)) {
                        return @intFromEnum(a.phase) < @intFromEnum(b.phase);
                    }
                    return a.priority < b.priority;
                }
            }.lessThan,
        );

        self.sorted = true;
    }

    /// Run all systems in a specific phase
    pub fn runPhase(self: *Self, phase: Phase) void {
        self.sortSystems();

        for (self.systems[0..self.system_count]) |system| {
            if (system.phase == phase and system.enabled) {
                system.func(self.context);
            }
        }
    }

    /// Run all systems in all phases (full tick)
    pub fn runAll(self: *Self) void {
        self.sortSystems();

        for (self.systems[0..self.system_count]) |system| {
            if (system.enabled) {
                system.func(self.context);
            }
        }
    }

    /// Run update phases only (pre_update, update, post_update)
    pub fn runUpdate(self: *Self) void {
        self.runPhase(.pre_update);
        self.runPhase(.update);
        self.runPhase(.post_update);
    }

    /// Get slice of registered systems
    pub fn getSystems(self: *Self) []SystemEntry {
        self.sortSystems();
        return self.systems[0..self.system_count];
    }
};

test "SystemScheduler phase ordering" {
    var call_order = std.ArrayList([]const u8).init(std.testing.allocator);
    defer call_order.deinit();

    const context: *anyopaque = @ptrCast(&call_order);

    var scheduler = SystemScheduler.init(context);

    // Add systems in random order
    try scheduler.addSystem("render", struct {
        fn run(ctx: *anyopaque) void {
            const list: *std.ArrayList([]const u8) = @ptrCast(@alignCast(ctx));
            list.append("render") catch {};
        }
    }.run, .render_prep, 0);

    try scheduler.addSystem("physics", struct {
        fn run(ctx: *anyopaque) void {
            const list: *std.ArrayList([]const u8) = @ptrCast(@alignCast(ctx));
            list.append("physics") catch {};
        }
    }.run, .update, 0);

    try scheduler.addSystem("input", struct {
        fn run(ctx: *anyopaque) void {
            const list: *std.ArrayList([]const u8) = @ptrCast(@alignCast(ctx));
            list.append("input") catch {};
        }
    }.run, .pre_update, 0);

    try scheduler.addSystem("cleanup", struct {
        fn run(ctx: *anyopaque) void {
            const list: *std.ArrayList([]const u8) = @ptrCast(@alignCast(ctx));
            list.append("cleanup") catch {};
        }
    }.run, .post_update, 0);

    scheduler.runAll();

    try std.testing.expectEqual(@as(usize, 4), call_order.items.len);
    try std.testing.expectEqualStrings("input", call_order.items[0]);
    try std.testing.expectEqualStrings("physics", call_order.items[1]);
    try std.testing.expectEqualStrings("cleanup", call_order.items[2]);
    try std.testing.expectEqualStrings("render", call_order.items[3]);
}

test "SystemScheduler priority within phase" {
    var call_order = std.ArrayList([]const u8).init(std.testing.allocator);
    defer call_order.deinit();

    const context: *anyopaque = @ptrCast(&call_order);

    var scheduler = SystemScheduler.init(context);

    // Add systems with different priorities in same phase
    try scheduler.addSystem("low_priority", struct {
        fn run(ctx: *anyopaque) void {
            const list: *std.ArrayList([]const u8) = @ptrCast(@alignCast(ctx));
            list.append("low") catch {};
        }
    }.run, .update, 10);

    try scheduler.addSystem("high_priority", struct {
        fn run(ctx: *anyopaque) void {
            const list: *std.ArrayList([]const u8) = @ptrCast(@alignCast(ctx));
            list.append("high") catch {};
        }
    }.run, .update, -10);

    try scheduler.addSystem("medium_priority", struct {
        fn run(ctx: *anyopaque) void {
            const list: *std.ArrayList([]const u8) = @ptrCast(@alignCast(ctx));
            list.append("medium") catch {};
        }
    }.run, .update, 0);

    scheduler.runPhase(.update);

    try std.testing.expectEqual(@as(usize, 3), call_order.items.len);
    try std.testing.expectEqualStrings("high", call_order.items[0]);
    try std.testing.expectEqualStrings("medium", call_order.items[1]);
    try std.testing.expectEqualStrings("low", call_order.items[2]);
}
