// Entity - like Minecraft's Entity.java

const std = @import("std");
const math = @import("math.zig");
const Vec3 = math.Vec3;

pub const Entity = struct {
    const Self = @This();

    position: Vec3 = Vec3.ZERO,
    delta_movement: Vec3 = Vec3.ZERO,

    y_rot: f32 = 0,
    x_rot: f32 = 0,

    // Previous tick position/rotation for interpolation
    xo: f32 = 0,
    yo: f32 = 0,
    zo: f32 = 0,
    y_rot_o: f32 = 0,
    x_rot_o: f32 = 0,

    pub fn init() Self {
        return .{};
    }

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

    /// Save current position/rotation as old values (called at start of each tick)
    pub fn setOldPosAndRot(self: *Self) void {
        self.xo = self.position.x;
        self.yo = self.position.y;
        self.zo = self.position.z;
        self.y_rot_o = self.y_rot;
        self.x_rot_o = self.x_rot;
    }

    /// Get interpolated position for rendering
    pub fn getPosition(self: *const Self, partial_tick: f32) Vec3 {
        return Vec3{
            .x = math.lerp(self.xo, self.position.x, partial_tick),
            .y = math.lerp(self.yo, self.position.y, partial_tick),
            .z = math.lerp(self.zo, self.position.z, partial_tick),
        };
    }

    /// Get interpolated yaw for rendering
    pub fn getViewYRot(self: *const Self, partial_tick: f32) f32 {
        if (partial_tick == 1.0) return self.y_rot;
        return math.rotLerp(self.y_rot_o, self.y_rot, partial_tick);
    }

    /// Get interpolated pitch for rendering
    pub fn getViewXRot(self: *const Self, partial_tick: f32) f32 {
        if (partial_tick == 1.0) return self.x_rot;
        return math.lerp(self.x_rot_o, self.x_rot, partial_tick);
    }

    pub fn moveRelative(self: *Self, speed: f32, input: Vec3) void {
        const delta = getInputVector(input, speed, self.y_rot);
        self.delta_movement = self.delta_movement.add(delta);
    }

    pub fn getInputVector(input: Vec3, speed: f32, y_rot: f32) Vec3 {
        const length_sq = input.lengthSquared();
        if (length_sq < 1.0e-7) {
            return Vec3.ZERO;
        }

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

    pub fn move(self: *Self) void {
        self.position = self.position.add(self.delta_movement);
    }

    pub fn turn(self: *Self, yaw: f64, pitch: f64) void {
        self.setYRot(self.y_rot + @as(f32, @floatCast(yaw)) * 0.15);
        self.setXRot(self.x_rot + @as(f32, @floatCast(pitch)) * 0.15);
    }
};
