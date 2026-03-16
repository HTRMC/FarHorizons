const std = @import("std");
const zlm = @import("zlm");
const WorldState = @import("world/WorldState.zig");
const ChunkMap = @import("world/ChunkMap.zig").ChunkMap;
const Physics = @import("Physics.zig");

const BlockState = WorldState.BlockState;
const AABB = BlockState.AABB;
const MAX_RANGE: f32 = 5.0;

pub const Direction = enum {
    west,
    east,
    down,
    up,
    north,
    south,

    pub fn normal(self: Direction) [3]i32 {
        return switch (self) {
            .west => .{ -1, 0, 0 },
            .east => .{ 1, 0, 0 },
            .down => .{ 0, -1, 0 },
            .up => .{ 0, 1, 0 },
            .north => .{ 0, 0, -1 },
            .south => .{ 0, 0, 1 },
        };
    }
};

pub const BlockHitResult = struct {
    block_pos: [3]i32,
    direction: Direction,
    hit_pos: [3]f32, // exact world-space hit point
};

pub fn raycast(chunk_map: *const ChunkMap, origin: zlm.Vec3, dir: zlm.Vec3) ?BlockHitResult {
    var block_x: i32 = @intFromFloat(@floor(origin.x));
    var block_y: i32 = @intFromFloat(@floor(origin.y));
    var block_z: i32 = @intFromFloat(@floor(origin.z));

    if (BlockState.isTargetable(chunk_map.getBlock(block_x, block_y, block_z))) {
        if (testBlockHitbox(chunk_map, origin, dir, block_x, block_y, block_z)) |result| {
            return result;
        }
    }

    const step_x: i32 = if (dir.x > 0) 1 else if (dir.x < 0) -1 else 0;
    const step_y: i32 = if (dir.y > 0) 1 else if (dir.y < 0) -1 else 0;
    const step_z: i32 = if (dir.z > 0) 1 else if (dir.z < 0) -1 else 0;

    const t_delta_x: f32 = if (dir.x != 0) @abs(1.0 / dir.x) else std.math.inf(f32);
    const t_delta_y: f32 = if (dir.y != 0) @abs(1.0 / dir.y) else std.math.inf(f32);
    const t_delta_z: f32 = if (dir.z != 0) @abs(1.0 / dir.z) else std.math.inf(f32);

    var t_max_x: f32 = if (dir.x > 0)
        (@as(f32, @floatFromInt(block_x)) + 1.0 - origin.x) / dir.x
    else if (dir.x < 0)
        (@as(f32, @floatFromInt(block_x)) - origin.x) / dir.x
    else
        std.math.inf(f32);

    var t_max_y: f32 = if (dir.y > 0)
        (@as(f32, @floatFromInt(block_y)) + 1.0 - origin.y) / dir.y
    else if (dir.y < 0)
        (@as(f32, @floatFromInt(block_y)) - origin.y) / dir.y
    else
        std.math.inf(f32);

    var t_max_z: f32 = if (dir.z > 0)
        (@as(f32, @floatFromInt(block_z)) + 1.0 - origin.z) / dir.z
    else if (dir.z < 0)
        (@as(f32, @floatFromInt(block_z)) - origin.z) / dir.z
    else
        std.math.inf(f32);

    const max_steps: u32 = @intFromFloat(@ceil(MAX_RANGE) * 3.0 + 3.0);

    for (0..max_steps) |_| {
        if (t_max_x < t_max_y and t_max_x < t_max_z) {
            if (t_max_x > MAX_RANGE) return null;
            block_x += step_x;
            t_max_x += t_delta_x;
        } else if (t_max_y < t_max_z) {
            if (t_max_y > MAX_RANGE) return null;
            block_y += step_y;
            t_max_y += t_delta_y;
        } else {
            if (t_max_z > MAX_RANGE) return null;
            block_z += step_z;
            t_max_z += t_delta_z;
        }

        if (BlockState.isTargetable(chunk_map.getBlock(block_x, block_y, block_z))) {
            if (testBlockHitbox(chunk_map, origin, dir, block_x, block_y, block_z)) |result| {
                return result;
            }
        }
    }

    return null;
}

/// Test if a ray hits any of the block's hitboxes. Returns the closest hit result
/// with correct face direction and hit position, or null if the ray misses all boxes.
fn testBlockHitbox(
    chunk_map: *const ChunkMap,
    origin: zlm.Vec3,
    dir: zlm.Vec3,
    bx: i32,
    by: i32,
    bz: i32,
) ?BlockHitResult {
    const state = chunk_map.getBlock(bx, by, bz);
    const block_boxes = Physics.getBlockBoxes(state);

    const fx: f32 = @floatFromInt(bx);
    const fy: f32 = @floatFromInt(by);
    const fz: f32 = @floatFromInt(bz);
    const o = [3]f32{ origin.x, origin.y, origin.z };
    const d = [3]f32{ dir.x, dir.y, dir.z };

    var best_t: f32 = std.math.inf(f32);
    var best_axis: u2 = 0;
    var best_inside = false;

    for (block_boxes.boxes[0..block_boxes.count]) |box| {
        const box_min = [3]f32{ fx + box.min[0], fy + box.min[1], fz + box.min[2] };
        const box_max = [3]f32{ fx + box.max[0], fy + box.max[1], fz + box.max[2] };

        var t_near: f32 = -std.math.inf(f32);
        var t_far: f32 = std.math.inf(f32);
        var near_axis: u2 = 0;
        var missed = false;

        for (0..3) |axis| {
            if (@abs(d[axis]) < 1e-9) {
                if (o[axis] < box_min[axis] or o[axis] > box_max[axis]) {
                    missed = true;
                    break;
                }
            } else {
                var t1 = (box_min[axis] - o[axis]) / d[axis];
                var t2 = (box_max[axis] - o[axis]) / d[axis];
                if (t1 > t2) {
                    const tmp = t1;
                    t1 = t2;
                    t2 = tmp;
                }
                if (t1 > t_near) {
                    t_near = t1;
                    near_axis = @intCast(axis);
                }
                if (t2 < t_far) t_far = t2;
                if (t_near > t_far or t_far < 0) {
                    missed = true;
                    break;
                }
            }
        }
        if (missed) continue;

        const hit_t = if (t_near >= 0) t_near else 0;
        if (hit_t > MAX_RANGE) continue;

        if (hit_t < best_t) {
            best_t = hit_t;
            best_axis = near_axis;
            best_inside = t_near < 0;
        }
    }

    if (best_t == std.math.inf(f32)) return null;

    const face: Direction = if (best_inside)
        .up
    else switch (best_axis) {
        0 => if (d[0] > 0) .west else .east,
        1 => if (d[1] > 0) .down else .up,
        2 => if (d[2] > 0) .north else .south,
        else => unreachable,
    };

    return .{
        .block_pos = .{ bx, by, bz },
        .direction = face,
        .hit_pos = .{
            origin.x + dir.x * best_t,
            origin.y + dir.y * best_t,
            origin.z + dir.z * best_t,
        },
    };
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn makeRaycastTestMap(allocator: std.mem.Allocator) !struct { map: ChunkMap, chunk: *WorldState.Chunk } {
    var map = ChunkMap.init(allocator);
    const chunk = try allocator.create(WorldState.Chunk);
    @memset(&chunk.blocks, @as(u16, 0));
    map.put(WorldState.ChunkKey{ .cx = 0, .cy = 0, .cz = 0 }, chunk);
    return .{ .map = map, .chunk = chunk };
}

test "Direction.normal: all 6 directions have unit length" {
    const dirs = [_]Direction{ .west, .east, .down, .up, .north, .south };
    for (dirs) |d| {
        const n = d.normal();
        const len_sq = n[0] * n[0] + n[1] * n[1] + n[2] * n[2];
        try testing.expectEqual(@as(i32, 1), len_sq);
    }
}

test "Direction.normal: opposite pairs cancel" {
    const west = Direction.west.normal();
    const east = Direction.east.normal();
    try testing.expectEqual(@as(i32, 0), west[0] + east[0]);

    const down = Direction.down.normal();
    const up = Direction.up.normal();
    try testing.expectEqual(@as(i32, 0), down[1] + up[1]);

    const north = Direction.north.normal();
    const south = Direction.south.normal();
    try testing.expectEqual(@as(i32, 0), north[2] + south[2]);
}

test "raycast: hit block directly ahead +x" {
    var state = try makeRaycastTestMap(testing.allocator);
    defer state.map.deinit();

    state.chunk.blocks[WorldState.chunkIndex(10, 5, 5)] = BlockState.defaultState(.stone);

    const origin = zlm.Vec3.new(5.5, 5.5, 5.5);
    const dir = zlm.Vec3.new(1.0, 0.0, 0.0);
    const result = raycast(&state.map, origin, dir);

    try testing.expect(result != null);
    const hit = result.?;
    try testing.expectEqual(@as(i32, 10), hit.block_pos[0]);
    try testing.expectEqual(@as(i32, 5), hit.block_pos[1]);
    try testing.expectEqual(@as(i32, 5), hit.block_pos[2]);
    try testing.expectEqual(Direction.west, hit.direction);
}

test "raycast: hit block directly ahead -x" {
    var state = try makeRaycastTestMap(testing.allocator);
    defer state.map.deinit();

    state.chunk.blocks[WorldState.chunkIndex(2, 5, 5)] = BlockState.defaultState(.stone);

    const origin = zlm.Vec3.new(5.5, 5.5, 5.5);
    const dir = zlm.Vec3.new(-1.0, 0.0, 0.0);
    const result = raycast(&state.map, origin, dir);

    try testing.expect(result != null);
    const hit = result.?;
    try testing.expectEqual(@as(i32, 2), hit.block_pos[0]);
    try testing.expectEqual(Direction.east, hit.direction);
}

test "raycast: hit block above (+y)" {
    var state = try makeRaycastTestMap(testing.allocator);
    defer state.map.deinit();

    state.chunk.blocks[WorldState.chunkIndex(5, 8, 5)] = BlockState.defaultState(.stone);

    const origin = zlm.Vec3.new(5.5, 5.5, 5.5);
    const dir = zlm.Vec3.new(0.0, 1.0, 0.0);
    const result = raycast(&state.map, origin, dir);

    try testing.expect(result != null);
    try testing.expectEqual(@as(i32, 8), result.?.block_pos[1]);
    try testing.expectEqual(Direction.down, result.?.direction);
}

test "raycast: miss when no solid blocks" {
    var state = try makeRaycastTestMap(testing.allocator);
    defer state.map.deinit();

    const origin = zlm.Vec3.new(5.5, 5.5, 5.5);
    const dir = zlm.Vec3.new(1.0, 0.0, 0.0);
    const result = raycast(&state.map, origin, dir);

    try testing.expect(result == null);
}

test "raycast: block beyond MAX_RANGE is not hit" {
    var state = try makeRaycastTestMap(testing.allocator);
    defer state.map.deinit();

    // Place block 6 blocks away (MAX_RANGE = 5.0)
    state.chunk.blocks[WorldState.chunkIndex(12, 5, 5)] = BlockState.defaultState(.stone);

    const origin = zlm.Vec3.new(5.5, 5.5, 5.5);
    const dir = zlm.Vec3.new(1.0, 0.0, 0.0);
    const result = raycast(&state.map, origin, dir);

    try testing.expect(result == null);
}

test "raycast: starting inside solid block returns it" {
    var state = try makeRaycastTestMap(testing.allocator);
    defer state.map.deinit();

    state.chunk.blocks[WorldState.chunkIndex(5, 5, 5)] = BlockState.defaultState(.stone);

    const origin = zlm.Vec3.new(5.5, 5.5, 5.5);
    const dir = zlm.Vec3.new(1.0, 0.0, 0.0);
    const result = raycast(&state.map, origin, dir);

    try testing.expect(result != null);
    try testing.expectEqual(@as(i32, 5), result.?.block_pos[0]);
    try testing.expectEqual(@as(i32, 5), result.?.block_pos[1]);
    try testing.expectEqual(@as(i32, 5), result.?.block_pos[2]);
    try testing.expectEqual(Direction.up, result.?.direction);
}

test "raycast: diagonal ray hits nearest block" {
    var state = try makeRaycastTestMap(testing.allocator);
    defer state.map.deinit();

    // Place blocks at (8,5,5) and (5,8,5)
    state.chunk.blocks[WorldState.chunkIndex(8, 5, 5)] = BlockState.defaultState(.stone);
    state.chunk.blocks[WorldState.chunkIndex(5, 8, 5)] = BlockState.defaultState(.stone);

    // Diagonal ray at 45 degrees in XY from center of block (5,5,5)
    const origin = zlm.Vec3.new(5.5, 5.5, 5.5);
    const dir = zlm.Vec3.new(1.0, 1.0, 0.0);
    const result = raycast(&state.map, origin, dir);

    // Both blocks are equidistant on their respective axes — we get whichever
    // the DDA visits first; the important thing is that we get a valid hit
    try testing.expect(result != null);
}

test "raycast: axis-aligned ray with zero components" {
    var state = try makeRaycastTestMap(testing.allocator);
    defer state.map.deinit();

    state.chunk.blocks[WorldState.chunkIndex(5, 5, 8)] = BlockState.defaultState(.stone);

    // Pure +z ray
    const origin = zlm.Vec3.new(5.5, 5.5, 5.5);
    const dir = zlm.Vec3.new(0.0, 0.0, 1.0);
    const result = raycast(&state.map, origin, dir);

    try testing.expect(result != null);
    try testing.expectEqual(@as(i32, 8), result.?.block_pos[2]);
    try testing.expectEqual(Direction.north, result.?.direction);
}

test "raycast: glass is solid and blocks ray" {
    var state = try makeRaycastTestMap(testing.allocator);
    defer state.map.deinit();

    state.chunk.blocks[WorldState.chunkIndex(8, 5, 5)] = BlockState.defaultState(.glass);

    const origin = zlm.Vec3.new(5.5, 5.5, 5.5);
    const dir = zlm.Vec3.new(1.0, 0.0, 0.0);
    const result = raycast(&state.map, origin, dir);

    try testing.expect(result != null);
    try testing.expectEqual(@as(i32, 8), result.?.block_pos[0]);
}

test "raycast: water is not solid and ray passes through" {
    var state = try makeRaycastTestMap(testing.allocator);
    defer state.map.deinit();

    state.chunk.blocks[WorldState.chunkIndex(8, 5, 5)] = BlockState.defaultState(.water);

    const origin = zlm.Vec3.new(5.5, 5.5, 5.5);
    const dir = zlm.Vec3.new(1.0, 0.0, 0.0);
    const result = raycast(&state.map, origin, dir);

    try testing.expect(result == null);
}

test "raycast: ray with negative direction -z" {
    var state = try makeRaycastTestMap(testing.allocator);
    defer state.map.deinit();

    state.chunk.blocks[WorldState.chunkIndex(5, 5, 2)] = BlockState.defaultState(.stone);

    const origin = zlm.Vec3.new(5.5, 5.5, 5.5);
    const dir = zlm.Vec3.new(0.0, 0.0, -1.0);
    const result = raycast(&state.map, origin, dir);

    try testing.expect(result != null);
    try testing.expectEqual(@as(i32, 2), result.?.block_pos[2]);
    try testing.expectEqual(Direction.south, result.?.direction);
}

test "raycast: ray along -y hits block below" {
    var state = try makeRaycastTestMap(testing.allocator);
    defer state.map.deinit();

    state.chunk.blocks[WorldState.chunkIndex(5, 2, 5)] = BlockState.defaultState(.stone);

    const origin = zlm.Vec3.new(5.5, 5.5, 5.5);
    const dir = zlm.Vec3.new(0.0, -1.0, 0.0);
    const result = raycast(&state.map, origin, dir);

    try testing.expect(result != null);
    try testing.expectEqual(@as(i32, 2), result.?.block_pos[1]);
    try testing.expectEqual(Direction.up, result.?.direction);
}

test "raycast: block at exact MAX_RANGE boundary" {
    var state = try makeRaycastTestMap(testing.allocator);
    defer state.map.deinit();

    // Place block exactly 5 blocks away (at MAX_RANGE boundary)
    state.chunk.blocks[WorldState.chunkIndex(10, 5, 5)] = BlockState.defaultState(.stone);

    const origin = zlm.Vec3.new(5.5, 5.5, 5.5);
    const dir = zlm.Vec3.new(1.0, 0.0, 0.0);
    const result = raycast(&state.map, origin, dir);

    // 10 - 5.5 = 4.5 blocks away, within range
    try testing.expect(result != null);
    try testing.expectEqual(@as(i32, 10), result.?.block_pos[0]);
}

test "raycast: origin on block boundary" {
    var state = try makeRaycastTestMap(testing.allocator);
    defer state.map.deinit();

    state.chunk.blocks[WorldState.chunkIndex(8, 5, 5)] = BlockState.defaultState(.stone);

    // Origin exactly on block boundary (integer coordinate)
    const origin = zlm.Vec3.new(5.0, 5.5, 5.5);
    const dir = zlm.Vec3.new(1.0, 0.0, 0.0);
    const result = raycast(&state.map, origin, dir);

    try testing.expect(result != null);
    try testing.expectEqual(@as(i32, 8), result.?.block_pos[0]);
}
