const T = @import("../BlockTypes.zig");

fn isDoubleSlab(props: u8) bool {
    return @as(T.SlabType, @enumFromInt(@as(u2, @truncate(props)))) == .double;
}

fn isOpaque(props: u8) bool {
    return isDoubleSlab(props);
}

fn cullsSelf(props: u8) bool {
    return isDoubleSlab(props);
}

fn isShaped(props: u8) bool {
    return !isDoubleSlab(props);
}

fn isSolidShaped(props: u8) bool {
    return !isDoubleSlab(props);
}

fn hitbox(props: u8) ?T.AABB {
    const slab_type: T.SlabType = @enumFromInt(@as(u2, @truncate(props)));
    return switch (slab_type) {
        .bottom => .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 0.5, 1 } },
        .top => .{ .min = .{ 0, 0.5, 0 }, .max = .{ 1, 1, 1 } },
        .double => null,
    };
}

fn collision(props: u8) T.BlockBoxes {
    const slab_type: T.SlabType = @enumFromInt(@as(u2, @truncate(props)));
    return switch (slab_type) {
        .bottom => T.oneBox(.{ 0, 0, 0 }, .{ 1, 0.5, 1 }),
        .top => T.oneBox(.{ 0, 0.5, 0 }, .{ 1, 1, 1 }),
        .double => T.fullCubeBox(),
    };
}

fn modelInfo(props: u8) ?T.ModelInfo {
    const slab_type: T.SlabType = @enumFromInt(@as(u2, @truncate(props)));
    return switch (slab_type) {
        .bottom => .{ .json_file = "oak_slab.json", .transform = .none },
        .top => .{ .json_file = "oak_slab.json", .transform = .flip_y },
        .double => null,
    };
}

fn blockShape(props: u8) T.BlockShape {
    const slab_type: T.SlabType = @enumFromInt(@as(u2, @truncate(props)));
    return switch (slab_type) {
        .bottom => .slab_bottom,
        .top => .slab_top,
        .double => .full,
    };
}

pub const def = T.BlockDef{
    .name = "Oak Slab",
    .state_count = 3,
    .color = .{ 0.7, 0.55, 0.33, 1.0 },
    .tex_indices = .{ .top = 11, .side = 11 },
    .base_opaque = false,
    .base_culls_self = false,
    .is_opaque_fn = &isOpaque,
    .culls_self_fn = &cullsSelf,
    .is_shaped_fn = &isShaped,
    .is_solid_shaped_fn = &isSolidShaped,
    .hitbox_fn = &hitbox,
    .collision_fn = &collision,
    .model_info_fn = &modelInfo,
    .block_shape_fn = &blockShape,
};
