const T = @import("../BlockTypes.zig");

fn collision(props: u8) T.BlockBoxes {
    const facing: T.Facing = @enumFromInt(@as(u2, @truncate(props)));
    const half: T.Half = @enumFromInt(@as(u1, @truncate(props >> 2)));
    const shape: T.StairShape = @enumFromInt(@as(u3, @truncate(props >> 3)));

    const base_box: T.BlockBox = if (half == .bottom)
        .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 0.5, 1 } }
    else
        .{ .min = .{ 0, 0.5, 0 }, .max = .{ 1, 1, 1 } };

    const sy0: f32 = if (half == .bottom) 0.5 else 0.0;
    const sy1: f32 = if (half == .bottom) 1.0 else 0.5;

    switch (shape) {
        .straight => {
            const step = T.straightStepBox(facing, sy0, sy1);
            return .{ .boxes = .{ base_box, step, undefined }, .count = 2 };
        },
        .inner_left, .inner_right => {
            const back = T.straightStepBox(facing, sy0, sy1);
            const side_facing: T.Facing = if (shape == .inner_right)
                T.rotateCW(facing)
            else
                T.rotateCCW(facing);
            const side = T.quadrantBox(T.oppositeFacing(facing), side_facing, sy0, sy1);
            return .{ .boxes = .{ base_box, back, side }, .count = 3 };
        },
        .outer_left, .outer_right => {
            const side_facing: T.Facing = if (shape == .outer_right)
                T.rotateCW(facing)
            else
                T.rotateCCW(facing);
            const corner = T.quadrantBox(facing, side_facing, sy0, sy1);
            return .{ .boxes = .{ base_box, corner, undefined }, .count = 2 };
        },
    }
}

fn modelInfo(props: u8) ?T.ModelInfo {
    const facing: T.Facing = @enumFromInt(@as(u2, @truncate(props)));
    const half: T.Half = @enumFromInt(@as(u1, @truncate(props >> 2)));
    const shape: T.StairShape = @enumFromInt(@as(u3, @truncate(props >> 3)));

    const json_file: []const u8 = switch (shape) {
        .straight => "oak_stairs.json",
        .inner_left, .inner_right => "oak_stairs_inner.json",
        .outer_left, .outer_right => "oak_stairs_outer.json",
    };

    const shape_rotation: u16 = switch (shape) {
        .straight, .inner_right, .outer_right => 0,
        .inner_left, .outer_left => 90,
    };
    const facing_rotation: u16 = switch (facing) {
        .south => 0,
        .east => 90,
        .north => 180,
        .west => 270,
    };
    const total_rotation = (facing_rotation + shape_rotation) % 360;
    const rot_transform: T.Transform = switch (total_rotation) {
        0 => .none,
        90 => .rotate_90,
        180 => .rotate_180,
        270 => .rotate_270,
        else => .none,
    };

    return .{
        .json_file = json_file,
        .transform = if (half == .bottom) rot_transform else switch (rot_transform) {
            .none => .flip_y,
            .rotate_90 => .flip_y_rotate_90,
            .rotate_180 => .flip_y_rotate_180,
            .rotate_270 => .flip_y_rotate_270,
            else => .flip_y,
        },
    };
}

fn blockShape(_: u8) T.BlockShape {
    return .stairs;
}

pub const def = T.BlockDef{
    .name = "Oak Stairs",
    .state_count = 40,
    .color = .{ 0.7, 0.55, 0.33, 1.0 },
    .tex_indices = .{ .top = 11, .side = 11 },
    .base_opaque = false,
    .base_culls_self = false,
    .base_shaped = true,
    .base_block_shape = .stairs,
    .collision_fn = &collision,
    .model_info_fn = &modelInfo,
};
