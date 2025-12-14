/// SubShape - A view into a DiscreteVoxelShape with bounds
/// Equivalent to Minecraft's net.minecraft.world.phys.shapes.SubShape
///
/// SubShape provides a windowed view into a parent shape without copying data.
/// It's used by SliceShape to create thin 3D slices for face occlusion.
const std = @import("std");
const dvs = @import("DiscreteVoxelShape.zig");
const DiscreteVoxelShape = dvs.DiscreteVoxelShape;
const Axis = dvs.Axis;

/// A view into a parent DiscreteVoxelShape with offset bounds
pub const SubShape = struct {
    const Self = @This();

    /// Base discrete shape fields (size is end - start)
    base: DiscreteVoxelShape,

    /// Reference to parent shape (stored as pointer to the base)
    /// Note: Parent must outlive this SubShape
    parent_ptr: *const DiscreteVoxelShape,

    /// Start bounds (inclusive)
    start_x: u8,
    start_y: u8,
    start_z: u8,

    /// End bounds (exclusive)
    end_x: u8,
    end_y: u8,
    end_z: u8,

    /// Static vtable for DiscreteVoxelShape interface
    const vtable = DiscreteVoxelShape.VTable{
        .isFull = isFull,
        .fill = fill,
        .clear = clear,
        .isEmpty = isEmpty,
        .isFullBlock = isFullBlock,
    };

    /// Create a SubShape view into a parent shape
    pub fn init(
        parent: *const DiscreteVoxelShape,
        start_x: u8,
        start_y: u8,
        start_z: u8,
        end_x: u8,
        end_y: u8,
        end_z: u8,
    ) Self {
        const x_size = end_x - start_x;
        const y_size = end_y - start_y;
        const z_size = end_z - start_z;

        return .{
            .base = DiscreteVoxelShape.init(x_size, y_size, z_size, &vtable),
            .parent_ptr = parent,
            .start_x = start_x,
            .start_y = start_y,
            .start_z = start_z,
            .end_x = end_x,
            .end_y = end_y,
            .end_z = end_z,
        };
    }

    /// Create a slice along an axis at a specific position
    /// This creates a 1-unit thick slice perpendicular to the axis
    pub fn makeSlice(parent: *const DiscreteVoxelShape, axis: Axis, point: u8) Self {
        return switch (axis) {
            .x => init(
                parent,
                point,
                0,
                0,
                point + 1,
                parent.y_size,
                parent.z_size,
            ),
            .y => init(
                parent,
                0,
                point,
                0,
                parent.x_size,
                point + 1,
                parent.z_size,
            ),
            .z => init(
                parent,
                0,
                0,
                point,
                parent.x_size,
                parent.y_size,
                point + 1,
            ),
        };
    }

    // === DiscreteVoxelShape interface implementation ===

    fn isFull(base: *const DiscreteVoxelShape, x: u8, y: u8, z: u8) bool {
        const self: *const Self = @fieldParentPtr("base", base);
        // Translate to parent coordinates
        const px = self.start_x + x;
        const py = self.start_y + y;
        const pz = self.start_z + z;
        return self.parent_ptr.isFull(px, py, pz);
    }

    fn fill(base: *DiscreteVoxelShape, x: u8, y: u8, z: u8) void {
        // SubShape is read-only view, but we implement fill for interface compliance
        _ = base;
        _ = x;
        _ = y;
        _ = z;
    }

    fn clear(base: *DiscreteVoxelShape, x: u8, y: u8, z: u8) void {
        // SubShape is read-only view
        _ = base;
        _ = x;
        _ = y;
        _ = z;
    }

    fn isEmpty(base: *const DiscreteVoxelShape) bool {
        const self: *const Self = @fieldParentPtr("base", base);
        // Check if any voxel in our bounds is filled
        for (0..self.base.x_size) |x| {
            for (0..self.base.y_size) |y| {
                for (0..self.base.z_size) |z| {
                    if (isFull(base, @intCast(x), @intCast(y), @intCast(z))) {
                        return false;
                    }
                }
            }
        }
        return true;
    }

    fn isFullBlock(base: *const DiscreteVoxelShape) bool {
        const self: *const Self = @fieldParentPtr("base", base);
        // Check if all voxels in our bounds are filled
        for (0..self.base.x_size) |x| {
            for (0..self.base.y_size) |y| {
                for (0..self.base.z_size) |z| {
                    if (!isFull(base, @intCast(x), @intCast(y), @intCast(z))) {
                        return false;
                    }
                }
            }
        }
        return true;
    }

    // === Additional methods ===

    /// Clamp a parent coordinate result to this shape's local bounds
    pub fn clampToShape(self: *const Self, axis: Axis, parent_result: u8) u8 {
        const start = switch (axis) {
            .x => self.start_x,
            .y => self.start_y,
            .z => self.start_z,
        };
        const end = switch (axis) {
            .x => self.end_x,
            .y => self.end_y,
            .z => self.end_z,
        };
        const clamped = std.math.clamp(parent_result, start, end);
        return clamped - start;
    }

    /// Get first full coordinate along axis (in local coordinates)
    pub fn firstFull(self: *const Self, axis: Axis) u8 {
        const parent_first = self.parent_ptr.firstFull(axis);
        return self.clampToShape(axis, parent_first);
    }

    /// Get last full coordinate along axis (in local coordinates)
    pub fn lastFull(self: *const Self, axis: Axis) u8 {
        const parent_last = self.parent_ptr.lastFull(axis);
        return self.clampToShape(axis, parent_last);
    }
};

// Tests
test "SubShape basic" {
    const BitSetDiscreteVoxelShape = @import("BitsetDiscreteVoxelShape.zig").BitSetDiscreteVoxelShape;

    // Create a 4x4x4 shape with bottom half filled
    var parent = BitSetDiscreteVoxelShape.withFilledBounds(4, 4, 4, 0, 0, 0, 4, 2, 4);

    // Create a Y slice at y=0 (should be full)
    const slice_y0 = SubShape.makeSlice(&parent.base, .y, 0);
    try std.testing.expect(!slice_y0.base.isEmpty());
    try std.testing.expect(slice_y0.base.isFullBlock());

    // Create a Y slice at y=3 (should be empty)
    const slice_y3 = SubShape.makeSlice(&parent.base, .y, 3);
    try std.testing.expect(slice_y3.base.isEmpty());
}

test "SubShape dimensions" {
    const BitSetDiscreteVoxelShape = @import("BitsetDiscreteVoxelShape.zig").BitSetDiscreteVoxelShape;

    var parent = BitSetDiscreteVoxelShape.initFull(4, 4, 4);

    // X slice should be 1 x 4 x 4
    const x_slice = SubShape.makeSlice(&parent.base, .x, 2);
    try std.testing.expectEqual(@as(u8, 1), x_slice.base.x_size);
    try std.testing.expectEqual(@as(u8, 4), x_slice.base.y_size);
    try std.testing.expectEqual(@as(u8, 4), x_slice.base.z_size);

    // Y slice should be 4 x 1 x 4
    const y_slice = SubShape.makeSlice(&parent.base, .y, 1);
    try std.testing.expectEqual(@as(u8, 4), y_slice.base.x_size);
    try std.testing.expectEqual(@as(u8, 1), y_slice.base.y_size);
    try std.testing.expectEqual(@as(u8, 4), y_slice.base.z_size);

    // Z slice should be 4 x 4 x 1
    const z_slice = SubShape.makeSlice(&parent.base, .z, 0);
    try std.testing.expectEqual(@as(u8, 4), z_slice.base.x_size);
    try std.testing.expectEqual(@as(u8, 4), z_slice.base.y_size);
    try std.testing.expectEqual(@as(u8, 1), z_slice.base.z_size);
}
