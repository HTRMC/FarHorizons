const std = @import("std");
const Entity = @import("../Entity.zig").Entity;
const LivingEntity = @import("../LivingEntity.zig").LivingEntity;
const Mob = @import("../Mob.zig").Mob;
const PathfinderMob = @import("../PathfinderMob.zig").PathfinderMob;
const AgeableMob = @import("../AgeableMob.zig").AgeableMob;

/// Animal - Base for breedable, tameable animals
///
/// Modeled after Minecraft's Animal class which extends AgeableMob and adds:
/// - Love mode / breeding mechanics
/// - Food detection
/// - Spawn rules (grass blocks, light level)
/// - Experience drops
///
/// Inheritance: Entity -> LivingEntity -> Mob -> PathfinderMob -> AgeableMob -> Animal
pub const Animal = struct {
    const Self = @This();

    /// Breeding cooldown after mating (6000 ticks = 5 minutes)
    pub const PARENT_AGE_AFTER_BREEDING: i32 = 6000;

    /// Default love mode duration (600 ticks = 30 seconds)
    pub const LOVE_MODE_DURATION: i32 = 600;

    /// Age system from AgeableMob
    ageable: AgeableMob,

    /// Love mode timer (> 0 = in love, can breed)
    in_love: i32 = 0,

    /// UUID of player who caused love mode (for stats/advancements)
    love_cause_id: ?u64 = null,

    /// Initialize an Animal wrapper for an entity
    pub fn init(entity: *Entity) Self {
        return .{
            .ageable = AgeableMob.init(entity),
            .in_love = 0,
            .love_cause_id = null,
        };
    }

    /// Initialize as a baby animal
    pub fn initBaby(entity: *Entity) Self {
        return .{
            .ageable = AgeableMob.initBaby(entity),
            .in_love = 0,
            .love_cause_id = null,
        };
    }

    // ======================
    // Hierarchy Accessors
    // ======================

    /// Get the AgeableMob wrapper
    pub fn getAgeable(self: *Self) *AgeableMob {
        return &self.ageable;
    }

    /// Get the PathfinderMob wrapper
    pub fn getPathfinder(self: *Self) *PathfinderMob {
        return self.ageable.getPathfinder();
    }

    /// Get the Mob wrapper
    pub fn getMob(self: *Self) *Mob {
        return self.ageable.getMob();
    }

    /// Get the LivingEntity wrapper
    pub fn getLiving(self: *Self) *LivingEntity {
        return self.ageable.getLiving();
    }

    /// Get the underlying entity
    pub fn getEntity(self: *Self) *Entity {
        return self.ageable.entity;
    }

    // ======================
    // Convenience accessors
    // ======================

    /// Check if this is a baby
    pub fn isBaby(self: *const Self) bool {
        return self.ageable.isBaby();
    }

    /// Set baby state
    pub fn setBaby(self: *Self, baby: bool) void {
        self.ageable.setBaby(baby);
    }

    /// Get age
    pub fn getAge(self: *const Self) i32 {
        return self.ageable.getAge();
    }

    /// Set age
    pub fn setAge(self: *Self, age: i32) void {
        self.ageable.setAge(age);
    }

    /// Get scale for rendering
    pub fn getScale(self: *const Self) f32 {
        return self.ageable.getScale();
    }

    /// Refresh dimensions after baby/adult change
    pub fn refreshDimensions(self: *Self) void {
        self.ageable.refreshDimensions();
    }

    /// Attempt to jump
    pub fn jump(self: *Self) void {
        self.ageable.jump();
    }

    /// Try to jump over an obstacle
    pub fn tryJumpOver(self: *Self, obstacle_height: f32) bool {
        return self.ageable.tryJumpOver(obstacle_height);
    }

    // ======================
    // Love Mode / Breeding
    // ======================

    /// Check if animal is in love mode
    pub fn isInLove(self: *const Self) bool {
        return self.in_love > 0;
    }

    /// Get remaining love mode time
    pub fn getInLoveTime(self: *const Self) i32 {
        return self.in_love;
    }

    /// Set love mode time directly
    pub fn setInLoveTime(self: *Self, time: i32) void {
        self.in_love = time;
    }

    /// Enter love mode (called when fed breeding food)
    pub fn setInLove(self: *Self, player_id: ?u64) void {
        self.in_love = LOVE_MODE_DURATION;
        self.love_cause_id = player_id;
        // TODO: Broadcast entity event for heart particles
    }

    /// Reset love mode (called on damage or after breeding)
    pub fn resetLove(self: *Self) void {
        self.in_love = 0;
        self.love_cause_id = null;
    }

    /// Check if this animal can enter love mode
    pub fn canFallInLove(self: *const Self) bool {
        return self.in_love <= 0 and self.ageable.canBreed();
    }

    /// Check if two animals can mate
    pub fn canMate(self: *const Self, partner: *const Self) bool {
        // Can't mate with self
        if (self.ageable.entity.id == partner.ageable.entity.id) {
            return false;
        }

        // Both must be in love and same type
        if (!self.isInLove() or !partner.isInLove()) {
            return false;
        }

        // Same entity type check
        if (self.ageable.entity.entity_type != partner.ageable.entity.entity_type) {
            return false;
        }

        return true;
    }

    /// Called after breeding to reset both parents
    pub fn finishBreeding(self: *Self, partner: *Self) void {
        // Set breeding cooldown
        self.ageable.setAge(PARENT_AGE_AFTER_BREEDING);
        partner.ageable.setAge(PARENT_AGE_AFTER_BREEDING);

        // Reset love mode
        self.resetLove();
        partner.resetLove();

        // TODO: Spawn experience orbs
        // TODO: Trigger advancement
    }

    // ======================
    // Tick
    // ======================

    /// Tick the animal
    /// Call this every game tick
    pub fn tick(self: *Self) void {
        // Tick age system
        self.ageable.tickAge();

        // Reset love if not adult
        if (self.ageable.getAge() != 0) {
            self.in_love = 0;
        }

        // Decrement love timer
        if (self.in_love > 0) {
            self.in_love -= 1;

            // TODO: Spawn heart particles every 10 ticks
        }
    }

    // ======================
    // Food (to be overridden)
    // ======================

    /// Check if an item is food for this animal
    /// Override in subclasses (e.g., cow eats wheat)
    pub fn isFood(_: *const Self, item_id: u16) bool {
        _ = item_id;
        return false;
    }

    // ======================
    // Spawn Rules
    // ======================

    /// Check if position is valid for animal spawn
    /// Animals spawn on grass blocks in light level > 8
    pub fn checkSpawnRules(block_below_id: u16, light_level: u8) bool {
        // TODO: Check for GRASS_BLOCK when block IDs are properly defined
        _ = block_below_id;
        return light_level > 8;
    }
};
