const std = @import("std");
const zlm = @import("zlm");
const GameState = @import("GameState.zig");
const WorldState = @import("world/WorldState.zig");

const GRAVITY: f32 = 20.0;
const HALF_W: f32 = 0.4;
const HEIGHT: f32 = 1.8;
const MAX_DT: f32 = 0.05;
const WALK_SPEED: f32 = 4.3;
const FRICTION: f32 = 20.0;
const AIR_CONTROL: f32 = 0.3;

pub fn updateEntity(state: *GameState, dt: f32) void {
    if (state.mode == .flying) return;

    const clamped_dt = @min(dt, MAX_DT);

    // Walking movement from input
    const forward_input = state.input_move[0];
    const right_input = state.input_move[2];
    state.input_move = .{ 0.0, 0.0, 0.0 };

    // Project camera forward/right onto XZ plane
    const cam_forward = state.camera.getForward();
    const cam_right = state.camera.getRight();
    const fwd_xz = zlm.Vec3.init(cam_forward.x, 0.0, cam_forward.z);
    const right_xz = zlm.Vec3.init(cam_right.x, 0.0, cam_right.z);
    const fwd_norm = zlm.Vec3.normalize(fwd_xz);
    const right_norm = zlm.Vec3.normalize(right_xz);

    // Compute wish direction
    var wish = zlm.Vec3.add(
        zlm.Vec3.scale(fwd_norm, forward_input),
        zlm.Vec3.scale(right_norm, right_input),
    );
    const wish_len = zlm.Vec3.length(wish);
    if (wish_len > 1.0) {
        wish = zlm.Vec3.scale(wish, 1.0 / wish_len);
    }

    // Target velocity
    const target_vx = wish.x * WALK_SPEED;
    const target_vz = wish.z * WALK_SPEED;

    // Approach target velocity (full friction on ground, reduced in air)
    const control = if (state.entity_on_ground) FRICTION else FRICTION * AIR_CONTROL;
    const max_delta = control * clamped_dt;
    state.entity_vel[0] = approach(state.entity_vel[0], target_vx, max_delta);
    state.entity_vel[2] = approach(state.entity_vel[2], target_vz, max_delta);

    // Apply gravity
    state.entity_vel[1] -= GRAVITY * clamped_dt;

    state.entity_on_ground = false;

    // Sort axes by |velocity| descending
    const abs_vel = [3]f32{
        @abs(state.entity_vel[0]),
        @abs(state.entity_vel[1]),
        @abs(state.entity_vel[2]),
    };

    var axes = [3]usize{ 0, 1, 2 };
    // Simple sort of 3 elements
    if (abs_vel[axes[0]] < abs_vel[axes[1]]) std.mem.swap(usize, &axes[0], &axes[1]);
    if (abs_vel[axes[1]] < abs_vel[axes[2]]) std.mem.swap(usize, &axes[1], &axes[2]);
    if (abs_vel[axes[0]] < abs_vel[axes[1]]) std.mem.swap(usize, &axes[0], &axes[1]);

    // Resolve each axis sequentially
    for (axes) |axis| {
        if (state.entity_vel[axis] == 0.0) continue;

        state.entity_pos[axis] += state.entity_vel[axis] * clamped_dt;

        // Compute AABB from pos (foot position, bottom-center)
        const min_x = state.entity_pos[0] - HALF_W;
        const min_y = state.entity_pos[1];
        const min_z = state.entity_pos[2] - HALF_W;
        const max_x = state.entity_pos[0] + HALF_W;
        const max_y = state.entity_pos[1] + HEIGHT;
        const max_z = state.entity_pos[2] + HALF_W;

        // Voxel range the AABB overlaps
        const bx0 = floori(min_x);
        const by0 = floori(min_y);
        const bz0 = floori(min_z);
        const bx1 = floori(max_x);
        const by1 = floori(max_y);
        const bz1 = floori(max_z);

        var max_pen: f32 = 0.0;

        var by: i32 = by0;
        while (by <= by1) : (by += 1) {
            var bz: i32 = bz0;
            while (bz <= bz1) : (bz += 1) {
                var bx: i32 = bx0;
                while (bx <= bx1) : (bx += 1) {
                    const block = WorldState.getBlock(state.world, bx, by, bz);
                    if (!WorldState.block_properties.isSolid(block)) continue;

                    // Block occupies [bx, bx+1) x [by, by+1) x [bz, bz+1) in world space
                    const block_min = @as(f32, @floatFromInt(blockCoord(axis, bx, by, bz)));
                    const block_max = block_min + 1.0;
                    const aabb_min = aabbMin(axis, min_x, min_y, min_z);
                    const aabb_max = aabbMax(axis, max_x, max_y, max_z);

                    if (state.entity_vel[axis] > 0.0) {
                        // Moving positive: penetration = aabb_max - block_min
                        const pen = aabb_max - block_min;
                        if (pen > 0.0 and pen < 1.0) {
                            max_pen = @max(max_pen, pen);
                        }
                    } else {
                        // Moving negative: penetration = block_max - aabb_min
                        const pen = block_max - aabb_min;
                        if (pen > 0.0 and pen < 1.0) {
                            max_pen = @max(max_pen, pen);
                        }
                    }
                }
            }
        }

        if (max_pen > 0.0) {
            if (state.entity_vel[axis] > 0.0) {
                state.entity_pos[axis] -= max_pen;
            } else {
                state.entity_pos[axis] += max_pen;
            }

            // Landing detection
            if (axis == 1 and state.entity_vel[1] < 0.0) {
                state.entity_on_ground = true;
            }

            state.entity_vel[axis] = 0.0;
        }
    }
}

fn floori(v: f32) i32 {
    return @intFromFloat(@floor(v));
}

fn blockCoord(axis: usize, bx: i32, by: i32, bz: i32) i32 {
    return switch (axis) {
        0 => bx,
        1 => by,
        2 => bz,
        else => unreachable,
    };
}

fn aabbMin(axis: usize, min_x: f32, min_y: f32, min_z: f32) f32 {
    return switch (axis) {
        0 => min_x,
        1 => min_y,
        2 => min_z,
        else => unreachable,
    };
}

fn aabbMax(axis: usize, max_x: f32, max_y: f32, max_z: f32) f32 {
    return switch (axis) {
        0 => max_x,
        1 => max_y,
        2 => max_z,
        else => unreachable,
    };
}

fn approach(current: f32, target: f32, max_delta: f32) f32 {
    const diff = target - current;
    if (diff > max_delta) return current + max_delta;
    if (diff < -max_delta) return current - max_delta;
    return target;
}
