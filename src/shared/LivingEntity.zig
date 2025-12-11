// LivingEntity - like Minecraft's LivingEntity.java
// Extends Entity with travel methods and friction

const std = @import("std");
const math = @import("Math.zig");
const Vec3 = math.Vec3;
const Entity = @import("Entity.zig").Entity;

pub const LivingEntity = struct {
    const Self = @This();

    // Friction constants from Minecraft's LivingEntity.travelFlying
    pub const AIR_FRICTION: f64 = 0.91;
    pub const WATER_FRICTION: f64 = 0.8;
    pub const LAVA_FRICTION: f64 = 0.5;

    // Base entity
    entity: Entity = Entity.init(),

    // Sprinting state
    sprinting: bool = false,

    pub fn init() Self {
        return .{};
    }

    // Forward entity methods
    pub fn getDeltaMovement(self: *const Self) Vec3 {
        return self.entity.getDeltaMovement();
    }

    pub fn setDeltaMovement(self: *Self, movement: Vec3) void {
        self.entity.setDeltaMovement(movement);
    }

    pub fn getYRot(self: *const Self) f32 {
        return self.entity.getYRot();
    }

    pub fn setYRot(self: *Self, yaw: f32) void {
        self.entity.setYRot(yaw);
    }

    pub fn getXRot(self: *const Self) f32 {
        return self.entity.getXRot();
    }

    pub fn setXRot(self: *Self, pitch: f32) void {
        self.entity.setXRot(pitch);
    }

    pub fn moveRelative(self: *Self, speed: f32, input: Vec3) void {
        self.entity.moveRelative(speed, input);
    }

    pub fn move(self: *Self) void {
        self.entity.move();
    }

    pub fn turn(self: *Self, yaw: f64, pitch: f64) void {
        self.entity.turn(yaw, pitch);
    }

    pub fn isSprinting(self: *const Self) bool {
        return self.sprinting;
    }

    pub fn setSprinting(self: *Self, sprinting: bool) void {
        self.sprinting = sprinting;
    }

    pub fn setOldPosAndRot(self: *Self) void {
        self.entity.setOldPosAndRot();
    }

    pub fn getPosition(self: *const Self, partial_tick: f32) Vec3 {
        return self.entity.getPosition(partial_tick);
    }

    pub fn getViewYRot(self: *const Self, partial_tick: f32) f32 {
        return self.entity.getViewYRot(partial_tick);
    }

    pub fn getViewXRot(self: *const Self, partial_tick: f32) f32 {
        return self.entity.getViewXRot(partial_tick);
    }

    /// Flying travel with friction
    /// Like Minecraft's LivingEntity.travelFlying(Vec3 input, float airSpeed)
    pub fn travelFlying(self: *Self, input: Vec3, air_speed: f32) void {
        // Apply movement relative to rotation
        self.moveRelative(air_speed, input);

        // Move entity by delta
        self.move();

        // Apply air friction (0.91)
        const movement = self.getDeltaMovement();
        self.setDeltaMovement(Vec3{
            .x = @floatCast(movement.x * AIR_FRICTION),
            .y = @floatCast(movement.y * AIR_FRICTION),
            .z = @floatCast(movement.z * AIR_FRICTION),
        });
    }
};
