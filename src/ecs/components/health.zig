const Vec3 = @import("Shared").Vec3;

/// Health component - health, damage, and invulnerability
/// Extracted from LivingEntity.zig
pub const Health = struct {
    /// Current health
    current: f32 = 20.0,

    /// Maximum health
    max: f32 = 20.0,

    /// Whether entity is dead
    dead: bool = false,

    /// Ticks remaining in hurt animation (visual feedback)
    hurt_time: u32 = 0,

    /// Invulnerability timer (can't be hurt until 0)
    invulnerable_time: u32 = 0,

    /// Direction of last knockback (for animation)
    hurt_dir: f32 = 0,

    /// Position of last attacker (for fleeing AI)
    last_hurt_by_pos: ?Vec3 = null,

    /// Tick when last hurt (for panic duration)
    last_hurt_timestamp: u64 = 0,

    // Constants from LivingEntity
    pub const INVULNERABLE_DURATION: u32 = 20;
    pub const PANIC_DURATION: u64 = 100;
    pub const BASE_KNOCKBACK: f32 = 0.4;
    pub const HURT_DURATION: u32 = 10;

    pub fn init() Health {
        return .{};
    }

    pub fn initWith(max_health: f32) Health {
        return .{
            .current = max_health,
            .max = max_health,
        };
    }

    /// Check if alive
    pub fn isAlive(self: *const Health) bool {
        return !self.dead and self.current > 0;
    }

    /// Check if currently invulnerable
    pub fn isInvulnerable(self: *const Health) bool {
        return self.invulnerable_time > 0;
    }

    /// Check if currently showing hurt animation
    pub fn isHurt(self: *const Health) bool {
        return self.hurt_time > 0;
    }

    /// Check if recently hurt (for panic AI)
    pub fn wasRecentlyHurt(self: *const Health) bool {
        return self.last_hurt_by_pos != null;
    }

    /// Heal the entity
    pub fn heal(self: *Health, amount: f32) void {
        if (self.dead) return;
        self.current = @min(self.current + amount, self.max);
    }

    /// Mark as dead
    pub fn die(self: *Health) void {
        self.dead = true;
        self.current = 0;
    }

    /// Tick health timers
    pub fn tick(self: *Health, current_tick: u64) void {
        // Decrement hurt time
        if (self.hurt_time > 0) {
            self.hurt_time -= 1;
        }

        // Decrement invulnerability
        if (self.invulnerable_time > 0) {
            self.invulnerable_time -= 1;
        }

        // Clear attacker position after panic duration
        if (self.last_hurt_by_pos != null) {
            const ticks_since_hurt = current_tick - self.last_hurt_timestamp;
            if (ticks_since_hurt > PANIC_DURATION) {
                self.last_hurt_by_pos = null;
            }
        }
    }
};
