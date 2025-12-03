// Math utilities for FarHorizons

const std = @import("std");

pub const Vec3 = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,

    pub const ZERO = Vec3{ .x = 0, .y = 0, .z = 0 };
    pub const UP = Vec3{ .x = 0, .y = 1, .z = 0 };
    pub const DOWN = Vec3{ .x = 0, .y = -1, .z = 0 };
    pub const FORWARD = Vec3{ .x = 0, .y = 0, .z = -1 };
    pub const BACKWARD = Vec3{ .x = 0, .y = 0, .z = 1 };
    pub const LEFT = Vec3{ .x = -1, .y = 0, .z = 0 };
    pub const RIGHT = Vec3{ .x = 1, .y = 0, .z = 0 };

    pub fn init(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn add(self: Vec3, other: Vec3) Vec3 {
        return .{
            .x = self.x + other.x,
            .y = self.y + other.y,
            .z = self.z + other.z,
        };
    }

    pub fn sub(self: Vec3, other: Vec3) Vec3 {
        return .{
            .x = self.x - other.x,
            .y = self.y - other.y,
            .z = self.z - other.z,
        };
    }

    pub fn scale(self: Vec3, s: f32) Vec3 {
        return .{
            .x = self.x * s,
            .y = self.y * s,
            .z = self.z * s,
        };
    }

    pub fn dot(self: Vec3, other: Vec3) f32 {
        return self.x * other.x + self.y * other.y + self.z * other.z;
    }

    pub fn cross(self: Vec3, other: Vec3) Vec3 {
        return .{
            .x = self.y * other.z - self.z * other.y,
            .y = self.z * other.x - self.x * other.z,
            .z = self.x * other.y - self.y * other.x,
        };
    }

    pub fn length(self: Vec3) f32 {
        return @sqrt(self.lengthSquared());
    }

    pub fn lengthSquared(self: Vec3) f32 {
        return self.x * self.x + self.y * self.y + self.z * self.z;
    }

    pub fn normalize(self: Vec3) Vec3 {
        const len = self.length();
        if (len == 0) return ZERO;
        return self.scale(1.0 / len);
    }

    pub fn negate(self: Vec3) Vec3 {
        return .{ .x = -self.x, .y = -self.y, .z = -self.z };
    }

    pub fn lerp(a: Vec3, b: Vec3, t: f32) Vec3 {
        return .{
            .x = a.x + (b.x - a.x) * t,
            .y = a.y + (b.y - a.y) * t,
            .z = a.z + (b.z - a.z) * t,
        };
    }
};

pub const Mat4 = struct {
    data: [16]f32,

    pub const IDENTITY = Mat4{
        .data = .{
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        },
    };

    pub fn perspective(fov_radians: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const tan_half_fov = @tan(fov_radians / 2.0);
        var result = Mat4{ .data = .{0} ** 16 };

        result.data[0] = 1.0 / (aspect * tan_half_fov);
        result.data[5] = 1.0 / tan_half_fov;
        result.data[10] = -(far + near) / (far - near);
        result.data[11] = -1.0;
        result.data[14] = -(2.0 * far * near) / (far - near);

        return result;
    }

    pub fn lookAt(eye: Vec3, target: Vec3, up: Vec3) Mat4 {
        const f = target.sub(eye).normalize();
        const s = f.cross(up).normalize();
        const u = s.cross(f);

        var result = IDENTITY;

        result.data[0] = s.x;
        result.data[4] = s.y;
        result.data[8] = s.z;

        result.data[1] = u.x;
        result.data[5] = u.y;
        result.data[9] = u.z;

        result.data[2] = -f.x;
        result.data[6] = -f.y;
        result.data[10] = -f.z;

        result.data[12] = -s.dot(eye);
        result.data[13] = -u.dot(eye);
        result.data[14] = f.dot(eye);

        return result;
    }

    pub fn translation(v: Vec3) Mat4 {
        var result = IDENTITY;
        result.data[12] = v.x;
        result.data[13] = v.y;
        result.data[14] = v.z;
        return result;
    }

    pub fn rotationY(angle_radians: f32) Mat4 {
        const c = @cos(angle_radians);
        const s = @sin(angle_radians);
        var result = IDENTITY;
        result.data[0] = c;
        result.data[2] = s;
        result.data[8] = -s;
        result.data[10] = c;
        return result;
    }

    pub fn rotationX(angle_radians: f32) Mat4 {
        const c = @cos(angle_radians);
        const s = @sin(angle_radians);
        var result = IDENTITY;
        result.data[5] = c;
        result.data[6] = -s;
        result.data[9] = s;
        result.data[10] = c;
        return result;
    }

    pub fn multiply(a: Mat4, b: Mat4) Mat4 {
        var result: Mat4 = undefined;
        for (0..4) |col| {
            for (0..4) |row| {
                var sum: f32 = 0;
                for (0..4) |k| {
                    sum += a.data[row + k * 4] * b.data[k + col * 4];
                }
                result.data[row + col * 4] = sum;
            }
        }
        return result;
    }
};

// Angle utilities
pub fn degreesToRadians(degrees: f32) f32 {
    return degrees * (std.math.pi / 180.0);
}

pub fn radiansToDegrees(radians: f32) f32 {
    return radians * (180.0 / std.math.pi);
}

pub fn clamp(value: f32, min_val: f32, max_val: f32) f32 {
    return @max(min_val, @min(max_val, value));
}

pub fn wrapDegrees(degrees: f32) f32 {
    var result = @mod(degrees, 360.0);
    if (result < 0) result += 360.0;
    if (result > 180.0) result -= 360.0;
    return result;
}
