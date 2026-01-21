const Vec3 = @import("Shared").Vec3;

/// Transform component - position and rotation in world space
/// Extracted from Entity.zig: position, prev_position, yaw, prev_yaw
pub const Transform = struct {
    /// World position (center of entity at feet level)
    position: Vec3,

    /// Previous position (for interpolation)
    prev_position: Vec3,

    /// Rotation around Y-axis (yaw) in degrees
    yaw: f32 = 0,

    /// Previous yaw (for interpolation)
    prev_yaw: f32 = 0,

    /// Body yaw offset (for body rotation following head)
    body_yaw_offset: f32 = 0,

    /// Last stable head yaw (for body rotation control)
    last_stable_head_yaw: f32 = 0,

    /// Ticks head has been stable
    head_stable_time: u32 = 0,

    pub fn init(x: f32, y: f32, z: f32) Transform {
        const pos = Vec3{ .x = x, .y = y, .z = z };
        return .{
            .position = pos,
            .prev_position = pos,
        };
    }

    pub fn initVec(pos: Vec3) Transform {
        return .{
            .position = pos,
            .prev_position = pos,
        };
    }

    /// Get interpolated position for rendering
    pub fn getInterpolatedPosition(self: *const Transform, partial_tick: f32) Vec3 {
        return Vec3{
            .x = self.prev_position.x + (self.position.x - self.prev_position.x) * partial_tick,
            .y = self.prev_position.y + (self.position.y - self.prev_position.y) * partial_tick,
            .z = self.prev_position.z + (self.position.z - self.prev_position.z) * partial_tick,
        };
    }

    /// Get interpolated yaw for rendering (handles wrap-around)
    pub fn getInterpolatedYaw(self: *const Transform, partial_tick: f32) f32 {
        var delta = self.yaw - self.prev_yaw;
        while (delta > 180) delta -= 360;
        while (delta < -180) delta += 360;
        return self.prev_yaw + delta * partial_tick;
    }

    /// Store current values as previous (call at start of tick)
    pub fn savePrevious(self: *Transform) void {
        self.prev_position = self.position;
        self.prev_yaw = self.yaw;
    }

    /// Set position and update prev_position
    pub fn setPosition(self: *Transform, pos: Vec3) void {
        self.position = pos;
        self.prev_position = pos;
    }

    /// Move by delta
    pub fn move(self: *Transform, delta: Vec3) void {
        self.position.x += delta.x;
        self.position.y += delta.y;
        self.position.z += delta.z;
    }
};
