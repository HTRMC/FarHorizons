// Entity - like Minecraft's Entity.java
// Base entity with position, velocity, rotation, and movement methods

const std = @import("std");
const math = @import("math.zig");
const Vec3 = math.Vec3;

pub const Entity = struct {
    const Self = @This();

    // Position in world space
    position: Vec3 = Vec3.ZERO,

    // Velocity (delta movement)
    delta_movement: Vec3 = Vec3.ZERO,

    // Rotation in degrees
    y_rot: f32 = 0, // yaw
    x_rot: f32 = 0, // pitch

    pub fn init() Self {
        return .{};
    }

    // Getters/setters for delta movement (like Minecraft's getDeltaMovement/setDeltaMovement)
    pub fn getDeltaMovement(self: *const Self) Vec3 {
        return self.delta_movement;
    }

    pub fn setDeltaMovement(self: *Self, movement: Vec3) void {
        self.delta_movement = movement;
    }

    pub fn getYRot(self: *const Self) f32 {
        return self.y_rot;
    }

    pub fn setYRot(self: *Self, yaw: f32) void {
        self.y_rot = @mod(yaw, 360.0);
    }

    pub fn getXRot(self: *const Self) f32 {
        return self.x_rot;
    }

    pub fn setXRot(self: *Self, pitch: f32) void {
        self.x_rot = std.math.clamp(pitch, -90.0, 90.0);
    }

    /// Add to velocity based on input and speed, rotated by yaw
    /// Like Minecraft's Entity.moveRelative(float speed, Vec3 input)
    pub fn moveRelative(self: *Self, speed: f32, input: Vec3) void {
        const delta = getInputVector(input, speed, self.y_rot);
        self.delta_movement = self.delta_movement.add(delta);
    }

    /// Convert input vector to world-space movement vector
    /// Like Minecraft's Entity.getInputVector(Vec3 input, float speed, float yRot)
    /// input.x = strafe (left/right), input.z = forward/backward, input.y = vertical
    pub fn getInputVector(input: Vec3, speed: f32, y_rot: f32) Vec3 {
        const length_sq = input.lengthSquared();
        if (length_sq < 1.0e-7) {
            return Vec3.ZERO;
        }

        // Normalize if length > 1, then scale by speed
        const movement = if (length_sq > 1.0)
            input.normalize().scale(speed)
        else
            input.scale(speed);

        const yaw_rad = math.degreesToRadians(y_rot);
        const sin_yaw = @sin(yaw_rad);
        const cos_yaw = @cos(yaw_rad);

        return Vec3{
            .x = movement.x * cos_yaw - movement.z * sin_yaw,
            .y = movement.y,
            .z = movement.z * cos_yaw + movement.x * sin_yaw,
        };
    }

    /// Apply delta movement to position
    /// Like Minecraft's Entity.move(MoverType, Vec3)
    pub fn move(self: *Self) void {
        self.position = self.position.add(self.delta_movement);
    }

    /// Turn the entity (add to rotation)
    /// Like Minecraft's Entity.turn(double yaw, double pitch)
    pub fn turn(self: *Self, yaw: f64, pitch: f64) void {
        self.setYRot(self.y_rot + @as(f32, @floatCast(yaw)) * 0.15);
        self.setXRot(self.x_rot + @as(f32, @floatCast(pitch)) * 0.15);
    }
};
