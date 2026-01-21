const std = @import("std");
const Vec3 = @import("Shared").Vec3;
const EntityId = @import("../entity.zig").EntityId;

/// Goal flags - used to prevent conflicts between goals
pub const Flag = enum(u8) {
    move = 0,
    look = 1,
    jump = 2,
    target = 3,

    pub const COUNT = 4;
};

/// FlagSet for tracking which flags are in use
pub const FlagSet = std.EnumSet(Flag);

/// Goal type enum - replaces VTable polymorphism
/// Each goal type has its own data and behavior
pub const GoalType = enum(u8) {
    random_stroll,
    look_at_player,
    random_look_around,
    panic,
    // Add more as needed
};

/// Goal-specific data union
pub const GoalData = union(GoalType) {
    random_stroll: RandomStrollData,
    look_at_player: LookAtPlayerData,
    random_look_around: RandomLookAroundData,
    panic: PanicData,
};

/// Data for RandomStrollGoal
pub const RandomStrollData = struct {
    /// Movement speed
    speed: f32 = 0.1,
    /// Ticks between wander attempts
    interval: u32 = 120,
    /// Current cooldown
    cooldown: u32 = 0,
    /// Target position
    target_x: f32 = 0,
    target_z: f32 = 0,
    /// Whether has valid target
    has_target: bool = false,
};

/// Data for LookAtPlayerGoal
pub const LookAtPlayerData = struct {
    /// Look distance
    look_distance: f32 = 6.0,
    /// Probability per tick (0.02 = 2%)
    probability: f32 = 0.02,
    /// Remaining look time
    look_time: i32 = 0,
    /// Target position
    target_pos: ?Vec3 = null,
};

/// Data for RandomLookAroundGoal
pub const RandomLookAroundData = struct {
    /// Relative look direction
    rel_x: f32 = 0,
    rel_z: f32 = 0,
    /// Remaining look time
    look_time: i32 = 0,
};

/// Data for PanicGoal
pub const PanicData = struct {
    /// Panic movement speed (faster than normal)
    speed: f32 = 0.2,
    /// Target position to flee to
    target_x: f32 = 0,
    target_z: f32 = 0,
    /// Whether currently fleeing
    is_fleeing: bool = false,
};

/// A single goal entry in the AI state
pub const GoalEntry = struct {
    goal_type: GoalType,
    data: GoalData,
    priority: u8,
    flags: FlagSet,
    is_running: bool = false,
};

/// AIState component - manages AI goals without VTable
/// Extracted from GoalSelector
pub const AIState = struct {
    const MAX_GOALS = 8;

    /// Registered goals
    goals: [MAX_GOALS]GoalEntry = undefined,
    goal_count: usize = 0,

    /// Which goals currently hold each flag
    locked_flags: [Flag.COUNT]?u8 = [_]?u8{null} ** Flag.COUNT,

    /// Random state (simple LCG)
    rand_state: u64 = 0,

    /// Player position (set each tick for AI targeting)
    player_target_pos: ?Vec3 = null,

    pub fn init() AIState {
        return .{};
    }

    pub fn initWithSeed(seed: u64) AIState {
        return .{
            .rand_state = seed,
        };
    }

    /// Add a goal with priority (lower = higher priority)
    pub fn addGoal(self: *AIState, priority: u8, goal_type: GoalType, data: GoalData, flags: FlagSet) void {
        if (self.goal_count >= MAX_GOALS) return;

        self.goals[self.goal_count] = .{
            .goal_type = goal_type,
            .data = data,
            .priority = priority,
            .flags = flags,
            .is_running = false,
        };
        self.goal_count += 1;

        // Sort by priority
        std.mem.sort(
            GoalEntry,
            self.goals[0..self.goal_count],
            {},
            struct {
                fn lessThan(_: void, a: GoalEntry, b: GoalEntry) bool {
                    return a.priority < b.priority;
                }
            }.lessThan,
        );
    }

    /// Add a random stroll goal
    pub fn addRandomStroll(self: *AIState, priority: u8, speed: f32, interval: u32) void {
        self.addGoal(priority, .random_stroll, .{
            .random_stroll = .{
                .speed = speed,
                .interval = interval,
            },
        }, FlagSet.initMany(&[_]Flag{.move}));
    }

    /// Add a look at player goal
    pub fn addLookAtPlayer(self: *AIState, priority: u8, look_distance: f32, probability: f32) void {
        self.addGoal(priority, .look_at_player, .{
            .look_at_player = .{
                .look_distance = look_distance,
                .probability = probability,
            },
        }, FlagSet.initMany(&[_]Flag{.look}));
    }

    /// Add a random look around goal
    pub fn addRandomLookAround(self: *AIState, priority: u8) void {
        self.addGoal(priority, .random_look_around, .{
            .random_look_around = .{},
        }, FlagSet.initMany(&[_]Flag{ .move, .look }));
    }

    /// Add a panic goal
    pub fn addPanic(self: *AIState, priority: u8, speed: f32) void {
        self.addGoal(priority, .panic, .{
            .panic = .{
                .speed = speed,
            },
        }, FlagSet.initMany(&[_]Flag{.move}));
    }

    /// Get next random number
    pub fn nextRandom(self: *AIState) u32 {
        self.rand_state = self.rand_state *% 6364136223846793005 +% 1442695040888963407;
        return @truncate(self.rand_state >> 33);
    }

    /// Get random float 0..1
    pub fn randomFloat(self: *AIState) f32 {
        return @as(f32, @floatFromInt(self.nextRandom() % 10000)) / 10000.0;
    }

    /// Check if goal can acquire all its flags
    pub fn canAcquireFlags(self: *AIState, goal_idx: usize) bool {
        const goal = &self.goals[goal_idx];
        var iter = goal.flags.iterator();
        while (iter.next()) |flag| {
            const locked_by = self.locked_flags[@intFromEnum(flag)];
            if (locked_by) |current_idx| {
                const current = &self.goals[current_idx];
                // Can't replace if current goal is not interruptable or has higher priority
                if (!current.is_running or current.priority <= goal.priority) {
                    return false;
                }
            }
        }
        return true;
    }

    /// Acquire flags for a goal, stopping conflicting goals
    pub fn acquireFlags(self: *AIState, goal_idx: usize) void {
        const goal = &self.goals[goal_idx];
        var iter = goal.flags.iterator();
        while (iter.next()) |flag| {
            const flag_idx = @intFromEnum(flag);
            if (self.locked_flags[flag_idx]) |current_idx| {
                // Stop the current goal
                self.goals[current_idx].is_running = false;
            }
            self.locked_flags[flag_idx] = @intCast(goal_idx);
        }
    }

    /// Unlock flags held by a goal
    pub fn unlockFlags(self: *AIState, goal_idx: usize) void {
        const goal = &self.goals[goal_idx];
        var iter = goal.flags.iterator();
        while (iter.next()) |flag| {
            const flag_idx = @intFromEnum(flag);
            if (self.locked_flags[flag_idx] == @as(u8, @intCast(goal_idx))) {
                self.locked_flags[flag_idx] = null;
            }
        }
    }

    /// Get slice of goals
    pub fn getGoals(self: *AIState) []GoalEntry {
        return self.goals[0..self.goal_count];
    }
};
