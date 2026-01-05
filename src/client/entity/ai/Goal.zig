const std = @import("std");
const Entity = @import("../Entity.zig").Entity;

/// Goal flags - used to prevent conflicts between goals
/// Only one goal can lock each flag at a time
pub const Flag = enum(u8) {
    move = 0,   // Movement control
    look = 1,   // Head/look direction
    jump = 2,   // Jumping
    target = 3, // Targeting

    pub const COUNT = 4;
};

/// FlagSet for tracking which flags are in use
pub const FlagSet = std.EnumSet(Flag);

/// Goal interface - all goals implement these methods via vtable
pub const Goal = struct {
    const Self = @This();

    /// Virtual function table
    pub const VTable = struct {
        /// Can this goal start running?
        canUse: *const fn (*Self) bool,

        /// Should this goal continue running? Default: same as canUse
        canContinueToUse: *const fn (*Self) bool,

        /// Called when goal starts
        start: *const fn (*Self) void,

        /// Called each tick while running
        tick: *const fn (*Self) void,

        /// Called when goal stops
        stop: *const fn (*Self) void,

        /// Can this goal be interrupted by other goals?
        isInterruptable: *const fn (*Self) bool,
    };

    vtable: *const VTable,
    flags: FlagSet,
    entity: *Entity,

    /// Check if this goal can start
    pub fn canUse(self: *Self) bool {
        return self.vtable.canUse(self);
    }

    /// Check if this goal should continue
    pub fn canContinueToUse(self: *Self) bool {
        return self.vtable.canContinueToUse(self);
    }

    /// Start the goal
    pub fn start(self: *Self) void {
        self.vtable.start(self);
    }

    /// Tick the goal
    pub fn tick(self: *Self) void {
        self.vtable.tick(self);
    }

    /// Stop the goal
    pub fn stop(self: *Self) void {
        self.vtable.stop(self);
    }

    /// Check if interruptable
    pub fn isInterruptable(self: *Self) bool {
        return self.vtable.isInterruptable(self);
    }

    /// Get the flags this goal requires
    pub fn getFlags(self: *const Self) FlagSet {
        return self.flags;
    }
};

/// Wrapped goal with priority and running state
pub const WrappedGoal = struct {
    goal: *Goal,
    priority: u8,
    is_running: bool = false,

    pub fn canBeReplacedBy(self: *const WrappedGoal, other: *const WrappedGoal) bool {
        return self.goal.isInterruptable() and other.priority < self.priority;
    }
};

/// GoalSelector - manages goal execution with priority and flag system
pub const GoalSelector = struct {
    const Self = @This();
    const MAX_GOALS = 16;

    goals: [MAX_GOALS]WrappedGoal,
    goal_count: usize,
    locked_flags: [Flag.COUNT]?*WrappedGoal,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .goals = undefined,
            .goal_count = 0,
            .locked_flags = [_]?*WrappedGoal{null} ** Flag.COUNT,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // Goals are owned elsewhere, nothing to free
    }

    /// Get slice of active goals
    fn slice(self: *Self) []WrappedGoal {
        return self.goals[0..self.goal_count];
    }

    /// Add a goal with priority (lower number = higher priority)
    pub fn addGoal(self: *Self, priority: u8, goal: *Goal) void {
        if (self.goal_count >= MAX_GOALS) {
            // Max goals reached
            return;
        }

        self.goals[self.goal_count] = .{
            .goal = goal,
            .priority = priority,
            .is_running = false,
        };
        self.goal_count += 1;

        // Sort by priority (lower = first)
        std.mem.sort(WrappedGoal, self.slice(), {}, struct {
            fn lessThan(_: void, a: WrappedGoal, b: WrappedGoal) bool {
                return a.priority < b.priority;
            }
        }.lessThan);
    }

    /// Main tick - runs each game tick
    pub fn tick(self: *Self) void {
        // Phase 1: Stop goals that can't continue
        for (self.slice()) |*wrapped| {
            if (wrapped.is_running) {
                if (!wrapped.goal.canContinueToUse()) {
                    wrapped.goal.stop();
                    wrapped.is_running = false;
                    self.unlockFlags(wrapped);
                }
            }
        }

        // Phase 2: Try to start new goals
        for (self.slice()) |*wrapped| {
            if (!wrapped.is_running) {
                // Check if we can acquire all required flags
                if (self.canAcquireFlags(wrapped) and wrapped.goal.canUse()) {
                    // Stop any conflicting goals and lock flags
                    self.acquireFlags(wrapped);
                    wrapped.goal.start();
                    wrapped.is_running = true;
                }
            }
        }

        // Phase 3: Tick running goals
        for (self.slice()) |*wrapped| {
            if (wrapped.is_running) {
                wrapped.goal.tick();
            }
        }
    }

    /// Check if we can acquire all flags for a goal
    fn canAcquireFlags(self: *Self, wrapped: *WrappedGoal) bool {
        var iter = wrapped.goal.getFlags().iterator();
        while (iter.next()) |flag| {
            const locked_by = self.locked_flags[@intFromEnum(flag)];
            if (locked_by) |current| {
                // Flag is locked - can we replace it?
                if (!current.canBeReplacedBy(wrapped)) {
                    return false;
                }
            }
        }
        return true;
    }

    /// Acquire flags for a goal, stopping conflicting goals
    fn acquireFlags(self: *Self, wrapped: *WrappedGoal) void {
        var iter = wrapped.goal.getFlags().iterator();
        while (iter.next()) |flag| {
            const flag_idx = @intFromEnum(flag);
            if (self.locked_flags[flag_idx]) |current| {
                // Stop the current goal holding this flag
                if (current.is_running) {
                    current.goal.stop();
                    current.is_running = false;
                }
            }
            self.locked_flags[flag_idx] = wrapped;
        }
    }

    /// Unlock flags held by a goal
    fn unlockFlags(self: *Self, wrapped: *WrappedGoal) void {
        var iter = wrapped.goal.getFlags().iterator();
        while (iter.next()) |flag| {
            const flag_idx = @intFromEnum(flag);
            if (self.locked_flags[flag_idx] == wrapped) {
                self.locked_flags[flag_idx] = null;
            }
        }
    }

    /// Check if any goal is running
    pub fn hasRunningGoal(self: *const Self) bool {
        for (self.goals[0..self.goal_count]) |wrapped| {
            if (wrapped.is_running) return true;
        }
        return false;
    }
};
