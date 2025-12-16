/// DiscreteVoxelShape - Base for discrete voxel representations
///
/// A discrete voxel shape represents a 3D boolean grid where each cell
/// is either filled or empty. The shape has dimensions (xSize, ySize, zSize)
/// and stores which cells are filled.
const std = @import("std");

/// Abstract discrete voxel shape interface
/// Concrete implementations: BitSetDiscreteVoxelShape
pub const DiscreteVoxelShape = struct {
    const Self = @This();

    x_size: u8,
    y_size: u8,
    z_size: u8,

    // Cached bounds (updated when shape changes)
    x_min: u8,
    y_min: u8,
    z_min: u8,
    x_max: u8,
    y_max: u8,
    z_max: u8,

    // Virtual function table for polymorphism
    vtable: *const VTable,

    pub const VTable = struct {
        isFull: *const fn (self: *const Self, x: u8, y: u8, z: u8) bool,
        fill: *const fn (self: *Self, x: u8, y: u8, z: u8) void,
        clear: *const fn (self: *Self, x: u8, y: u8, z: u8) void,
        isEmpty: *const fn (self: *const Self) bool,
        isFullBlock: *const fn (self: *const Self) bool,
    };

    pub fn init(x_size: u8, y_size: u8, z_size: u8, vtable: *const VTable) Self {
        return .{
            .x_size = x_size,
            .y_size = y_size,
            .z_size = z_size,
            .x_min = x_size,
            .y_min = y_size,
            .z_min = z_size,
            .x_max = 0,
            .y_max = 0,
            .z_max = 0,
            .vtable = vtable,
        };
    }

    /// Check if voxel at (x, y, z) is filled
    pub fn isFull(self: *const Self, x: u8, y: u8, z: u8) bool {
        return self.vtable.isFull(self, x, y, z);
    }

    /// Check if voxel at (x, y, z) is filled, with bounds safety for wide coords
    /// "Wide" means coordinates can be at the boundary (size instead of size-1)
    pub fn isFullWide(self: *const Self, x: u8, y: u8, z: u8) bool {
        if (x >= self.x_size or y >= self.y_size or z >= self.z_size) {
            return false;
        }
        return self.isFull(x, y, z);
    }

    /// Fill voxel at (x, y, z)
    pub fn fill(self: *Self, x: u8, y: u8, z: u8) void {
        self.vtable.fill(self, x, y, z);
        self.updateBoundsOnFill(x, y, z);
    }

    /// Clear voxel at (x, y, z)
    pub fn clear(self: *Self, x: u8, y: u8, z: u8) void {
        self.vtable.clear(self, x, y, z);
        // Note: clearing may invalidate bounds, but we don't recalculate here
        // for performance. Call recalculateBounds() if needed.
    }

    /// Check if shape is completely empty
    pub fn isEmpty(self: *const Self) bool {
        return self.vtable.isEmpty(self);
    }

    /// Check if shape fills the entire volume
    pub fn isFullBlock(self: *const Self) bool {
        return self.vtable.isFullBlock(self);
    }

    /// Update cached bounds when a voxel is filled
    fn updateBoundsOnFill(self: *Self, x: u8, y: u8, z: u8) void {
        self.x_min = @min(self.x_min, x);
        self.y_min = @min(self.y_min, y);
        self.z_min = @min(self.z_min, z);
        self.x_max = @max(self.x_max, x + 1);
        self.y_max = @max(self.y_max, y + 1);
        self.z_max = @max(self.z_max, z + 1);
    }

    /// Recalculate bounds by scanning all voxels (expensive)
    pub fn recalculateBounds(self: *Self) void {
        self.x_min = self.x_size;
        self.y_min = self.y_size;
        self.z_min = self.z_size;
        self.x_max = 0;
        self.y_max = 0;
        self.z_max = 0;

        for (0..self.x_size) |x| {
            for (0..self.y_size) |y| {
                for (0..self.z_size) |z| {
                    if (self.isFull(@intCast(x), @intCast(y), @intCast(z))) {
                        self.x_min = @min(self.x_min, @as(u8, @intCast(x)));
                        self.y_min = @min(self.y_min, @as(u8, @intCast(y)));
                        self.z_min = @min(self.z_min, @as(u8, @intCast(z)));
                        self.x_max = @max(self.x_max, @as(u8, @intCast(x + 1)));
                        self.y_max = @max(self.y_max, @as(u8, @intCast(y + 1)));
                        self.z_max = @max(self.z_max, @as(u8, @intCast(z + 1)));
                    }
                }
            }
        }
    }

    /// Get the first filled X coordinate, or x_size if empty
    pub fn firstFull(self: *const Self, axis: Axis) u8 {
        return switch (axis) {
            .x => self.x_min,
            .y => self.y_min,
            .z => self.z_min,
        };
    }

    /// Get one past the last filled coordinate, or 0 if empty
    pub fn lastFull(self: *const Self, axis: Axis) u8 {
        return switch (axis) {
            .x => self.x_max,
            .y => self.y_max,
            .z => self.z_max,
        };
    }

    /// Get size along axis
    pub fn getSize(self: *const Self, axis: Axis) u8 {
        return switch (axis) {
            .x => self.x_size,
            .y => self.y_size,
            .z => self.z_size,
        };
    }

    /// Fill a rectangular region
    pub fn fillBox(self: *Self, x1: u8, y1: u8, z1: u8, x2: u8, y2: u8, z2: u8) void {
        for (x1..x2) |x| {
            for (y1..y2) |y| {
                for (z1..z2) |z| {
                    self.fill(@intCast(x), @intCast(y), @intCast(z));
                }
            }
        }
    }

    /// Check if this shape contains another shape (all filled voxels of other are filled in self)
    pub fn contains(self: *const Self, other: *const Self) bool {
        if (self.x_size != other.x_size or self.y_size != other.y_size or self.z_size != other.z_size) {
            return false;
        }

        for (0..self.x_size) |x| {
            for (0..self.y_size) |y| {
                for (0..self.z_size) |z| {
                    const xu8: u8 = @intCast(x);
                    const yu8: u8 = @intCast(y);
                    const zu8: u8 = @intCast(z);
                    if (other.isFull(xu8, yu8, zu8) and !self.isFull(xu8, yu8, zu8)) {
                        return false;
                    }
                }
            }
        }
        return true;
    }
};

/// Axis enumeration
pub const Axis = enum(u2) {
    x = 0,
    y = 1,
    z = 2,

    pub fn choose(self: Axis, x: anytype, y: @TypeOf(x), z: @TypeOf(x)) @TypeOf(x) {
        return switch (self) {
            .x => x,
            .y => y,
            .z => z,
        };
    }
};

/// Direction enumeration with axis and sign
pub const Direction = enum(u3) {
    down = 0, // -Y
    up = 1, // +Y
    north = 2, // -Z
    south = 3, // +Z
    west = 4, // -X
    east = 5, // +X

    pub fn getAxis(self: Direction) Axis {
        return switch (self) {
            .down, .up => .y,
            .north, .south => .z,
            .west, .east => .x,
        };
    }

    pub fn getAxisDirection(self: Direction) AxisDirection {
        return switch (self) {
            .down, .north, .west => .negative,
            .up, .south, .east => .positive,
        };
    }

    pub fn opposite(self: Direction) Direction {
        return switch (self) {
            .down => .up,
            .up => .down,
            .north => .south,
            .south => .north,
            .west => .east,
            .east => .west,
        };
    }

    pub fn offset(self: Direction) [3]i32 {
        return switch (self) {
            .down => .{ 0, -1, 0 },
            .up => .{ 0, 1, 0 },
            .north => .{ 0, 0, -1 },
            .south => .{ 0, 0, 1 },
            .west => .{ -1, 0, 0 },
            .east => .{ 1, 0, 0 },
        };
    }
};

pub const AxisDirection = enum(u1) {
    positive = 0,
    negative = 1,

    pub fn step(self: AxisDirection) i32 {
        return switch (self) {
            .positive => 1,
            .negative => -1,
        };
    }
};
