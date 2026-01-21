/// Jump component - jumping state and mechanics
/// Extracted from LivingEntity.zig
pub const Jump = struct {
    /// Whether currently jumping
    jumping: bool = false,

    /// Ticks until next jump allowed
    jump_delay: u32 = 0,

    /// Base jump power (can be modified by effects/blocks)
    base_jump_power: f32 = BASE_JUMP_POWER,

    // Constants from LivingEntity
    pub const BASE_JUMP_POWER: f32 = 0.42;
    pub const JUMP_DELAY_TICKS: u32 = 10;
    pub const MAX_JUMP_HEIGHT: f32 = 1.25;

    pub fn init() Jump {
        return .{};
    }

    /// Get the effective jump power (with any modifiers)
    pub fn getJumpPower(self: *const Jump) f32 {
        // TODO: Apply block jump factor, potion effects, etc.
        return self.base_jump_power;
    }

    /// Check if can jump
    pub fn canJump(self: *const Jump, on_ground: bool) bool {
        return on_ground and self.jump_delay == 0;
    }

    /// Check if should jump to overcome an obstacle
    pub fn shouldJumpOver(self: *const Jump, on_ground: bool, obstacle_height: f32, step_height: f32) bool {
        if (!on_ground) return false;
        if (self.jump_delay > 0) return false;
        if (obstacle_height <= step_height) return false;
        if (obstacle_height <= MAX_JUMP_HEIGHT) return true;
        return false;
    }

    /// Start a jump (sets state, returns jump velocity)
    pub fn startJump(self: *Jump) f32 {
        self.jumping = true;
        self.jump_delay = JUMP_DELAY_TICKS;
        return self.getJumpPower();
    }

    /// Tick the jump system
    pub fn tick(self: *Jump, on_ground: bool) void {
        // Decrement jump delay
        if (self.jump_delay > 0) {
            self.jump_delay -= 1;
        }

        // Reset jumping flag when landed
        if (on_ground and self.jumping) {
            self.jumping = false;
        }
    }
};
