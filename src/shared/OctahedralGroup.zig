/// OctahedralGroup - 3D rotation and reflection transformations
/// Equivalent to Minecraft's com.mojang.math.OctahedralGroup
///
/// The octahedral group consists of 48 transformations that map a cube to itself:
/// - 24 proper rotations (orientation-preserving)
/// - 24 improper rotations (reflections)
///
/// Each transformation is defined by:
/// - A permutation of axes (which axis maps to which)
/// - Inversion flags for each axis (flip direction)
const std = @import("std");
const dvs = @import("DiscreteVoxelShape.zig");
const Axis = dvs.Axis;
const Direction = dvs.Direction;
const AxisDirection = dvs.AxisDirection;

/// Symmetric group of 3 elements - axis permutations
/// P123 = identity, P213 = swap X/Y, etc.
pub const SymmetricGroup3 = enum(u3) {
    P123 = 0, // X->X, Y->Y, Z->Z (identity)
    P213 = 1, // X->Y, Y->X, Z->Z (swap X/Y)
    P132 = 2, // X->X, Y->Z, Z->Y (swap Y/Z)
    P312 = 3, // X->Z, Y->X, Z->Y (cycle forward)
    P231 = 4, // X->Y, Y->Z, Z->X (cycle backward)
    P321 = 5, // X->Z, Y->Y, Z->X (swap X/Z)

    const Self = @This();

    /// Apply permutation to get which output axis corresponds to input axis
    pub fn permute(self: Self, i: u2) u2 {
        return switch (self) {
            .P123 => i, // identity
            .P213 => switch (i) {
                0 => 1,
                1 => 0,
                2 => 2,
                else => i,
            },
            .P132 => switch (i) {
                0 => 0,
                1 => 2,
                2 => 1,
                else => i,
            },
            .P312 => switch (i) {
                0 => 2,
                1 => 0,
                2 => 1,
                else => i,
            },
            .P231 => switch (i) {
                0 => 1,
                1 => 2,
                2 => 0,
                else => i,
            },
            .P321 => switch (i) {
                0 => 2,
                1 => 1,
                2 => 0,
                else => i,
            },
        };
    }

    /// Permute an axis
    pub fn permuteAxis(self: Self, axis: Axis) Axis {
        return @enumFromInt(self.permute(@intFromEnum(axis)));
    }

    /// Get the inverse permutation
    pub fn inverse(self: Self) Self {
        return switch (self) {
            .P123 => .P123, // identity inverse is identity
            .P213 => .P213, // swap X/Y is self-inverse
            .P132 => .P132, // swap Y/Z is self-inverse
            .P321 => .P321, // swap X/Z is self-inverse
            .P312 => .P231, // cycle forward inverse is cycle backward
            .P231 => .P312, // cycle backward inverse is cycle forward
        };
    }

    /// Compose two permutations: result = self(other(x))
    pub fn compose(self: Self, other: Self) Self {
        const p0 = self.permute(other.permute(0));
        const p1 = self.permute(other.permute(1));
        const p2 = self.permute(other.permute(2));

        // Find matching permutation
        inline for (std.meta.fields(Self)) |field| {
            const perm: Self = @enumFromInt(field.value);
            if (perm.permute(0) == p0 and perm.permute(1) == p1 and perm.permute(2) == p2) {
                return perm;
            }
        }
        return .P123; // fallback (shouldn't happen)
    }
};

/// Octahedral group element - a 3D transformation
pub const OctahedralGroup = struct {
    const Self = @This();

    permutation: SymmetricGroup3,
    invert_x: bool,
    invert_y: bool,
    invert_z: bool,

    /// Identity transformation (no change)
    pub const IDENTITY = Self{ .permutation = .P123, .invert_x = false, .invert_y = false, .invert_z = false };

    // === Block rotations (Y axis) ===
    /// 90 degree clockwise rotation around Y axis (looking down)
    /// North becomes East, East becomes South, etc.
    pub const BLOCK_ROT_Y_90 = ROT_90_Y_NEG;

    /// 180 degree rotation around Y axis
    pub const BLOCK_ROT_Y_180 = ROT_180_FACE_XZ;

    /// 270 degree clockwise (= 90 counter-clockwise) rotation around Y axis
    pub const BLOCK_ROT_Y_270 = ROT_90_Y_POS;

    // === Block rotations (X axis) ===
    pub const BLOCK_ROT_X_90 = ROT_90_X_NEG;
    pub const BLOCK_ROT_X_180 = ROT_180_FACE_YZ;
    pub const BLOCK_ROT_X_270 = ROT_90_X_POS;

    // === Block rotations (Z axis) ===
    pub const BLOCK_ROT_Z_90 = ROT_90_Z_NEG;
    pub const BLOCK_ROT_Z_180 = ROT_180_FACE_XY;
    pub const BLOCK_ROT_Z_270 = ROT_90_Z_POS;

    // === Core rotation elements ===
    /// 180 degree rotation around XY plane normal (Z axis)
    pub const ROT_180_FACE_XY = Self{ .permutation = .P123, .invert_x = true, .invert_y = true, .invert_z = false };

    /// 180 degree rotation around XZ plane normal (Y axis)
    pub const ROT_180_FACE_XZ = Self{ .permutation = .P123, .invert_x = true, .invert_y = false, .invert_z = true };

    /// 180 degree rotation around YZ plane normal (X axis)
    pub const ROT_180_FACE_YZ = Self{ .permutation = .P123, .invert_x = false, .invert_y = true, .invert_z = true };

    /// 90 degree rotation around Y axis (negative direction - clockwise from above)
    pub const ROT_90_Y_NEG = Self{ .permutation = .P321, .invert_x = true, .invert_y = false, .invert_z = false };

    /// 90 degree rotation around Y axis (positive direction - counter-clockwise from above)
    pub const ROT_90_Y_POS = Self{ .permutation = .P321, .invert_x = false, .invert_y = false, .invert_z = true };

    /// 90 degree rotation around X axis (negative direction)
    pub const ROT_90_X_NEG = Self{ .permutation = .P132, .invert_x = false, .invert_y = false, .invert_z = true };

    /// 90 degree rotation around X axis (positive direction)
    pub const ROT_90_X_POS = Self{ .permutation = .P132, .invert_x = false, .invert_y = true, .invert_z = false };

    /// 90 degree rotation around Z axis (negative direction)
    pub const ROT_90_Z_NEG = Self{ .permutation = .P213, .invert_x = false, .invert_y = true, .invert_z = false };

    /// 90 degree rotation around Z axis (positive direction)
    pub const ROT_90_Z_POS = Self{ .permutation = .P213, .invert_x = true, .invert_y = false, .invert_z = false };

    // === Inversions ===
    /// Invert X axis only (mirror across YZ plane)
    pub const INVERT_X = Self{ .permutation = .P123, .invert_x = true, .invert_y = false, .invert_z = false };

    /// Invert Y axis only (mirror across XZ plane) - used for top stairs
    pub const INVERT_Y = Self{ .permutation = .P123, .invert_x = false, .invert_y = true, .invert_z = false };

    /// Invert Z axis only (mirror across XY plane)
    pub const INVERT_Z = Self{ .permutation = .P123, .invert_x = false, .invert_y = false, .invert_z = true };

    /// Full inversion (point reflection through origin)
    pub const INVERSION = Self{ .permutation = .P123, .invert_x = true, .invert_y = true, .invert_z = true };

    /// Check if this inverts the given axis
    pub fn inverts(self: Self, axis: Axis) bool {
        return switch (axis) {
            .x => self.invert_x,
            .y => self.invert_y,
            .z => self.invert_z,
        };
    }

    /// Compose two transformations: result = self(other(x))
    pub fn compose(self: Self, other: Self) Self {
        const composed_permutation = other.permutation.compose(self.permutation);

        // For inversion, we need to consider how the permutation affects axes
        // self.invert_a XOR other.inverts(self.permutation.permuteAxis(a))
        const composed_invert_x = self.invert_x != other.inverts(self.permutation.permuteAxis(.x));
        const composed_invert_y = self.invert_y != other.inverts(self.permutation.permuteAxis(.y));
        const composed_invert_z = self.invert_z != other.inverts(self.permutation.permuteAxis(.z));

        return .{
            .permutation = composed_permutation,
            .invert_x = composed_invert_x,
            .invert_y = composed_invert_y,
            .invert_z = composed_invert_z,
        };
    }

    /// Rotate a 3D integer vector
    pub fn rotateVec(self: Self, x: i32, y: i32, z: i32) struct { x: i32, y: i32, z: i32 } {
        // First apply permutation
        const px = switch (self.permutation.permute(0)) {
            0 => x,
            1 => y,
            2 => z,
            else => x,
        };
        const py = switch (self.permutation.permute(1)) {
            0 => x,
            1 => y,
            2 => z,
            else => y,
        };
        const pz = switch (self.permutation.permute(2)) {
            0 => x,
            1 => y,
            2 => z,
            else => z,
        };

        // Then apply inversions
        return .{
            .x = if (self.invert_x) -px else px,
            .y = if (self.invert_y) -py else py,
            .z = if (self.invert_z) -pz else pz,
        };
    }

    /// Rotate a direction
    pub fn rotateDirection(self: Self, direction: Direction) Direction {
        const old_axis = direction.getAxis();
        const old_dir = direction.getAxisDirection();

        // Get the new axis using inverse permutation
        const new_axis = self.permutation.inverse().permuteAxis(old_axis);

        // Determine if direction is flipped
        const new_dir: AxisDirection = if (self.inverts(new_axis))
            (if (old_dir == .positive) .negative else .positive)
        else
            old_dir;

        return fromAxisAndDirection(new_axis, new_dir);
    }

    /// Check if this is the identity transformation
    pub fn isIdentity(self: Self) bool {
        return self.permutation == .P123 and !self.invert_x and !self.invert_y and !self.invert_z;
    }
};

/// Create a Direction from axis and direction
fn fromAxisAndDirection(axis: Axis, dir: AxisDirection) Direction {
    return switch (axis) {
        .x => if (dir == .positive) .east else .west,
        .y => if (dir == .positive) .up else .down,
        .z => if (dir == .positive) .south else .north,
    };
}

// === Tests ===

test "SymmetricGroup3 identity" {
    const p = SymmetricGroup3.P123;
    try std.testing.expectEqual(@as(u2, 0), p.permute(0));
    try std.testing.expectEqual(@as(u2, 1), p.permute(1));
    try std.testing.expectEqual(@as(u2, 2), p.permute(2));
}

test "SymmetricGroup3 swap XZ" {
    const p = SymmetricGroup3.P321;
    try std.testing.expectEqual(Axis.z, p.permuteAxis(.x));
    try std.testing.expectEqual(Axis.y, p.permuteAxis(.y));
    try std.testing.expectEqual(Axis.x, p.permuteAxis(.z));
}

test "OctahedralGroup identity" {
    const rot = OctahedralGroup.IDENTITY;
    try std.testing.expect(rot.isIdentity());

    const v = rot.rotateVec(1, 2, 3);
    try std.testing.expectEqual(@as(i32, 1), v.x);
    try std.testing.expectEqual(@as(i32, 2), v.y);
    try std.testing.expectEqual(@as(i32, 3), v.z);
}

test "OctahedralGroup Y rotation 90" {
    const rot = OctahedralGroup.BLOCK_ROT_Y_90;

    // North should become East
    try std.testing.expectEqual(Direction.east, rot.rotateDirection(.north));
    // East should become South
    try std.testing.expectEqual(Direction.south, rot.rotateDirection(.east));
    // South should become West
    try std.testing.expectEqual(Direction.west, rot.rotateDirection(.south));
    // West should become North
    try std.testing.expectEqual(Direction.north, rot.rotateDirection(.west));
    // Up and Down should stay the same
    try std.testing.expectEqual(Direction.up, rot.rotateDirection(.up));
    try std.testing.expectEqual(Direction.down, rot.rotateDirection(.down));
}

test "OctahedralGroup Y rotation 180" {
    const rot = OctahedralGroup.BLOCK_ROT_Y_180;

    // North becomes South
    try std.testing.expectEqual(Direction.south, rot.rotateDirection(.north));
    // East becomes West
    try std.testing.expectEqual(Direction.west, rot.rotateDirection(.east));
}

test "OctahedralGroup compose Y rotations" {
    // 90 + 90 = 180
    const rot_180 = OctahedralGroup.BLOCK_ROT_Y_90.compose(OctahedralGroup.BLOCK_ROT_Y_90);
    try std.testing.expectEqual(Direction.south, rot_180.rotateDirection(.north));

    // 90 + 180 = 270
    const rot_270 = OctahedralGroup.BLOCK_ROT_Y_90.compose(OctahedralGroup.BLOCK_ROT_Y_180);
    // North rotated 270 degrees = West
    try std.testing.expectEqual(Direction.west, rot_270.rotateDirection(.north));
}

test "OctahedralGroup INVERT_Y" {
    const rot = OctahedralGroup.INVERT_Y;

    // Up becomes Down
    try std.testing.expectEqual(Direction.down, rot.rotateDirection(.up));
    // Down becomes Up
    try std.testing.expectEqual(Direction.up, rot.rotateDirection(.down));
    // Horizontal directions unchanged
    try std.testing.expectEqual(Direction.north, rot.rotateDirection(.north));
    try std.testing.expectEqual(Direction.east, rot.rotateDirection(.east));
}
