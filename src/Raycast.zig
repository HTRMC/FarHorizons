const std = @import("std");
const zlm = @import("zlm");
const WorldState = @import("world/WorldState.zig");

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
};

pub fn raycast(world: *const WorldState.World, origin: zlm.Vec3, dir: zlm.Vec3) ?BlockHitResult {
    var block_x: i32 = @intFromFloat(@floor(origin.x));
    var block_y: i32 = @intFromFloat(@floor(origin.y));
    var block_z: i32 = @intFromFloat(@floor(origin.z));

    // Check if starting block is solid (inside-block case)
    if (WorldState.block_properties.isSolid(WorldState.getBlock(world, block_x, block_y, block_z))) {
        return .{
            .block_pos = .{ block_x, block_y, block_z },
            .direction = .up,
        };
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
        var face: Direction = undefined;

        if (t_max_x < t_max_y and t_max_x < t_max_z) {
            if (t_max_x > MAX_RANGE) return null;
            block_x += step_x;
            t_max_x += t_delta_x;
            face = if (step_x > 0) .west else .east;
        } else if (t_max_y < t_max_z) {
            if (t_max_y > MAX_RANGE) return null;
            block_y += step_y;
            t_max_y += t_delta_y;
            face = if (step_y > 0) .down else .up;
        } else {
            if (t_max_z > MAX_RANGE) return null;
            block_z += step_z;
            t_max_z += t_delta_z;
            face = if (step_z > 0) .north else .south;
        }

        if (WorldState.block_properties.isSolid(WorldState.getBlock(world, block_x, block_y, block_z))) {
            return .{
                .block_pos = .{ block_x, block_y, block_z },
                .direction = face,
            };
        }
    }

    return null;
}
