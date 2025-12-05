// Abilities - like Minecraft's Abilities.java
// Stores player ability flags and speed values

const std = @import("std");

pub const Abilities = struct {
    const Self = @This();

    // Default values from Minecraft's Abilities.java
    pub const DEFAULT_FLYING_SPEED: f32 = 0.05;
    pub const DEFAULT_WALKING_SPEED: f32 = 0.1;
    pub const MIN_FLYING_SPEED: f32 = 0.0;
    pub const MAX_FLYING_SPEED: f32 = 0.2;

    // Ability flags
    invulnerable: bool = false,
    flying: bool = false,
    may_fly: bool = false,
    instabuild: bool = false,
    may_build: bool = true,

    // Speed values
    flying_speed: f32 = DEFAULT_FLYING_SPEED,
    walking_speed: f32 = DEFAULT_WALKING_SPEED,

    pub fn init() Self {
        return .{};
    }

    pub fn getFlyingSpeed(self: *const Self) f32 {
        return self.flying_speed;
    }

    pub fn setFlyingSpeed(self: *Self, value: f32) void {
        self.flying_speed = std.math.clamp(value, MIN_FLYING_SPEED, MAX_FLYING_SPEED);
    }

    pub fn getWalkingSpeed(self: *const Self) f32 {
        return self.walking_speed;
    }

    pub fn setWalkingSpeed(self: *Self, value: f32) void {
        self.walking_speed = value;
    }

    /// Adjust flying speed by scroll amount (Minecraft uses 0.005 per scroll notch)
    pub fn adjustFlyingSpeed(self: *Self, scroll_delta: f32) void {
        self.setFlyingSpeed(self.flying_speed + scroll_delta * 0.005);
    }
};
