const std = @import("std");

pub const Degrees = struct {
    value: f32,

    pub fn toRadians(self: Degrees) Radians {
        return .{ .value = std.math.degreesToRadians(self.value) };
    }

    pub fn add(a: Degrees, b: Degrees) Degrees {
        return .{ .value = a.value + b.value };
    }

    pub fn sub(a: Degrees, b: Degrees) Degrees {
        return .{ .value = a.value - b.value };
    }

    pub fn scale(self: Degrees, s: f32) Degrees {
        return .{ .value = self.value * s };
    }

    pub fn clamp(self: Degrees, min_val: f32, max_val: f32) Degrees {
        return .{ .value = @max(min_val, @min(max_val, self.value)) };
    }

    pub fn mod(self: Degrees, denom: f32) Degrees {
        return .{ .value = @mod(self.value, denom) };
    }

    pub fn normalize360(self: Degrees) Degrees {
        return .{ .value = @mod(self.value, 360.0) };
    }
};

pub const Radians = struct {
    value: f32,

    pub fn toDegrees(self: Radians) Degrees {
        return .{ .value = std.math.radiansToDegrees(self.value) };
    }

    pub fn sin(self: Radians) f32 {
        return @sin(self.value);
    }

    pub fn cos(self: Radians) f32 {
        return @cos(self.value);
    }

    pub fn add(a: Radians, b: Radians) Radians {
        return .{ .value = a.value + b.value };
    }

    pub fn sub(a: Radians, b: Radians) Radians {
        return .{ .value = a.value - b.value };
    }

    pub fn offset(self: Radians, v: f32) Radians {
        return .{ .value = self.value + v };
    }

    pub fn normalize(self: Radians) Radians {
        return .{ .value = @mod(self.value + std.math.pi, std.math.tau) - std.math.pi };
    }
};

pub fn deg(value: f32) Degrees {
    return .{ .value = value };
}

pub fn rad(value: f32) Radians {
    return .{ .value = value };
}
