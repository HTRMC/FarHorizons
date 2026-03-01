const std = @import("std");
const types = @import("../renderer/vulkan/types.zig");
const FaceData = types.FaceData;
const LightEntry = types.LightEntry;
const tracy = @import("../platform/tracy.zig");

pub const CHUNK_SIZE = 32;
pub const BLOCKS_PER_CHUNK = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE;
pub const MAX_FACES_PER_CHUNK = BLOCKS_PER_CHUNK * 6;

pub const WORLD_CHUNKS_X = 4;
pub const WORLD_CHUNKS_Y = 1;
pub const WORLD_CHUNKS_Z = 4;
pub const WORLD_SIZE_X = WORLD_CHUNKS_X * CHUNK_SIZE;
pub const WORLD_SIZE_Y = WORLD_CHUNKS_Y * CHUNK_SIZE;
pub const WORLD_SIZE_Z = WORLD_CHUNKS_Z * CHUNK_SIZE;
pub const TOTAL_WORLD_CHUNKS = WORLD_CHUNKS_X * WORLD_CHUNKS_Y * WORLD_CHUNKS_Z;

pub const face_vertices = [6][4]struct { px: f32, py: f32, pz: f32, u: f32, v: f32 }{
    .{
        .{ .px = 0.0, .py = 0.0, .pz = 1.0, .u = 0.0, .v = 1.0 },
        .{ .px = 1.0, .py = 0.0, .pz = 1.0, .u = 1.0, .v = 1.0 },
        .{ .px = 1.0, .py = 1.0, .pz = 1.0, .u = 1.0, .v = 0.0 },
        .{ .px = 0.0, .py = 1.0, .pz = 1.0, .u = 0.0, .v = 0.0 },
    },
    .{
        .{ .px = 1.0, .py = 0.0, .pz = 0.0, .u = 0.0, .v = 1.0 },
        .{ .px = 0.0, .py = 0.0, .pz = 0.0, .u = 1.0, .v = 1.0 },
        .{ .px = 0.0, .py = 1.0, .pz = 0.0, .u = 1.0, .v = 0.0 },
        .{ .px = 1.0, .py = 1.0, .pz = 0.0, .u = 0.0, .v = 0.0 },
    },
    .{
        .{ .px = 0.0, .py = 0.0, .pz = 0.0, .u = 0.0, .v = 1.0 },
        .{ .px = 0.0, .py = 0.0, .pz = 1.0, .u = 1.0, .v = 1.0 },
        .{ .px = 0.0, .py = 1.0, .pz = 1.0, .u = 1.0, .v = 0.0 },
        .{ .px = 0.0, .py = 1.0, .pz = 0.0, .u = 0.0, .v = 0.0 },
    },
    .{
        .{ .px = 1.0, .py = 0.0, .pz = 1.0, .u = 0.0, .v = 1.0 },
        .{ .px = 1.0, .py = 0.0, .pz = 0.0, .u = 1.0, .v = 1.0 },
        .{ .px = 1.0, .py = 1.0, .pz = 0.0, .u = 1.0, .v = 0.0 },
        .{ .px = 1.0, .py = 1.0, .pz = 1.0, .u = 0.0, .v = 0.0 },
    },
    .{
        .{ .px = 0.0, .py = 1.0, .pz = 1.0, .u = 0.0, .v = 1.0 },
        .{ .px = 1.0, .py = 1.0, .pz = 1.0, .u = 1.0, .v = 1.0 },
        .{ .px = 1.0, .py = 1.0, .pz = 0.0, .u = 1.0, .v = 0.0 },
        .{ .px = 0.0, .py = 1.0, .pz = 0.0, .u = 0.0, .v = 0.0 },
    },
    .{
        .{ .px = 0.0, .py = 0.0, .pz = 0.0, .u = 0.0, .v = 1.0 },
        .{ .px = 1.0, .py = 0.0, .pz = 0.0, .u = 1.0, .v = 1.0 },
        .{ .px = 1.0, .py = 0.0, .pz = 1.0, .u = 1.0, .v = 0.0 },
        .{ .px = 0.0, .py = 0.0, .pz = 1.0, .u = 0.0, .v = 0.0 },
    },
};

pub const face_index_pattern = [6]u32{ 0, 1, 2, 2, 3, 0 };

pub const face_neighbor_offsets = [6][3]i32{
    .{ 0, 0, 1 },
    .{ 0, 0, -1 },
    .{ -1, 0, 0 },
    .{ 1, 0, 0 },
    .{ 0, 1, 0 },
    .{ 0, -1, 0 },
};

pub const BlockType = enum(u8) {
    air,
    glass,
    grass_block,
    dirt,
    stone,
    glowstone,
};

pub const block_properties = struct {
    pub fn isOpaque(block: BlockType) bool {
        return switch (block) {
            .air => false,
            .glass => false,
            .grass_block, .dirt, .stone, .glowstone => true,
        };
    }
    pub fn cullsSelf(block: BlockType) bool {
        return switch (block) {
            .air => false,
            .glass => true,
            .grass_block, .dirt, .stone, .glowstone => true,
        };
    }
    pub fn isSolid(block: BlockType) bool {
        return block != .air;
    }
    pub fn emittedLight(block: BlockType) [3]u8 {
        return switch (block) {
            .glowstone => .{ 255, 200, 100 },
            else => .{ 0, 0, 0 },
        };
    }
};

pub const LightMap = struct {
    block: [WORLD_SIZE_Y][WORLD_SIZE_Z][WORLD_SIZE_X][3]u8,
    sky: [WORLD_SIZE_Y][WORLD_SIZE_Z][WORLD_SIZE_X]u8,

    pub fn getBlock(self: *const LightMap, wx: i32, wy: i32, wz: i32) [3]u8 {
        const vx = wx + @as(i32, WORLD_SIZE_X / 2);
        const vy = wy + @as(i32, WORLD_SIZE_Y / 2);
        const vz = wz + @as(i32, WORLD_SIZE_Z / 2);
        if (vx < 0 or vx >= WORLD_SIZE_X or vy < 0 or vy >= WORLD_SIZE_Y or vz < 0 or vz >= WORLD_SIZE_Z) {
            return .{ 0, 0, 0 };
        }
        return self.block[@intCast(vy)][@intCast(vz)][@intCast(vx)];
    }

    pub fn getSky(self: *const LightMap, wx: i32, wy: i32, wz: i32) u8 {
        const vx = wx + @as(i32, WORLD_SIZE_X / 2);
        const vy = wy + @as(i32, WORLD_SIZE_Y / 2);
        const vz = wz + @as(i32, WORLD_SIZE_Z / 2);
        if (vx < 0 or vx >= WORLD_SIZE_X or vy < 0 or vy >= WORLD_SIZE_Y or vz < 0 or vz >= WORLD_SIZE_Z) {
            return 255;
        }
        return self.sky[@intCast(vy)][@intCast(vz)][@intCast(vx)];
    }
};

const LIGHT_ATTENUATION: u8 = 8;
pub const LIGHT_MAX_RADIUS: i32 = 255 / LIGHT_ATTENUATION;

fn getBlockAt(world: *const World, vx: usize, vy: usize, vz: usize) BlockType {
    return world[vy / CHUNK_SIZE][vz / CHUNK_SIZE][vx / CHUNK_SIZE]
        .blocks[chunkIndex(vx % CHUNK_SIZE, vy % CHUNK_SIZE, vz % CHUNK_SIZE)];
}

pub fn computeLightMap(world: *const World, light_map: *LightMap) void {
    @memset(std.mem.asBytes(&light_map.block), 0);
    @memset(std.mem.asBytes(&light_map.sky), 0);

    const QueueEntry = struct { vx: u8, vy: u8, vz: u8, level: u8 };
    const RgbQueueEntry = struct { vx: u8, vy: u8, vz: u8, r: u8, g: u8, b: u8 };

    const bfs_offsets = [6][3]i32{
        .{ 1, 0, 0 }, .{ -1, 0, 0 },
        .{ 0, 1, 0 }, .{ 0, -1, 0 },
        .{ 0, 0, 1 }, .{ 0, 0, -1 },
    };

    var sky_queue_buf: [WORLD_SIZE_X * WORLD_SIZE_Y * WORLD_SIZE_Z]QueueEntry = undefined;
    var sky_head: usize = 0;
    var sky_tail: usize = 0;

    for (0..WORLD_SIZE_Z) |vz| {
        for (0..WORLD_SIZE_X) |vx| {
            var vy: usize = WORLD_SIZE_Y;
            while (vy > 0) {
                vy -= 1;
                if (block_properties.isOpaque(getBlockAt(world, vx, vy, vz))) break;
                light_map.sky[vy][vz][vx] = 255;
                if (sky_tail < sky_queue_buf.len) {
                    sky_queue_buf[sky_tail] = .{
                        .vx = @intCast(vx),
                        .vy = @intCast(vy),
                        .vz = @intCast(vz),
                        .level = 255,
                    };
                    sky_tail += 1;
                }
            }
        }
    }

    while (sky_head < sky_tail) {
        const e = sky_queue_buf[sky_head];
        sky_head += 1;

        for (bfs_offsets) |off| {
            const nx_i: i32 = @as(i32, e.vx) + off[0];
            const ny_i: i32 = @as(i32, e.vy) + off[1];
            const nz_i: i32 = @as(i32, e.vz) + off[2];

            if (nx_i < 0 or nx_i >= WORLD_SIZE_X or ny_i < 0 or ny_i >= WORLD_SIZE_Y or nz_i < 0 or nz_i >= WORLD_SIZE_Z) continue;

            const nx: usize = @intCast(nx_i);
            const ny: usize = @intCast(ny_i);
            const nz: usize = @intCast(nz_i);

            if (block_properties.isOpaque(getBlockAt(world, nx, ny, nz))) continue;

            const new_level = e.level -| LIGHT_ATTENUATION;
            if (new_level == 0) continue;
            if (new_level <= light_map.sky[ny][nz][nx]) continue;

            light_map.sky[ny][nz][nx] = new_level;

            if (sky_tail < sky_queue_buf.len) {
                sky_queue_buf[sky_tail] = .{
                    .vx = @intCast(nx),
                    .vy = @intCast(ny),
                    .vz = @intCast(nz),
                    .level = new_level,
                };
                sky_tail += 1;
            }
        }
    }

    var queue_buf: [256 * 1024]RgbQueueEntry = undefined;
    var head: usize = 0;
    var tail: usize = 0;

    for (0..WORLD_SIZE_Y) |vy| {
        for (0..WORLD_SIZE_Z) |vz| {
            for (0..WORLD_SIZE_X) |vx| {
                const emit = block_properties.emittedLight(getBlockAt(world, vx, vy, vz));
                if (emit[0] > 0 or emit[1] > 0 or emit[2] > 0) {
                    light_map.block[vy][vz][vx] = emit;
                    queue_buf[tail] = .{
                        .vx = @intCast(vx),
                        .vy = @intCast(vy),
                        .vz = @intCast(vz),
                        .r = emit[0],
                        .g = emit[1],
                        .b = emit[2],
                    };
                    tail += 1;
                }
            }
        }
    }

    while (head < tail) {
        const e = queue_buf[head];
        head += 1;

        for (bfs_offsets) |off| {
            const nx_i: i32 = @as(i32, e.vx) + off[0];
            const ny_i: i32 = @as(i32, e.vy) + off[1];
            const nz_i: i32 = @as(i32, e.vz) + off[2];

            if (nx_i < 0 or nx_i >= WORLD_SIZE_X or ny_i < 0 or ny_i >= WORLD_SIZE_Y or nz_i < 0 or nz_i >= WORLD_SIZE_Z) continue;

            const nx: usize = @intCast(nx_i);
            const ny: usize = @intCast(ny_i);
            const nz: usize = @intCast(nz_i);

            if (block_properties.isOpaque(getBlockAt(world, nx, ny, nz))) continue;

            const nr = e.r -| LIGHT_ATTENUATION;
            const ng = e.g -| LIGHT_ATTENUATION;
            const nb = e.b -| LIGHT_ATTENUATION;

            if (nr == 0 and ng == 0 and nb == 0) continue;

            const existing = &light_map.block[ny][nz][nx];
            if (nr <= existing[0] and ng <= existing[1] and nb <= existing[2]) continue;

            existing[0] = @max(existing[0], nr);
            existing[1] = @max(existing[1], ng);
            existing[2] = @max(existing[2], nb);

            if (tail < queue_buf.len) {
                queue_buf[tail] = .{
                    .vx = @intCast(nx),
                    .vy = @intCast(ny),
                    .vz = @intCast(nz),
                    .r = nr,
                    .g = ng,
                    .b = nb,
                };
                tail += 1;
            }
        }
    }
}

pub fn updateLightMap(world: *const World, light_map: *LightMap, wx: i32, wy: i32, wz: i32) void {
    const bfs_offsets = [6][3]i32{
        .{ 1, 0, 0 }, .{ -1, 0, 0 },
        .{ 0, 1, 0 }, .{ 0, -1, 0 },
        .{ 0, 0, 1 }, .{ 0, 0, -1 },
    };

    const cvx = wx + @as(i32, WORLD_SIZE_X / 2);
    const cvy = wy + @as(i32, WORLD_SIZE_Y / 2);
    const cvz = wz + @as(i32, WORLD_SIZE_Z / 2);
    if (cvx < 0 or cvx >= WORLD_SIZE_X or cvy < 0 or cvy >= WORLD_SIZE_Y or cvz < 0 or cvz >= WORLD_SIZE_Z) return;

    const radius = LIGHT_MAX_RADIUS + 1;

    const min_vx: usize = @intCast(@max(0, cvx - radius));
    const max_vx: usize = @intCast(@min(@as(i32, WORLD_SIZE_X) - 1, cvx + radius));
    const min_vy: usize = @intCast(@max(0, cvy - radius));
    const max_vy: usize = @intCast(@min(@as(i32, WORLD_SIZE_Y) - 1, cvy + radius));
    const min_vz: usize = @intCast(@max(0, cvz - radius));
    const max_vz: usize = @intCast(@min(@as(i32, WORLD_SIZE_Z) - 1, cvz + radius));


    for (min_vy..max_vy + 1) |vy| {
        for (min_vz..max_vz + 1) |vz| {
            for (min_vx..max_vx + 1) |vx| {
                light_map.block[vy][vz][vx] = .{ 0, 0, 0 };
            }
        }
    }

    for (min_vy..max_vy + 1) |vy| {
        for (min_vz..max_vz + 1) |vz| {
            for (min_vx..max_vx + 1) |vx| {
                light_map.sky[vy][vz][vx] = 0;
            }
        }
    }

    const QueueEntry = struct { vx: u8, vy: u8, vz: u8, level: u8 };
    const RgbQueueEntry = struct { vx: u8, vy: u8, vz: u8, r: u8, g: u8, b: u8 };

    var sky_queue_buf: [128 * 1024]QueueEntry = undefined;
    var sky_head: usize = 0;
    var sky_tail: usize = 0;

    for (min_vz..max_vz + 1) |vz| {
        for (min_vx..max_vx + 1) |vx| {
            var vy: usize = WORLD_SIZE_Y;
            while (vy > 0) {
                vy -= 1;
                if (block_properties.isOpaque(getBlockAt(world, vx, vy, vz))) break;
                light_map.sky[vy][vz][vx] = 255;
                if (vy >= min_vy and vy <= max_vy) {
                    if (sky_tail < sky_queue_buf.len) {
                        sky_queue_buf[sky_tail] = .{
                            .vx = @intCast(vx),
                            .vy = @intCast(vy),
                            .vz = @intCast(vz),
                            .level = 255,
                        };
                        sky_tail += 1;
                    }
                }
            }
        }
    }

    const border_ranges = [_][2]usize{
        .{ min_vx, max_vx },
        .{ min_vy, max_vy },
        .{ min_vz, max_vz },
    };
    _ = border_ranges;

    for (min_vy..max_vy + 1) |vy| {
        for (min_vz..max_vz + 1) |vz| {
            for (min_vx..max_vx + 1) |vx| {
                if (light_map.sky[vy][vz][vx] > 0) continue;
                if (block_properties.isOpaque(getBlockAt(world, vx, vy, vz))) continue;

                for (bfs_offsets) |off| {
                    const nx_i: i32 = @as(i32, @intCast(vx)) + off[0];
                    const ny_i: i32 = @as(i32, @intCast(vy)) + off[1];
                    const nz_i: i32 = @as(i32, @intCast(vz)) + off[2];

                    if (nx_i >= @as(i32, @intCast(min_vx)) and nx_i <= @as(i32, @intCast(max_vx)) and
                        ny_i >= @as(i32, @intCast(min_vy)) and ny_i <= @as(i32, @intCast(max_vy)) and
                        nz_i >= @as(i32, @intCast(min_vz)) and nz_i <= @as(i32, @intCast(max_vz)))
                        continue;

                    if (nx_i < 0 or nx_i >= WORLD_SIZE_X or ny_i < 0 or ny_i >= WORLD_SIZE_Y or nz_i < 0 or nz_i >= WORLD_SIZE_Z) {
                        const new_level: u8 = 255 -| LIGHT_ATTENUATION;
                        if (new_level > light_map.sky[vy][vz][vx]) {
                            light_map.sky[vy][vz][vx] = new_level;
                            if (sky_tail < sky_queue_buf.len) {
                                sky_queue_buf[sky_tail] = .{ .vx = @intCast(vx), .vy = @intCast(vy), .vz = @intCast(vz), .level = new_level };
                                sky_tail += 1;
                            }
                        }
                        continue;
                    }

                    const nx: usize = @intCast(nx_i);
                    const ny: usize = @intCast(ny_i);
                    const nz: usize = @intCast(nz_i);

                    const neighbor_sky = light_map.sky[ny][nz][nx];
                    if (neighbor_sky > LIGHT_ATTENUATION) {
                        const new_level = neighbor_sky - LIGHT_ATTENUATION;
                        if (new_level > light_map.sky[vy][vz][vx]) {
                            light_map.sky[vy][vz][vx] = new_level;
                            if (sky_tail < sky_queue_buf.len) {
                                sky_queue_buf[sky_tail] = .{ .vx = @intCast(vx), .vy = @intCast(vy), .vz = @intCast(vz), .level = new_level };
                                sky_tail += 1;
                            }
                        }
                    }
                }
            }
        }
    }

    while (sky_head < sky_tail) {
        const e = sky_queue_buf[sky_head];
        sky_head += 1;

        for (bfs_offsets) |off| {
            const nx_i: i32 = @as(i32, e.vx) + off[0];
            const ny_i: i32 = @as(i32, e.vy) + off[1];
            const nz_i: i32 = @as(i32, e.vz) + off[2];

            if (nx_i < 0 or nx_i >= WORLD_SIZE_X or ny_i < 0 or ny_i >= WORLD_SIZE_Y or nz_i < 0 or nz_i >= WORLD_SIZE_Z) continue;

            const nx: usize = @intCast(nx_i);
            const ny: usize = @intCast(ny_i);
            const nz: usize = @intCast(nz_i);

            if (block_properties.isOpaque(getBlockAt(world, nx, ny, nz))) continue;

            const new_level = e.level -| LIGHT_ATTENUATION;
            if (new_level == 0) continue;
            if (new_level <= light_map.sky[ny][nz][nx]) continue;

            light_map.sky[ny][nz][nx] = new_level;

            if (sky_tail < sky_queue_buf.len) {
                sky_queue_buf[sky_tail] = .{ .vx = @intCast(nx), .vy = @intCast(ny), .vz = @intCast(nz), .level = new_level };
                sky_tail += 1;
            }
        }
    }

    var queue_buf: [128 * 1024]RgbQueueEntry = undefined;
    var head: usize = 0;
    var tail: usize = 0;

    for (min_vy..max_vy + 1) |vy| {
        for (min_vz..max_vz + 1) |vz| {
            for (min_vx..max_vx + 1) |vx| {
                const emit = block_properties.emittedLight(getBlockAt(world, vx, vy, vz));
                if (emit[0] > 0 or emit[1] > 0 or emit[2] > 0) {
                    light_map.block[vy][vz][vx] = emit;
                    if (tail < queue_buf.len) {
                        queue_buf[tail] = .{ .vx = @intCast(vx), .vy = @intCast(vy), .vz = @intCast(vz), .r = emit[0], .g = emit[1], .b = emit[2] };
                        tail += 1;
                    }
                }
            }
        }
    }

    for (min_vy..max_vy + 1) |vy| {
        for (min_vz..max_vz + 1) |vz| {
            for (min_vx..max_vx + 1) |vx| {
                if (block_properties.isOpaque(getBlockAt(world, vx, vy, vz))) continue;

                for (bfs_offsets) |off| {
                    const nx_i: i32 = @as(i32, @intCast(vx)) + off[0];
                    const ny_i: i32 = @as(i32, @intCast(vy)) + off[1];
                    const nz_i: i32 = @as(i32, @intCast(vz)) + off[2];

                    if (nx_i >= @as(i32, @intCast(min_vx)) and nx_i <= @as(i32, @intCast(max_vx)) and
                        ny_i >= @as(i32, @intCast(min_vy)) and ny_i <= @as(i32, @intCast(max_vy)) and
                        nz_i >= @as(i32, @intCast(min_vz)) and nz_i <= @as(i32, @intCast(max_vz)))
                        continue;

                    if (nx_i < 0 or nx_i >= WORLD_SIZE_X or ny_i < 0 or ny_i >= WORLD_SIZE_Y or nz_i < 0 or nz_i >= WORLD_SIZE_Z) continue;

                    const nx: usize = @intCast(nx_i);
                    const ny: usize = @intCast(ny_i);
                    const nz: usize = @intCast(nz_i);

                    const nb = light_map.block[ny][nz][nx];
                    const nr = nb[0] -| LIGHT_ATTENUATION;
                    const ng = nb[1] -| LIGHT_ATTENUATION;
                    const nbb = nb[2] -| LIGHT_ATTENUATION;

                    if (nr == 0 and ng == 0 and nbb == 0) continue;

                    const existing = &light_map.block[vy][vz][vx];
                    var changed = false;
                    if (nr > existing[0]) {
                        existing[0] = nr;
                        changed = true;
                    }
                    if (ng > existing[1]) {
                        existing[1] = ng;
                        changed = true;
                    }
                    if (nbb > existing[2]) {
                        existing[2] = nbb;
                        changed = true;
                    }

                    if (changed and tail < queue_buf.len) {
                        queue_buf[tail] = .{ .vx = @intCast(vx), .vy = @intCast(vy), .vz = @intCast(vz), .r = existing[0], .g = existing[1], .b = existing[2] };
                        tail += 1;
                    }
                }
            }
        }
    }

    while (head < tail) {
        const e = queue_buf[head];
        head += 1;

        for (bfs_offsets) |off| {
            const nx_i: i32 = @as(i32, e.vx) + off[0];
            const ny_i: i32 = @as(i32, e.vy) + off[1];
            const nz_i: i32 = @as(i32, e.vz) + off[2];

            if (nx_i < 0 or nx_i >= WORLD_SIZE_X or ny_i < 0 or ny_i >= WORLD_SIZE_Y or nz_i < 0 or nz_i >= WORLD_SIZE_Z) continue;

            const nx: usize = @intCast(nx_i);
            const ny: usize = @intCast(ny_i);
            const nz: usize = @intCast(nz_i);

            if (block_properties.isOpaque(getBlockAt(world, nx, ny, nz))) continue;

            const nr = e.r -| LIGHT_ATTENUATION;
            const ng = e.g -| LIGHT_ATTENUATION;
            const nb = e.b -| LIGHT_ATTENUATION;

            if (nr == 0 and ng == 0 and nb == 0) continue;

            const existing = &light_map.block[ny][nz][nx];
            if (nr <= existing[0] and ng <= existing[1] and nb <= existing[2]) continue;

            existing[0] = @max(existing[0], nr);
            existing[1] = @max(existing[1], ng);
            existing[2] = @max(existing[2], nb);

            if (tail < queue_buf.len) {
                queue_buf[tail] = .{ .vx = @intCast(nx), .vy = @intCast(ny), .vz = @intCast(nz), .r = existing[0], .g = existing[1], .b = existing[2] };
                tail += 1;
            }
        }
    }
}

pub const Chunk = struct {
    blocks: [BLOCKS_PER_CHUNK]BlockType,
};

pub const World = [WORLD_CHUNKS_Y][WORLD_CHUNKS_Z][WORLD_CHUNKS_X]Chunk;

pub const ChunkCoord = struct {
    cx: u8,
    cy: u8,
    cz: u8,

    pub fn flatIndex(self: ChunkCoord) usize {
        return @as(usize, self.cy) * WORLD_CHUNKS_Z * WORLD_CHUNKS_X +
            @as(usize, self.cz) * WORLD_CHUNKS_X +
            @as(usize, self.cx);
    }

    pub fn eql(a: ChunkCoord, b: ChunkCoord) bool {
        return a.cx == b.cx and a.cy == b.cy and a.cz == b.cz;
    }

    pub fn position(self: ChunkCoord) [3]i32 {
        return .{
            @as(i32, @intCast(self.cx)) * CHUNK_SIZE - @as(i32, WORLD_SIZE_X / 2),
            @as(i32, @intCast(self.cy)) * CHUNK_SIZE - @as(i32, WORLD_SIZE_Y / 2),
            @as(i32, @intCast(self.cz)) * CHUNK_SIZE - @as(i32, WORLD_SIZE_Z / 2),
        };
    }

    pub fn positionScaled(self: ChunkCoord, voxel_size: u32) [3]i32 {
        const vs: i32 = @intCast(voxel_size);
        return .{
            @as(i32, @intCast(self.cx)) * CHUNK_SIZE * vs - @as(i32, WORLD_SIZE_X / 2),
            @as(i32, @intCast(self.cy)) * CHUNK_SIZE * vs - @as(i32, WORLD_SIZE_Y / 2),
            @as(i32, @intCast(self.cz)) * CHUNK_SIZE * vs - @as(i32, WORLD_SIZE_Z / 2),
        };
    }
};

pub const ChunkMeshResult = struct {
    faces: []FaceData,
    face_counts: [6]u32,
    total_face_count: u32,
    lights: []LightEntry,
    light_count: u32,
};

pub fn chunkIndex(x: usize, y: usize, z: usize) usize {
    return y * CHUNK_SIZE * CHUNK_SIZE + z * CHUNK_SIZE + x;
}

pub fn setBlock(world: *World, wx: i32, wy: i32, wz: i32, block: BlockType) void {
    const vx = wx + @as(i32, WORLD_SIZE_X / 2);
    const vy = wy + @as(i32, WORLD_SIZE_Y / 2);
    const vz = wz + @as(i32, WORLD_SIZE_Z / 2);

    if (vx < 0 or vx >= WORLD_SIZE_X or vy < 0 or vy >= WORLD_SIZE_Y or vz < 0 or vz >= WORLD_SIZE_Z) return;

    const uvx: usize = @intCast(vx);
    const uvy: usize = @intCast(vy);
    const uvz: usize = @intCast(vz);

    world[uvy / CHUNK_SIZE][uvz / CHUNK_SIZE][uvx / CHUNK_SIZE]
        .blocks[chunkIndex(uvx % CHUNK_SIZE, uvy % CHUNK_SIZE, uvz % CHUNK_SIZE)] = block;
}

pub fn getBlock(world: *const World, wx: i32, wy: i32, wz: i32) BlockType {
    const vx = wx + @as(i32, WORLD_SIZE_X / 2);
    const vy = wy + @as(i32, WORLD_SIZE_Y / 2);
    const vz = wz + @as(i32, WORLD_SIZE_Z / 2);

    if (vx < 0 or vx >= WORLD_SIZE_X or vy < 0 or vy >= WORLD_SIZE_Y or vz < 0 or vz >= WORLD_SIZE_Z) {
        return .air;
    }

    const uvx: usize = @intCast(vx);
    const uvy: usize = @intCast(vy);
    const uvz: usize = @intCast(vz);

    const cx = uvx / CHUNK_SIZE;
    const cy = uvy / CHUNK_SIZE;
    const cz = uvz / CHUNK_SIZE;
    const lx = uvx % CHUNK_SIZE;
    const ly = uvy % CHUNK_SIZE;
    const lz = uvz % CHUNK_SIZE;

    return world[cy][cz][cx].blocks[chunkIndex(lx, ly, lz)];
}

pub fn generateTerrainWorld(out: *World) void {
    const half_y: i32 = WORLD_SIZE_Y / 2;

    for (0..WORLD_CHUNKS_Y) |cy| {
        for (0..WORLD_CHUNKS_Z) |cz| {
            for (0..WORLD_CHUNKS_X) |cx| {
                var blocks: [BLOCKS_PER_CHUNK]BlockType = .{.air} ** BLOCKS_PER_CHUNK;

                for (0..CHUNK_SIZE) |y| {
                    const wy: i32 = @as(i32, @intCast(cy * CHUNK_SIZE + y)) - half_y;

                    const block_type: BlockType = if (wy == 0)
                        .grass_block
                    else if (wy >= -2 and wy <= -1)
                        .dirt
                    else if (wy >= -7 and wy <= -3)
                        .stone
                    else
                        .air;

                    if (block_type == .air) continue;

                    for (0..CHUNK_SIZE) |z| {
                        for (0..CHUNK_SIZE) |x| {
                            blocks[chunkIndex(x, y, z)] = block_type;
                        }
                    }
                }

                out[cy][cz][cx] = .{ .blocks = blocks };
            }
        }
    }
}

/// Recompute a single output block from its 2x2x2 source neighborhood.
/// `dst_bx/by/bz` are block coords within the destination world's voxel space.
/// Returns the majority-vote block type from the 2x2x2 source region.
pub fn downsampleBlock(src: *const World, dst_bx: i32, dst_by: i32, dst_bz: i32) BlockType {
    const src_half_x: i32 = WORLD_SIZE_X / 2;
    const src_half_y: i32 = WORLD_SIZE_Y / 2;
    const src_half_z: i32 = WORLD_SIZE_Z / 2;

    // Map destination block to source world coords (2x scale)
    const src_wx = dst_bx * 2 - src_half_x;
    const src_wy = dst_by * 2 - src_half_y;
    const src_wz = dst_bz * 2 - src_half_z;

    var counts = [_]u32{0} ** 6;
    var non_air_total: u32 = 0;

    var dy: i32 = 0;
    while (dy < 2) : (dy += 1) {
        var dz: i32 = 0;
        while (dz < 2) : (dz += 1) {
            var dx: i32 = 0;
            while (dx < 2) : (dx += 1) {
                const b = getBlock(src, src_wx + dx, src_wy + dy, src_wz + dz);
                if (b != .air) {
                    counts[@intFromEnum(b)] += 1;
                    non_air_total += 1;
                }
            }
        }
    }

    if (non_air_total == 0) return .air;

    var best_type: BlockType = .air;
    var best_count: u32 = 0;
    for (1..counts.len) |i| {
        if (counts[i] > best_count) {
            best_count = counts[i];
            best_type = @enumFromInt(i);
        }
    }

    return best_type;
}

/// 2x downsample: each output block is the majority vote of 2x2x2 source blocks.
/// `src_lod_level` is the LOD level of `src` (0 for the base world).
/// The output will be at LOD level `src_lod_level + 1`.
pub fn downsampleWorld(src: *const World, dst: *World, src_lod_level: u8) void {
    @memset(std.mem.asBytes(dst), 0);

    const src_scale: u32 = @as(u32, 1) << @intCast(src_lod_level);
    const src_chunks_x = @max(1, WORLD_CHUNKS_X / src_scale);
    const src_chunks_y = @max(1, WORLD_CHUNKS_Y / src_scale);
    const src_chunks_z = @max(1, WORLD_CHUNKS_Z / src_scale);

    const dst_chunks_x = @max(1, src_chunks_x / 2);
    const dst_chunks_y = @max(1, src_chunks_y / 2);
    const dst_chunks_z = @max(1, src_chunks_z / 2);

    // Always use global half — getBlock/setBlock offset by WORLD_SIZE/2
    const src_half_x: i32 = WORLD_SIZE_X / 2;
    const src_half_y: i32 = WORLD_SIZE_Y / 2;
    const src_half_z: i32 = WORLD_SIZE_Z / 2;

    for (0..dst_chunks_y) |cy| {
        for (0..dst_chunks_z) |cz| {
            for (0..dst_chunks_x) |cx| {
                var blocks: [BLOCKS_PER_CHUNK]BlockType = .{.air} ** BLOCKS_PER_CHUNK;

                for (0..CHUNK_SIZE) |by| {
                    for (0..CHUNK_SIZE) |bz| {
                        for (0..CHUNK_SIZE) |bx| {
                            // Map output block to source world coords (2x scale)
                            const src_wx: i32 = (@as(i32, @intCast(cx)) * CHUNK_SIZE + @as(i32, @intCast(bx))) * 2 - src_half_x;
                            const src_wy: i32 = (@as(i32, @intCast(cy)) * CHUNK_SIZE + @as(i32, @intCast(by))) * 2 - src_half_y;
                            const src_wz: i32 = (@as(i32, @intCast(cz)) * CHUNK_SIZE + @as(i32, @intCast(bz))) * 2 - src_half_z;

                            var counts = [_]u32{0} ** 6;
                            var non_air_total: u32 = 0;

                            var dy: i32 = 0;
                            while (dy < 2) : (dy += 1) {
                                var dz: i32 = 0;
                                while (dz < 2) : (dz += 1) {
                                    var dx: i32 = 0;
                                    while (dx < 2) : (dx += 1) {
                                        const b = getBlock(src, src_wx + dx, src_wy + dy, src_wz + dz);
                                        if (b != .air) {
                                            counts[@intFromEnum(b)] += 1;
                                            non_air_total += 1;
                                        }
                                    }
                                }
                            }

                            if (non_air_total == 0) continue;

                            var best_type: BlockType = .air;
                            var best_count: u32 = 0;
                            for (1..counts.len) |i| {
                                if (counts[i] > best_count) {
                                    best_count = counts[i];
                                    best_type = @enumFromInt(i);
                                }
                            }

                            blocks[chunkIndex(bx, by, bz)] = best_type;
                        }
                    }
                }

                dst[cy][cz][cx] = .{ .blocks = blocks };
            }
        }
    }
}

const ao_offsets = computeAoOffsets();

fn computeAoOffsets() [6][4][3][3]i32 {
    var result: [6][4][3][3]i32 = undefined;

    for (0..6) |face| {
        const normal = face_neighbor_offsets[face];

        for (0..4) |corner| {
            const vert = face_vertices[face][corner];
            const pos = [3]f32{ vert.px, vert.py, vert.pz };

            var tang: [2]usize = undefined;
            var ti: usize = 0;
            for (0..3) |axis| {
                if (normal[axis] == 0) {
                    tang[ti] = axis;
                    ti += 1;
                }
            }

            var edge1 = [3]i32{ 0, 0, 0 };
            var edge2 = [3]i32{ 0, 0, 0 };
            edge1[tang[0]] = if (pos[tang[0]] == 0.0) -1 else 1;
            edge2[tang[1]] = if (pos[tang[1]] == 0.0) -1 else 1;

            result[face][corner][0] = .{
                normal[0] + edge1[0],
                normal[1] + edge1[1],
                normal[2] + edge1[2],
            };
            result[face][corner][1] = .{
                normal[0] + edge2[0],
                normal[1] + edge2[1],
                normal[2] + edge2[2],
            };
            result[face][corner][2] = .{
                normal[0] + edge1[0] + edge2[0],
                normal[1] + edge1[1] + edge2[1],
                normal[2] + edge1[2] + edge2[2],
            };
        }
    }

    return result;
}

fn getNeighborBlock(
    world: *const World,
    cx: usize,
    cy: usize,
    cz: usize,
    lx: i32,
    ly: i32,
    lz: i32,
) BlockType {
    if (lx >= 0 and lx < CHUNK_SIZE and ly >= 0 and ly < CHUNK_SIZE and lz >= 0 and lz < CHUNK_SIZE) {
        return world[cy][cz][cx].blocks[chunkIndex(@intCast(lx), @intCast(ly), @intCast(lz))];
    }

    const ncx: i32 = @as(i32, @intCast(cx)) + if (lx < 0) @as(i32, -1) else if (lx >= CHUNK_SIZE) @as(i32, 1) else @as(i32, 0);
    const ncy: i32 = @as(i32, @intCast(cy)) + if (ly < 0) @as(i32, -1) else if (ly >= CHUNK_SIZE) @as(i32, 1) else @as(i32, 0);
    const ncz: i32 = @as(i32, @intCast(cz)) + if (lz < 0) @as(i32, -1) else if (lz >= CHUNK_SIZE) @as(i32, 1) else @as(i32, 0);

    if (ncx < 0 or ncx >= WORLD_CHUNKS_X or ncy < 0 or ncy >= WORLD_CHUNKS_Y or ncz < 0 or ncz >= WORLD_CHUNKS_Z) {
        return .air;
    }

    const flx: usize = @intCast(@mod(lx, @as(i32, CHUNK_SIZE)));
    const fly: usize = @intCast(@mod(ly, @as(i32, CHUNK_SIZE)));
    const flz: usize = @intCast(@mod(lz, @as(i32, CHUNK_SIZE)));
    return world[@intCast(ncy)][@intCast(ncz)][@intCast(ncx)].blocks[chunkIndex(flx, fly, flz)];
}

pub fn generateChunkMesh(
    allocator: std.mem.Allocator,
    world: *const World,
    coord: ChunkCoord,
    light_map_ptr: ?*const LightMap,
) !ChunkMeshResult {
    const tz = tracy.zone(@src(), "generateChunkMesh");
    defer tz.end();

    const cx: usize = coord.cx;
    const cy: usize = coord.cy;
    const cz: usize = coord.cz;

    const chunk_origin_x: i32 = @as(i32, @intCast(cx)) * CHUNK_SIZE - @as(i32, WORLD_SIZE_X / 2);
    const chunk_origin_y: i32 = @as(i32, @intCast(cy)) * CHUNK_SIZE - @as(i32, WORLD_SIZE_Y / 2);
    const chunk_origin_z: i32 = @as(i32, @intCast(cz)) * CHUNK_SIZE - @as(i32, WORLD_SIZE_Z / 2);

    var normal_faces: [6]std.ArrayList(FaceData) = undefined;
    var normal_lights: [6]std.ArrayList(LightEntry) = undefined;
    for (0..6) |i| {
        normal_faces[i] = .empty;
        normal_lights[i] = .empty;
    }
    errdefer for (0..6) |i| {
        normal_faces[i].deinit(allocator);
        normal_lights[i].deinit(allocator);
    };

    for (0..CHUNK_SIZE) |by| {
        for (0..CHUNK_SIZE) |bz| {
            for (0..CHUNK_SIZE) |bx| {
                const block = world[cy][cz][cx].blocks[chunkIndex(bx, by, bz)];
                if (block == .air) continue;

                const ibx: i32 = @intCast(bx);
                const iby: i32 = @intCast(by);
                const ibz: i32 = @intCast(bz);

                const wx = chunk_origin_x + ibx;
                const wy = chunk_origin_y + iby;
                const wz = chunk_origin_z + ibz;

                const emits = block_properties.emittedLight(block);
                const is_emitter = emits[0] > 0 or emits[1] > 0 or emits[2] > 0;

                for (0..6) |face| {
                    const fno = face_neighbor_offsets[face];
                    const neighbor = getNeighborBlock(world, cx, cy, cz, ibx + fno[0], iby + fno[1], ibz + fno[2]);

                    if (block_properties.isOpaque(neighbor)) continue;
                    if (neighbor == block and block_properties.cullsSelf(block)) continue;

                    const tex_index: u8 = switch (block) {
                        .air => unreachable,
                        .glass => 0,
                        .grass_block => 1,
                        .dirt => 2,
                        .stone => 3,
                        .glowstone => 4,
                    };

                    var corner_packed: [4]u32 = undefined;
                    var corner_block_brightness: [4]u8 = .{ 0, 0, 0, 0 };

                    if (is_emitter) {
                        const br5: u32 = @as(u32, emits[0]) >> 3;
                        const bg5: u32 = @as(u32, emits[1]) >> 3;
                        const bb5: u32 = @as(u32, emits[2]) >> 3;
                        const emit_packed: u32 = (31 << 0) | (31 << 5) | (31 << 10) | (br5 << 15) | (bg5 << 20) | (bb5 << 25);
                        corner_packed = .{ emit_packed, emit_packed, emit_packed, emit_packed };
                        corner_block_brightness = .{ 255, 255, 255, 255 };
                    } else {
                        for (0..4) |corner| {
                            const offsets = ao_offsets[face][corner];

                            if (light_map_ptr) |lm| {
                                var sum_r: u32 = 0;
                                var sum_g: u32 = 0;
                                var sum_b: u32 = 0;

                                const face_light = lm.getBlock(wx + fno[0], wy + fno[1], wz + fno[2]);
                                sum_r += face_light[0];
                                sum_g += face_light[1];
                                sum_b += face_light[2];

                                for (0..3) |s| {
                                    const sl = lm.getBlock(wx + offsets[s][0], wy + offsets[s][1], wz + offsets[s][2]);
                                    sum_r += sl[0];
                                    sum_g += sl[1];
                                    sum_b += sl[2];
                                }

                                const avg_r: u32 = sum_r / 4;
                                const avg_g: u32 = sum_g / 4;
                                const avg_b: u32 = sum_b / 4;

                                corner_block_brightness[corner] = @intCast(@max(avg_r, @max(avg_g, avg_b)));

                                var sky_sum: u32 = 0;
                                sky_sum += lm.getSky(wx + fno[0], wy + fno[1], wz + fno[2]);
                                for (0..3) |s| {
                                    sky_sum += lm.getSky(wx + offsets[s][0], wy + offsets[s][1], wz + offsets[s][2]);
                                }
                                const sky_avg: u32 = sky_sum / 4;

                                const sr5: u32 = sky_avg >> 3;
                                const sg5: u32 = sky_avg >> 3;
                                const sb5: u32 = sky_avg >> 3;
                                const br5: u32 = avg_r >> 3;
                                const bg5: u32 = avg_g >> 3;
                                const bb5: u32 = avg_b >> 3;

                                corner_packed[corner] = sr5 | (sg5 << 5) | (sb5 << 10) | (br5 << 15) | (bg5 << 20) | (bb5 << 25);
                            } else {
                                corner_packed[corner] = 31 | (31 << 5) | (31 << 10);
                            }
                        }
                    }

                    var ao: [4]u2 = undefined;
                    if (is_emitter) {
                        ao = .{ 0, 0, 0, 0 };
                    } else {
                        for (0..4) |corner| {
                            const offsets = ao_offsets[face][corner];
                            const s1 = block_properties.isOpaque(getNeighborBlock(world, cx, cy, cz, ibx + offsets[0][0], iby + offsets[0][1], ibz + offsets[0][2]));
                            const s2 = block_properties.isOpaque(getNeighborBlock(world, cx, cy, cz, ibx + offsets[1][0], iby + offsets[1][1], ibz + offsets[1][2]));
                            const diag = if (s1 and s2)
                                true
                            else
                                block_properties.isOpaque(getNeighborBlock(world, cx, cy, cz, ibx + offsets[2][0], iby + offsets[2][1], ibz + offsets[2][2]));
                            const raw_ao: u3 = @as(u3, @intFromBool(s1)) + @intFromBool(s2) + @intFromBool(diag);

                            const reduction: u3 = @intCast(@min(@as(u32, 3), @as(u32, corner_block_brightness[corner]) / 64));
                            ao[corner] = @intCast(raw_ao -| reduction);
                        }
                    }

                    const face_data = types.packFaceData(
                        @intCast(bx),
                        @intCast(by),
                        @intCast(bz),
                        tex_index,
                        @intCast(face),
                        0,
                        ao,
                    );

                    try normal_faces[face].append(allocator, face_data);
                    try normal_lights[face].append(allocator, .{ .corners = corner_packed });
                }
            }
        }
    }

    var face_counts: [6]u32 = undefined;
    var total_face_count: u32 = 0;
    for (0..6) |i| {
        face_counts[i] = @intCast(normal_faces[i].items.len);
        total_face_count += face_counts[i];
    }

    const faces = try allocator.alloc(FaceData, total_face_count);
    errdefer allocator.free(faces);
    const lights = try allocator.alloc(LightEntry, total_face_count);
    errdefer allocator.free(lights);

    var write_offset: usize = 0;
    for (0..6) |i| {
        const fitems = normal_faces[i].items;
        const litems = normal_lights[i].items;
        @memcpy(faces[write_offset..][0..fitems.len], fitems);
        @memcpy(lights[write_offset..][0..litems.len], litems);
        write_offset += fitems.len;
        normal_faces[i].deinit(allocator);
        normal_lights[i].deinit(allocator);
    }

    return .{
        .faces = faces,
        .face_counts = face_counts,
        .total_face_count = total_face_count,
        .lights = lights,
        .light_count = total_face_count,
    };
}

pub const AffectedChunks = struct {
    coords: [7]ChunkCoord,
    count: u8,
};

pub fn affectedChunks(wx: i32, wy: i32, wz: i32) AffectedChunks {
    const vx = wx + @as(i32, WORLD_SIZE_X / 2);
    const vy = wy + @as(i32, WORLD_SIZE_Y / 2);
    const vz = wz + @as(i32, WORLD_SIZE_Z / 2);

    if (vx < 0 or vx >= WORLD_SIZE_X or vy < 0 or vy >= WORLD_SIZE_Y or vz < 0 or vz >= WORLD_SIZE_Z) {
        return .{ .coords = undefined, .count = 0 };
    }

    const uvx: usize = @intCast(vx);
    const uvy: usize = @intCast(vy);
    const uvz: usize = @intCast(vz);

    const base_cx: u8 = @intCast(uvx / CHUNK_SIZE);
    const base_cy: u8 = @intCast(uvy / CHUNK_SIZE);
    const base_cz: u8 = @intCast(uvz / CHUNK_SIZE);

    var result = AffectedChunks{
        .coords = undefined,
        .count = 0,
    };

    result.coords[0] = .{ .cx = base_cx, .cy = base_cy, .cz = base_cz };
    result.count = 1;

    const lx = uvx % CHUNK_SIZE;
    const ly = uvy % CHUNK_SIZE;
    const lz = uvz % CHUNK_SIZE;

    if (lx <= 1 and base_cx > 0) {
        result.coords[result.count] = .{ .cx = base_cx - 1, .cy = base_cy, .cz = base_cz };
        result.count += 1;
    }
    if (lx >= CHUNK_SIZE - 2 and base_cx + 1 < WORLD_CHUNKS_X) {
        result.coords[result.count] = .{ .cx = base_cx + 1, .cy = base_cy, .cz = base_cz };
        result.count += 1;
    }

    if (ly <= 1 and base_cy > 0) {
        result.coords[result.count] = .{ .cx = base_cx, .cy = base_cy - 1, .cz = base_cz };
        result.count += 1;
    }
    if (ly >= CHUNK_SIZE - 2 and base_cy + 1 < WORLD_CHUNKS_Y) {
        result.coords[result.count] = .{ .cx = base_cx, .cy = base_cy + 1, .cz = base_cz };
        result.count += 1;
    }

    if (lz <= 1 and base_cz > 0) {
        result.coords[result.count] = .{ .cx = base_cx, .cy = base_cy, .cz = base_cz - 1 };
        result.count += 1;
    }
    if (lz >= CHUNK_SIZE - 2 and base_cz + 1 < WORLD_CHUNKS_Z) {
        result.coords[result.count] = .{ .cx = base_cx, .cy = base_cy, .cz = base_cz + 1 };
        result.count += 1;
    }

    return result;
}


const testing = std.testing;

fn unpackFace(fd: FaceData) struct { x: u5, y: u5, z: u5, tex_index: u8, normal_index: u3, light_index: u6 } {
    return .{
        .x = @intCast(fd.word0 & 0x1F),
        .y = @intCast((fd.word0 >> 5) & 0x1F),
        .z = @intCast((fd.word0 >> 10) & 0x1F),
        .tex_index = @intCast((fd.word0 >> 15) & 0xFF),
        .normal_index = @intCast((fd.word0 >> 23) & 0x7),
        .light_index = @intCast((fd.word0 >> 26) & 0x3F),
    };
}

fn makeEmptyWorld() World {
    var world: World = undefined;
    for (0..WORLD_CHUNKS_Y) |cy| {
        for (0..WORLD_CHUNKS_Z) |cz| {
            for (0..WORLD_CHUNKS_X) |cx| {
                world[cy][cz][cx] = .{ .blocks = .{.air} ** BLOCKS_PER_CHUNK };
            }
        }
    }
    return world;
}

test "single block in air produces 6 faces" {
    var world = makeEmptyWorld();
    world[0][0][0].blocks[chunkIndex(5, 5, 5)] = .stone;

    const result = try generateChunkMesh(testing.allocator, &world, .{ .cx = 0, .cy = 0, .cz = 0 }, null);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    try testing.expectEqual(@as(u32, 6), result.total_face_count);

    for (0..6) |i| {
        try testing.expectEqual(@as(u32, 1), result.face_counts[i]);
    }

    for (result.faces) |face| {
        const u = unpackFace(face);
        try testing.expectEqual(@as(u5, 5), u.x);
        try testing.expectEqual(@as(u5, 5), u.y);
        try testing.expectEqual(@as(u5, 5), u.z);
        try testing.expectEqual(@as(u8, 3), u.tex_index);
    }
}

test "two adjacent blocks share face - culled" {
    var world = makeEmptyWorld();
    world[0][0][0].blocks[chunkIndex(5, 5, 5)] = .stone;
    world[0][0][0].blocks[chunkIndex(6, 5, 5)] = .stone;

    const result = try generateChunkMesh(testing.allocator, &world, .{ .cx = 0, .cy = 0, .cz = 0 }, null);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    try testing.expectEqual(@as(u32, 10), result.total_face_count);

    try testing.expectEqual(@as(u32, 1), result.face_counts[2]);
    try testing.expectEqual(@as(u32, 1), result.face_counts[3]);
    try testing.expectEqual(@as(u32, 2), result.face_counts[0]);
    try testing.expectEqual(@as(u32, 2), result.face_counts[1]);
    try testing.expectEqual(@as(u32, 2), result.face_counts[4]);
    try testing.expectEqual(@as(u32, 2), result.face_counts[5]);
}

test "face_counts sum equals total_face_count" {
    var world = makeEmptyWorld();
    for (3..7) |x| {
        for (3..6) |y| {
            world[0][0][0].blocks[chunkIndex(x, y, 4)] = .dirt;
        }
    }

    const result = try generateChunkMesh(testing.allocator, &world, .{ .cx = 0, .cy = 0, .cz = 0 }, null);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    var sum: u32 = 0;
    for (result.face_counts) |fc| sum += fc;
    try testing.expectEqual(sum, result.total_face_count);
    try testing.expectEqual(result.total_face_count, @as(u32, @intCast(result.faces.len)));
}

test "normal indices in faces match their group" {
    var world = makeEmptyWorld();
    world[0][0][0].blocks[chunkIndex(10, 10, 10)] = .grass_block;

    const result = try generateChunkMesh(testing.allocator, &world, .{ .cx = 0, .cy = 0, .cz = 0 }, null);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    var offset: usize = 0;
    for (0..6) |normal_idx| {
        const count = result.face_counts[normal_idx];
        for (offset..offset + count) |i| {
            const u = unpackFace(result.faces[i]);
            try testing.expectEqual(@as(u3, @intCast(normal_idx)), u.normal_index);
        }
        offset += count;
    }
}

test "cross-chunk boundary face culling" {
    var world = makeEmptyWorld();
    world[0][0][0].blocks[chunkIndex(CHUNK_SIZE - 1, 5, 5)] = .stone;
    world[0][0][1].blocks[chunkIndex(0, 5, 5)] = .stone;

    const result0 = try generateChunkMesh(testing.allocator, &world, .{ .cx = 0, .cy = 0, .cz = 0 }, null);
    defer testing.allocator.free(result0.faces);
    defer testing.allocator.free(result0.lights);

    const result1 = try generateChunkMesh(testing.allocator, &world, .{ .cx = 1, .cy = 0, .cz = 0 }, null);
    defer testing.allocator.free(result1.faces);
    defer testing.allocator.free(result1.lights);

    try testing.expectEqual(@as(u32, 5), result0.total_face_count);
    try testing.expectEqual(@as(u32, 5), result1.total_face_count);

    try testing.expectEqual(@as(u32, 0), result0.face_counts[3]);
    try testing.expectEqual(@as(u32, 0), result1.face_counts[2]);
}

test "empty chunk produces no faces" {
    var world = makeEmptyWorld();
    const result = try generateChunkMesh(testing.allocator, &world, .{ .cx = 0, .cy = 0, .cz = 0 }, null);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    try testing.expectEqual(@as(u32, 0), result.total_face_count);
    try testing.expectEqual(@as(usize, 0), result.faces.len);
}

test "glass does not cull adjacent non-glass" {
    var world = makeEmptyWorld();
    world[0][0][0].blocks[chunkIndex(5, 5, 5)] = .stone;
    world[0][0][0].blocks[chunkIndex(6, 5, 5)] = .glass;

    const result = try generateChunkMesh(testing.allocator, &world, .{ .cx = 0, .cy = 0, .cz = 0 }, null);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    try testing.expectEqual(@as(u32, 11), result.total_face_count);
}

test "glass-glass adjacency culls shared face" {
    var world = makeEmptyWorld();
    world[0][0][0].blocks[chunkIndex(5, 5, 5)] = .glass;
    world[0][0][0].blocks[chunkIndex(6, 5, 5)] = .glass;

    const result = try generateChunkMesh(testing.allocator, &world, .{ .cx = 0, .cy = 0, .cz = 0 }, null);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    try testing.expectEqual(@as(u32, 10), result.total_face_count);
}

test "light count equals face count (1:1 mapping)" {
    var world = makeEmptyWorld();
    for (0..4) |x| {
        world[0][0][0].blocks[chunkIndex(x, 5, 5)] = .stone;
    }

    const result = try generateChunkMesh(testing.allocator, &world, .{ .cx = 0, .cy = 0, .cz = 0 }, null);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    try testing.expectEqual(result.total_face_count, result.light_count);
    try testing.expectEqual(result.faces.len, result.lights.len);
}

test "ChunkCoord.position returns correct world-space origin" {
    const pos0 = (ChunkCoord{ .cx = 0, .cy = 0, .cz = 0 }).position();
    try testing.expectEqual(@as(i32, -64), pos0[0]);
    try testing.expectEqual(@as(i32, -16), pos0[1]);
    try testing.expectEqual(@as(i32, -64), pos0[2]);

    const pos2 = (ChunkCoord{ .cx = 2, .cy = 0, .cz = 2 }).position();
    try testing.expectEqual(@as(i32, 0), pos2[0]);
    try testing.expectEqual(@as(i32, -16), pos2[1]);
    try testing.expectEqual(@as(i32, 0), pos2[2]);
}

test "world boundary blocks have all outer faces" {
    var world = makeEmptyWorld();
    world[0][0][0].blocks[chunkIndex(0, 0, 0)] = .stone;

    const result = try generateChunkMesh(testing.allocator, &world, .{ .cx = 0, .cy = 0, .cz = 0 }, null);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    try testing.expectEqual(@as(u32, 6), result.total_face_count);
}


fn unpackAo(fd: FaceData) [4]u2 {
    return .{
        @intCast(fd.word1 & 0x3),
        @intCast((fd.word1 >> 2) & 0x3),
        @intCast((fd.word1 >> 4) & 0x3),
        @intCast((fd.word1 >> 6) & 0x3),
    };
}

fn findFaceByNormal(result: ChunkMeshResult, normal: u3) ?FaceData {
    var offset: usize = 0;
    for (0..6) |i| {
        const count = result.face_counts[i];
        if (i == normal) {
            if (count > 0) return result.faces[offset];
            return null;
        }
        offset += count;
    }
    return null;
}

test "AO: single block in air has no occlusion" {
    var world = makeEmptyWorld();
    world[0][0][0].blocks[chunkIndex(5, 5, 5)] = .stone;

    const result = try generateChunkMesh(testing.allocator, &world, .{ .cx = 0, .cy = 0, .cz = 0 }, null);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    for (result.faces) |face| {
        try testing.expectEqual([4]u2{ 0, 0, 0, 0 }, unpackAo(face));
    }
}

test "AO: block on flat surface has correct top face AO" {
    var world = makeEmptyWorld();
    for (4..7) |x| {
        for (4..7) |z| {
            world[0][0][0].blocks[chunkIndex(x, 5, z)] = .stone;
        }
    }

    const result = try generateChunkMesh(testing.allocator, &world, .{ .cx = 0, .cy = 0, .cz = 0 }, null);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    var offset: usize = 0;
    for (0..4) |i| {
        offset += result.face_counts[i];
    }
    var center_top: ?FaceData = null;
    for (offset..offset + result.face_counts[4]) |i| {
        const u = unpackFace(result.faces[i]);
        if (u.x == 5 and u.y == 5 and u.z == 5) {
            center_top = result.faces[i];
            break;
        }
    }

    const ao = unpackAo(center_top.?);
    for (ao) |level| {
        try testing.expectEqual(@as(u2, 3), level);
    }
}

test "AO: block in corner has maximum occlusion on enclosed corner" {
    var world = makeEmptyWorld();
    world[0][0][0].blocks[chunkIndex(5, 5, 5)] = .stone;
    world[0][0][0].blocks[chunkIndex(6, 5, 5)] = .stone;
    world[0][0][0].blocks[chunkIndex(5, 6, 5)] = .stone;
    world[0][0][0].blocks[chunkIndex(5, 5, 6)] = .stone;

    const result = try generateChunkMesh(testing.allocator, &world, .{ .cx = 0, .cy = 0, .cz = 0 }, null);
    defer testing.allocator.free(result.faces);
    defer testing.allocator.free(result.lights);

    var found_nonzero = false;
    for (result.faces) |face| {
        const ao = unpackAo(face);
        for (ao) |level| {
            if (level > 0) {
                found_nonzero = true;
                break;
            }
        }
        if (found_nonzero) break;
    }
    try testing.expect(found_nonzero);
}

test "AO: comptime offset table sanity" {
    for (0..6) |face| {
        const normal = face_neighbor_offsets[face];
        for (0..4) |corner| {
            for (0..3) |sample| {
                const off = ao_offsets[face][corner][sample];
                for (0..3) |axis| {
                    try testing.expect(off[axis] >= -1 and off[axis] <= 1);
                }
                for (0..3) |axis| {
                    if (normal[axis] != 0) {
                        try testing.expectEqual(normal[axis], off[axis]);
                    }
                }
            }
        }
    }
}
