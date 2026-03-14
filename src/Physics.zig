const std = @import("std");
const GameState = @import("GameState.zig");
const WorldState = @import("world/WorldState.zig");
const ChunkMap = @import("world/ChunkMap.zig").ChunkMap;

const GRAVITY: f32 = 32.0;
const Y_DRAG: f32 = 0.9866;
pub const HALF_W: f32 = 0.4;
pub const HEIGHT: f32 = 1.8;
const WALK_SPEED: f32 = 4.3;
const FRICTION: f32 = 20.0;
const AIR_CONTROL: f32 = 0.3;
const EPSILON: f32 = 1.0e-7;

// Water physics (matched to Minecraft constants)
const WATER_GRAVITY: f32 = 2.0; // GRAVITY / 16
const WATER_SPEED: f32 = 2.0; // terminal horizontal velocity in water
const WATER_SWIM_SPEED: f32 = 3.0; // vertical swim speed
const WATER_FRICTION: f32 = 12.0; // approach rate for velocity
const WATER_XZ_DRAG: f32 = 0.86; // per-tick horizontal drag (MC 0.8 @20Hz → 0.86 @30Hz)
const WATER_Y_DRAG: f32 = 0.86; // per-tick vertical drag

// Ladder physics (matched to Minecraft)
pub const LADDER_CLIMB_SPEED: f32 = 3.0; // climb speed when holding jump
const LADDER_MAX_FALL: f32 = -2.4; // max fall speed on ladder (MC: -0.15/tick @20Hz)

pub fn updateEntity(state: *GameState, dt: f32) void {
    if (state.mode == .flying) return;

    const forward_input = state.input_move[0];
    const right_input = state.input_move[2];

    const sin_yaw = @sin(state.camera.yaw);
    const cos_yaw = @cos(state.camera.yaw);

    var wish_x = -forward_input * sin_yaw + right_input * cos_yaw;
    var wish_z = -forward_input * cos_yaw - right_input * sin_yaw;
    const wish_len_sq = wish_x * wish_x + wish_z * wish_z;
    if (wish_len_sq > 1.0) {
        const inv_len = 1.0 / @sqrt(wish_len_sq);
        wish_x *= inv_len;
        wish_z *= inv_len;
    }

    if (state.entity_in_water) {
        // Water horizontal movement
        const target_vx = wish_x * WATER_SPEED;
        const target_vz = wish_z * WATER_SPEED;
        const water_control = WATER_FRICTION * dt;
        state.entity_vel[0] = approach(state.entity_vel[0], target_vx, water_control);
        state.entity_vel[2] = approach(state.entity_vel[2], target_vz, water_control);

        // Vertical swimming (input_move[1]: +1 jump, -1 sneak)
        // Only apply when input is active — otherwise let gravity/drag handle sinking
        const up_input = state.input_move[1];
        if (up_input != 0.0) {
            const target_vy = up_input * WATER_SWIM_SPEED;
            state.entity_vel[1] = approach(state.entity_vel[1], target_vy, water_control);
        }
    } else {
        // Land horizontal movement
        const target_vx = wish_x * WALK_SPEED;
        const target_vz = wish_z * WALK_SPEED;
        const control = if (state.entity_on_ground) FRICTION else FRICTION * AIR_CONTROL;
        const max_delta = control * dt;
        state.entity_vel[0] = approach(state.entity_vel[0], target_vx, max_delta);
        state.entity_vel[2] = approach(state.entity_vel[2], target_vz, max_delta);
    }

    state.entity_on_ground = false;

    const movement = [3]f32{
        state.entity_vel[0] * dt,
        state.entity_vel[1] * dt,
        state.entity_vel[2] * dt,
    };

    const abs_mov = [3]f32{
        @abs(movement[0]),
        @abs(movement[1]),
        @abs(movement[2]),
    };

    var axes = [3]usize{ 0, 1, 2 };
    if (abs_mov[axes[0]] < abs_mov[axes[1]]) std.mem.swap(usize, &axes[0], &axes[1]);
    if (abs_mov[axes[1]] < abs_mov[axes[2]]) std.mem.swap(usize, &axes[1], &axes[2]);
    if (abs_mov[axes[0]] < abs_mov[axes[1]]) std.mem.swap(usize, &axes[0], &axes[1]);

    for (axes) |axis| {
        const desired = movement[axis];
        if (desired == 0.0) continue;

        const result = collideAxis(&state.chunk_map, state.entity_pos, desired, axis);
        state.entity_pos[axis] += result.distance;

        if (result.hit) {
            if (axis == 1 and state.entity_vel[1] < 0.0) {
                state.entity_on_ground = true;
            }
            state.entity_vel[axis] = 0.0;
        }
    }

    if (state.entity_in_water) {
        state.entity_vel[1] -= WATER_GRAVITY * dt;
        state.entity_vel[0] *= WATER_XZ_DRAG;
        state.entity_vel[1] *= WATER_Y_DRAG;
        state.entity_vel[2] *= WATER_XZ_DRAG;
    } else if (state.entity_on_ladder) {
        state.entity_vel[1] -= GRAVITY * dt;
        state.entity_vel[1] *= Y_DRAG;
        // Cap fall speed on ladder
        if (state.entity_vel[1] < LADDER_MAX_FALL) {
            state.entity_vel[1] = LADDER_MAX_FALL;
        }
        // Sneak to hold position on ladder
        if (state.input_move[1] < 0.0 and state.entity_vel[1] < 0.0) {
            state.entity_vel[1] = 0.0;
        }
    } else {
        state.entity_vel[1] -= GRAVITY * dt;
        state.entity_vel[1] *= Y_DRAG;
    }
}

fn collideAxis(chunk_map: *const ChunkMap, pos: [3]f32, movement: f32, axis: usize) struct { distance: f32, hit: bool } {
    const aabb_min = [3]f32{ pos[0] - HALF_W, pos[1], pos[2] - HALF_W };
    const aabb_max = [3]f32{ pos[0] + HALF_W, pos[1] + HEIGHT, pos[2] + HALF_W };

    var scan_min = aabb_min;
    var scan_max = aabb_max;
    if (movement > 0) {
        scan_max[axis] += movement;
    } else {
        scan_min[axis] += movement;
    }

    const bx0 = floori(scan_min[0]);
    const by0 = floori(scan_min[1]);
    const bz0 = floori(scan_min[2]);
    const bx1 = floori(scan_max[0]);
    const by1 = floori(scan_max[1]);
    const bz1 = floori(scan_max[2]);

    var safe_dist = movement;
    var hit = false;

    var by: i32 = by0;
    while (by <= by1) : (by += 1) {
        var bz: i32 = bz0;
        while (bz <= bz1) : (bz += 1) {
            var bx: i32 = bx0;
            while (bx <= bx1) : (bx += 1) {
                const block = chunk_map.getBlock(bx, by, bz);
                if (!WorldState.block_properties.isSolid(block)) continue;

                const coords = [3]i32{ bx, by, bz };
                const block_boxes = getBlockBoxes(block);
                for (block_boxes.boxes[0..block_boxes.count]) |box| {
                    const box_min = [3]f32{
                        @as(f32, @floatFromInt(coords[0])) + box.min[0],
                        @as(f32, @floatFromInt(coords[1])) + box.min[1],
                        @as(f32, @floatFromInt(coords[2])) + box.min[2],
                    };
                    const box_max = [3]f32{
                        @as(f32, @floatFromInt(coords[0])) + box.max[0],
                        @as(f32, @floatFromInt(coords[1])) + box.max[1],
                        @as(f32, @floatFromInt(coords[2])) + box.max[2],
                    };

                    if (!overlapsOtherAxesBox(aabb_min, aabb_max, box_min, box_max, axis)) continue;

                    if (movement > 0) {
                        const gap = box_min[axis] - aabb_max[axis];
                        if (gap >= -EPSILON and gap < safe_dist) {
                            safe_dist = @max(gap, 0.0);
                            hit = true;
                        }
                    } else {
                        const gap = box_max[axis] - aabb_min[axis];
                        if (gap <= EPSILON and gap > safe_dist) {
                            safe_dist = @min(gap, 0.0);
                            hit = true;
                        }
                    }
                }
            }
        }
    }

    return .{ .distance = safe_dist, .hit = hit };
}

pub const BlockBox = struct { min: [3]f32, max: [3]f32 };
pub const BlockBoxes = struct { boxes: [2]BlockBox, count: u8 };

pub fn getBlockBoxes(block: WorldState.BlockType) BlockBoxes {
    return switch (block) {
        .oak_slab_bottom => .{
            .boxes = .{
                .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 0.5, 1 } },
                undefined,
            },
            .count = 1,
        },
        .oak_slab_top => .{
            .boxes = .{
                .{ .min = .{ 0, 0.5, 0 }, .max = .{ 1, 1, 1 } },
                undefined,
            },
            .count = 1,
        },
        .oak_stairs_south => .{ // back at -Z, step at +Z
            .boxes = .{
                .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 0.5, 1 } }, // bottom slab
                .{ .min = .{ 0, 0.5, 0 }, .max = .{ 1, 1, 0.5 } }, // upper back
            },
            .count = 2,
        },
        .oak_stairs_north => .{ // back at +Z, step at -Z
            .boxes = .{
                .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 0.5, 1 } },
                .{ .min = .{ 0, 0.5, 0.5 }, .max = .{ 1, 1, 1 } },
            },
            .count = 2,
        },
        .oak_stairs_east => .{ // back at -X, step at +X
            .boxes = .{
                .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 0.5, 1 } },
                .{ .min = .{ 0, 0.5, 0 }, .max = .{ 0.5, 1, 1 } },
            },
            .count = 2,
        },
        .oak_stairs_west => .{ // back at +X, step at -X
            .boxes = .{
                .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 0.5, 1 } },
                .{ .min = .{ 0.5, 0.5, 0 }, .max = .{ 1, 1, 1 } },
            },
            .count = 2,
        },
        .torch => .{
            .boxes = .{
                .{ .min = .{ 6.0 / 16.0, 0.0, 6.0 / 16.0 }, .max = .{ 10.0 / 16.0, 10.0 / 16.0, 10.0 / 16.0 } },
                undefined,
            },
            .count = 1,
        },
        .torch_wall_south => .{
            .boxes = .{
                .{ .min = .{ 5.5 / 16.0, 3.0 / 16.0, 11.0 / 16.0 }, .max = .{ 10.5 / 16.0, 1.0, 1.0 } },
                undefined,
            },
            .count = 1,
        },
        .torch_wall_north => .{
            .boxes = .{
                .{ .min = .{ 5.5 / 16.0, 3.0 / 16.0, 0.0 }, .max = .{ 10.5 / 16.0, 1.0, 5.0 / 16.0 } },
                undefined,
            },
            .count = 1,
        },
        .torch_wall_east => .{
            .boxes = .{
                .{ .min = .{ 11.0 / 16.0, 3.0 / 16.0, 5.5 / 16.0 }, .max = .{ 1.0, 1.0, 10.5 / 16.0 } },
                undefined,
            },
            .count = 1,
        },
        .torch_wall_west => .{
            .boxes = .{
                .{ .min = .{ 0.0, 3.0 / 16.0, 5.5 / 16.0 }, .max = .{ 5.0 / 16.0, 1.0, 10.5 / 16.0 } },
                undefined,
            },
            .count = 1,
        },
        .ladder_south => .{
            .boxes = .{
                .{ .min = .{ 0.0, 0.0, 0.0 }, .max = .{ 1.0, 1.0, 3.0 / 16.0 } },
                undefined,
            },
            .count = 1,
        },
        .ladder_north => .{
            .boxes = .{
                .{ .min = .{ 0.0, 0.0, 13.0 / 16.0 }, .max = .{ 1.0, 1.0, 1.0 } },
                undefined,
            },
            .count = 1,
        },
        .ladder_east => .{
            .boxes = .{
                .{ .min = .{ 0.0, 0.0, 0.0 }, .max = .{ 3.0 / 16.0, 1.0, 1.0 } },
                undefined,
            },
            .count = 1,
        },
        .ladder_west => .{
            .boxes = .{
                .{ .min = .{ 13.0 / 16.0, 0.0, 0.0 }, .max = .{ 1.0, 1.0, 1.0 } },
                undefined,
            },
            .count = 1,
        },
        // Closed doors: 3px slab collision box (same positions as hitboxes)
        .oak_door_bottom_east, .oak_door_top_east => .{
            .boxes = .{ .{ .min = .{ 0, 0, 0 }, .max = .{ 3.0 / 16.0, 1, 1 } }, undefined },
            .count = 1,
        },
        .oak_door_bottom_south, .oak_door_top_south => .{
            .boxes = .{ .{ .min = .{ 0, 0, 13.0 / 16.0 }, .max = .{ 1, 1, 1 } }, undefined },
            .count = 1,
        },
        .oak_door_bottom_west, .oak_door_top_west => .{
            .boxes = .{ .{ .min = .{ 13.0 / 16.0, 0, 0 }, .max = .{ 1, 1, 1 } }, undefined },
            .count = 1,
        },
        .oak_door_bottom_north, .oak_door_top_north => .{
            .boxes = .{ .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 3.0 / 16.0 } }, undefined },
            .count = 1,
        },
        // Fence collision: post (6-10 x/z) + connection bars, 1.5 blocks tall
        .oak_fence_post => .{
            .boxes = .{ .{ .min = .{ 6.0 / 16.0, 0, 6.0 / 16.0 }, .max = .{ 10.0 / 16.0, 1.5, 10.0 / 16.0 } }, undefined },
            .count = 1,
        },
        .oak_fence_n => .{
            .boxes = .{ .{ .min = .{ 6.0 / 16.0, 0, 0 }, .max = .{ 10.0 / 16.0, 1.5, 10.0 / 16.0 } }, undefined },
            .count = 1,
        },
        .oak_fence_s => .{
            .boxes = .{ .{ .min = .{ 6.0 / 16.0, 0, 6.0 / 16.0 }, .max = .{ 10.0 / 16.0, 1.5, 1 } }, undefined },
            .count = 1,
        },
        .oak_fence_e => .{
            .boxes = .{ .{ .min = .{ 6.0 / 16.0, 0, 6.0 / 16.0 }, .max = .{ 1, 1.5, 10.0 / 16.0 } }, undefined },
            .count = 1,
        },
        .oak_fence_w => .{
            .boxes = .{ .{ .min = .{ 0, 0, 6.0 / 16.0 }, .max = .{ 10.0 / 16.0, 1.5, 10.0 / 16.0 } }, undefined },
            .count = 1,
        },
        .oak_fence_ns => .{
            .boxes = .{ .{ .min = .{ 6.0 / 16.0, 0, 0 }, .max = .{ 10.0 / 16.0, 1.5, 1 } }, undefined },
            .count = 1,
        },
        .oak_fence_ew => .{
            .boxes = .{ .{ .min = .{ 0, 0, 6.0 / 16.0 }, .max = .{ 1, 1.5, 10.0 / 16.0 } }, undefined },
            .count = 1,
        },
        .oak_fence_ne => .{
            .boxes = .{
                .{ .min = .{ 6.0 / 16.0, 0, 0 }, .max = .{ 10.0 / 16.0, 1.5, 10.0 / 16.0 } },
                .{ .min = .{ 6.0 / 16.0, 0, 6.0 / 16.0 }, .max = .{ 1, 1.5, 10.0 / 16.0 } },
            },
            .count = 2,
        },
        .oak_fence_nw => .{
            .boxes = .{
                .{ .min = .{ 6.0 / 16.0, 0, 0 }, .max = .{ 10.0 / 16.0, 1.5, 10.0 / 16.0 } },
                .{ .min = .{ 0, 0, 6.0 / 16.0 }, .max = .{ 10.0 / 16.0, 1.5, 10.0 / 16.0 } },
            },
            .count = 2,
        },
        .oak_fence_se => .{
            .boxes = .{
                .{ .min = .{ 6.0 / 16.0, 0, 6.0 / 16.0 }, .max = .{ 10.0 / 16.0, 1.5, 1 } },
                .{ .min = .{ 6.0 / 16.0, 0, 6.0 / 16.0 }, .max = .{ 1, 1.5, 10.0 / 16.0 } },
            },
            .count = 2,
        },
        .oak_fence_sw => .{
            .boxes = .{
                .{ .min = .{ 6.0 / 16.0, 0, 6.0 / 16.0 }, .max = .{ 10.0 / 16.0, 1.5, 1 } },
                .{ .min = .{ 0, 0, 6.0 / 16.0 }, .max = .{ 10.0 / 16.0, 1.5, 10.0 / 16.0 } },
            },
            .count = 2,
        },
        .oak_fence_nse, .oak_fence_nsw, .oak_fence_new, .oak_fence_sew, .oak_fence_nsew => .{
            // For 3+ connections: use N-S bar + E-W bar (covers all cases)
            .boxes = .{
                .{ .min = .{ 6.0 / 16.0, 0, 0 }, .max = .{ 10.0 / 16.0, 1.5, 1 } },
                .{ .min = .{ 0, 0, 6.0 / 16.0 }, .max = .{ 1, 1.5, 10.0 / 16.0 } },
            },
            .count = 2,
        },
        else => .{
            .boxes = .{
                .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } },
                undefined,
            },
            .count = 1,
        },
    };
}

fn overlapsOtherAxesBox(aabb_min: [3]f32, aabb_max: [3]f32, box_min: [3]f32, box_max: [3]f32, skip_axis: usize) bool {
    const axes_to_check: [2]usize = switch (skip_axis) {
        0 => .{ 1, 2 },
        1 => .{ 0, 2 },
        2 => .{ 0, 1 },
        else => unreachable,
    };

    for (axes_to_check) |a| {
        if (aabb_max[a] <= box_min[a] + EPSILON or aabb_min[a] >= box_max[a] - EPSILON) {
            return false;
        }
    }
    return true;
}

fn overlapsOtherAxes(aabb_min: [3]f32, aabb_max: [3]f32, block: [3]i32, skip_axis: usize) bool {
    const axes_to_check: [2]usize = switch (skip_axis) {
        0 => .{ 1, 2 },
        1 => .{ 0, 2 },
        2 => .{ 0, 1 },
        else => unreachable,
    };

    for (axes_to_check) |a| {
        const block_min = @as(f32, @floatFromInt(block[a]));
        const block_max = block_min + 1.0;
        if (aabb_max[a] <= block_min + EPSILON or aabb_min[a] >= block_max - EPSILON) {
            return false;
        }
    }
    return true;
}

pub fn floori(v: f32) i32 {
    return @intFromFloat(@floor(v));
}

fn approach(current: f32, target: f32, max_delta: f32) f32 {
    const diff = target - current;
    if (diff > max_delta) return current + max_delta;
    if (diff < -max_delta) return current - max_delta;
    return target;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "approach: moves toward target within delta" {
    try testing.expectEqual(@as(f32, 5.0), approach(0.0, 10.0, 5.0));
    try testing.expectEqual(@as(f32, -5.0), approach(0.0, -10.0, 5.0));
}

test "approach: snaps to target when within delta" {
    try testing.expectEqual(@as(f32, 3.0), approach(2.0, 3.0, 5.0));
    try testing.expectEqual(@as(f32, -1.0), approach(0.0, -1.0, 5.0));
}

test "approach: zero delta means no movement" {
    try testing.expectEqual(@as(f32, 5.0), approach(5.0, 10.0, 0.0));
}

test "approach: already at target" {
    try testing.expectEqual(@as(f32, 7.0), approach(7.0, 7.0, 1.0));
}

test "floori: positive values" {
    try testing.expectEqual(@as(i32, 0), floori(0.0));
    try testing.expectEqual(@as(i32, 0), floori(0.5));
    try testing.expectEqual(@as(i32, 0), floori(0.999));
    try testing.expectEqual(@as(i32, 1), floori(1.0));
}

test "floori: negative values" {
    try testing.expectEqual(@as(i32, -1), floori(-0.001));
    try testing.expectEqual(@as(i32, -1), floori(-0.5));
    try testing.expectEqual(@as(i32, -1), floori(-1.0));
    try testing.expectEqual(@as(i32, -2), floori(-1.001));
}

test "overlapsOtherAxes: overlapping block" {
    const aabb_min = [3]f32{ 0.0, 0.0, 0.0 };
    const aabb_max = [3]f32{ 1.0, 2.0, 1.0 };
    const block = [3]i32{ 0, 0, 0 };

    // Skip axis 0 (x), check y and z — block [0,0,0] spans [0,1) in each dim
    // aabb y=[0,2), block y=[0,1) — overlap in y
    // aabb z=[0,1), block z=[0,1) — tricky: aabb_max[z]=1.0, block_min+eps ~ block at z=0
    // overlapsOtherAxes uses EPSILON tolerance
    try testing.expect(overlapsOtherAxes(aabb_min, aabb_max, block, 0));
}

test "overlapsOtherAxes: non-overlapping block" {
    const aabb_min = [3]f32{ 0.0, 0.0, 0.0 };
    const aabb_max = [3]f32{ 1.0, 2.0, 1.0 };
    const block = [3]i32{ 0, 5, 0 }; // block at y=5, aabb goes to y=2

    try testing.expect(!overlapsOtherAxes(aabb_min, aabb_max, block, 0));
}

test "overlapsOtherAxes: flush edge is not overlap" {
    // AABB exactly touching block edge — should NOT overlap (uses EPSILON tolerance)
    const aabb_min = [3]f32{ 0.0, 0.0, 0.0 };
    const aabb_max = [3]f32{ 1.0, 1.0, 1.0 };
    const block = [3]i32{ 0, 1, 0 }; // block starts at y=1, aabb ends at y=1

    // Checking skip_axis=0: check y and z
    // y: aabb_max[1]=1.0, block_min=1, so aabb_max <= block_min + EPSILON → no overlap
    try testing.expect(!overlapsOtherAxes(aabb_min, aabb_max, block, 0));
}

test "collideAxis: no collision in empty chunk" {
    var map = ChunkMap.init(testing.allocator);
    defer map.deinit();

    const chunk = try testing.allocator.create(WorldState.Chunk);
    defer testing.allocator.destroy(chunk);
    chunk.blocks = .{.air} ** WorldState.BLOCKS_PER_CHUNK;
    map.put(WorldState.ChunkKey{ .cx = 0, .cy = 0, .cz = 0 }, chunk);

    const pos = [3]f32{ 5.0, 5.0, 5.0 };
    const result = collideAxis(&map, pos, 1.0, 0);
    try testing.expectEqual(@as(f32, 1.0), result.distance);
    try testing.expect(!result.hit);
}

test "collideAxis: collision with solid block" {
    var map = ChunkMap.init(testing.allocator);
    defer map.deinit();

    const chunk = try testing.allocator.create(WorldState.Chunk);
    defer testing.allocator.destroy(chunk);
    chunk.blocks = .{.air} ** WorldState.BLOCKS_PER_CHUNK;

    // Place stone at (10, 5, 5)
    chunk.blocks[WorldState.chunkIndex(10, 5, 5)] = .stone;
    map.put(WorldState.ChunkKey{ .cx = 0, .cy = 0, .cz = 0 }, chunk);

    // Entity at x=8.0 (HALF_W=0.4, so right edge at 8.4), moving +x toward block at x=10
    // Block face at x=10, entity AABB max x = 8.4 + movement
    const pos = [3]f32{ 8.0, 5.0, 5.5 };
    const result = collideAxis(&map, pos, 5.0, 0);

    // Should hit: gap = 10.0 - 8.4 = 1.6, so distance should be 1.6
    try testing.expect(result.hit);
    try testing.expectApproxEqAbs(@as(f32, 1.6), result.distance, 1e-5);
}

test "collideAxis: negative movement collision" {
    var map = ChunkMap.init(testing.allocator);
    defer map.deinit();

    const chunk = try testing.allocator.create(WorldState.Chunk);
    defer testing.allocator.destroy(chunk);
    chunk.blocks = .{.air} ** WorldState.BLOCKS_PER_CHUNK;

    // Place stone at (3, 5, 5) — block spans x=[3,4)
    chunk.blocks[WorldState.chunkIndex(3, 5, 5)] = .stone;
    map.put(WorldState.ChunkKey{ .cx = 0, .cy = 0, .cz = 0 }, chunk);

    // Entity at x=5.0 (left edge at 4.6), moving -x toward block ending at x=4
    const pos = [3]f32{ 5.0, 5.0, 5.5 };
    const result = collideAxis(&map, pos, -5.0, 0);

    // Should hit: block top at x=4, entity min at 4.6, gap = 4.0 - 4.6 = -0.6
    try testing.expect(result.hit);
    try testing.expectApproxEqAbs(@as(f32, -0.6), result.distance, 1e-5);
}

test "collideAxis: water is not solid" {
    var map = ChunkMap.init(testing.allocator);
    defer map.deinit();

    const chunk = try testing.allocator.create(WorldState.Chunk);
    defer testing.allocator.destroy(chunk);
    chunk.blocks = .{.air} ** WorldState.BLOCKS_PER_CHUNK;

    // Place water at (10, 5, 5)
    chunk.blocks[WorldState.chunkIndex(10, 5, 5)] = .water;
    map.put(WorldState.ChunkKey{ .cx = 0, .cy = 0, .cz = 0 }, chunk);

    const pos = [3]f32{ 8.0, 5.0, 5.5 };
    const result = collideAxis(&map, pos, 5.0, 0);

    // Water is not solid, so no collision
    try testing.expect(!result.hit);
    try testing.expectEqual(@as(f32, 5.0), result.distance);
}
