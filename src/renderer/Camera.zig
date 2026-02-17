const std = @import("std");
const zlm = @import("../math/zlm.zig");

const Camera = @This();

distance: f32,
azimuth: f32,
elevation: f32,
target: zlm.Vec3,
fov: f32,
aspect: f32,
near: f32,
far: f32,

const MIN_DISTANCE: f32 = 1.0;
const MAX_DISTANCE: f32 = 20.0;
const MIN_ELEVATION: f32 = -std.math.pi / 2.0 + 0.1;
const MAX_ELEVATION: f32 = std.math.pi / 2.0 - 0.1;

pub fn init(width: u32, height: u32) Camera {
    const aspect_ratio = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));

    return Camera{
        .distance = 3.0,
        .azimuth = 0.0,
        .elevation = 0.3,
        .target = zlm.Vec3.init(0.0, 0.0, 0.0),
        .fov = std.math.pi / 4.0, // 45 degrees
        .aspect = aspect_ratio,
        .near = 0.1,
        .far = 100.0,
    };
}

pub fn updateAspect(self: *Camera, width: u32, height: u32) void {
    self.aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
}

pub fn getPosition(self: Camera) zlm.Vec3 {
    const x = self.distance * @cos(self.elevation) * @sin(self.azimuth);
    const y = self.distance * @sin(self.elevation);
    const z = self.distance * @cos(self.elevation) * @cos(self.azimuth);
    return zlm.Vec3.init(x, y, z);
}

pub fn getViewMatrix(self: Camera) zlm.Mat4 {
    const position = self.getPosition();
    const up = zlm.Vec3.init(0.0, 1.0, 0.0);
    return zlm.Mat4.lookAt(position, self.target, up);
}

pub fn getProjectionMatrix(self: Camera) zlm.Mat4 {
    return zlm.Mat4.perspective(self.fov, self.aspect, self.near, self.far);
}

pub fn getViewProjectionMatrix(self: Camera) zlm.Mat4 {
    const view = self.getViewMatrix();
    const proj = self.getProjectionMatrix();
    return zlm.Mat4.mul(proj, view);
}

pub fn rotate(self: *Camera, delta_azimuth: f32, delta_elevation: f32) void {
    self.azimuth += delta_azimuth;
    self.elevation += delta_elevation;

    // Clamp elevation to prevent gimbal lock
    self.elevation = @max(MIN_ELEVATION, @min(MAX_ELEVATION, self.elevation));

    // Normalize azimuth to [0, 2π]
    self.azimuth = @mod(self.azimuth, 2.0 * std.math.pi);
}

pub fn zoom(self: *Camera, delta_distance: f32) void {
    self.distance += delta_distance;
    self.distance = @max(MIN_DISTANCE, @min(MAX_DISTANCE, self.distance));
}
