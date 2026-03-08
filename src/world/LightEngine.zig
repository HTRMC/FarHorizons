const std = @import("std");
const WorldState = @import("WorldState.zig");
const LightMapMod = @import("LightMap.zig");
const LightMap = LightMapMod.LightMap;
const BlockType = WorldState.BlockType;
const block_properties = WorldState.block_properties;

const CHUNK_SIZE = WorldState.CHUNK_SIZE;
const BLOCKS_PER_CHUNK = WorldState.BLOCKS_PER_CHUNK;

const ATTENUATION: u8 = 8;

const BFS_OFFSETS = [6][3]i32{
    .{ 1, 0, 0 },
    .{ -1, 0, 0 },
    .{ 0, 1, 0 },
    .{ 0, -1, 0 },
    .{ 0, 0, 1 },
    .{ 0, 0, -1 },
};

const OPPOSITE_DIR = [6]u3{ 1, 0, 3, 2, 5, 4 };

fn chunkIndex(x: usize, y: usize, z: usize) usize {
    return y * CHUNK_SIZE * CHUNK_SIZE + z * CHUNK_SIZE + x;
}

fn getBlock(chunk: *const WorldState.Chunk, neighbors: [6]?*const WorldState.Chunk, x: i32, y: i32, z: i32) BlockType {
    if (x >= 0 and x < CHUNK_SIZE and y >= 0 and y < CHUNK_SIZE and z >= 0 and z < CHUNK_SIZE) {
        return chunk.blocks[chunkIndex(@intCast(x), @intCast(y), @intCast(z))];
    }
    // Check neighbor chunks
    if (x >= CHUNK_SIZE) {
        const n = neighbors[3] orelse return .air; // +X
        return n.blocks[chunkIndex(0, @intCast(y), @intCast(z))];
    }
    if (x < 0) {
        const n = neighbors[2] orelse return .air; // -X
        return n.blocks[chunkIndex(CHUNK_SIZE - 1, @intCast(y), @intCast(z))];
    }
    if (y >= CHUNK_SIZE) {
        const n = neighbors[4] orelse return .air; // +Y
        return n.blocks[chunkIndex(@intCast(x), 0, @intCast(z))];
    }
    if (y < 0) {
        const n = neighbors[5] orelse return .air; // -Y
        return n.blocks[chunkIndex(@intCast(x), CHUNK_SIZE - 1, @intCast(z))];
    }
    if (z >= CHUNK_SIZE) {
        const n = neighbors[0] orelse return .air; // +Z
        return n.blocks[chunkIndex(@intCast(x), @intCast(y), 0)];
    }
    if (z < 0) {
        const n = neighbors[1] orelse return .air; // -Z
        return n.blocks[chunkIndex(@intCast(x), @intCast(y), CHUNK_SIZE - 1)];
    }
    return .air;
}

fn getNeighborLight(neighbor_lights: [6]?*const LightMap, face: usize, x: usize, y: usize, z: usize) [3]u8 {
    const lm = neighbor_lights[face] orelse return .{ 0, 0, 0 };
    return lm.block_light[chunkIndex(x, y, z)];
}

fn getNeighborSkyLight(neighbor_lights: [6]?*const LightMap, face: usize, x: usize, y: usize, z: usize) u8 {
    const lm = neighbor_lights[face] orelse return 0;
    return lm.sky_light[chunkIndex(x, y, z)];
}

const QueueEntry = struct {
    x: i8,
    y: i8,
    z: i8,
    dir: u3,
    r: u8,
    g: u8,
    b: u8,
};

const SkyQueueEntry = struct {
    x: i8,
    y: i8,
    z: i8,
    dir: u3,
    level: u8,
};

const MAX_QUEUE = BLOCKS_PER_CHUNK * 2;

pub fn computeChunkLight(
    chunk: *const WorldState.Chunk,
    neighbors: [6]?*const WorldState.Chunk,
    neighbor_lights: [6]?*const LightMap,
    light_map: *LightMap,
) void {
    @memset(std.mem.asBytes(&light_map.block_light), 0);
    @memset(&light_map.sky_light, 0);

    computeSkyLight(chunk, neighbors, neighbor_lights, light_map);
    computeBlockLight(chunk, neighbors, neighbor_lights, light_map);

    light_map.dirty = false;
}

fn computeSkyLight(
    chunk: *const WorldState.Chunk,
    neighbors: [6]?*const WorldState.Chunk,
    neighbor_lights: [6]?*const LightMap,
    light_map: *LightMap,
) void {
    var queue: [MAX_QUEUE]SkyQueueEntry = undefined;
    var head: u32 = 0;
    var tail: u32 = 0;

    // Phase 1: Column scan — fill skylight from top down
    // If there's no chunk above, sky is open
    const has_above = neighbors[4] != null;
    for (0..CHUNK_SIZE) |z| {
        for (0..CHUNK_SIZE) |x| {
            // Check if sky is open above this column
            var sky_open = !has_above;
            if (!sky_open) {
                // Check if neighbor above has opaque block at y=0 for this x,z
                const above_block = getBlock(chunk, neighbors, @intCast(x), CHUNK_SIZE, @intCast(z));
                sky_open = !block_properties.isOpaque(above_block);
            }

            if (sky_open) {
                var y: i32 = CHUNK_SIZE - 1;
                while (y >= 0) : (y -= 1) {
                    const uy: usize = @intCast(y);
                    if (block_properties.isOpaque(chunk.blocks[chunkIndex(x, uy, z)])) break;
                    light_map.sky_light[chunkIndex(x, uy, z)] = 255;
                    if (tail < MAX_QUEUE) {
                        queue[tail] = .{ .x = @intCast(x), .y = @intCast(y), .z = @intCast(z), .dir = 6, .level = 255 };
                        tail += 1;
                    }
                }
            }
        }
    }

    // Phase 2: Seed from neighbor chunks' sky light at boundaries
    // +X boundary: neighbor[3], their x=0 face
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |z| {
            const nl = getNeighborSkyLight(neighbor_lights, 3, 0, y, z);
            if (nl > ATTENUATION) {
                const new_level = nl - ATTENUATION;
                const idx = chunkIndex(CHUNK_SIZE - 1, y, z);
                if (new_level > light_map.sky_light[idx] and !block_properties.isOpaque(chunk.blocks[idx])) {
                    light_map.sky_light[idx] = new_level;
                    if (tail < MAX_QUEUE) {
                        queue[tail] = .{ .x = @intCast(CHUNK_SIZE - 1), .y = @intCast(y), .z = @intCast(z), .dir = 0, .level = new_level };
                        tail += 1;
                    }
                }
            }
        }
    }
    // -X boundary: neighbor[2], their x=31 face
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |z| {
            const nl = getNeighborSkyLight(neighbor_lights, 2, CHUNK_SIZE - 1, y, z);
            if (nl > ATTENUATION) {
                const new_level = nl - ATTENUATION;
                const idx = chunkIndex(0, y, z);
                if (new_level > light_map.sky_light[idx] and !block_properties.isOpaque(chunk.blocks[idx])) {
                    light_map.sky_light[idx] = new_level;
                    if (tail < MAX_QUEUE) {
                        queue[tail] = .{ .x = 0, .y = @intCast(y), .z = @intCast(z), .dir = 1, .level = new_level };
                        tail += 1;
                    }
                }
            }
        }
    }
    // +Z boundary: neighbor[0], their z=0 face
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |x| {
            const nl = getNeighborSkyLight(neighbor_lights, 0, x, y, 0);
            if (nl > ATTENUATION) {
                const new_level = nl - ATTENUATION;
                const idx = chunkIndex(x, y, CHUNK_SIZE - 1);
                if (new_level > light_map.sky_light[idx] and !block_properties.isOpaque(chunk.blocks[idx])) {
                    light_map.sky_light[idx] = new_level;
                    if (tail < MAX_QUEUE) {
                        queue[tail] = .{ .x = @intCast(x), .y = @intCast(y), .z = @intCast(CHUNK_SIZE - 1), .dir = 4, .level = new_level };
                        tail += 1;
                    }
                }
            }
        }
    }
    // -Z boundary: neighbor[1], their z=31 face
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |x| {
            const nl = getNeighborSkyLight(neighbor_lights, 1, x, y, CHUNK_SIZE - 1);
            if (nl > ATTENUATION) {
                const new_level = nl - ATTENUATION;
                const idx = chunkIndex(x, y, 0);
                if (new_level > light_map.sky_light[idx] and !block_properties.isOpaque(chunk.blocks[idx])) {
                    light_map.sky_light[idx] = new_level;
                    if (tail < MAX_QUEUE) {
                        queue[tail] = .{ .x = @intCast(x), .y = @intCast(y), .z = 0, .dir = 5, .level = new_level };
                        tail += 1;
                    }
                }
            }
        }
    }
    // +Y boundary: neighbor[4], their y=0 face
    for (0..CHUNK_SIZE) |z| {
        for (0..CHUNK_SIZE) |x| {
            const nl = getNeighborSkyLight(neighbor_lights, 4, x, 0, z);
            if (nl > ATTENUATION) {
                const new_level = nl - ATTENUATION;
                const idx = chunkIndex(x, CHUNK_SIZE - 1, z);
                if (new_level > light_map.sky_light[idx] and !block_properties.isOpaque(chunk.blocks[idx])) {
                    light_map.sky_light[idx] = new_level;
                    if (tail < MAX_QUEUE) {
                        queue[tail] = .{ .x = @intCast(x), .y = @intCast(CHUNK_SIZE - 1), .z = @intCast(z), .dir = 2, .level = new_level };
                        tail += 1;
                    }
                }
            }
        }
    }
    // -Y boundary: neighbor[5], their y=31 face
    for (0..CHUNK_SIZE) |z| {
        for (0..CHUNK_SIZE) |x| {
            const nl = getNeighborSkyLight(neighbor_lights, 5, x, CHUNK_SIZE - 1, z);
            if (nl > ATTENUATION) {
                const new_level = nl - ATTENUATION;
                const idx = chunkIndex(x, 0, z);
                if (new_level > light_map.sky_light[idx] and !block_properties.isOpaque(chunk.blocks[idx])) {
                    light_map.sky_light[idx] = new_level;
                    if (tail < MAX_QUEUE) {
                        queue[tail] = .{ .x = @intCast(x), .y = 0, .z = @intCast(z), .dir = 3, .level = new_level };
                        tail += 1;
                    }
                }
            }
        }
    }

    // Phase 3: BFS propagation within chunk
    while (head < tail) {
        const e = queue[head];
        head += 1;

        for (0..6) |dir| {
            // Skip reverse direction (ScalableLux optimization)
            if (e.dir < 6 and dir == OPPOSITE_DIR[e.dir]) continue;

            const nx = @as(i32, e.x) + BFS_OFFSETS[dir][0];
            const ny = @as(i32, e.y) + BFS_OFFSETS[dir][1];
            const nz = @as(i32, e.z) + BFS_OFFSETS[dir][2];

            // Stay within chunk bounds
            if (nx < 0 or nx >= CHUNK_SIZE or ny < 0 or ny >= CHUNK_SIZE or nz < 0 or nz >= CHUNK_SIZE) continue;

            const ux: usize = @intCast(nx);
            const uy: usize = @intCast(ny);
            const uz: usize = @intCast(nz);

            if (block_properties.isOpaque(chunk.blocks[chunkIndex(ux, uy, uz)])) continue;

            const new_level = e.level -| ATTENUATION;
            if (new_level == 0) continue;

            const idx = chunkIndex(ux, uy, uz);
            if (new_level <= light_map.sky_light[idx]) continue;

            light_map.sky_light[idx] = new_level;
            if (tail < MAX_QUEUE) {
                queue[tail] = .{ .x = @intCast(nx), .y = @intCast(ny), .z = @intCast(nz), .dir = @intCast(dir), .level = new_level };
                tail += 1;
            }
        }
    }
}

fn computeBlockLight(
    chunk: *const WorldState.Chunk,
    neighbors: [6]?*const WorldState.Chunk,
    neighbor_lights: [6]?*const LightMap,
    light_map: *LightMap,
) void {
    _ = neighbors;

    var queue: [MAX_QUEUE]QueueEntry = undefined;
    var head: u32 = 0;
    var tail: u32 = 0;

    // Phase 1: Seed from emitters within chunk
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |z| {
            for (0..CHUNK_SIZE) |x| {
                const block = chunk.blocks[chunkIndex(x, y, z)];
                const emit = block_properties.emittedLight(block);
                if (emit[0] > 0 or emit[1] > 0 or emit[2] > 0) {
                    light_map.block_light[chunkIndex(x, y, z)] = emit;
                    if (tail < MAX_QUEUE) {
                        queue[tail] = .{
                            .x = @intCast(x),
                            .y = @intCast(y),
                            .z = @intCast(z),
                            .dir = 6, // no source direction
                            .r = emit[0],
                            .g = emit[1],
                            .b = emit[2],
                        };
                        tail += 1;
                    }
                }
            }
        }
    }

    // Phase 2: Seed from neighbor chunks' block light at boundaries
    // +X boundary: neighbor[3], their x=0 face
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |z| {
            const nl = getNeighborLight(neighbor_lights, 3, 0, y, z);
            seedBoundaryBlockLight(&queue, &tail, chunk, light_map, @intCast(CHUNK_SIZE - 1), @intCast(y), @intCast(z), 0, nl);
        }
    }
    // -X boundary: neighbor[2], their x=31 face
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |z| {
            const nl = getNeighborLight(neighbor_lights, 2, CHUNK_SIZE - 1, y, z);
            seedBoundaryBlockLight(&queue, &tail, chunk, light_map, 0, @intCast(y), @intCast(z), 1, nl);
        }
    }
    // +Z boundary: neighbor[0], their z=0 face
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |x| {
            const nl = getNeighborLight(neighbor_lights, 0, x, y, 0);
            seedBoundaryBlockLight(&queue, &tail, chunk, light_map, @intCast(x), @intCast(y), @intCast(CHUNK_SIZE - 1), 4, nl);
        }
    }
    // -Z boundary: neighbor[1], their z=31 face
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |x| {
            const nl = getNeighborLight(neighbor_lights, 1, x, y, CHUNK_SIZE - 1);
            seedBoundaryBlockLight(&queue, &tail, chunk, light_map, @intCast(x), @intCast(y), 0, 5, nl);
        }
    }
    // +Y boundary: neighbor[4], their y=0 face
    for (0..CHUNK_SIZE) |z| {
        for (0..CHUNK_SIZE) |x| {
            const nl = getNeighborLight(neighbor_lights, 4, x, 0, z);
            seedBoundaryBlockLight(&queue, &tail, chunk, light_map, @intCast(x), @intCast(CHUNK_SIZE - 1), @intCast(z), 2, nl);
        }
    }
    // -Y boundary: neighbor[5], their y=31 face
    for (0..CHUNK_SIZE) |z| {
        for (0..CHUNK_SIZE) |x| {
            const nl = getNeighborLight(neighbor_lights, 5, x, CHUNK_SIZE - 1, z);
            seedBoundaryBlockLight(&queue, &tail, chunk, light_map, @intCast(x), 0, @intCast(z), 3, nl);
        }
    }

    // Phase 3: BFS propagation within chunk
    while (head < tail) {
        const e = queue[head];
        head += 1;

        for (0..6) |dir| {
            if (e.dir < 6 and dir == OPPOSITE_DIR[e.dir]) continue;

            const nx = @as(i32, e.x) + BFS_OFFSETS[dir][0];
            const ny = @as(i32, e.y) + BFS_OFFSETS[dir][1];
            const nz = @as(i32, e.z) + BFS_OFFSETS[dir][2];

            if (nx < 0 or nx >= CHUNK_SIZE or ny < 0 or ny >= CHUNK_SIZE or nz < 0 or nz >= CHUNK_SIZE) continue;

            const ux: usize = @intCast(nx);
            const uy: usize = @intCast(ny);
            const uz: usize = @intCast(nz);

            if (block_properties.isOpaque(chunk.blocks[chunkIndex(ux, uy, uz)])) continue;

            const nr = e.r -| ATTENUATION;
            const ng = e.g -| ATTENUATION;
            const nb = e.b -| ATTENUATION;

            if (nr == 0 and ng == 0 and nb == 0) continue;

            const idx = chunkIndex(ux, uy, uz);
            const existing = &light_map.block_light[idx];
            if (nr <= existing[0] and ng <= existing[1] and nb <= existing[2]) continue;

            existing[0] = @max(existing[0], nr);
            existing[1] = @max(existing[1], ng);
            existing[2] = @max(existing[2], nb);

            if (tail < MAX_QUEUE) {
                queue[tail] = .{
                    .x = @intCast(nx),
                    .y = @intCast(ny),
                    .z = @intCast(nz),
                    .dir = @intCast(dir),
                    .r = existing[0],
                    .g = existing[1],
                    .b = existing[2],
                };
                tail += 1;
            }
        }
    }
}

fn seedBoundaryBlockLight(
    queue: *[MAX_QUEUE]QueueEntry,
    tail: *u32,
    chunk: *const WorldState.Chunk,
    light_map: *LightMap,
    x: i8,
    y: i8,
    z: i8,
    dir: u3,
    nl: [3]u8,
) void {
    const nr = nl[0] -| ATTENUATION;
    const ng = nl[1] -| ATTENUATION;
    const nb = nl[2] -| ATTENUATION;
    if (nr == 0 and ng == 0 and nb == 0) return;

    const ux: usize = @intCast(x);
    const uy: usize = @intCast(y);
    const uz: usize = @intCast(z);
    const idx = chunkIndex(ux, uy, uz);

    if (block_properties.isOpaque(chunk.blocks[idx])) return;

    const existing = &light_map.block_light[idx];
    if (nr <= existing[0] and ng <= existing[1] and nb <= existing[2]) return;

    existing[0] = @max(existing[0], nr);
    existing[1] = @max(existing[1], ng);
    existing[2] = @max(existing[2], nb);

    if (tail.* < MAX_QUEUE) {
        queue[tail.*] = .{
            .x = x,
            .y = y,
            .z = z,
            .dir = dir,
            .r = existing[0],
            .g = existing[1],
            .b = existing[2],
        };
        tail.* += 1;
    }
}
