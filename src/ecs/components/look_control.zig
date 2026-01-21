const std = @import("std");
const Vec3 = @import("Shared").Vec3;

/// LookControlState component - smooth head rotation control
/// Extracted from LookControl.zig
pub const LookControlState = struct {
    /// Target position to look at
    wanted_x: f32 = 0,
    wanted_y: f32 = 0,
    wanted_z: f32 = 0,

    /// Countdown - when > 0, actively looking at target
    look_at_cooldown: i32 = 0,

    /// Maximum rotation speeds (degrees per tick)
    y_max_rot_speed: f32 = 10.0, // Yaw speed
    x_max_rot_angle: f32 = 40.0, // Pitch speed

    pub fn init() LookControlState {
        return .{};
    }

    /// Set look target to a position
    pub fn setLookAt(self: *LookControlState, x: f32, y: f32, z: f32) void {
        self.setLookAtWithSpeed(x, y, z, 10.0, 40.0);
    }

    /// Set look target to a Vec3
    pub fn setLookAtVec(self: *LookControlState, pos: Vec3) void {
        self.setLookAt(pos.x, pos.y, pos.z);
    }

    /// Set look target with custom rotation speeds
    pub fn setLookAtWithSpeed(
        self: *LookControlState,
        x: f32,
        y: f32,
        z: f32,
        y_max_rot_speed: f32,
        x_max_rot_angle: f32,
    ) void {
        self.wanted_x = x;
        self.wanted_y = y;
        self.wanted_z = z;
        self.y_max_rot_speed = y_max_rot_speed;
        self.x_max_rot_angle = x_max_rot_angle;
        self.look_at_cooldown = 2;
    }

    /// Check if currently looking at a target
    pub fn isLookingAtTarget(self: *const LookControlState) bool {
        return self.look_at_cooldown > 0;
    }

    /// Get target position as Vec3
    pub fn getTargetPos(self: *const LookControlState) Vec3 {
        return Vec3{
            .x = self.wanted_x,
            .y = self.wanted_y,
            .z = self.wanted_z,
        };
    }

    /// Calculate target yaw angle in degrees (world space)
    pub fn getTargetYaw(self: *const LookControlState, entity_pos: Vec3) ?f32 {
        const dx = self.wanted_x - entity_pos.x;
        const dz = self.wanted_z - entity_pos.z;

        if (@abs(dz) < 0.00001 and @abs(dx) < 0.00001) {
            return null;
        }

        return std.math.atan2(dz, dx) * 180.0 / std.math.pi - 90.0;
    }

    /// Calculate target pitch angle in degrees
    pub fn getTargetPitch(self: *const LookControlState, entity_pos: Vec3) ?f32 {
        const dx = self.wanted_x - entity_pos.x;
        const dy = self.wanted_y - (entity_pos.y + 1.0); // Eye height
        const dz = self.wanted_z - entity_pos.z;
        const horizontal_dist = @sqrt(dx * dx + dz * dz);

        if (@abs(dy) < 0.00001 and @abs(horizontal_dist) < 0.00001) {
            return null;
        }

        return -std.math.atan2(dy, horizontal_dist) * 180.0 / std.math.pi;
    }

    /// Rotate toward target angle by at most max_rot
    pub fn rotateTowards(from: f32, to: f32, max_rot: f32) f32 {
        var diff = to - from;
        while (diff > std.math.pi) diff -= 2.0 * std.math.pi;
        while (diff < -std.math.pi) diff += 2.0 * std.math.pi;
        const clamped = std.math.clamp(diff, -max_rot, max_rot);
        return from + clamped;
    }
};
