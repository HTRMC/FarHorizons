const std = @import("std");
const Goal = @import("Goal.zig").Goal;
const FlagSet = @import("Goal.zig").FlagSet;
const Flag = @import("Goal.zig").Flag;
const Entity = @import("../Entity.zig").Entity;
const LookControl = @import("LookControl.zig").LookControl;
const Vec3 = @import("Shared").Vec3;

/// LookAtPlayerGoal - makes entity look at nearby players
/// Like MC's LookAtPlayerGoal with 2% probability, 6 block range
pub const LookAtPlayerGoal = struct {
    const Self = @This();

    // Goal base
    base: Goal,

    // Parameters
    look_distance: f32,
    probability: f32,

    // State
    look_time: i32 = 0,
    target_pos: ?Vec3 = null,

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

    pub fn init(
        entity: *Entity,
        look_control: *LookControl,
        look_distance: f32,
        probability: f32,
    ) Self {
        const seed = entity.id *% 2654435761 +% entity.tick_count;

        return Self{
            .base = .{
                .vtable = &VTABLE,
                .flags = FlagSet.initMany(&[_]Flag{.look}),
                .entity = entity,
            },
            .look_distance = look_distance,
            .probability = probability,
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

        // 2% chance per tick (like MC's DEFAULT_PROBABILITY = 0.02F)
        if (self.randomFloat() >= self.probability) {
            return false;
        }

        // Check if player is available (passed via entity's player_pos tracking)
        // For now, we'll use the entity's stored player position if looking at target
        // This requires the player position to be passed during tick
        if (self.entity.player_target_pos) |player_pos| {
            // Check distance
            const dx = player_pos.x - self.entity.position.x;
            const dy = player_pos.y - self.entity.position.y;
            const dz = player_pos.z - self.entity.position.z;
            const dist_sq = dx * dx + dy * dy + dz * dz;

            if (dist_sq <= self.look_distance * self.look_distance) {
                self.target_pos = player_pos;
                return true;
            }
        }

        return false;
    }

    fn canContinueToUse(goal: *Goal) bool {
        const self: *Self = @fieldParentPtr("base", goal);

        if (self.target_pos == null) return false;
        if (self.look_time <= 0) return false;

        // Check if still in range
        if (self.entity.player_target_pos) |player_pos| {
            const dx = player_pos.x - self.entity.position.x;
            const dy = player_pos.y - self.entity.position.y;
            const dz = player_pos.z - self.entity.position.z;
            const dist_sq = dx * dx + dy * dy + dz * dz;

            if (dist_sq > self.look_distance * self.look_distance) {
                return false;
            }

            // Update target position (player may have moved)
            self.target_pos = player_pos;
            return true;
        }

        return false;
    }

    fn start(goal: *Goal) void {
        const self: *Self = @fieldParentPtr("base", goal);

        // Look for 40-80 ticks (2-4 seconds)
        self.look_time = @intCast(40 + self.nextRandom() % 40);
    }

    fn tick(goal: *Goal) void {
        const self: *Self = @fieldParentPtr("base", goal);

        if (self.target_pos) |pos| {
            // Tell look control to look at player
            self.look_control.setLookAt(pos.x, pos.y, pos.z);
            self.look_time -= 1;
        }
    }

    fn stop(goal: *Goal) void {
        const self: *Self = @fieldParentPtr("base", goal);
        self.target_pos = null;
    }

    fn isInterruptable(_: *Goal) bool {
        return true;
    }
};
