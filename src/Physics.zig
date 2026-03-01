const std = @import("std");
const GameState = @import("GameState.zig");
const WorldState = @import("world/WorldState.zig");

const GRAVITY: f32 = 32.0;
const Y_DRAG: f32 = 0.9866;
const HALF_W: f32 = 0.4;
const HEIGHT: f32 = 1.8;
const WALK_SPEED: f32 = 4.3;
const FRICTION: f32 = 20.0;
const AIR_CONTROL: f32 = 0.3;
const EPSILON: f32 = 1.0e-7;

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

    const target_vx = wish_x * WALK_SPEED;
    const target_vz = wish_z * WALK_SPEED;

    const control = if (state.entity_on_ground) FRICTION else FRICTION * AIR_CONTROL;
    const max_delta = control * dt;
    state.entity_vel[0] = approach(state.entity_vel[0], target_vx, max_delta);
    state.entity_vel[2] = approach(state.entity_vel[2], target_vz, max_delta);

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

        const result = collideAxis(state.world, state.entity_pos, desired, axis);
        state.entity_pos[axis] += result.distance;

        if (result.hit) {
            if (axis == 1 and state.entity_vel[1] < 0.0) {
                state.entity_on_ground = true;
            }
            state.entity_vel[axis] = 0.0;
        }
    }

    state.entity_vel[1] -= GRAVITY * dt;
    state.entity_vel[1] *= Y_DRAG;
}

fn collideAxis(world: *WorldState.World, pos: [3]f32, movement: f32, axis: usize) struct { distance: f32, hit: bool } {
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
                const block = WorldState.getBlock(world, bx, by, bz);
                if (!WorldState.block_properties.isSolid(block)) continue;

                const coords = [3]i32{ bx, by, bz };
                if (!overlapsOtherAxes(aabb_min, aabb_max, coords, axis)) continue;

                const block_coord = @as(f32, @floatFromInt(coords[axis]));

                if (movement > 0) {
                    const gap = block_coord - aabb_max[axis];
                    if (gap >= -EPSILON and gap < safe_dist) {
                        safe_dist = @max(gap, 0.0);
                        hit = true;
                    }
                } else {
                    const gap = (block_coord + 1.0) - aabb_min[axis];
                    if (gap <= EPSILON and gap > safe_dist) {
                        safe_dist = @min(gap, 0.0);
                        hit = true;
                    }
                }
            }
        }
    }

    return .{ .distance = safe_dist, .hit = hit };
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

fn floori(v: f32) i32 {
    return @intFromFloat(@floor(v));
}

fn approach(current: f32, target: f32, max_delta: f32) f32 {
    const diff = target - current;
    if (diff > max_delta) return current + max_delta;
    if (diff < -max_delta) return current - max_delta;
    return target;
}
