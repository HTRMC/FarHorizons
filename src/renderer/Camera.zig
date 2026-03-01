const std = @import("std");
const zlm = @import("zlm");

const Camera = @This();

position: zlm.Vec3,
yaw: f32,
pitch: f32,
fov: f32,
aspect: f32,
near: f32,
far: f32,

const MAX_PITCH: f32 = std.math.degreesToRadians(89.0);
const MIN_PITCH: f32 = -MAX_PITCH;

pub fn init(width: u32, height: u32) Camera {
    const aspect_ratio = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));

    return Camera{
        .position = zlm.Vec3.init(0.0, 40.0, 80.0),
        .yaw = 0.0,
        .pitch = -0.3,
        .fov = std.math.pi / 4.0,
        .aspect = aspect_ratio,
        .near = 0.1,
        .far = 500.0,
    };
}

pub fn updateAspect(self: *Camera, width: u32, height: u32) void {
    self.aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
}

pub fn getForward(self: Camera) zlm.Vec3 {
    const cos_pitch = @cos(self.pitch);
    return zlm.Vec3.init(
        -@sin(self.yaw) * cos_pitch,
        @sin(self.pitch),
        -@cos(self.yaw) * cos_pitch,
    );
}

pub fn getRight(self: Camera) zlm.Vec3 {
    const world_up = zlm.Vec3.init(0.0, 1.0, 0.0);
    return zlm.Vec3.cross(self.getForward(), world_up).normalize();
}

pub fn getViewMatrix(self: Camera) zlm.Mat4 {
    const forward = self.getForward();
    const target = zlm.Vec3.add(self.position, forward);
    const up = zlm.Vec3.init(0.0, 1.0, 0.0);
    return zlm.Mat4.lookAt(self.position, target, up);
}

pub fn getProjectionMatrix(self: Camera) zlm.Mat4 {
    return zlm.Mat4.perspective(self.fov, self.aspect, self.near, self.far);
}

pub fn getViewProjectionMatrix(self: Camera) zlm.Mat4 {
    const view = self.getViewMatrix();
    const proj = self.getProjectionMatrix();
    return zlm.Mat4.mul(proj, view);
}

pub fn move(self: *Camera, forward_amount: f32, right_amount: f32, up_amount: f32) void {
    const sin_yaw = @sin(self.yaw);
    const cos_yaw = @cos(self.yaw);

    self.position.x += -sin_yaw * forward_amount + cos_yaw * right_amount;
    self.position.y += up_amount;
    self.position.z += -cos_yaw * forward_amount - sin_yaw * right_amount;
}

pub fn look(self: *Camera, delta_yaw: f32, delta_pitch: f32) void {
    self.yaw += delta_yaw;
    self.pitch += delta_pitch;
    self.pitch = @max(MIN_PITCH, @min(MAX_PITCH, self.pitch));
}
