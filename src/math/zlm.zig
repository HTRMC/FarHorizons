const std = @import("std");

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn init(x: f32, y: f32, z: f32) Vec3 {
        return Vec3{ .x = x, .y = y, .z = z };
    }

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return Vec3{
            .x = a.x + b.x,
            .y = a.y + b.y,
            .z = a.z + b.z,
        };
    }

    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return Vec3{
            .x = a.x - b.x,
            .y = a.y - b.y,
            .z = a.z - b.z,
        };
    }

    pub fn scale(v: Vec3, s: f32) Vec3 {
        return Vec3{
            .x = v.x * s,
            .y = v.y * s,
            .z = v.z * s,
        };
    }

    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    pub fn length(v: Vec3) f32 {
        return @sqrt(dot(v, v));
    }

    pub fn normalize(v: Vec3) Vec3 {
        const len = length(v);
        if (len < std.math.floatEps(f32)) return v;
        return scale(v, 1.0 / len);
    }

    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return Vec3{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }
};

pub const Vec4 = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    pub fn init(x: f32, y: f32, z: f32, w: f32) Vec4 {
        return Vec4{ .x = x, .y = y, .z = z, .w = w };
    }
};

pub const Mat4 = struct {
    m: [16]f32, // Column-major order for GLSL compatibility

    pub fn identity() Mat4 {
        return Mat4{
            .m = [16]f32{
                1.0, 0.0, 0.0, 0.0,
                0.0, 1.0, 0.0, 0.0,
                0.0, 0.0, 1.0, 0.0,
                0.0, 0.0, 0.0, 1.0,
            },
        };
    }

    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var result: Mat4 = undefined;
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            var j: usize = 0;
            while (j < 4) : (j += 1) {
                var sum: f32 = 0.0;
                var k: usize = 0;
                while (k < 4) : (k += 1) {
                    sum += a.m[k * 4 + j] * b.m[i * 4 + k];
                }
                result.m[i * 4 + j] = sum;
            }
        }
        return result;
    }

    pub fn perspective(fov: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const tan_half_fov = @tan(fov / 2.0);
        var result = Mat4{ .m = [_]f32{0.0} ** 16 };

        result.m[0] = 1.0 / (aspect * tan_half_fov);
        result.m[5] = -1.0 / tan_half_fov; // Flip Y for Vulkan (clip space Y points down)
        result.m[10] = far / (near - far); // Vulkan uses 0-1 depth range
        result.m[11] = -1.0;
        result.m[14] = -(far * near) / (far - near); // Vulkan 0-1 depth

        return result;
    }

    pub fn lookAt(eye: Vec3, target: Vec3, up: Vec3) Mat4 {
        const f = Vec3.normalize(Vec3.sub(target, eye));
        const s = Vec3.normalize(Vec3.cross(f, up));
        const u = Vec3.cross(s, f);

        var result = Mat4.identity();

        result.m[0] = s.x;
        result.m[4] = s.y;
        result.m[8] = s.z;

        result.m[1] = u.x;
        result.m[5] = u.y;
        result.m[9] = u.z;

        result.m[2] = -f.x;
        result.m[6] = -f.y;
        result.m[10] = -f.z;

        result.m[12] = -Vec3.dot(s, eye);
        result.m[13] = -Vec3.dot(u, eye);
        result.m[14] = Vec3.dot(f, eye);

        return result;
    }
};
