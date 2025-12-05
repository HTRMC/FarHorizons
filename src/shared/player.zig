// Player - like Minecraft's Player.java
// Extends LivingEntity with abilities and flying speed calculation

const std = @import("std");
const math = @import("math.zig");
const Vec3 = math.Vec3;
const LivingEntity = @import("living_entity.zig").LivingEntity;
const Abilities = @import("abilities.zig").Abilities;

pub const Player = struct {
    const Self = @This();

    // Y-axis dampening when flying (from Player.java:1322)
    pub const FLYING_Y_DAMPENING: f64 = 0.6;

    // Base living entity
    living_entity: LivingEntity = LivingEntity.init(),

    // Player abilities (flying speed, etc.)
    abilities: Abilities = Abilities.init(),

    pub fn init() Self {
        return .{};
    }

    // Forward LivingEntity methods
    pub fn getDeltaMovement(self: *const Self) Vec3 {
        return self.living_entity.getDeltaMovement();
    }

    pub fn setDeltaMovement(self: *Self, movement: Vec3) void {
        self.living_entity.setDeltaMovement(movement);
    }

    pub fn getYRot(self: *const Self) f32 {
        return self.living_entity.getYRot();
    }

    pub fn setYRot(self: *Self, yaw: f32) void {
        self.living_entity.setYRot(yaw);
    }

    pub fn getXRot(self: *const Self) f32 {
        return self.living_entity.getXRot();
    }

    pub fn setXRot(self: *Self, pitch: f32) void {
        self.living_entity.setXRot(pitch);
    }

    pub fn isSprinting(self: *const Self) bool {
        return self.living_entity.isSprinting();
    }

    pub fn setSprinting(self: *Self, sprinting: bool) void {
        self.living_entity.setSprinting(sprinting);
    }

    pub fn moveRelative(self: *Self, speed: f32, input: Vec3) void {
        self.living_entity.moveRelative(speed, input);
    }

    pub fn move(self: *Self) void {
        self.living_entity.move();
    }

    pub fn turn(self: *Self, yaw: f64, pitch: f64) void {
        self.living_entity.turn(yaw, pitch);
    }

    pub fn getAbilities(self: *Self) *Abilities {
        return &self.abilities;
    }

    pub fn getPosition(self: *const Self) Vec3 {
        return self.living_entity.entity.position;
    }

    pub fn setPosition(self: *Self, pos: Vec3) void {
        self.living_entity.entity.position = pos;
    }

    /// Get effective flying speed with sprint modifier
    /// Like Minecraft's Player.getFlyingSpeed() (Player.java:1823-1826)
    /// Returns flyingSpeed * 2.0 if sprinting, else flyingSpeed
    pub fn getFlyingSpeed(self: *const Self) f32 {
        if (self.abilities.flying) {
            return if (self.isSprinting())
                self.abilities.getFlyingSpeed() * 2.0
            else
                self.abilities.getFlyingSpeed();
        }
        // Not flying - return walking speeds (not used in spectator mode)
        return if (self.isSprinting()) 0.026 else 0.02;
    }

    /// Travel method for flying players
    /// Like Minecraft's Player.travel(Vec3 input) (Player.java:1306-1326)
    /// Applies Y-axis dampening of 0.6 when flying
    pub fn travel(self: *Self, input: Vec3) void {
        if (self.abilities.flying) {
            // Save original Y velocity
            const original_y = self.getDeltaMovement().y;

            // Call base travelFlying
            self.living_entity.travelFlying(input, self.getFlyingSpeed());

            // Apply Y-axis dampening (multiply by 0.6)
            const movement = self.getDeltaMovement();
            self.setDeltaMovement(Vec3{
                .x = movement.x,
                .y = @floatCast(original_y * FLYING_Y_DAMPENING),
                .z = movement.z,
            });
        } else {
            // Non-flying travel (TODO: implement ground movement)
            self.living_entity.travelFlying(input, self.getFlyingSpeed());
        }
    }
};
