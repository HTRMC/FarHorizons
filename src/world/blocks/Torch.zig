const T = @import("../BlockTypes.zig");

fn hitbox(props: u8) ?T.AABB {
    const placement: T.Placement = @enumFromInt(@as(u3, @truncate(props)));
    return switch (placement) {
        .standing => .{ .min = .{ 6.0 / 16.0, 0.0, 6.0 / 16.0 }, .max = .{ 10.0 / 16.0, 10.0 / 16.0, 10.0 / 16.0 } },
        .wall_south => .{ .min = .{ 5.5 / 16.0, 3.0 / 16.0, 11.0 / 16.0 }, .max = .{ 10.5 / 16.0, 1.0, 1.0 } },
        .wall_north => .{ .min = .{ 5.5 / 16.0, 3.0 / 16.0, 0.0 }, .max = .{ 10.5 / 16.0, 1.0, 5.0 / 16.0 } },
        .wall_east => .{ .min = .{ 11.0 / 16.0, 3.0 / 16.0, 5.5 / 16.0 }, .max = .{ 1.0, 1.0, 10.5 / 16.0 } },
        .wall_west => .{ .min = .{ 0.0, 3.0 / 16.0, 5.5 / 16.0 }, .max = .{ 5.0 / 16.0, 1.0, 10.5 / 16.0 } },
    };
}

fn modelInfo(props: u8) ?T.ModelInfo {
    const placement: T.Placement = @enumFromInt(@as(u3, @truncate(props)));
    return switch (placement) {
        .standing => .{ .json_file = "torch_standing.json", .transform = .none },
        .wall_south => .{ .json_file = "torch_wall.json", .transform = .rotate_90 },
        .wall_north => .{ .json_file = "torch_wall.json", .transform = .rotate_270 },
        .wall_east => .{ .json_file = "torch_wall.json", .transform = .rotate_180 },
        .wall_west => .{ .json_file = "torch_wall.json", .transform = .none },
    };
}

pub const def = T.BlockDef{
    .name = "Torch",
    .state_count = 5,
    .color = .{ 0.9, 0.7, 0.2, 1.0 },
    .tex_indices = .{ .top = 28, .side = 28 },
    .render_layer = .cutout,
    .emitted_light = .{ 200, 160, 80 },
    .base_opaque = false,
    .base_solid = false,
    .base_culls_self = false,
    .base_shaped = true,
    .base_block_shape = .torch,
    .hitbox_fn = &hitbox,
    .model_info_fn = &modelInfo,
};
