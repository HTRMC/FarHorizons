const Direction = @import("model/BlockElement.zig").Direction;

/// Extent enum for selecting min/max coordinates
pub const Extent = enum {
    min_x,
    min_y,
    min_z,
    max_x,
    max_y,
    max_z,

    pub fn select(self: Extent, min_x: f32, min_y: f32, min_z: f32, max_x: f32, max_y: f32, max_z: f32) f32 {
        return switch (self) {
            .min_x => min_x,
            .min_y => min_y,
            .min_z => min_z,
            .max_x => max_x,
            .max_y => max_y,
            .max_z => max_z,
        };
    }
};

/// Vertex info specifying which extent to use for each axis
pub const VertexInfo = struct {
    x_face: Extent,
    y_face: Extent,
    z_face: Extent,

    pub fn select(self: VertexInfo, min_x: f32, min_y: f32, min_z: f32, max_x: f32, max_y: f32, max_z: f32) [3]f32 {
        return .{
            self.x_face.select(min_x, min_y, min_z, max_x, max_y, max_z),
            self.y_face.select(min_x, min_y, min_z, max_x, max_y, max_z),
            self.z_face.select(min_x, min_y, min_z, max_x, max_y, max_z),
        };
    }
};

/// Face vertex ordering information for each direction
pub const FaceInfo = struct {
    infos: [4]VertexInfo,

    // Face info for each direction - vertices in CCW order when viewed from outside
    // Matches FaceInfo.java exactly

    // DOWN: (MIN_X,MIN_Y,MAX_Z), (MIN_X,MIN_Y,MIN_Z), (MAX_X,MIN_Y,MIN_Z), (MAX_X,MIN_Y,MAX_Z)
    pub const DOWN = FaceInfo{ .infos = .{
        .{ .x_face = .min_x, .y_face = .min_y, .z_face = .max_z },
        .{ .x_face = .min_x, .y_face = .min_y, .z_face = .min_z },
        .{ .x_face = .max_x, .y_face = .min_y, .z_face = .min_z },
        .{ .x_face = .max_x, .y_face = .min_y, .z_face = .max_z },
    } };

    // UP: (MIN_X,MAX_Y,MIN_Z), (MIN_X,MAX_Y,MAX_Z), (MAX_X,MAX_Y,MAX_Z), (MAX_X,MAX_Y,MIN_Z)
    pub const UP = FaceInfo{ .infos = .{
        .{ .x_face = .min_x, .y_face = .max_y, .z_face = .min_z },
        .{ .x_face = .min_x, .y_face = .max_y, .z_face = .max_z },
        .{ .x_face = .max_x, .y_face = .max_y, .z_face = .max_z },
        .{ .x_face = .max_x, .y_face = .max_y, .z_face = .min_z },
    } };

    // NORTH: (MAX_X,MAX_Y,MIN_Z), (MAX_X,MIN_Y,MIN_Z), (MIN_X,MIN_Y,MIN_Z), (MIN_X,MAX_Y,MIN_Z)
    pub const NORTH = FaceInfo{ .infos = .{
        .{ .x_face = .max_x, .y_face = .max_y, .z_face = .min_z },
        .{ .x_face = .max_x, .y_face = .min_y, .z_face = .min_z },
        .{ .x_face = .min_x, .y_face = .min_y, .z_face = .min_z },
        .{ .x_face = .min_x, .y_face = .max_y, .z_face = .min_z },
    } };

    // SOUTH: (MIN_X,MAX_Y,MAX_Z), (MIN_X,MIN_Y,MAX_Z), (MAX_X,MIN_Y,MAX_Z), (MAX_X,MAX_Y,MAX_Z)
    pub const SOUTH = FaceInfo{ .infos = .{
        .{ .x_face = .min_x, .y_face = .max_y, .z_face = .max_z },
        .{ .x_face = .min_x, .y_face = .min_y, .z_face = .max_z },
        .{ .x_face = .max_x, .y_face = .min_y, .z_face = .max_z },
        .{ .x_face = .max_x, .y_face = .max_y, .z_face = .max_z },
    } };

    // WEST: (MIN_X,MAX_Y,MIN_Z), (MIN_X,MIN_Y,MIN_Z), (MIN_X,MIN_Y,MAX_Z), (MIN_X,MAX_Y,MAX_Z)
    pub const WEST = FaceInfo{ .infos = .{
        .{ .x_face = .min_x, .y_face = .max_y, .z_face = .min_z },
        .{ .x_face = .min_x, .y_face = .min_y, .z_face = .min_z },
        .{ .x_face = .min_x, .y_face = .min_y, .z_face = .max_z },
        .{ .x_face = .min_x, .y_face = .max_y, .z_face = .max_z },
    } };

    // EAST: (MAX_X,MAX_Y,MAX_Z), (MAX_X,MIN_Y,MAX_Z), (MAX_X,MIN_Y,MIN_Z), (MAX_X,MAX_Y,MIN_Z)
    pub const EAST = FaceInfo{ .infos = .{
        .{ .x_face = .max_x, .y_face = .max_y, .z_face = .max_z },
        .{ .x_face = .max_x, .y_face = .min_y, .z_face = .max_z },
        .{ .x_face = .max_x, .y_face = .min_y, .z_face = .min_z },
        .{ .x_face = .max_x, .y_face = .max_y, .z_face = .min_z },
    } };

    pub fn fromFacing(direction: Direction) FaceInfo {
        return switch (direction) {
            .down => DOWN,
            .up => UP,
            .north => NORTH,
            .south => SOUTH,
            .west => WEST,
            .east => EAST,
        };
    }

    pub fn getVertexInfo(self: FaceInfo, index: u32) VertexInfo {
        return self.infos[index];
    }
};
