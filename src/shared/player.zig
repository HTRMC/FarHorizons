// Player entity - like Minecraft's LocalPlayer

const std = @import("std");
const math = @import("math.zig");
const Camera = @import("camera.zig").Camera;
const Vec3 = math.Vec3;

pub const Player = struct {
    const Self = @This();

    // Position and movement
    position: Vec3 = Vec3.init(0, 0, 0),
    velocity: Vec3 = Vec3.ZERO,

    // Rotation (in degrees, like Minecraft)
    yaw: f32 = 0,
    pitch: f32 = 0,

    // Physics
    on_ground: bool = false,
    move_speed: f32 = 4.317, // Minecraft walking speed (blocks/sec)
    fly_speed: f32 = 10.0,
    jump_velocity: f32 = 8.0,

    // Input state
    input: Input = .{},

    // Camera attached to player
    camera: Camera = Camera.init(),

    // Player dimensions
    eye_height: f32 = 1.62,
    height: f32 = 1.8,
    width: f32 = 0.6,

    // Game mode
    flying: bool = true, // Start in fly mode for now

    pub const Input = struct {
        forward: bool = false,
        backward: bool = false,
        left: bool = false,
        right: bool = false,
        jump: bool = false,
        sneak: bool = false,
        sprint: bool = false,
    };

    pub fn init() Self {
        return .{};
    }

    /// Update player from mouse movement
    pub fn handleMouseMove(self: *Self, delta_yaw: f32, delta_pitch: f32) void {
        self.yaw = math.wrapDegrees(self.yaw + delta_yaw);
        self.pitch = math.clamp(self.pitch + delta_pitch, -89.9, 89.9);

        // Sync camera rotation
        self.camera.setRotation(self.yaw, self.pitch);
    }

    /// Update player each tick
    pub fn tick(self: *Self, delta_time: f32) void {
        if (self.flying) {
            self.tickFlying(delta_time);
        } else {
            self.tickWalking(delta_time);
        }

        // Update camera position (eye position)
        self.camera.position = Vec3{
            .x = self.position.x,
            .y = self.position.y + self.eye_height,
            .z = self.position.z,
        };
    }

    fn tickFlying(self: *Self, delta_time: f32) void {
        var move_dir = Vec3.ZERO;

        // Get horizontal movement direction
        const yaw_rad = math.degreesToRadians(self.yaw);
        const forward_dir = Vec3{
            .x = -@sin(yaw_rad),
            .y = 0,
            .z = -@cos(yaw_rad),
        };
        const right_dir = Vec3{
            .x = @cos(yaw_rad),
            .y = 0,
            .z = -@sin(yaw_rad),
        };

        // Accumulate movement from input
        if (self.input.forward) move_dir = move_dir.add(forward_dir);
        if (self.input.backward) move_dir = move_dir.sub(forward_dir);
        if (self.input.right) move_dir = move_dir.add(right_dir);
        if (self.input.left) move_dir = move_dir.sub(right_dir);
        if (self.input.jump) move_dir.y += 1;
        if (self.input.sneak) move_dir.y -= 1;

        // Normalize and apply speed
        if (move_dir.lengthSquared() > 0) {
            move_dir = move_dir.normalize();
            const speed = if (self.input.sprint) self.fly_speed * 2 else self.fly_speed;
            self.velocity = move_dir.scale(speed);
        } else {
            // Decelerate when not moving
            self.velocity = self.velocity.scale(0.8);
        }

        // Apply movement
        self.position = self.position.add(self.velocity.scale(delta_time));
    }

    fn tickWalking(self: *Self, delta_time: f32) void {
        var move_dir = Vec3.ZERO;

        // Get horizontal movement direction
        const yaw_rad = math.degreesToRadians(self.yaw);
        const forward_dir = Vec3{
            .x = -@sin(yaw_rad),
            .y = 0,
            .z = -@cos(yaw_rad),
        };
        const right_dir = Vec3{
            .x = @cos(yaw_rad),
            .y = 0,
            .z = -@sin(yaw_rad),
        };

        // Accumulate movement from input
        if (self.input.forward) move_dir = move_dir.add(forward_dir);
        if (self.input.backward) move_dir = move_dir.sub(forward_dir);
        if (self.input.right) move_dir = move_dir.add(right_dir);
        if (self.input.left) move_dir = move_dir.sub(right_dir);

        // Normalize horizontal movement
        if (move_dir.lengthSquared() > 0) {
            move_dir = move_dir.normalize();
            const speed = if (self.input.sprint) self.move_speed * 1.3 else self.move_speed;
            self.velocity.x = move_dir.x * speed;
            self.velocity.z = move_dir.z * speed;
        } else {
            // Friction
            self.velocity.x *= 0.8;
            self.velocity.z *= 0.8;
        }

        // Jumping
        if (self.input.jump and self.on_ground) {
            self.velocity.y = self.jump_velocity;
            self.on_ground = false;
        }

        // Gravity
        if (!self.on_ground) {
            self.velocity.y -= 20.0 * delta_time; // Gravity
        }

        // Apply movement
        self.position = self.position.add(self.velocity.scale(delta_time));

        // Simple ground collision (y = 0)
        if (self.position.y < 0) {
            self.position.y = 0;
            self.velocity.y = 0;
            self.on_ground = true;
        }
    }

    /// Toggle fly mode
    pub fn toggleFlying(self: *Self) void {
        self.flying = !self.flying;
        if (self.flying) {
            self.velocity = Vec3.ZERO;
        }
    }

    /// Get the camera for rendering
    pub fn getCamera(self: *Self) *Camera {
        return &self.camera;
    }
};
