// Camera class

const std = @import("std");
const math = @import("Math.zig");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;

pub const Camera = struct {
    const Self = @This();

    // Position in world space
    position: Vec3 = Vec3.ZERO,

    // Rotation in degrees
    // yaw: horizontal rotation (0 = +Z, 90 = -X, 180 = -Z, 270 = +X)
    // pitch: vertical rotation (-90 = down, 0 = forward, 90 = up)
    yaw: f32 = 0,
    pitch: f32 = 0,

    // Direction vectors (computed from rotation)
    forward: Vec3 = Vec3.FORWARD,
    up: Vec3 = Vec3.UP,
    right: Vec3 = Vec3.RIGHT,

    // Camera settings
    fov: f32 = 70.0, // Field of view in degrees
    near: f32 = 0.05,
    far: f32 = 1000.0,

    // Eye height for first person
    eye_height: f32 = 1.62, // Player eye height

    pub fn init() Self {
        var cam = Self{};
        cam.updateVectors();
        return cam;
    }

    /// Set rotation and update direction vectors
    pub fn setRotation(self: *Self, yaw: f32, pitch: f32) void {
        self.yaw = math.wrapDegrees(yaw);
        self.pitch = math.clamp(pitch, -89.9, 89.9); // Clamp to prevent gimbal lock
        self.updateVectors();
    }

    /// Add to rotation (from mouse movement)
    pub fn rotate(self: *Self, delta_yaw: f32, delta_pitch: f32) void {
        self.setRotation(self.yaw + delta_yaw, self.pitch + delta_pitch);
    }

    fn updateVectors(self: *Self) void {
        const yaw_rad = math.degreesToRadians(self.yaw);
        const pitch_rad = math.degreesToRadians(self.pitch);

        self.forward = Vec3{
            .x = -@sin(yaw_rad) * @cos(pitch_rad),
            .y = @sin(pitch_rad),
            .z = @cos(yaw_rad) * @cos(pitch_rad),
        };

        self.right = Vec3{
            .x = @cos(yaw_rad),
            .y = 0,
            .z = @sin(yaw_rad),
        };

        self.up = self.right.cross(self.forward).normalize();
    }

    /// Move relative to camera orientation
    pub fn moveRelative(self: *Self, forward_amount: f32, right_amount: f32, up_amount: f32) void {
        // For movement, use horizontal forward (ignore pitch)
        const horizontal_forward = self.getHorizontalForward();

        var movement = Vec3.ZERO;
        movement = movement.add(horizontal_forward.scale(forward_amount));
        movement = movement.add(self.right.scale(right_amount));
        movement = movement.add(Vec3.UP.scale(up_amount));

        self.position = self.position.add(movement);
    }

    /// Get view matrix for rendering
    pub fn getViewMatrix(self: *const Self) Mat4 {
        const target = self.position.add(self.forward);
        return Mat4.lookAt(self.position, target, Vec3.UP);
    }

    pub fn getProjectionMatrix(self: *const Self, aspect_ratio: f32) Mat4 {
        var proj = Mat4.perspective(
            math.degreesToRadians(self.fov),
            aspect_ratio,
            self.near,
            self.far,
        );
        proj.data[5] = -proj.data[5]; // Vulkan Y-flip
        return proj;
    }

    /// Get combined view-projection matrix
    pub fn getViewProjectionMatrix(self: *const Self, aspect_ratio: f32) Mat4 {
        const view = self.getViewMatrix();
        const proj = self.getProjectionMatrix(aspect_ratio);
        return Mat4.multiply(proj, view);
    }

    pub fn getHorizontalForward(self: *const Self) Vec3 {
        const yaw_rad = math.degreesToRadians(self.yaw);
        return (Vec3{
            .x = -@sin(yaw_rad),
            .y = 0,
            .z = @cos(yaw_rad),
        }).normalize();
    }
};
