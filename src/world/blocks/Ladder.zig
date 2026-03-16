const T = @import("../BlockTypes.zig");

fn hitbox(props: u8) ?T.AABB {
    const facing: T.Facing = @enumFromInt(@as(u2, @truncate(props)));
    return switch (facing) {
        .south => .{ .min = .{ 0.0, 0.0, 0.0 }, .max = .{ 1.0, 1.0, 3.0 / 16.0 } },
        .north => .{ .min = .{ 0.0, 0.0, 13.0 / 16.0 }, .max = .{ 1.0, 1.0, 1.0 } },
        .east => .{ .min = .{ 0.0, 0.0, 0.0 }, .max = .{ 3.0 / 16.0, 1.0, 1.0 } },
        .west => .{ .min = .{ 13.0 / 16.0, 0.0, 0.0 }, .max = .{ 1.0, 1.0, 1.0 } },
    };
}

fn modelInfo(props: u8) ?T.ModelInfo {
    const facing: T.Facing = @enumFromInt(@as(u2, @truncate(props)));
    return .{ .json_file = "ladder.json", .transform = T.facingToRotation(facing) };
}

pub const def = T.BlockDef{
    .name = "Ladder",
    .state_count = 4,
    .color = .{ 0.6, 0.45, 0.25, 1.0 },
    .tex_indices = .{ .top = 29, .side = 29 },
    .render_layer = .cutout,
    .base_opaque = false,
    .base_solid = false,
    .base_culls_self = false,
    .base_shaped = true,
    .hitbox_fn = &hitbox,
    .model_info_fn = &modelInfo,
};
