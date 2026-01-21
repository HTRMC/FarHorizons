const Vec3 = @import("Shared").Vec3;

/// Velocity component - linear velocity and movement state flags
/// Extracted from Entity.zig: velocity, on_ground, horizontally_blocked
pub const Velocity = struct {
    /// Linear velocity in blocks per tick
    linear: Vec3 = Vec3.ZERO,

    /// Whether entity is on ground
    on_ground: bool = false,

    /// Whether horizontal movement was blocked this tick
    horizontally_blocked: bool = false,

    pub fn init() Velocity {
        return .{};
    }

    pub fn initWith(x: f32, y: f32, z: f32) Velocity {
        return .{
            .linear = Vec3{ .x = x, .y = y, .z = z },
        };
    }

    /// Get horizontal speed (magnitude of X/Z velocity)
    pub fn horizontalSpeed(self: *const Velocity) f32 {
        return @sqrt(self.linear.x * self.linear.x + self.linear.z * self.linear.z);
    }

    /// Check if entity is moving significantly
    pub fn isMoving(self: *const Velocity) bool {
        return self.horizontalSpeed() > 0.01;
    }

    /// Apply horizontal friction
    pub fn applyFriction(self: *Velocity, friction: f32) void {
        self.linear.x *= friction;
        self.linear.z *= friction;
    }

    /// Apply vertical drag
    pub fn applyDrag(self: *Velocity, drag: f32) void {
        self.linear.y *= drag;
    }
};
