const T = @import("../BlockTypes.zig");

fn hitbox(props: u8) ?T.AABB {
    const n = props & 1 != 0;
    const s = (props >> 1) & 1 != 0;
    const e = (props >> 2) & 1 != 0;
    const w = (props >> 3) & 1 != 0;
    return .{
        .min = .{
            if (w) 0.0 else 6.0 / 16.0,
            0.0,
            if (n) 0.0 else 6.0 / 16.0,
        },
        .max = .{
            if (e) 1.0 else 10.0 / 16.0,
            1.0,
            if (s) 1.0 else 10.0 / 16.0,
        },
    };
}

fn collision(props: u8) T.BlockBoxes {
    const n = props & 1 != 0;
    const s = (props >> 1) & 1 != 0;
    const e = (props >> 2) & 1 != 0;
    const w = (props >> 3) & 1 != 0;

    const min_x: f32 = if (w) 0.0 else 6.0 / 16.0;
    const max_x: f32 = if (e) 1.0 else 10.0 / 16.0;
    const min_z: f32 = if (n) 0.0 else 6.0 / 16.0;
    const max_z: f32 = if (s) 1.0 else 10.0 / 16.0;

    const n_count = @as(u8, @intFromBool(n)) + @intFromBool(s) + @intFromBool(e) + @intFromBool(w);
    if (n_count >= 2 and (n or s) and (e or w)) {
        return .{
            .boxes = .{
                .{ .min = .{ 6.0 / 16.0, 0, min_z }, .max = .{ 10.0 / 16.0, 1.5, max_z } },
                .{ .min = .{ min_x, 0, 6.0 / 16.0 }, .max = .{ max_x, 1.5, 10.0 / 16.0 } },
                undefined,
            },
            .count = 2,
        };
    }
    return T.oneBox(.{ min_x, 0, min_z }, .{ max_x, 1.5, max_z });
}

fn modelInfo(props: u8) ?T.ModelInfo {
    return .{
        .json_file = fence_model_files[props & 0xF],
        .transform = .none,
    };
}

const fence_model_files = [16][]const u8{
    "oak_fence_post.json", // 0000
    "oak_fence_n.json", // 0001
    "oak_fence_s.json", // 0010
    "oak_fence_ns.json", // 0011
    "oak_fence_e.json", // 0100
    "oak_fence_ne.json", // 0101
    "oak_fence_se.json", // 0110
    "oak_fence_nse.json", // 0111
    "oak_fence_w.json", // 1000
    "oak_fence_nw.json", // 1001
    "oak_fence_sw.json", // 1010
    "oak_fence_nsw.json", // 1011
    "oak_fence_ew.json", // 1100
    "oak_fence_new.json", // 1101
    "oak_fence_sew.json", // 1110
    "oak_fence_nsew.json", // 1111
};

pub const def = T.BlockDef{
    .name = "Oak Fence",
    .state_count = 16,
    .color = .{ 0.7, 0.55, 0.33, 1.0 },
    .tex_indices = .{ .top = 11, .side = 11 },
    .render_layer = .cutout,
    .base_opaque = false,
    .base_culls_self = false,
    .base_shaped = true,
    .base_block_shape = .fence,
    .hitbox_fn = &hitbox,
    .collision_fn = &collision,
    .model_info_fn = &modelInfo,
};
