const std = @import("std");
const shared = @import("Shared");
const Vec3 = shared.Vec3;
const Entity = @import("Entity.zig").Entity;

/// LivingEntity - entities that are "alive" (have health, can jump, etc.)
///
/// Modeled after Minecraft's LivingEntity.java which extends Entity and adds:
/// - Health and damage system
/// - Jump mechanics with block-specific jump factors
/// - Hurt animation state
///
/// Inheritance: Entity -> LivingEntity
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

    /// Invulnerability timer (can't be hurt again until this reaches 0)
    invulnerable_time: u32 = 0,

    /// Last attacker position (for PanicGoal to flee from)
    last_hurt_by_pos: ?Vec3 = null,

    /// Tick when last hurt (for panic duration tracking)
    last_hurt_timestamp: u64 = 0,

    // =====================
    // Damage Constants (from Minecraft)
    // =====================

    /// Invulnerability duration after being hurt (in ticks)
    /// MC uses 20 ticks (1 second) of invulnerability
    pub const INVULNERABLE_DURATION: u32 = 20;

    /// How long to remember attacker position (for panic fleeing)
    /// MC's PanicGoal uses 100 ticks (5 seconds) as panic duration
    pub const PANIC_DURATION: u64 = 100;

    /// Base knockback strength
    pub const BASE_KNOCKBACK: f32 = 0.4;

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

        // Decrement invulnerability timer
        if (self.invulnerable_time > 0) {
            self.invulnerable_time -= 1;
        }

        // Clear attacker position after panic duration
        if (self.last_hurt_by_pos != null) {
            const ticks_since_hurt = self.entity.tick_count - self.last_hurt_timestamp;
            if (ticks_since_hurt > PANIC_DURATION) {
                self.last_hurt_by_pos = null;
            }
        }
    }

    // =====================
    // Health & Damage
    // =====================

    /// Deal damage to this entity (simple version without attacker tracking)
    pub fn hurt(self: *Self, amount: f32, knockback_dir: f32) void {
        self.hurtByEntity(amount, knockback_dir, null);
    }

    /// Deal damage from an attacker at a position
    /// attacker_pos: Position of the attacker (for knockback direction and panic fleeing)
    pub fn hurtByEntity(self: *Self, amount: f32, knockback_dir: f32, attacker_pos: ?Vec3) void {
        if (self.dead) return;

        // Check invulnerability
        if (self.invulnerable_time > 0) return;

        // Apply damage
        self.health -= amount;
        self.hurt_time = 10; // Hurt animation duration
        self.hurt_dir = knockback_dir;

        // Set invulnerability
        self.invulnerable_time = INVULNERABLE_DURATION;

        // Store attacker position for PanicGoal
        if (attacker_pos) |pos| {
            self.last_hurt_by_pos = pos;
            self.last_hurt_timestamp = self.entity.tick_count;

            // Apply knockback away from attacker
            self.knockback(pos);
        }

        if (self.health <= 0) {
            self.health = 0;
            self.die();
        }
    }

    /// Apply knockback away from a position
    /// Like Minecraft's LivingEntity.knockback()
    pub fn knockback(self: *Self, from_pos: Vec3) void {
        // Calculate direction away from attacker
        const dx = self.entity.position.x - from_pos.x;
        const dz = self.entity.position.z - from_pos.z;
        const dist = @sqrt(dx * dx + dz * dz);

        if (dist < 0.01) return; // Too close, no knockback direction

        // Normalize and apply knockback
        const nx = dx / dist;
        const nz = dz / dist;

        // Apply knockback velocity (like MC)
        self.entity.velocity.x = nx * BASE_KNOCKBACK;
        self.entity.velocity.y = BASE_KNOCKBACK; // Slight upward boost
        self.entity.velocity.z = nz * BASE_KNOCKBACK;
    }

    /// Check if this entity was recently hurt (for PanicGoal)
    pub fn wasRecentlyHurt(self: *const Self) bool {
        return self.last_hurt_by_pos != null;
    }

    /// Get the position to flee from (last attacker position)
    pub fn getLastHurtByPos(self: *const Self) ?Vec3 {
        return self.last_hurt_by_pos;
    }

    /// Check if currently invulnerable
    pub fn isInvulnerable(self: *const Self) bool {
        return self.invulnerable_time > 0;
    }

    /// Check if currently showing hurt animation
    pub fn isHurt(self: *const Self) bool {
        return self.hurt_time > 0;
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
