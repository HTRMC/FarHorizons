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
    // Skip dirty neighbors — their data is stale and will be recomputed
    if (lm.dirty) return .{ 0, 0, 0 };
    return lm.block_light[chunkIndex(x, y, z)];
}

fn getNeighborSkyLight(neighbor_lights: [6]?*const LightMap, face: usize, x: usize, y: usize, z: usize) u8 {
    const lm = neighbor_lights[face] orelse return 0;
    if (lm.dirty) return 0;
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

/// Returns a 6-bit mask of faces that have nonzero boundary light (for cascade).
pub fn computeChunkLight(
    chunk: *const WorldState.Chunk,
    neighbors: [6]?*const WorldState.Chunk,
    neighbor_lights: [6]?*const LightMap,
    light_map: *LightMap,
) u6 {
    @memset(std.mem.asBytes(&light_map.block_light), 0);
    @memset(&light_map.sky_light, 0);

    computeSkyLight(chunk, neighbors, neighbor_lights, light_map);
    computeBlockLight(chunk, neighbors, neighbor_lights, light_map);

    light_map.dirty = false;

    // Check boundary faces for nonzero light > attenuation (can propagate further)
    var boundary_mask: u6 = 0;
    // +X face (3): check x=31
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |z| {
            const idx = chunkIndex(CHUNK_SIZE - 1, y, z);
            const bl = light_map.block_light[idx];
            if (bl[0] > ATTENUATION or bl[1] > ATTENUATION or bl[2] > ATTENUATION or light_map.sky_light[idx] > ATTENUATION) {
                boundary_mask |= (1 << 3);
                break;
            }
        }
        if (boundary_mask & (1 << 3) != 0) break;
    }
    // -X face (2): check x=0
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |z| {
            const idx = chunkIndex(0, y, z);
            const bl = light_map.block_light[idx];
            if (bl[0] > ATTENUATION or bl[1] > ATTENUATION or bl[2] > ATTENUATION or light_map.sky_light[idx] > ATTENUATION) {
                boundary_mask |= (1 << 2);
                break;
            }
        }
        if (boundary_mask & (1 << 2) != 0) break;
    }
    // +Z face (0): check z=31
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |x| {
            const idx = chunkIndex(x, y, CHUNK_SIZE - 1);
            const bl = light_map.block_light[idx];
            if (bl[0] > ATTENUATION or bl[1] > ATTENUATION or bl[2] > ATTENUATION or light_map.sky_light[idx] > ATTENUATION) {
                boundary_mask |= (1 << 0);
                break;
            }
        }
        if (boundary_mask & (1 << 0) != 0) break;
    }
    // -Z face (1): check z=0
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |x| {
            const idx = chunkIndex(x, y, 0);
            const bl = light_map.block_light[idx];
            if (bl[0] > ATTENUATION or bl[1] > ATTENUATION or bl[2] > ATTENUATION or light_map.sky_light[idx] > ATTENUATION) {
                boundary_mask |= (1 << 1);
                break;
            }
        }
        if (boundary_mask & (1 << 1) != 0) break;
    }
    // +Y face (4): check y=31
    for (0..CHUNK_SIZE) |z| {
        for (0..CHUNK_SIZE) |x| {
            const idx = chunkIndex(x, CHUNK_SIZE - 1, z);
            const bl = light_map.block_light[idx];
            if (bl[0] > ATTENUATION or bl[1] > ATTENUATION or bl[2] > ATTENUATION or light_map.sky_light[idx] > ATTENUATION) {
                boundary_mask |= (1 << 4);
                break;
            }
        }
        if (boundary_mask & (1 << 4) != 0) break;
    }
    // -Y face (5): check y=0
    for (0..CHUNK_SIZE) |z| {
        for (0..CHUNK_SIZE) |x| {
            const idx = chunkIndex(x, 0, z);
            const bl = light_map.block_light[idx];
            if (bl[0] > ATTENUATION or bl[1] > ATTENUATION or bl[2] > ATTENUATION or light_map.sky_light[idx] > ATTENUATION) {
                boundary_mask |= (1 << 5);
                break;
            }
        }
        if (boundary_mask & (1 << 5) != 0) break;
    }

    return boundary_mask;
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
    // Sky is open if: no chunk above, OR the above chunk's LightMap has full
    // sky light (255) at y=0 for this column (meaning sky reaches down to there).
    // This correctly handles multi-chunk terrain: cave ceilings block sky even
    // if the immediate block above is air.
    const above_lm: ?*const LightMap = neighbor_lights[4];
    const has_above = neighbors[4] != null;
    for (0..CHUNK_SIZE) |z| {
        for (0..CHUNK_SIZE) |x| {
            var sky_open = false;
            if (!has_above) {
                // No chunk above — sky is open
                sky_open = true;
            } else if (above_lm) |alm| {
                if (!alm.dirty) {
                    // Check if sky reaches the bottom of the above chunk at this column
                    sky_open = alm.sky_light[chunkIndex(x, 0, z)] == 255;
                }
                // If above LightMap is dirty, conservatively assume sky blocked
            }
            // If above chunk exists but has no LightMap, assume sky blocked

            if (sky_open) {
                // Also verify the block just above us isn't opaque
                const above_block = getBlock(chunk, neighbors, @intCast(x), CHUNK_SIZE, @intCast(z));
                if (block_properties.isOpaque(above_block)) continue;

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
    // +X boundary: neighbor[3], their x=0 face → light travels -X (dir=1)
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |z| {
            const nl = getNeighborSkyLight(neighbor_lights, 3, 0, y, z);
            if (nl > ATTENUATION) {
                const new_level = nl - ATTENUATION;
                const idx = chunkIndex(CHUNK_SIZE - 1, y, z);
                if (new_level > light_map.sky_light[idx] and !block_properties.isOpaque(chunk.blocks[idx])) {
                    light_map.sky_light[idx] = new_level;
                    if (tail < MAX_QUEUE) {
                        queue[tail] = .{ .x = @intCast(CHUNK_SIZE - 1), .y = @intCast(y), .z = @intCast(z), .dir = 1, .level = new_level };
                        tail += 1;
                    }
                }
            }
        }
    }
    // -X boundary: neighbor[2], their x=31 face → light travels +X (dir=0)
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |z| {
            const nl = getNeighborSkyLight(neighbor_lights, 2, CHUNK_SIZE - 1, y, z);
            if (nl > ATTENUATION) {
                const new_level = nl - ATTENUATION;
                const idx = chunkIndex(0, y, z);
                if (new_level > light_map.sky_light[idx] and !block_properties.isOpaque(chunk.blocks[idx])) {
                    light_map.sky_light[idx] = new_level;
                    if (tail < MAX_QUEUE) {
                        queue[tail] = .{ .x = 0, .y = @intCast(y), .z = @intCast(z), .dir = 0, .level = new_level };
                        tail += 1;
                    }
                }
            }
        }
    }
    // +Z boundary: neighbor[0], their z=0 face → light travels -Z (dir=5)
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |x| {
            const nl = getNeighborSkyLight(neighbor_lights, 0, x, y, 0);
            if (nl > ATTENUATION) {
                const new_level = nl - ATTENUATION;
                const idx = chunkIndex(x, y, CHUNK_SIZE - 1);
                if (new_level > light_map.sky_light[idx] and !block_properties.isOpaque(chunk.blocks[idx])) {
                    light_map.sky_light[idx] = new_level;
                    if (tail < MAX_QUEUE) {
                        queue[tail] = .{ .x = @intCast(x), .y = @intCast(y), .z = @intCast(CHUNK_SIZE - 1), .dir = 5, .level = new_level };
                        tail += 1;
                    }
                }
            }
        }
    }
    // -Z boundary: neighbor[1], their z=31 face → light travels +Z (dir=4)
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |x| {
            const nl = getNeighborSkyLight(neighbor_lights, 1, x, y, CHUNK_SIZE - 1);
            if (nl > ATTENUATION) {
                const new_level = nl - ATTENUATION;
                const idx = chunkIndex(x, y, 0);
                if (new_level > light_map.sky_light[idx] and !block_properties.isOpaque(chunk.blocks[idx])) {
                    light_map.sky_light[idx] = new_level;
                    if (tail < MAX_QUEUE) {
                        queue[tail] = .{ .x = @intCast(x), .y = @intCast(y), .z = 0, .dir = 4, .level = new_level };
                        tail += 1;
                    }
                }
            }
        }
    }
    // +Y boundary: neighbor[4], their y=0 face → light travels -Y (dir=3)
    for (0..CHUNK_SIZE) |z| {
        for (0..CHUNK_SIZE) |x| {
            const nl = getNeighborSkyLight(neighbor_lights, 4, x, 0, z);
            if (nl > ATTENUATION) {
                const new_level = nl - ATTENUATION;
                const idx = chunkIndex(x, CHUNK_SIZE - 1, z);
                if (new_level > light_map.sky_light[idx] and !block_properties.isOpaque(chunk.blocks[idx])) {
                    light_map.sky_light[idx] = new_level;
                    if (tail < MAX_QUEUE) {
                        queue[tail] = .{ .x = @intCast(x), .y = @intCast(CHUNK_SIZE - 1), .z = @intCast(z), .dir = 3, .level = new_level };
                        tail += 1;
                    }
                }
            }
        }
    }
    // -Y boundary: neighbor[5], their y=31 face → light travels +Y (dir=2)
    for (0..CHUNK_SIZE) |z| {
        for (0..CHUNK_SIZE) |x| {
            const nl = getNeighborSkyLight(neighbor_lights, 5, x, CHUNK_SIZE - 1, z);
            if (nl > ATTENUATION) {
                const new_level = nl - ATTENUATION;
                const idx = chunkIndex(x, 0, z);
                if (new_level > light_map.sky_light[idx] and !block_properties.isOpaque(chunk.blocks[idx])) {
                    light_map.sky_light[idx] = new_level;
                    if (tail < MAX_QUEUE) {
                        queue[tail] = .{ .x = @intCast(x), .y = 0, .z = @intCast(z), .dir = 2, .level = new_level };
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
    // +X boundary: neighbor[3], their x=0 face → light travels -X (dir=1)
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |z| {
            const nl = getNeighborLight(neighbor_lights, 3, 0, y, z);
            seedBoundaryBlockLight(&queue, &tail, chunk, light_map, @intCast(CHUNK_SIZE - 1), @intCast(y), @intCast(z), 1, nl);
        }
    }
    // -X boundary: neighbor[2], their x=31 face → light travels +X (dir=0)
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |z| {
            const nl = getNeighborLight(neighbor_lights, 2, CHUNK_SIZE - 1, y, z);
            seedBoundaryBlockLight(&queue, &tail, chunk, light_map, 0, @intCast(y), @intCast(z), 0, nl);
        }
    }
    // +Z boundary: neighbor[0], their z=0 face → light travels -Z (dir=5)
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |x| {
            const nl = getNeighborLight(neighbor_lights, 0, x, y, 0);
            seedBoundaryBlockLight(&queue, &tail, chunk, light_map, @intCast(x), @intCast(y), @intCast(CHUNK_SIZE - 1), 5, nl);
        }
    }
    // -Z boundary: neighbor[1], their z=31 face → light travels +Z (dir=4)
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |x| {
            const nl = getNeighborLight(neighbor_lights, 1, x, y, CHUNK_SIZE - 1);
            seedBoundaryBlockLight(&queue, &tail, chunk, light_map, @intCast(x), @intCast(y), 0, 4, nl);
        }
    }
    // +Y boundary: neighbor[4], their y=0 face → light travels -Y (dir=3)
    for (0..CHUNK_SIZE) |z| {
        for (0..CHUNK_SIZE) |x| {
            const nl = getNeighborLight(neighbor_lights, 4, x, 0, z);
            seedBoundaryBlockLight(&queue, &tail, chunk, light_map, @intCast(x), @intCast(CHUNK_SIZE - 1), @intCast(z), 3, nl);
        }
    }
    // -Y boundary: neighbor[5], their y=31 face → light travels +Y (dir=2)
    for (0..CHUNK_SIZE) |z| {
        for (0..CHUNK_SIZE) |x| {
            const nl = getNeighborLight(neighbor_lights, 5, x, CHUNK_SIZE - 1, z);
            seedBoundaryBlockLight(&queue, &tail, chunk, light_map, @intCast(x), 0, @intCast(z), 2, nl);
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

// ─── Tests ───

const testing = std.testing;

const Chunk = WorldState.Chunk;

const no_neighbors: [6]?*const Chunk = .{ null, null, null, null, null, null };
const no_light_neighbors: [6]?*const LightMap = .{ null, null, null, null, null, null };

fn allocChunk() !*Chunk {
    const chunk = try testing.allocator.create(Chunk);
    chunk.* = .{ .blocks = .{.air} ** BLOCKS_PER_CHUNK };
    return chunk;
}

fn allocLightMap() !*LightMap {
    const lm = try testing.allocator.create(LightMap);
    lm.clear();
    return lm;
}

test "glowstone emitter lights surrounding blocks" {
    const chunk = try allocChunk();
    defer testing.allocator.destroy(chunk);
    chunk.blocks[chunkIndex(16, 16, 16)] = .glowstone;

    const lm = try allocLightMap();
    defer testing.allocator.destroy(lm);
    _ = computeChunkLight(chunk, no_neighbors, no_light_neighbors, lm);

    // Emitter itself should have full light
    const emit = lm.block_light[chunkIndex(16, 16, 16)];
    try testing.expectEqual(@as(u8, 255), emit[0]);
    try testing.expectEqual(@as(u8, 200), emit[1]);
    try testing.expectEqual(@as(u8, 100), emit[2]);

    // Adjacent block should have emitter - ATTENUATION
    const adj = lm.block_light[chunkIndex(17, 16, 16)];
    try testing.expectEqual(@as(u8, 255 - ATTENUATION), adj[0]);
    try testing.expectEqual(@as(u8, 200 - ATTENUATION), adj[1]);
    try testing.expectEqual(@as(u8, 100 - ATTENUATION), adj[2]);

    // Two blocks away
    const adj2 = lm.block_light[chunkIndex(18, 16, 16)];
    try testing.expectEqual(@as(u8, 255 - 2 * ATTENUATION), adj2[0]);
}

test "block light attenuates to zero" {
    const chunk = try allocChunk();
    defer testing.allocator.destroy(chunk);
    chunk.blocks[chunkIndex(16, 16, 16)] = .glowstone;

    const lm = try allocLightMap();
    defer testing.allocator.destroy(lm);
    _ = computeChunkLight(chunk, no_neighbors, no_light_neighbors, lm);

    // Glowstone emits 100 on blue channel. 100/8 = 12.5 steps, so at distance 13 should be 0.
    const far = lm.block_light[chunkIndex(16, 16, 16 + 13)];
    try testing.expectEqual(@as(u8, 0), far[2]);

    // But distance 12 should still have some
    const near = lm.block_light[chunkIndex(16, 16, 16 + 12)];
    try testing.expect(near[2] > 0);
}

test "opaque block stops light propagation" {
    const chunk = try allocChunk();
    defer testing.allocator.destroy(chunk);
    chunk.blocks[chunkIndex(16, 16, 16)] = .glowstone;
    chunk.blocks[chunkIndex(17, 16, 16)] = .stone;

    const lm = try allocLightMap();
    defer testing.allocator.destroy(lm);
    _ = computeChunkLight(chunk, no_neighbors, no_light_neighbors, lm);

    const behind = lm.block_light[chunkIndex(18, 16, 16)];
    const no_wall_level = 255 - 2 * ATTENUATION;
    try testing.expect(behind[0] < no_wall_level);
}

test "sky light fills air chunk with no above neighbor" {
    const chunk = try allocChunk();
    defer testing.allocator.destroy(chunk);

    const lm = try allocLightMap();
    defer testing.allocator.destroy(lm);
    _ = computeChunkLight(chunk, no_neighbors, no_light_neighbors, lm);

    try testing.expectEqual(@as(u8, 255), lm.sky_light[chunkIndex(0, 0, 0)]);
    try testing.expectEqual(@as(u8, 255), lm.sky_light[chunkIndex(16, 16, 16)]);
    try testing.expectEqual(@as(u8, 255), lm.sky_light[chunkIndex(CHUNK_SIZE - 1, CHUNK_SIZE - 1, CHUNK_SIZE - 1)]);
}

test "sky light blocked by opaque block above" {
    const chunk = try allocChunk();
    defer testing.allocator.destroy(chunk);
    for (0..CHUNK_SIZE) |z| {
        for (0..CHUNK_SIZE) |x| {
            chunk.blocks[chunkIndex(x, CHUNK_SIZE - 1, z)] = .stone;
        }
    }

    const lm = try allocLightMap();
    defer testing.allocator.destroy(lm);
    _ = computeChunkLight(chunk, no_neighbors, no_light_neighbors, lm);

    try testing.expectEqual(@as(u8, 0), lm.sky_light[chunkIndex(16, 0, 16)]);
}

test "block light propagates across chunk boundary via neighbor light map" {
    const chunk_a = try allocChunk();
    defer testing.allocator.destroy(chunk_a);
    chunk_a.blocks[chunkIndex(CHUNK_SIZE - 1, 16, 16)] = .glowstone;

    const lm_a = try allocLightMap();
    defer testing.allocator.destroy(lm_a);
    _ = computeChunkLight(chunk_a, no_neighbors, no_light_neighbors, lm_a);

    try testing.expectEqual(@as(u8, 255), lm_a.block_light[chunkIndex(CHUNK_SIZE - 1, 16, 16)][0]);

    const chunk_b = try allocChunk();
    defer testing.allocator.destroy(chunk_b);
    const lm_b = try allocLightMap();
    defer testing.allocator.destroy(lm_b);

    var b_neighbor_lights = no_light_neighbors;
    b_neighbor_lights[2] = lm_a;
    var b_neighbors = no_neighbors;
    b_neighbors[2] = chunk_a;

    _ = computeChunkLight(chunk_b, b_neighbors, b_neighbor_lights, lm_b);

    const received = lm_b.block_light[chunkIndex(0, 16, 16)];
    try testing.expectEqual(@as(u8, 255 - ATTENUATION), received[0]);

    const further = lm_b.block_light[chunkIndex(1, 16, 16)];
    try testing.expectEqual(@as(u8, 255 - 2 * ATTENUATION), further[0]);
}

test "sky light propagates across chunk boundary via column scan" {
    // Chunk A (all air, no above neighbor) has full skylight
    const chunk_a = try allocChunk();
    defer testing.allocator.destroy(chunk_a);
    const lm_a = try allocLightMap();
    defer testing.allocator.destroy(lm_a);
    _ = computeChunkLight(chunk_a, no_neighbors, no_light_neighbors, lm_a);

    // Chunk B (all air) with chunk A as +Y neighbor
    // Column scan sees non-opaque block at y=0 in chunk_a → sky open → fills all blocks
    const chunk_b = try allocChunk();
    defer testing.allocator.destroy(chunk_b);

    var b_neighbors = no_neighbors;
    b_neighbors[4] = chunk_a;
    var b_neighbor_lights = no_light_neighbors;
    b_neighbor_lights[4] = lm_a;

    const lm_b = try allocLightMap();
    defer testing.allocator.destroy(lm_b);
    _ = computeChunkLight(chunk_b, b_neighbors, b_neighbor_lights, lm_b);

    try testing.expectEqual(@as(u8, 255), lm_b.sky_light[chunkIndex(16, CHUNK_SIZE - 1, 16)]);
    try testing.expectEqual(@as(u8, 255), lm_b.sky_light[chunkIndex(16, 0, 16)]);
}

test "sky light propagates laterally across chunk boundary" {
    // Chunk A has full skylight (no above, all air)
    const chunk_a = try allocChunk();
    defer testing.allocator.destroy(chunk_a);
    const lm_a = try allocLightMap();
    defer testing.allocator.destroy(lm_a);
    _ = computeChunkLight(chunk_a, no_neighbors, no_light_neighbors, lm_a);

    // Chunk B has an opaque ceiling and no sky access — but chunk A is its -X neighbor
    // Sky light from A should propagate through boundary at x=0
    const chunk_b = try allocChunk();
    defer testing.allocator.destroy(chunk_b);
    // Add above neighbor to block column scan
    const chunk_above = try allocChunk();
    defer testing.allocator.destroy(chunk_above);
    // Fill chunk_above bottom layer with stone to block sky
    for (0..CHUNK_SIZE) |z| {
        for (0..CHUNK_SIZE) |x| {
            chunk_above.blocks[chunkIndex(x, 0, z)] = .stone;
        }
    }
    var b_neighbors = no_neighbors;
    b_neighbors[4] = chunk_above; // +Y neighbor has stone floor → blocks sky
    b_neighbors[2] = chunk_a; // -X neighbor has sky light
    var b_neighbor_lights = no_light_neighbors;
    b_neighbor_lights[2] = lm_a;

    const lm_b = try allocLightMap();
    defer testing.allocator.destroy(lm_b);
    _ = computeChunkLight(chunk_b, b_neighbors, b_neighbor_lights, lm_b);

    // x=0 in chunk B should receive sky from chunk A's x=31 (255 - 8 = 247)
    const received = lm_b.sky_light[chunkIndex(0, 16, 16)];
    try testing.expectEqual(@as(u8, 255 - ATTENUATION), received);

    // Should propagate further into chunk B
    const further = lm_b.sky_light[chunkIndex(1, 16, 16)];
    try testing.expectEqual(@as(u8, 255 - 2 * ATTENUATION), further);
}

test "boundary mask set for face with light above attenuation" {
    const chunk = try allocChunk();
    defer testing.allocator.destroy(chunk);
    chunk.blocks[chunkIndex(CHUNK_SIZE - 1, 16, 16)] = .glowstone;

    const lm = try allocLightMap();
    defer testing.allocator.destroy(lm);
    const mask = computeChunkLight(chunk, no_neighbors, no_light_neighbors, lm);

    try testing.expect(mask & (1 << 3) != 0);
}

test "boundary mask not set for face with no light" {
    const chunk = try allocChunk();
    defer testing.allocator.destroy(chunk);
    chunk.blocks[chunkIndex(16, 16, 16)] = .glowstone;

    const lm = try allocLightMap();
    defer testing.allocator.destroy(lm);
    const mask = computeChunkLight(chunk, no_neighbors, no_light_neighbors, lm);

    // Red channel 255 reaches all boundaries (255 - 16*8 = 127 > 8)
    try testing.expectEqual(@as(u6, 0b111111), mask);
}

test "dirty flag cleared after compute" {
    const chunk = try allocChunk();
    defer testing.allocator.destroy(chunk);
    const lm = try allocLightMap();
    defer testing.allocator.destroy(lm);
    try testing.expect(lm.dirty);

    _ = computeChunkLight(chunk, no_neighbors, no_light_neighbors, lm);
    try testing.expect(!lm.dirty);
}

test "bidirectional boundary propagation" {
    const chunk_a = try allocChunk();
    defer testing.allocator.destroy(chunk_a);
    chunk_a.blocks[chunkIndex(CHUNK_SIZE - 2, 16, 16)] = .glowstone;

    const lm_a = try allocLightMap();
    defer testing.allocator.destroy(lm_a);
    _ = computeChunkLight(chunk_a, no_neighbors, no_light_neighbors, lm_a);

    const chunk_b = try allocChunk();
    defer testing.allocator.destroy(chunk_b);
    const lm_b = try allocLightMap();
    defer testing.allocator.destroy(lm_b);
    var b_neighbor_lights = no_light_neighbors;
    b_neighbor_lights[2] = lm_a;
    var b_neighbors = no_neighbors;
    b_neighbors[2] = chunk_a;

    _ = computeChunkLight(chunk_b, b_neighbors, b_neighbor_lights, lm_b);

    // Light at chunk A boundary (x=31): 255 - 1*8 = 247
    // Light entering chunk B at x=0: 247 - 8 = 239
    const at_b_0 = lm_b.block_light[chunkIndex(0, 16, 16)];
    try testing.expectEqual(@as(u8, 255 - 2 * ATTENUATION), at_b_0[0]);

    // Light at x=5 in chunk B: 255 - 7*8 = 199
    const at_b_5 = lm_b.block_light[chunkIndex(5, 16, 16)];
    try testing.expectEqual(@as(u8, 255 - 7 * ATTENUATION), at_b_5[0]);
}
