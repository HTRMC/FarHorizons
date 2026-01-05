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

        // Stop if we're close enough (within 0.5 blocks)
        if (dist_sq < 0.25) {
            return false;
        }

        // Stop if we're stuck (velocity very low but not at target)
        const vel_sq = self.entity.velocity.x * self.entity.velocity.x +
            self.entity.velocity.z * self.entity.velocity.z;
        if (vel_sq < 0.0001 and self.entity.on_ground) {
            // We're stuck, give up
            return false;
        }

        return true;
    }

    fn start(goal: *Goal) void {
        _ = goal;
        // Movement is handled in tick
    }

    fn tick(goal: *Goal) void {
        const self: *Self = @fieldParentPtr("base", goal);

        if (!self.has_target) return;

        // Calculate direction to target
        const dx = self.target_x - self.entity.position.x;
        const dz = self.target_z - self.entity.position.z;
        const dist = @sqrt(dx * dx + dz * dz);

        if (dist < 0.1) {
            self.has_target = false;
            return;
        }

        // Normalize and apply speed
        const nx = dx / dist;
        const nz = dz / dist;

        // Set velocity toward target
        self.entity.velocity.x = nx * self.speed;
        self.entity.velocity.z = nz * self.speed;

        // Face movement direction
        const target_yaw = std.math.atan2(nx, nz) * 180.0 / std.math.pi;
        self.entity.yaw = target_yaw;
    }

    fn stop(goal: *Goal) void {
        const self: *Self = @fieldParentPtr("base", goal);

        // Stop moving
        self.entity.velocity.x = 0;
        self.entity.velocity.z = 0;
        self.has_target = false;

        // Set cooldown before next wander
        self.cooldown = self.interval / 2;
    }

    fn isInterruptable(_: *Goal) bool {
        return true;
    }
};
