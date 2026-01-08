const Axis = @import("Axis.zig").Axis;

/// AxisCycle for coordinate transformation (like Minecraft's AxisCycle)
/// Used to write generic collision code that works for any axis by rotating
/// the coordinate system so the collision axis becomes X.
///
/// Example usage:
///   To collide on the Z axis, use AxisCycle.between(.z, .x)
///   This gives you a cycle that transforms Z→X, so your generic code
///   can always work on "X" while actually operating on Z.
pub const AxisCycle = enum(u2) {
    /// Identity: X→X, Y→Y, Z→Z
    none = 0,
    /// Forward rotation: X→Y, Y→Z, Z→X
    forward = 1,
    /// Backward rotation: X→Z, Y→X, Z→Y
    backward = 2,

    pub const VALUES = [_]AxisCycle{ .none, .forward, .backward };

    /// Get the cycle needed to transform 'from' axis to 'to' axis
    /// Example: between(.z, .x) returns the cycle that maps Z to X
    pub fn between(from: Axis, to: Axis) AxisCycle {
        const diff = @as(i32, @intFromEnum(to)) - @as(i32, @intFromEnum(from));
        const mod: u2 = @intCast(@mod(diff, 3));
        return @enumFromInt(mod);
    }

    /// Get the inverse cycle
    pub fn inverse(self: AxisCycle) AxisCycle {
        return switch (self) {
            .none => .none,
            .forward => .backward,
            .backward => .forward,
        };
    }

    /// Cycle an axis through the transformation
    pub fn cycle(self: AxisCycle, axis: Axis) Axis {
        const ord = @intFromEnum(axis);
        const new_ord: u2 = @intCast(@mod(ord + @intFromEnum(self), 3));
        return @enumFromInt(new_ord);
    }

    /// Choose int value based on cycle and axis
    /// This rotates coordinates so generic code can always work on axis X
    ///
    /// For NONE:     choose(x,y,z, .x) = x, choose(x,y,z, .y) = y, choose(x,y,z, .z) = z
    /// For FORWARD:  choose(x,y,z, .x) = z, choose(x,y,z, .y) = x, choose(x,y,z, .z) = y
    /// For BACKWARD: choose(x,y,z, .x) = y, choose(x,y,z, .y) = z, choose(x,y,z, .z) = x
    pub inline fn chooseInt(self: AxisCycle, x: i32, y: i32, z: i32, axis: Axis) i32 {
        return switch (self) {
            .none => axis.chooseInt(x, y, z),
            .forward => axis.chooseInt(z, x, y),
            .backward => axis.chooseInt(y, z, x),
        };
    }

    /// Choose f32 value based on cycle and axis
    pub inline fn chooseF32(self: AxisCycle, x: f32, y: f32, z: f32, axis: Axis) f32 {
        return switch (self) {
            .none => axis.chooseF32(x, y, z),
            .forward => axis.chooseF32(z, x, y),
            .backward => axis.chooseF32(y, z, x),
        };
    }

    /// Choose f64 value based on cycle and axis
    pub inline fn chooseF64(self: AxisCycle, x: f64, y: f64, z: f64, axis: Axis) f64 {
        return switch (self) {
            .none => axis.chooseF64(x, y, z),
            .forward => axis.chooseF64(z, x, y),
            .backward => axis.chooseF64(y, z, x),
        };
    }
};
