const std = @import("std");
const Goal = @import("Goal.zig").Goal;
const FlagSet = @import("Goal.zig").FlagSet;
const Flag = @import("Goal.zig").Flag;
const Entity = @import("../Entity.zig").Entity;
const LookControl = @import("LookControl.zig").LookControl;

/// RandomLookAroundGoal - makes entity look around randomly when idle
/// Like MC's RandomLookAroundGoal with 2% probability
pub const RandomLookAroundGoal = struct {
    const Self = @This();

    // Goal base
    base: Goal,

    // State
    rel_x: f32 = 0,
    rel_z: f32 = 0,
    look_time: i32 = 0,

    // References
    entity: *Entity,
    look_control: *LookControl,

    // Random state
    rand_state: u64,

    const VTABLE = Goal.VTable{
        .canUse = canUse,
        .canContinueToUse = canContinueToUse,
        .start = start,
        .tick = tick,
        .stop = stop,
        .isInterruptable = isInterruptable,
    };

    pub fn init(entity: *Entity, look_control: *LookControl) Self {
        const seed = entity.id *% 1597334677 +% entity.tick_count;

        return Self{
            .base = .{
                .vtable = &VTABLE,
                // MC uses MOVE and LOOK flags for RandomLookAroundGoal
                // This prevents movement while looking around idly
                .flags = FlagSet.initMany(&[_]Flag{ .move, .look }),
                .entity = entity,
            },
            .entity = entity,
            .look_control = look_control,
            .rand_state = seed,
        };
    }

    /// Get pointer to Goal base for GoalSelector
    pub fn asGoal(self: *Self) *Goal {
        return &self.base;
    }

    fn nextRandom(self: *Self) u32 {
        self.rand_state = self.rand_state *% 6364136223846793005 +% 1442695040888963407;
        return @truncate(self.rand_state >> 33);
    }

    fn randomFloat(self: *Self) f32 {
        return @as(f32, @floatFromInt(self.nextRandom() % 10000)) / 10000.0;
    }

    fn canUse(goal: *Goal) bool {
        const self: *Self = @fieldParentPtr("base", goal);

        // 2% chance per tick (like MC)
        return self.randomFloat() < 0.02;
    }

    fn canContinueToUse(goal: *Goal) bool {
        const self: *Self = @fieldParentPtr("base", goal);
        return self.look_time >= 0;
    }

    fn start(goal: *Goal) void {
        const self: *Self = @fieldParentPtr("base", goal);

        // Pick random direction to look (like MC)
        const angle = self.randomFloat() * std.math.pi * 2.0;
        self.rel_x = @cos(angle);
        self.rel_z = @sin(angle);

        // Look for 20-40 ticks (1-2 seconds)
        self.look_time = @intCast(20 + self.nextRandom() % 20);
    }

    fn tick(goal: *Goal) void {
        const self: *Self = @fieldParentPtr("base", goal);

        self.look_time -= 1;

        // Look at position relative to entity (like MC)
        self.look_control.setLookAt(
            self.entity.position.x + self.rel_x,
            self.entity.position.y + 1.0, // Eye height
            self.entity.position.z + self.rel_z,
        );
    }

    fn stop(_: *Goal) void {
        // Nothing to clean up
    }

    fn isInterruptable(_: *Goal) bool {
        return true;
    }
};
