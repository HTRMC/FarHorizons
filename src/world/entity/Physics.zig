const std = @import("std");
const GameState = @import("../GameState.zig");
const Entity = GameState.Entity;
const WorldState = @import("../WorldState.zig");
const BlockState = WorldState.BlockState;
const ChunkMap = @import("../ChunkMap.zig").ChunkMap;
const tracy = @import("../../platform/tracy.zig");
const Radians = @import("../../math/Angle.zig").Radians;

const GRAVITY: f32 = 32.0;
const Y_DRAG: f32 = 0.9866;
const AIR_CONTROL: f32 = 0.3;
const EPSILON: f32 = 1.0e-7;

// Default player dimensions (used by blockOverlapsPlayer and debug hitbox)
pub const PLAYER_HALF_W: f32 = 0.4;
pub const PLAYER_HEIGHT: f32 = 1.8;

// Water physics
const WATER_SPEED: f32 = 2.0; // terminal horizontal velocity in water
const WATER_SWIM_SPEED: f32 = 3.0; // vertical swim speed
const WATER_FRICTION: f32 = 12.0; // approach rate for velocity
const WATER_XZ_DRAG: f32 = 0.86; // per-tick horizontal drag (MC 0.8 @20Hz → 0.86 @30Hz)
const WATER_Y_DRAG: f32 = 0.86; // per-tick vertical drag

// Ladder physics
pub const LADDER_CLIMB_SPEED: f32 = 3.0; // climb speed when holding jump
const LADDER_MAX_FALL: f32 = -2.4; // max fall speed on ladder (MC: -0.15/tick @20Hz)

const DeltaSeconds = GameState.DeltaSeconds;

pub fn updateEntity(
    entities: *Entity.EntityStore,
    id: Entity.EntityId,
    chunk_map: *const ChunkMap,
    input_move: [3]f32,
    camera_yaw: Radians,
    dt: DeltaSeconds,
) void {
    const tz = tracy.zone(@src(), "updateEntity");
    defer tz.end();
    const params = entities.physics[id];
    const forward_input = input_move[0];
    const right_input = input_move[2];

    const sin_yaw = camera_yaw.sin();
    const cos_yaw = camera_yaw.cos();

    var wish_x = -forward_input * sin_yaw + right_input * cos_yaw;
    var wish_z = -forward_input * cos_yaw - right_input * sin_yaw;
    const wish_len_sq = wish_x * wish_x + wish_z * wish_z;
    if (wish_len_sq > 1.0) {
        const inv_len = 1.0 / @sqrt(wish_len_sq);
        wish_x *= inv_len;
        wish_z *= inv_len;
    }

    const flags = entities.flags[id];

    if (flags.in_water) {
        // Water horizontal movement
        const target_vx = wish_x * WATER_SPEED;
        const target_vz = wish_z * WATER_SPEED;
        const water_control = dt.scale(WATER_FRICTION);
        entities.vel[id][0] = approach(entities.vel[id][0], target_vx, water_control);
        entities.vel[id][2] = approach(entities.vel[id][2], target_vz, water_control);

        // Vertical swimming (input_move[1]: +1 jump, -1 sneak)
        // Only apply when input is active — otherwise let gravity/drag handle sinking
        const up_input = input_move[1];
        if (up_input != 0.0) {
            const target_vy = up_input * WATER_SWIM_SPEED;
            entities.vel[id][1] = approach(entities.vel[id][1], target_vy, water_control);
        }
    } else {
        // Land horizontal movement
        const target_vx = wish_x * params.walk_speed;
        const target_vz = wish_z * params.walk_speed;
        const control = if (flags.on_ground) params.friction else params.friction * AIR_CONTROL;
        const max_delta = dt.scale(control);
        entities.vel[id][0] = approach(entities.vel[id][0], target_vx, max_delta);
        entities.vel[id][2] = approach(entities.vel[id][2], target_vz, max_delta);
    }

    entities.flags[id].on_ground = false;

    const movement = [3]f32{
        dt.scale(entities.vel[id][0]),
        dt.scale(entities.vel[id][1]),
        dt.scale(entities.vel[id][2]),
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

        const result = collideAxis(chunk_map, entities.pos[id], desired, axis, params.half_width, params.height);
        entities.pos[id][axis] += result.distance;

        if (result.hit) {
            if (axis == 1 and entities.vel[id][1] < 0.0) {
                entities.flags[id].on_ground = true;
            }
            entities.vel[id][axis] = 0.0;
        }
    }

    const gravity = GRAVITY * params.gravity_scale;

    if (flags.in_water) {
        entities.vel[id][1] -= dt.scale(gravity / 16.0);
        entities.vel[id][0] *= WATER_XZ_DRAG;
        entities.vel[id][1] *= WATER_Y_DRAG;
        entities.vel[id][2] *= WATER_XZ_DRAG;
    } else if (flags.on_ladder) {
        entities.vel[id][1] -= dt.scale(gravity);
        entities.vel[id][1] *= Y_DRAG;
        // Cap fall speed on ladder
        if (entities.vel[id][1] < LADDER_MAX_FALL) {
            entities.vel[id][1] = LADDER_MAX_FALL;
        }
        // Sneak to hold position on ladder
        if (input_move[1] < 0.0 and entities.vel[id][1] < 0.0) {
            entities.vel[id][1] = 0.0;
        }
    } else {
        entities.vel[id][1] -= dt.scale(gravity);
        entities.vel[id][1] *= Y_DRAG;
    }
}

fn collideAxis(chunk_map: *const ChunkMap, pos: [3]f32, movement: f32, axis: usize, half_w: f32, height: f32) struct { distance: f32, hit: bool } {
    const aabb_min = [3]f32{ pos[0] - half_w, pos[1], pos[2] - half_w };
    const aabb_max = [3]f32{ pos[0] + half_w, pos[1] + height, pos[2] + half_w };

    var scan_min = aabb_min;
    var scan_max = aabb_max;
    if (movement > 0) {
        scan_max[axis] += movement;
    } else {
        scan_min[axis] += movement;
    }

    // Expand scan by 1 block to catch blocks with collision boxes that extend
    // beyond their own block (e.g. fences are 1.5 blocks tall).
    const bx0 = floori(scan_min[0]) - 1;
    const by0 = floori(scan_min[1]) - 1;
    const bz0 = floori(scan_min[2]) - 1;
    const bx1 = floori(scan_max[0]) + 1;
    const by1 = floori(scan_max[1]) + 1;
    const bz1 = floori(scan_max[2]) + 1;

    var safe_dist = movement;
    var hit = false;

    var by: i32 = by0;
    while (by <= by1) : (by += 1) {
        var bz: i32 = bz0;
        while (bz <= bz1) : (bz += 1) {
            var bx: i32 = bx0;
            while (bx <= bx1) : (bx += 1) {
                const block = chunk_map.getBlock(WorldState.WorldBlockPos.init(bx, by, bz));
                if (!BlockState.isSolid(block)) continue;

                const coords = [3]i32{ bx, by, bz };
                const block_boxes = BlockState.getCollisionBoxes(block);
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

pub const BlockBox = BlockState.BlockBox;
pub const BlockBoxes = BlockState.BlockBoxes;
pub const getBlockBoxes = BlockState.getCollisionBoxes;

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
    defer {
        chunk.blocks.deinit();
        testing.allocator.destroy(chunk);
    }
    chunk.blocks = WorldState.PaletteBlocks.init(testing.allocator);
    map.put(WorldState.ChunkKey{ .cx = 0, .cy = 0, .cz = 0 }, chunk);

    const pos = [3]f32{ 5.0, 5.0, 5.0 };
    const result = collideAxis(&map, pos, 1.0, 0, PLAYER_HALF_W, PLAYER_HEIGHT);
    try testing.expectEqual(@as(f32, 1.0), result.distance);
    try testing.expect(!result.hit);
}

test "collideAxis: collision with solid block" {
    var map = ChunkMap.init(testing.allocator);
    defer map.deinit();

    const chunk = try testing.allocator.create(WorldState.Chunk);
    defer {
        chunk.blocks.deinit();
        testing.allocator.destroy(chunk);
    }
    chunk.blocks = WorldState.PaletteBlocks.init(testing.allocator);

    // Place stone at (10, 5, 5)
    chunk.blocks.set(WorldState.chunkIndex(10, 5, 5), BlockState.defaultState(.stone));
    map.put(WorldState.ChunkKey{ .cx = 0, .cy = 0, .cz = 0 }, chunk);

    // Entity at x=8.0 (HALF_W=0.4, so right edge at 8.4), moving +x toward block at x=10
    // Block face at x=10, entity AABB max x = 8.4 + movement
    const pos = [3]f32{ 8.0, 5.0, 5.5 };
    const result = collideAxis(&map, pos, 5.0, 0, PLAYER_HALF_W, PLAYER_HEIGHT);

    // Should hit: gap = 10.0 - 8.4 = 1.6, so distance should be 1.6
    try testing.expect(result.hit);
    try testing.expectApproxEqAbs(@as(f32, 1.6), result.distance, 1e-5);
}

test "collideAxis: negative movement collision" {
    var map = ChunkMap.init(testing.allocator);
    defer map.deinit();

    const chunk = try testing.allocator.create(WorldState.Chunk);
    defer {
        chunk.blocks.deinit();
        testing.allocator.destroy(chunk);
    }
    chunk.blocks = WorldState.PaletteBlocks.init(testing.allocator);

    // Place stone at (3, 5, 5) — block spans x=[3,4)
    chunk.blocks.set(WorldState.chunkIndex(3, 5, 5), BlockState.defaultState(.stone));
    map.put(WorldState.ChunkKey{ .cx = 0, .cy = 0, .cz = 0 }, chunk);

    // Entity at x=5.0 (left edge at 4.6), moving -x toward block ending at x=4
    const pos = [3]f32{ 5.0, 5.0, 5.5 };
    const result = collideAxis(&map, pos, -5.0, 0, PLAYER_HALF_W, PLAYER_HEIGHT);

    // Should hit: block top at x=4, entity min at 4.6, gap = 4.0 - 4.6 = -0.6
    try testing.expect(result.hit);
    try testing.expectApproxEqAbs(@as(f32, -0.6), result.distance, 1e-5);
}

test "collideAxis: water is not solid" {
    var map = ChunkMap.init(testing.allocator);
    defer map.deinit();

    const chunk = try testing.allocator.create(WorldState.Chunk);
    defer {
        chunk.blocks.deinit();
        testing.allocator.destroy(chunk);
    }
    chunk.blocks = WorldState.PaletteBlocks.init(testing.allocator);

    // Place water at (10, 5, 5)
    chunk.blocks.set(WorldState.chunkIndex(10, 5, 5), BlockState.defaultState(.water));
    map.put(WorldState.ChunkKey{ .cx = 0, .cy = 0, .cz = 0 }, chunk);

    const pos = [3]f32{ 8.0, 5.0, 5.5 };
    const result = collideAxis(&map, pos, 5.0, 0, PLAYER_HALF_W, PLAYER_HEIGHT);

    // Water is not solid, so no collision
    try testing.expect(!result.hit);
    try testing.expectEqual(@as(f32, 5.0), result.distance);
}
