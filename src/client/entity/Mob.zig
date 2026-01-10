const std = @import("std");
const Entity = @import("Entity.zig").Entity;
const LivingEntity = @import("LivingEntity.zig").LivingEntity;
const ai = @import("ai/ai.zig");
const GoalSelector = ai.GoalSelector;
const LookControl = ai.LookControl;

/// Mob - Base class for all AI-driven entities
///
/// Modeled after Minecraft's Mob class which extends LivingEntity and adds:
/// - AI goal system (GoalSelector)
/// - Look/Move/Jump controls
/// - Equipment handling
/// - Sensing system for detecting nearby entities
/// - Leash/persistence/spawning rules
///
/// Inheritance: Entity -> LivingEntity -> Mob
pub const Mob = struct {
    const Self = @This();

    /// Reference to the base entity
    entity: *Entity,

    /// Living entity wrapper (health, jumping, etc.)
    living: LivingEntity,

    /// AI goal selector - manages and runs goals
    goal_selector: ?GoalSelector = null,

    /// Target goal selector - for hostile targeting
    target_selector: ?GoalSelector = null,

    /// Look control - manages head rotation
    look_control: ?LookControl = null,

    /// Whether this mob persists (won't despawn)
    persist: bool = false,

    /// Whether this mob can pick up loot
    can_pick_up_loot: bool = false,

    /// No despawn distance (mobs inside this range never despawn)
    pub const NO_DESPAWN_DISTANCE: f32 = 32.0;

    /// Initialize a Mob wrapper for an entity
    pub fn init(entity: *Entity) Self {
        return .{
            .entity = entity,
            .living = LivingEntity.init(entity),
        };
    }

    /// Initialize a Mob with health
    pub fn initWithHealth(entity: *Entity, max_hp: f32) Self {
        return .{
            .entity = entity,
            .living = LivingEntity.initWithHealth(entity, max_hp),
        };
    }

    // ======================
    // AI System
    // ======================

    /// Set the goal selector (called by subclasses during init)
    pub fn setGoalSelector(self: *Self, selector: *GoalSelector) void {
        self.goal_selector = selector.*;
        self.entity.goal_selector = &self.goal_selector.?;
    }

    /// Set the look control (called by subclasses during init)
    pub fn setLookControl(self: *Self, control: *LookControl) void {
        self.look_control = control.*;
        self.entity.look_control = &self.look_control.?;
    }

    /// Tick the AI system
    pub fn tickAI(self: *Self) void {
        // Run goal selector if present
        if (self.entity.goal_selector) |selector| {
            selector.tick();
        }

        // Update look control if present
        if (self.entity.look_control) |control| {
            control.tick();
        }
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

    /// Check if entity is alive
    pub fn isAlive(self: *const Self) bool {
        return self.living.isAlive();
    }

    /// Get health
    pub fn getHealth(self: *const Self) f32 {
        return self.living.health;
    }

    /// Deal damage to this mob
    pub fn hurt(self: *Self, amount: f32, knockback_dir: f32) void {
        self.living.hurt(amount, knockback_dir);
    }

    /// Heal this mob
    pub fn heal(self: *Self, amount: f32) void {
        self.living.heal(amount);
    }

    // ======================
    // Tick Update
    // ======================

    /// Tick the mob (call after Entity.tick)
    pub fn tick(self: *Self) void {
        // Tick living entity (jump cooldowns, hurt timers)
        self.living.tick();

        // AI is ticked separately via tickAI() to allow
        // subclasses to control when AI runs
    }

    // ======================
    // Spawning & Persistence
    // ======================

    /// Check if this mob should persist (not despawn)
    pub fn isPersistent(self: *const Self) bool {
        return self.persist;
    }

    /// Set persistence (called when named, leashed, etc.)
    pub fn setPersistent(self: *Self, persistent: bool) void {
        self.persist = persistent;
    }

    /// Check if mob should despawn based on distance to player
    pub fn shouldDespawn(self: *const Self, distance_to_player: f32) bool {
        if (self.persist) return false;
        if (distance_to_player < NO_DESPAWN_DISTANCE) return false;

        // TODO: Random despawn chance based on distance
        // MC uses: distanceToPlayer > 128 = instant despawn
        // MC uses: 32-128 range = random chance over time
        return distance_to_player > 128.0;
    }

    // ======================
    // Equipment (placeholder)
    // ======================

    pub const EquipmentSlot = enum {
        main_hand,
        off_hand,
        head,
        chest,
        legs,
        feet,
    };

    /// Set whether this mob can pick up loot
    pub fn setCanPickUpLoot(self: *Self, can_pick_up: bool) void {
        self.can_pick_up_loot = can_pick_up;
    }

    /// Check if this mob can pick up loot
    pub fn canPickUpLoot(self: *const Self) bool {
        return self.can_pick_up_loot;
    }
};
