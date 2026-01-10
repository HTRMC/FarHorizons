const std = @import("std");
const Entity = @import("Entity.zig").Entity;
const LivingEntity = @import("LivingEntity.zig").LivingEntity;

/// AgeableMob - Base for entities that can be babies and grow up
///
/// Modeled after Minecraft's AgeableMob class which provides:
/// - Age tracking (negative = baby, 0+ = adult)
/// - Baby state with smaller dimensions
/// - Age progression over time
/// - Forced aging (feeding to speed up growth)
///
/// Inheritance: Entity -> LivingEntity -> AgeableMob -> Animal
///
/// Age system:
/// - BABY_START_AGE (-24000 ticks = -20 minutes) = newborn baby
/// - Negative age = baby, increments each tick toward 0
/// - Age 0 = adult
/// - Positive age = breeding cooldown (decrements toward 0)
pub const AgeableMob = struct {
    const Self = @This();

    /// Starting age for babies (-24000 ticks = 20 minutes to grow up)
    pub const BABY_START_AGE: i32 = -24000;

    /// Default adult age
    pub const DEFAULT_AGE: i32 = 0;

    /// Ticks to show particles when force-aged
    pub const FORCED_AGE_PARTICLE_TICKS: i32 = 40;

    /// Reference to the base entity
    entity: *Entity,

    /// Living entity wrapper (for health, jumping, etc.)
    living: LivingEntity,

    /// Current age (negative = baby, 0+ = adult)
    /// Baby ages increment toward 0, adult breeding cooldown decrements toward 0
    age: i32 = DEFAULT_AGE,

    /// Forced age accumulator (from feeding)
    forced_age: i32 = 0,

    /// Timer for forced age particles
    forced_age_timer: i32 = 0,

    /// Baby scale factor (MC uses 0.5 for most baby animals)
    pub const BABY_SCALE: f32 = 0.5;

    /// Initialize an AgeableMob wrapper for an entity
    pub fn init(entity: *Entity) Self {
        return .{
            .entity = entity,
            .living = LivingEntity.init(entity),
            .age = DEFAULT_AGE,
            .forced_age = 0,
            .forced_age_timer = 0,
        };
    }

    /// Initialize as a baby
    pub fn initBaby(entity: *Entity) Self {
        entity.is_baby = true;
        return .{
            .entity = entity,
            .living = LivingEntity.init(entity),
            .age = BABY_START_AGE,
            .forced_age = 0,
            .forced_age_timer = 0,
        };
    }

    // ======================
    // LivingEntity Accessors
    // ======================

    /// Get the living entity wrapper
    pub fn getLiving(self: *Self) *LivingEntity {
        return &self.living;
    }

    /// Attempt to jump (delegates to LivingEntity)
    pub fn jump(self: *Self) void {
        self.living.jumpFromGround();
    }

    /// Try to jump over an obstacle
    pub fn tryJumpOver(self: *Self, obstacle_height: f32) bool {
        return self.living.tryJumpOverObstacle(obstacle_height);
    }

    // ======================
    // Age Management
    // ======================

    /// Get current age
    pub fn getAge(self: *const Self) i32 {
        return self.age;
    }

    /// Set age directly
    pub fn setAge(self: *Self, new_age: i32) void {
        const old_age = self.age;
        self.age = new_age;

        // Check if we crossed the baby/adult boundary
        if ((old_age < 0 and new_age >= 0) or (old_age >= 0 and new_age < 0)) {
            self.onAgeBoundaryReached();
        }
    }

    /// Check if this mob is a baby
    pub fn isBaby(self: *const Self) bool {
        return self.age < 0;
    }

    /// Set baby state
    pub fn setBaby(self: *Self, baby: bool) void {
        self.setAge(if (baby) BABY_START_AGE else 0);
    }

    /// Age up by a number of seconds
    /// If forced is true, accumulates forced_age for particle effects
    pub fn ageUp(self: *Self, seconds: i32, forced: bool) void {
        var new_age = self.age;
        new_age += seconds * 20; // Convert seconds to ticks

        // Clamp to 0 if crossing boundary
        if (new_age > 0 and self.age < 0) {
            new_age = 0;
        }

        const delta = new_age - self.age;
        self.setAge(new_age);

        if (forced) {
            self.forced_age += delta;
            if (self.forced_age_timer == 0) {
                self.forced_age_timer = FORCED_AGE_PARTICLE_TICKS;
            }
        }

        // Apply any remaining forced age after becoming adult
        if (self.getAge() == 0 and self.forced_age != 0) {
            self.setAge(self.forced_age);
        }
    }

    /// Tick the age system
    /// Call this every game tick
    pub fn tickAge(self: *Self) void {
        // Tick the living entity (jump cooldowns, hurt timers, etc.)
        self.living.tick();

        // Handle forced age particle timer
        if (self.forced_age_timer > 0) {
            self.forced_age_timer -= 1;
            // TODO: Spawn happy villager particles every 4 ticks
        }

        // Age progression
        if (self.age < 0) {
            // Baby: age toward 0 (growing up)
            self.setAge(self.age + 1);
        } else if (self.age > 0) {
            // Adult with breeding cooldown: age toward 0
            self.setAge(self.age - 1);
        }
    }

    /// Called when crossing the baby/adult age boundary
    fn onAgeBoundaryReached(self: *Self) void {
        // Update entity's is_baby flag for renderer
        self.entity.is_baby = self.isBaby();

        // Update entity dimensions
        self.refreshDimensions();

        // TODO: Handle dismounting from vehicles if too big
    }

    /// Refresh entity dimensions based on baby/adult state
    pub fn refreshDimensions(self: *Self) void {
        if (self.isBaby()) {
            // Baby dimensions (half size)
            self.entity.width = self.getAdultWidth() * BABY_SCALE;
            self.entity.height = self.getAdultHeight() * BABY_SCALE;
        } else {
            // Adult dimensions
            self.entity.width = self.getAdultWidth();
            self.entity.height = self.getAdultHeight();
        }
    }

    /// Get adult width (override per entity type)
    fn getAdultWidth(self: *const Self) f32 {
        // Default cow dimensions
        _ = self;
        return 0.9;
    }

    /// Get adult height (override per entity type)
    fn getAdultHeight(self: *const Self) f32 {
        // Default cow dimensions
        _ = self;
        return 1.4;
    }

    /// Get the scale factor for rendering
    pub fn getScale(self: *const Self) f32 {
        return if (self.isBaby()) BABY_SCALE else 1.0;
    }

    /// Calculate speed up seconds when feeding a baby
    /// MC formula: (ticksUntilAdult / 20) * 0.1
    pub fn getSpeedUpSecondsWhenFeeding(ticks_until_adult: i32) i32 {
        return @intFromFloat(@as(f32, @floatFromInt(@divTrunc(ticks_until_adult, 20))) * 0.1);
    }

    // ======================
    // Breeding (to be implemented by Animal)
    // ======================

    /// Check if this mob can breed (adult with no cooldown)
    pub fn canBreed(self: *const Self) bool {
        return self.age == 0;
    }

    /// Set breeding cooldown after mating
    pub fn setBreedingCooldown(self: *Self) void {
        // 6000 ticks = 5 minutes cooldown after breeding
        self.setAge(6000);
    }
};
