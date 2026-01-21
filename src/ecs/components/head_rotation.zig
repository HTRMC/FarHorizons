/// HeadRotation component - head pitch and yaw
/// Extracted from Entity.zig
pub const HeadRotation = struct {
    /// Head pitch (up/down) in radians
    pitch: f32 = 0,

    /// Head yaw (left/right relative to body) in radians
    yaw: f32 = 0,

    /// Previous head pitch (for interpolation)
    prev_pitch: f32 = 0,

    /// Previous head yaw (for interpolation)
    prev_yaw: f32 = 0,

    pub fn init() HeadRotation {
        return .{};
    }

    /// Save current values as previous (call at start of tick)
    pub fn savePrevious(self: *HeadRotation) void {
        self.prev_pitch = self.pitch;
        self.prev_yaw = self.yaw;
    }

    /// Get interpolated head pitch for rendering
    pub fn getInterpolatedPitch(self: *const HeadRotation, partial_tick: f32) f32 {
        return self.prev_pitch + (self.pitch - self.prev_pitch) * partial_tick;
    }

    /// Get interpolated head yaw for rendering
    pub fn getInterpolatedYaw(self: *const HeadRotation, partial_tick: f32) f32 {
        return self.prev_yaw + (self.yaw - self.prev_yaw) * partial_tick;
    }
};
