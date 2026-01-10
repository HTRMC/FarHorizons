const std = @import("std");
const shared = @import("Shared");
const Vec3 = shared.Vec3;
const Entity = @import("Entity.zig").Entity;

/// LivingEntity - entities that are "alive" (have health, can jump, etc.)
/// Like Minecraft's LivingEntity.java
pub const LivingEntity = struct {
    const Self = @This();

    /// The base entity
    entity: *Entity,

    /// Health (0 = dead)
    health: f32 = 20.0,
    max_health: f32 = 20.0,

    /// Whether this entity is dead
    dead: bool = false,

    /// Jump state
    jumping: bool = false,
    jump_delay: u32 = 0, // Ticks until next jump allowed

    /// Hurt state
    hurt_time: u32 = 0, // Ticks remaining in hurt animation
    hurt_dir: f32 = 0, // Direction of knockback

    // =====================
    // Jump Constants (from Minecraft)
    // =====================

    /// Base jump power (blocks per tick upward velocity)
    /// Minecraft uses 0.42 which gives ~1.25 block jump height
    const BASE_JUMP_POWER: f32 = 0.42;

    /// Ticks between allowed jumps
    const JUMP_DELAY_TICKS: u32 = 10;

    /// Maximum obstacle height that can be jumped over
    pub const MAX_JUMP_HEIGHT: f32 = 1.25;

    // =====================
    // Initialization
    // =====================

    pub fn init(entity: *Entity) Self {
        return Self{
            .entity = entity,
        };
    }

    pub fn initWithHealth(entity: *Entity, max_hp: f32) Self {
        return Self{
            .entity = entity,
            .health = max_hp,
            .max_health = max_hp,
        };
    }

    // =====================
    // Jump Mechanics (like Minecraft's LivingEntity)
    // =====================

    /// Get the jump power, modified by block factor
    /// Like Minecraft's getJumpPower()
    pub fn getJumpPower(self: *Self) f32 {
        return BASE_JUMP_POWER * self.getBlockJumpFactor();
    }

    /// Get jump factor based on block standing on
    /// Like Minecraft's getBlockJumpFactor()
    /// Returns 1.0 normally, less for honey blocks, etc.
    pub fn getBlockJumpFactor(self: *Self) f32 {
        // TODO: Check block below entity and return appropriate factor
        // For now, return 1.0 (normal jump)
        _ = self;
        return 1.0;
    }

    /// Execute a jump from the ground
    /// Like Minecraft's jumpFromGround()
    pub fn jumpFromGround(self: *Self) void {
        if (!self.entity.on_ground) return;
        if (self.jump_delay > 0) return;

        const jump_power = self.getJumpPower();
        if (jump_power <= 0) return;

        // Set upward velocity
        self.entity.velocity.y = jump_power;
        self.entity.on_ground = false;
        self.jumping = true;
        self.jump_delay = JUMP_DELAY_TICKS;

        // Sprint jump boost would go here if sprinting
    }

    /// Check if entity should jump to overcome an obstacle
    /// Called when movement is blocked
    pub fn shouldJumpToOvercome(self: *Self, obstacle_height: f32) bool {
        // Can only jump if on ground
        if (!self.entity.on_ground) return false;

        // Can only jump if not on cooldown
        if (self.jump_delay > 0) return false;

        // Can step over small obstacles
        if (obstacle_height <= Entity.STEP_HEIGHT) return false;

        // Can jump over obstacles up to MAX_JUMP_HEIGHT
        if (obstacle_height <= MAX_JUMP_HEIGHT) return true;

        return false;
    }

    /// Attempt to jump over an obstacle
    /// Returns true if jump was initiated
    pub fn tryJumpOverObstacle(self: *Self, obstacle_height: f32) bool {
        if (self.shouldJumpToOvercome(obstacle_height)) {
            self.jumpFromGround();
            return true;
        }
        return false;
    }

    // =====================
    // Tick Update
    // =====================

    /// Update living entity state (call after Entity.tick)
    pub fn tick(self: *Self) void {
        // Decrement jump delay
        if (self.jump_delay > 0) {
            self.jump_delay -= 1;
        }

        // Reset jumping flag when landed
        if (self.entity.on_ground and self.jumping) {
            self.jumping = false;
        }

        // Decrement hurt time
        if (self.hurt_time > 0) {
            self.hurt_time -= 1;
        }
    }

    // =====================
    // Health & Damage
    // =====================

    /// Deal damage to this entity
    pub fn hurt(self: *Self, amount: f32, knockback_dir: f32) void {
        if (self.dead) return;

        self.health -= amount;
        self.hurt_time = 10; // Hurt animation duration
        self.hurt_dir = knockback_dir;

        if (self.health <= 0) {
            self.health = 0;
            self.die();
        }
    }

    /// Heal this entity
    pub fn heal(self: *Self, amount: f32) void {
        if (self.dead) return;

        self.health = @min(self.health + amount, self.max_health);
    }

    /// Kill this entity
    pub fn die(self: *Self) void {
        self.dead = true;
        // Death logic (drop items, play sound, etc.) would go here
    }

    /// Check if entity is alive
    pub fn isAlive(self: *const Self) bool {
        return !self.dead and self.health > 0;
    }

    // =====================
    // Convenience Accessors
    // =====================

    pub fn getPosition(self: *const Self) Vec3 {
        return self.entity.position;
    }

    pub fn isOnGround(self: *const Self) bool {
        return self.entity.on_ground;
    }

    pub fn isJumping(self: *const Self) bool {
        return self.jumping;
    }
};
