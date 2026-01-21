/// Animation component - walk animation state
/// Extracted from Entity.zig
pub const Animation = struct {
    /// Walk animation parameter (phase of leg swing)
    walk_animation: f32 = 0,

    /// Previous walk animation (for interpolation)
    prev_walk_animation: f32 = 0,

    /// Walk animation speed (amplitude of leg swing)
    walk_speed: f32 = 0,

    /// Previous walk speed (for interpolation)
    prev_walk_speed: f32 = 0,

    /// Total tick count (for other animations)
    tick_count: u64 = 0,

    pub fn init() Animation {
        return .{};
    }

    /// Save current values as previous (call at start of tick)
    pub fn savePrevious(self: *Animation) void {
        self.prev_walk_animation = self.walk_animation;
        self.prev_walk_speed = self.walk_speed;
    }

    /// Update animation based on horizontal speed
    pub fn update(self: *Animation, horizontal_speed: f32) void {
        if (horizontal_speed > 0.01) {
            self.walk_speed = @min(1.0, horizontal_speed * 4.0);
            // Scale animation so legs move at reasonable speed
            self.walk_animation += horizontal_speed * 6.0;
        } else {
            self.walk_speed *= 0.9; // Smoothly reduce when stopping
        }
    }

    /// Get interpolated walk animation for rendering
    pub fn getInterpolatedWalkAnimation(self: *const Animation, partial_tick: f32) f32 {
        return self.prev_walk_animation + (self.walk_animation - self.prev_walk_animation) * partial_tick;
    }

    /// Get interpolated walk speed for rendering
    pub fn getInterpolatedWalkSpeed(self: *const Animation, partial_tick: f32) f32 {
        return self.prev_walk_speed + (self.walk_speed - self.prev_walk_speed) * partial_tick;
    }

    /// Tick animation counter
    pub fn tick(self: *Animation) void {
        self.tick_count += 1;
    }
};
