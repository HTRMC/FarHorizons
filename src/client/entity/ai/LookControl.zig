const std = @import("std");
const Entity = @import("../Entity.zig").Entity;
const Vec3 = @import("Shared").Vec3;

/// LookControl - handles smooth head rotation toward a target position
/// Goals call setLookAt() and this controller smoothly rotates the head each tick
pub const LookControl = struct {
    const Self = @This();

    // Reference to the entity
    entity: *Entity,

    // Maximum rotation speeds (degrees per tick)
    y_max_rot_speed: f32 = 10.0, // Yaw speed
    x_max_rot_angle: f32 = 40.0, // Pitch speed

    // Countdown - when > 0, we're actively looking at target
    look_at_cooldown: i32 = 0,

    // Target position to look at
    wanted_x: f32 = 0,
    wanted_y: f32 = 0,
    wanted_z: f32 = 0,

    pub fn init(entity: *Entity) Self {
        return Self{
            .entity = entity,
        };
    }

    /// Set look target to a position (uses default rotation speeds)
    pub fn setLookAt(self: *Self, x: f32, y: f32, z: f32) void {
        self.setLookAtWithSpeed(x, y, z, 10.0, 40.0);
    }

    /// Set look target to a Vec3 position
    pub fn setLookAtVec(self: *Self, pos: Vec3) void {
        self.setLookAt(pos.x, pos.y, pos.z);
    }

    /// Set look target with custom rotation speeds
    pub fn setLookAtWithSpeed(
        self: *Self,
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
        self.look_at_cooldown = 2; // Active for 2 ticks minimum
    }

    /// Called each tick to update head rotation
    pub fn tick(self: *Self) void {
        if (self.look_at_cooldown > 0) {
            self.look_at_cooldown -= 1;

            // Calculate target yaw
            if (self.getYRotD()) |target_yaw| {
                // Convert to radians for entity head_yaw (entity stores in radians)
                const target_rad = target_yaw * std.math.pi / 180.0;
                // head_yaw is relative to body, so subtract body yaw
                const body_yaw_rad = self.entity.yaw * std.math.pi / 180.0;
                var rel_yaw = -(target_rad - body_yaw_rad); // Negate for model orientation

                // Normalize to -PI to PI
                while (rel_yaw > std.math.pi) rel_yaw -= 2.0 * std.math.pi;
                while (rel_yaw < -std.math.pi) rel_yaw += 2.0 * std.math.pi;

                // Clamp to max head rotation (75 degrees)
                const max_head_yaw: f32 = 75.0 * std.math.pi / 180.0;
                rel_yaw = std.math.clamp(rel_yaw, -max_head_yaw, max_head_yaw);

                // Smooth rotation toward target
                const max_rot = self.y_max_rot_speed * std.math.pi / 180.0;
                self.entity.head_yaw = rotateTowards(self.entity.head_yaw, rel_yaw, max_rot);
            }

            // Calculate target pitch
            if (self.getXRotD()) |target_pitch| {
                // Negate because model X rotation is inverted
                const target_rad = -target_pitch * std.math.pi / 180.0;

                // Clamp to max pitch (40 degrees)
                const max_pitch: f32 = 40.0 * std.math.pi / 180.0;
                const clamped = std.math.clamp(target_rad, -max_pitch, max_pitch);

                // Smooth rotation toward target
                const max_rot = self.x_max_rot_angle * std.math.pi / 180.0;
                self.entity.head_pitch = rotateTowards(self.entity.head_pitch, clamped, max_rot);
            }
        } else {
            // Not looking at anything - gradually return head to center
            const idle_speed: f32 = 5.0 * std.math.pi / 180.0;
            self.entity.head_yaw = rotateTowards(self.entity.head_yaw, 0, idle_speed);
            self.entity.head_pitch = rotateTowards(self.entity.head_pitch, 0, idle_speed);
        }
    }

    /// Check if currently looking at a target
    pub fn isLookingAtTarget(self: *const Self) bool {
        return self.look_at_cooldown > 0;
    }

    /// Calculate target yaw angle in degrees (world space)
    fn getYRotD(self: *const Self) ?f32 {
        const dx = self.wanted_x - self.entity.position.x;
        const dz = self.wanted_z - self.entity.position.z;

        if (@abs(dz) < 0.00001 and @abs(dx) < 0.00001) {
            return null;
        }

        // MC formula: atan2(zd, xd) * 180/PI - 90
        return std.math.atan2(dz, dx) * 180.0 / std.math.pi - 90.0;
    }

    /// Calculate target pitch angle in degrees
    fn getXRotD(self: *const Self) ?f32 {
        const dx = self.wanted_x - self.entity.position.x;
        const dy = self.wanted_y - (self.entity.position.y + 1.0); // Eye height
        const dz = self.wanted_z - self.entity.position.z;
        const horizontal_dist = @sqrt(dx * dx + dz * dz);

        if (@abs(dy) < 0.00001 and @abs(horizontal_dist) < 0.00001) {
            return null;
        }

        // MC formula: -atan2(yd, sd) * 180/PI
        return -std.math.atan2(dy, horizontal_dist) * 180.0 / std.math.pi;
    }

    /// Rotate from current angle toward target by at most max_rot
    fn rotateTowards(from: f32, to: f32, max_rot: f32) f32 {
        var diff = to - from;
        // Normalize difference to -PI to PI
        while (diff > std.math.pi) diff -= 2.0 * std.math.pi;
        while (diff < -std.math.pi) diff += 2.0 * std.math.pi;
        // Clamp to max rotation speed
        const clamped = std.math.clamp(diff, -max_rot, max_rot);
        return from + clamped;
    }
};
