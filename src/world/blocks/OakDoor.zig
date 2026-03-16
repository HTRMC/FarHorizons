const T = @import("../BlockTypes.zig");

fn isSolid(props: u8) bool {
    return (props >> 3) & 1 == 0;
}

fn hitbox(props: u8) ?T.AABB {
    const facing: T.Facing = @enumFromInt(@as(u2, @truncate(props)));
    const open_bit = (props >> 3) & 1 != 0;
    const edge = computeDoorEdge(facing, open_bit);
    return door_edge_hitboxes[edge];
}

fn computeDoorEdge(facing: T.Facing, open_bit: bool) u2 {
    const base: u2 = switch (facing) {
        .south => 1,
        .north => 3,
        .east => 0,
        .west => 2,
    };
    return if (open_bit) base +% 1 else base;
}

const door_edge_hitboxes = [4]T.AABB{
    // 0: west edge (x=0..3/16)
    .{ .min = .{ 0.0, 0.0, 0.0 }, .max = .{ 3.0 / 16.0, 1.0, 1.0 } },
    // 1: south edge (z=13/16..1)
    .{ .min = .{ 0.0, 0.0, 13.0 / 16.0 }, .max = .{ 1.0, 1.0, 1.0 } },
    // 2: east edge (x=13/16..1)
    .{ .min = .{ 13.0 / 16.0, 0.0, 0.0 }, .max = .{ 1.0, 1.0, 1.0 } },
    // 3: north edge (z=0..3/16)
    .{ .min = .{ 0.0, 0.0, 0.0 }, .max = .{ 1.0, 1.0, 3.0 / 16.0 } },
};

fn collision(props: u8) T.BlockBoxes {
    const hb = hitbox(props).?;
    return T.oneBox(hb.min, hb.max);
}

fn modelInfo(props: u8) ?T.ModelInfo {
    const facing: T.Facing = @enumFromInt(@as(u2, @truncate(props)));
    const half: T.Half = @enumFromInt(@as(u1, @truncate(props >> 2)));
    const open_flag = (props >> 3) & 1 != 0;
    return .{
        .json_file = if (half == .bottom) "oak_door_bottom.json" else "oak_door_top.json",
        .transform = doorTransform(facing, open_flag),
    };
}

fn doorTransform(facing: T.Facing, open_flag: bool) T.Transform {
    const base: u16 = switch (facing) {
        .east => 0,
        .south => 90,
        .west => 180,
        .north => 270,
    };
    const angle = (base + if (open_flag) @as(u16, 90) else 0) % 360;
    return switch (angle) {
        0 => .none,
        90 => .rotate_90,
        180 => .rotate_180,
        270 => .rotate_270,
        else => .none,
    };
}

fn texIndices(props: u8) T.TexIndices {
    const half: T.Half = @enumFromInt(@as(u1, @truncate(props >> 2)));
    return switch (half) {
        .bottom => .{ .top = 32, .side = 32 },
        .top => .{ .top = 33, .side = 33 },
    };
}

pub const def = T.BlockDef{
    .name = "Oak Door",
    .state_count = 16,
    .color = .{ 0.7, 0.55, 0.33, 1.0 },
    .render_layer = .cutout,
    .base_opaque = false,
    .base_culls_self = false,
    .base_shaped = true,
    .is_solid_fn = &isSolid,
    .hitbox_fn = &hitbox,
    .collision_fn = &collision,
    .model_info_fn = &modelInfo,
    .tex_indices_fn = &texIndices,
};
