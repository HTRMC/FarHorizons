const Vec3 = @import("Math.zig").Vec3;

/// Axis enum for coordinate operations (like Minecraft's Direction.Axis)
pub const Axis = enum(u2) {
    x = 0,
    y = 1,
    z = 2,

    /// Get value from Vec3 on this axis
    pub inline fn get(self: Axis, v: Vec3) f32 {
        return switch (self) {
            .x => v.x,
            .y => v.y,
            .z => v.z,
        };
    }

    /// Choose int value based on axis (like MC's Axis.choose(int, int, int))
    pub inline fn chooseInt(self: Axis, x: i32, y: i32, z: i32) i32 {
        return switch (self) {
            .x => x,
            .y => y,
            .z => z,
        };
    }

    /// Choose f32 value based on axis (like MC's Axis.choose(double, double, double))
    pub inline fn chooseF32(self: Axis, x: f32, y: f32, z: f32) f32 {
        return switch (self) {
            .x => x,
            .y => y,
            .z => z,
        };
    }

    /// Choose f64 value based on axis (like MC's Axis.choose(double, double, double))
    pub inline fn chooseF64(self: Axis, x: f64, y: f64, z: f64) f64 {
        return switch (self) {
            .x => x,
            .y => y,
            .z => z,
        };
    }

    /// Choose bool value based on axis (like MC's Axis.choose(boolean, boolean, boolean))
    pub inline fn chooseBool(self: Axis, x: bool, y: bool, z: bool) bool {
        return switch (self) {
            .x => x,
            .y => y,
            .z => z,
        };
    }
};
