const std = @import("std");
const zlm = @import("zlm");
const Angle = @import("../math/Angle.zig");
const Degrees = Angle.Degrees;
const Radians = Angle.Radians;

const Camera = @This();

position: zlm.Vec3,
yaw: Degrees,
pitch: Degrees,
fov: Radians,
aspect: f32,
near: f32,
far: f32,

const MAX_PITCH: f32 = 90.0;
const MIN_PITCH: f32 = -90.0;

pub fn init(width: u32, height: u32) Camera {
    const aspect_ratio = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));

    return Camera{
        .position = zlm.Vec3.init(0.0, 40.0, 80.0),
        .yaw = Angle.deg(0.0),
        .pitch = Angle.deg(0.0),
        .fov = Angle.deg(70.0).toRadians(),
        .aspect = aspect_ratio,
        .near = 0.1,
        .far = 1000.0,
    };
}

pub fn updateAspect(self: *Camera, width: u32, height: u32) void {
    self.aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
}

pub fn getForward(self: Camera) zlm.Vec3 {
    const pitch_rad = self.pitch.toRadians();
    const yaw_rad = self.yaw.toRadians();
    const cos_pitch = pitch_rad.cos();
    return zlm.Vec3.init(
        -yaw_rad.sin() * cos_pitch,
        pitch_rad.sin(),
        -yaw_rad.cos() * cos_pitch,
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
    return zlm.Mat4.perspective(self.fov.value, self.aspect, self.near, self.far);
}

pub fn getViewProjectionMatrix(self: Camera) zlm.Mat4 {
    const view = self.getViewMatrix();
    const proj = self.getProjectionMatrix();
    return zlm.Mat4.mul(proj, view);
}

pub fn move(self: *Camera, forward_amount: f32, right_amount: f32, up_amount: f32) void {
    const yaw_rad = self.yaw.toRadians();
    const sin_yaw = yaw_rad.sin();
    const cos_yaw = yaw_rad.cos();

    self.position.x += -sin_yaw * forward_amount + cos_yaw * right_amount;
    self.position.y += up_amount;
    self.position.z += -cos_yaw * forward_amount - sin_yaw * right_amount;
}

/// Rotate camera by the given amounts in degrees.
pub fn look(self: *Camera, delta_yaw: Degrees, delta_pitch: Degrees) void {
    self.yaw = Degrees.add(self.yaw, delta_yaw);
    self.pitch = Degrees.add(self.pitch, delta_pitch).clamp(MIN_PITCH, MAX_PITCH);
}
