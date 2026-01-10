const std = @import("std");
const Goal = @import("Goal.zig").Goal;
const FlagSet = @import("Goal.zig").FlagSet;
const Flag = @import("Goal.zig").Flag;
const Entity = @import("../Entity.zig").Entity;
const Vec3 = @import("Shared").Vec3;

/// Random stroll goal - makes entity wander around randomly
pub const RandomStrollGoal = struct {
    const Self = @This();

    // Goal base
    base: Goal,

    // Stroll parameters
    speed: f32,
    interval: u32, // Ticks between wander attempts
    cooldown: u32 = 0,

    // Target position
    target_x: f32 = 0,
    target_z: f32 = 0,
    has_target: bool = false,

    // Random state (simple LCG)
    rand_state: u64,

    // Reference to entity
    entity: *Entity,

    const VTABLE = Goal.VTable{
        .canUse = canUse,
        .canContinueToUse = canContinueToUse,
        .start = start,
        .tick = tick,
        .stop = stop,
        .isInterruptable = isInterruptable,
    };

    pub fn init(entity: *Entity, speed: f32, interval: u32) Self {
        // Use entity id and tick count as random seed
        const seed = entity.id *% 2654435761 +% entity.tick_count;

        return Self{
            .base = .{
                .vtable = &VTABLE,
                .flags = FlagSet.initMany(&[_]Flag{.move}),
                .entity = entity,
            },
            .speed = speed,
            .interval = interval,
            .rand_state = seed,
            .entity = entity,
        };
    }

    /// Get pointer to Goal base for GoalSelector
    pub fn asGoal(self: *Self) *Goal {
        return &self.base;
    }

    fn nextRandom(self: *Self) u32 {
        // Simple LCG random
        self.rand_state = self.rand_state *% 6364136223846793005 +% 1442695040888963407;
        return @truncate(self.rand_state >> 33);
    }

    fn randomFloat(self: *Self) f32 {
        return @as(f32, @floatFromInt(self.nextRandom() % 10000)) / 10000.0;
    }

    fn canUse(goal: *Goal) bool {
        const self: *Self = @fieldParentPtr("base", goal);

        // Cooldown check
        if (self.cooldown > 0) {
            self.cooldown -= 1;
            return false;
        }

        // Random chance to start wandering (1/interval chance per tick)
        if (self.nextRandom() % self.interval != 0) {
            return false;
        }

        // Pick a random target position within 10 blocks
        const range: f32 = 10.0;
        const angle = self.randomFloat() * std.math.pi * 2.0;
        const distance = self.randomFloat() * range + 2.0; // At least 2 blocks away

        self.target_x = self.entity.position.x + @cos(angle) * distance;
        self.target_z = self.entity.position.z + @sin(angle) * distance;
        self.has_target = true;

        return true;
    }

    fn canContinueToUse(goal: *Goal) bool {
        const self: *Self = @fieldParentPtr("base", goal);

        if (!self.has_target) return false;

        // Check if we've reached the target
        const dx = self.target_x - self.entity.position.x;
        const dz = self.target_z - self.entity.position.z;
        const dist_sq = dx * dx + dz * dz;

        // Stop if we're close enough (within 1 block)
        if (dist_sq < 1.0) {
            return false;
        }

        return true;
    }

    fn start(goal: *Goal) void {
        _ = goal;
        // Movement is handled in tick
    }

    // Jump power constant (from Minecraft's LivingEntity)
    const JUMP_POWER: f32 = 0.42;

    fn tick(goal: *Goal) void {
        const self: *Self = @fieldParentPtr("base", goal);

        if (!self.has_target) return;

        // Calculate direction to target
        const dx = self.target_x - self.entity.position.x;
        const dz = self.target_z - self.entity.position.z;
        const dist = @sqrt(dx * dx + dz * dz);

        if (dist < 0.5) {
            self.has_target = false;
            return;
        }

        // Check if blocked and should jump
        if (self.entity.horizontally_blocked and self.entity.on_ground) {
            // Jump to try to get over the obstacle
            self.entity.velocity.y = JUMP_POWER;
            self.entity.on_ground = false;
        }

        // Calculate target yaw (cow model faces -Z, so use -dz)
        const target_yaw = std.math.atan2(dx, -dz) * 180.0 / std.math.pi;

        // Calculate yaw difference
        var yaw_diff = target_yaw - self.entity.yaw;
        // Normalize to -180..180
        while (yaw_diff > 180.0) yaw_diff -= 360.0;
        while (yaw_diff < -180.0) yaw_diff += 360.0;

        const abs_yaw_diff = @abs(yaw_diff);

        // Smooth rotation toward target (like MC's MoveControl.rotlerp)
        // Max turn speed ~30 degrees per tick for smooth turning
        const max_turn: f32 = 30.0;
        const clamped_diff = std.math.clamp(yaw_diff, -max_turn, max_turn);
        self.entity.yaw += clamped_diff;

        // Only walk forward when roughly facing the target (within 45 degrees)
        // This prevents walking in circles or away from target while turning
        if (abs_yaw_diff < 45.0) {
            // Move in the direction the entity is FACING (like MC)
            const facing_rad = self.entity.yaw * std.math.pi / 180.0;
            const forward_x = @sin(facing_rad);
            const forward_z = -@cos(facing_rad); // -cos because model faces -Z

            // Scale speed based on how well-aligned we are (full speed when facing target)
            const alignment = 1.0 - (abs_yaw_diff / 45.0) * 0.5; // 100% to 50% speed

            // Slow down as we approach the target (smooth deceleration)
            const distance_factor = std.math.clamp(dist / 3.0, 0.3, 1.0);

            const move_speed = self.speed * alignment * distance_factor;

            self.entity.velocity.x = forward_x * move_speed;
            self.entity.velocity.z = forward_z * move_speed;
        } else {
            // Turning sharply - stand still until facing target
            self.entity.velocity.x = 0;
            self.entity.velocity.z = 0;
        }
    }

    fn stop(goal: *Goal) void {
        const self: *Self = @fieldParentPtr("base", goal);

        // Don't abruptly stop - let friction naturally slow the cow down
        // Just clear the target so we stop setting velocity
        self.has_target = false;

        // Set cooldown before next wander
        self.cooldown = self.interval / 2;
    }

    fn isInterruptable(_: *Goal) bool {
        return true;
    }
};
