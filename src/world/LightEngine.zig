const std = @import("std");
const WorldState = @import("WorldState.zig");
const LightMapMod = @import("LightMap.zig");
const LightMap = LightMapMod.LightMap;
const LightBorderSnapshot = LightMapMod.LightBorderSnapshot;
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

fn getNeighborLight(neighbor_borders: [6]LightBorderSnapshot, face: usize, border_idx: usize) [3]u8 {
    if (!neighbor_borders[face].valid) return .{ 0, 0, 0 };
    return neighbor_borders[face].block[border_idx];
}

fn getNeighborSkyLight(neighbor_borders: [6]LightBorderSnapshot, face: usize, border_idx: usize) u8 {
    if (!neighbor_borders[face].valid) return 0;
    return neighbor_borders[face].sky[border_idx];
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
    neighbor_borders: [6]LightBorderSnapshot,
    light_map: *LightMap,
    chunk_cy: i32,
    surface_heights: ?*const [CHUNK_SIZE * CHUNK_SIZE]i32,
) u6 {
    light_map.clear();

    computeSkyLight(chunk, neighbors, neighbor_borders, light_map, chunk_cy, surface_heights);
    computeBlockLight(chunk, neighbors, neighbor_borders, light_map);

    light_map.dirty = false;

    // Check boundary faces for nonzero light > attenuation (can propagate further)
    var boundary_mask: u6 = 0;
    // +X face (3): check x=31
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |z| {
            const idx = chunkIndex(CHUNK_SIZE - 1, y, z);
            const bl = light_map.block_light.get(idx);
            if (bl[0] > ATTENUATION or bl[1] > ATTENUATION or bl[2] > ATTENUATION or light_map.sky_light.get(idx) > ATTENUATION) {
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
            const bl = light_map.block_light.get(idx);
            if (bl[0] > ATTENUATION or bl[1] > ATTENUATION or bl[2] > ATTENUATION or light_map.sky_light.get(idx) > ATTENUATION) {
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
            const bl = light_map.block_light.get(idx);
            if (bl[0] > ATTENUATION or bl[1] > ATTENUATION or bl[2] > ATTENUATION or light_map.sky_light.get(idx) > ATTENUATION) {
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
            const bl = light_map.block_light.get(idx);
            if (bl[0] > ATTENUATION or bl[1] > ATTENUATION or bl[2] > ATTENUATION or light_map.sky_light.get(idx) > ATTENUATION) {
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
            const bl = light_map.block_light.get(idx);
            if (bl[0] > ATTENUATION or bl[1] > ATTENUATION or bl[2] > ATTENUATION or light_map.sky_light.get(idx) > ATTENUATION) {
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
            const bl = light_map.block_light.get(idx);
            if (bl[0] > ATTENUATION or bl[1] > ATTENUATION or bl[2] > ATTENUATION or light_map.sky_light.get(idx) > ATTENUATION) {
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
    _: [6]?*const WorldState.Chunk,
    neighbor_borders: [6]LightBorderSnapshot,
    light_map: *LightMap,
    chunk_cy: i32,
    surface_heights: ?*const [CHUNK_SIZE * CHUNK_SIZE]i32,
) void {
    var queue: [MAX_QUEUE]SkyQueueEntry = undefined;
    var head: u32 = 0;
    var tail: u32 = 0;

    // Phase 1: Column fill using pre-computed surface height map.
    // For each (x,z) column, sky light (255) fills all non-opaque blocks whose
    // world Y is above the surface height (highest opaque block in the column).
    // Downward propagation through air has zero attenuation (like Cubyz).
    const chunk_base_y: i32 = chunk_cy * @as(i32, CHUNK_SIZE);
    for (0..CHUNK_SIZE) |z| {
        for (0..CHUNK_SIZE) |x| {
            const col_idx = z * CHUNK_SIZE + x;
            const sh: i32 = if (surface_heights) |sh| sh[col_idx] else std.math.minInt(i32);

            var y: i32 = CHUNK_SIZE - 1;
            while (y >= 0) : (y -= 1) {
                const world_y = chunk_base_y + y;
                if (world_y <= sh) break; // at or below surface — no sky
                const uy: usize = @intCast(y);
                if (block_properties.isOpaque(chunk.blocks[chunkIndex(x, uy, z)])) break;
                light_map.sky_light.set(chunkIndex(x, uy, z), 255);
                if (tail < MAX_QUEUE) {
                    queue[tail] = .{ .x = @intCast(x), .y = @intCast(y), .z = @intCast(z), .dir = 6, .level = 255 };
                    tail += 1;
                }
            }
        }
    }

    // Phase 2: Seed from neighbor chunks' sky light at boundaries
    // +X boundary: neighbor[3], their x=0 face → light travels -X (dir=1)
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |z| {
            const nl = getNeighborSkyLight(neighbor_borders, 3, y * CHUNK_SIZE + z);
            if (nl > ATTENUATION) {
                const new_level = nl - ATTENUATION;
                const idx = chunkIndex(CHUNK_SIZE - 1, y, z);
                if (new_level > light_map.sky_light.get(idx) and !block_properties.isOpaque(chunk.blocks[idx])) {
                    light_map.sky_light.set(idx, new_level);
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
            const nl = getNeighborSkyLight(neighbor_borders, 2, y * CHUNK_SIZE + z);
            if (nl > ATTENUATION) {
                const new_level = nl - ATTENUATION;
                const idx = chunkIndex(0, y, z);
                if (new_level > light_map.sky_light.get(idx) and !block_properties.isOpaque(chunk.blocks[idx])) {
                    light_map.sky_light.set(idx, new_level);
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
            const nl = getNeighborSkyLight(neighbor_borders, 0, y * CHUNK_SIZE + x);
            if (nl > ATTENUATION) {
                const new_level = nl - ATTENUATION;
                const idx = chunkIndex(x, y, CHUNK_SIZE - 1);
                if (new_level > light_map.sky_light.get(idx) and !block_properties.isOpaque(chunk.blocks[idx])) {
                    light_map.sky_light.set(idx, new_level);
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
            const nl = getNeighborSkyLight(neighbor_borders, 1, y * CHUNK_SIZE + x);
            if (nl > ATTENUATION) {
                const new_level = nl - ATTENUATION;
                const idx = chunkIndex(x, y, 0);
                if (new_level > light_map.sky_light.get(idx) and !block_properties.isOpaque(chunk.blocks[idx])) {
                    light_map.sky_light.set(idx, new_level);
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
            const nl = getNeighborSkyLight(neighbor_borders, 4, z * CHUNK_SIZE + x);
            if (nl > ATTENUATION) {
                const new_level = nl - ATTENUATION;
                const idx = chunkIndex(x, CHUNK_SIZE - 1, z);
                if (new_level > light_map.sky_light.get(idx) and !block_properties.isOpaque(chunk.blocks[idx])) {
                    light_map.sky_light.set(idx, new_level);
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
            const nl = getNeighborSkyLight(neighbor_borders, 5, z * CHUNK_SIZE + x);
            if (nl > ATTENUATION) {
                const new_level = nl - ATTENUATION;
                const idx = chunkIndex(x, 0, z);
                if (new_level > light_map.sky_light.get(idx) and !block_properties.isOpaque(chunk.blocks[idx])) {
                    light_map.sky_light.set(idx, new_level);
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
            if (new_level <= light_map.sky_light.get(idx)) continue;

            light_map.sky_light.set(idx, new_level);
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
    neighbor_borders: [6]LightBorderSnapshot,
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
                    light_map.block_light.set(chunkIndex(x, y, z), emit);
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
            const nl = getNeighborLight(neighbor_borders, 3, y * CHUNK_SIZE + z);
            seedBoundaryBlockLight(&queue, &tail, chunk, light_map, @intCast(CHUNK_SIZE - 1), @intCast(y), @intCast(z), 1, nl);
        }
    }
    // -X boundary: neighbor[2], their x=31 face → light travels +X (dir=0)
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |z| {
            const nl = getNeighborLight(neighbor_borders, 2, y * CHUNK_SIZE + z);
            seedBoundaryBlockLight(&queue, &tail, chunk, light_map, 0, @intCast(y), @intCast(z), 0, nl);
        }
    }
    // +Z boundary: neighbor[0], their z=0 face → light travels -Z (dir=5)
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |x| {
            const nl = getNeighborLight(neighbor_borders, 0, y * CHUNK_SIZE + x);
            seedBoundaryBlockLight(&queue, &tail, chunk, light_map, @intCast(x), @intCast(y), @intCast(CHUNK_SIZE - 1), 5, nl);
        }
    }
    // -Z boundary: neighbor[1], their z=31 face → light travels +Z (dir=4)
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |x| {
            const nl = getNeighborLight(neighbor_borders, 1, y * CHUNK_SIZE + x);
            seedBoundaryBlockLight(&queue, &tail, chunk, light_map, @intCast(x), @intCast(y), 0, 4, nl);
        }
    }
    // +Y boundary: neighbor[4], their y=0 face → light travels -Y (dir=3)
    for (0..CHUNK_SIZE) |z| {
        for (0..CHUNK_SIZE) |x| {
            const nl = getNeighborLight(neighbor_borders, 4, z * CHUNK_SIZE + x);
            seedBoundaryBlockLight(&queue, &tail, chunk, light_map, @intCast(x), @intCast(CHUNK_SIZE - 1), @intCast(z), 3, nl);
        }
    }
    // -Y boundary: neighbor[5], their y=31 face → light travels +Y (dir=2)
    for (0..CHUNK_SIZE) |z| {
        for (0..CHUNK_SIZE) |x| {
            const nl = getNeighborLight(neighbor_borders, 5, z * CHUNK_SIZE + x);
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
            const existing = light_map.block_light.get(idx);
            if (nr <= existing[0] and ng <= existing[1] and nb <= existing[2]) continue;

            const updated = [3]u8{
                @max(existing[0], nr),
                @max(existing[1], ng),
                @max(existing[2], nb),
            };
            light_map.block_light.set(idx, updated);

            if (tail < MAX_QUEUE) {
                queue[tail] = .{
                    .x = @intCast(nx),
                    .y = @intCast(ny),
                    .z = @intCast(nz),
                    .dir = @intCast(dir),
                    .r = updated[0],
                    .g = updated[1],
                    .b = updated[2],
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

    const existing = light_map.block_light.get(idx);
    if (nr <= existing[0] and ng <= existing[1] and nb <= existing[2]) return;

    const updated = [3]u8{
        @max(existing[0], nr),
        @max(existing[1], ng),
        @max(existing[2], nb),
    };
    light_map.block_light.set(idx, updated);

    if (tail.* < MAX_QUEUE) {
        queue[tail.*] = .{
            .x = x,
            .y = y,
            .z = z,
            .dir = dir,
            .r = updated[0],
            .g = updated[1],
            .b = updated[2],
        };
        tail.* += 1;
    }
}

// ─── Tests ───

const testing = std.testing;

const Chunk = WorldState.Chunk;

const no_neighbors: [6]?*const Chunk = .{ null, null, null, null, null, null };
const no_light_neighbors: [6]?*const LightMap = .{ null, null, null, null, null, null };
const no_borders: [6]LightBorderSnapshot = .{LightBorderSnapshot.empty} ** 6;

fn allocChunk() !*Chunk {
    const chunk = try testing.allocator.create(Chunk);
    chunk.* = .{ .blocks = .{.air} ** BLOCKS_PER_CHUNK };
    return chunk;
}

fn allocLightMap() !*LightMap {
    const lm = try testing.allocator.create(LightMap);
    lm.* = LightMap.init(testing.allocator);
    return lm;
}

fn freeLightMap(lm: *LightMap) void {
    lm.deinit();
    testing.allocator.destroy(lm);
}

test "glowstone emitter lights surrounding blocks" {
    const chunk = try allocChunk();
    defer testing.allocator.destroy(chunk);
    chunk.blocks[chunkIndex(16, 16, 16)] = .glowstone;

    const lm = try allocLightMap();
    defer freeLightMap(lm);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm, 0, null);

    // Emitter itself should have full light
    const emit = lm.block_light.get(chunkIndex(16, 16, 16));
    try testing.expectEqual(@as(u8, 255), emit[0]);
    try testing.expectEqual(@as(u8, 200), emit[1]);
    try testing.expectEqual(@as(u8, 100), emit[2]);

    // Adjacent block should have emitter - ATTENUATION
    const adj = lm.block_light.get(chunkIndex(17, 16, 16));
    try testing.expectEqual(@as(u8, 255 - ATTENUATION), adj[0]);
    try testing.expectEqual(@as(u8, 200 - ATTENUATION), adj[1]);
    try testing.expectEqual(@as(u8, 100 - ATTENUATION), adj[2]);

    // Two blocks away
    const adj2 = lm.block_light.get(chunkIndex(18, 16, 16));
    try testing.expectEqual(@as(u8, 255 - 2 * ATTENUATION), adj2[0]);
}

test "block light attenuates to zero" {
    const chunk = try allocChunk();
    defer testing.allocator.destroy(chunk);
    chunk.blocks[chunkIndex(16, 16, 16)] = .glowstone;

    const lm = try allocLightMap();
    defer freeLightMap(lm);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm, 0, null);

    // Glowstone emits 100 on blue channel. 100/8 = 12.5 steps, so at distance 13 should be 0.
    const far = lm.block_light.get(chunkIndex(16, 16, 16 + 13));
    try testing.expectEqual(@as(u8, 0), far[2]);

    // But distance 12 should still have some
    const near = lm.block_light.get(chunkIndex(16, 16, 16 + 12));
    try testing.expect(near[2] > 0);
}

test "opaque block stops light propagation" {
    const chunk = try allocChunk();
    defer testing.allocator.destroy(chunk);
    chunk.blocks[chunkIndex(16, 16, 16)] = .glowstone;
    chunk.blocks[chunkIndex(17, 16, 16)] = .stone;

    const lm = try allocLightMap();
    defer freeLightMap(lm);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm, 0, null);

    const behind = lm.block_light.get(chunkIndex(18, 16, 16));
    const no_wall_level = 255 - 2 * ATTENUATION;
    try testing.expect(behind[0] < no_wall_level);
}

test "sky light fills air chunk with no above neighbor" {
    const chunk = try allocChunk();
    defer testing.allocator.destroy(chunk);

    const lm = try allocLightMap();
    defer freeLightMap(lm);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm, 0, null);

    try testing.expectEqual(@as(u8, 255), lm.sky_light.get(chunkIndex(0, 0, 0)));
    try testing.expectEqual(@as(u8, 255), lm.sky_light.get(chunkIndex(16, 16, 16)));
    try testing.expectEqual(@as(u8, 255), lm.sky_light.get(chunkIndex(CHUNK_SIZE - 1, CHUNK_SIZE - 1, CHUNK_SIZE - 1)));
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
    defer freeLightMap(lm);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm, 0, null);

    try testing.expectEqual(@as(u8, 0), lm.sky_light.get(chunkIndex(16, 0, 16)));
}

test "block light propagates across chunk boundary via neighbor light map" {
    const chunk_a = try allocChunk();
    defer testing.allocator.destroy(chunk_a);
    chunk_a.blocks[chunkIndex(CHUNK_SIZE - 1, 16, 16)] = .glowstone;

    const lm_a = try allocLightMap();
    defer freeLightMap(lm_a);
    _ = computeChunkLight(chunk_a, no_neighbors, no_borders, lm_a, 0, null);

    try testing.expectEqual(@as(u8, 255), lm_a.block_light.get(chunkIndex(CHUNK_SIZE - 1, 16, 16))[0]);

    const chunk_b = try allocChunk();
    defer testing.allocator.destroy(chunk_b);
    const lm_b = try allocLightMap();
    defer freeLightMap(lm_b);

    var b_neighbor_lights = no_light_neighbors;
    b_neighbor_lights[2] = lm_a;
    const b_borders = LightMapMod.snapshotNeighborBorders(b_neighbor_lights);
    var b_neighbors = no_neighbors;
    b_neighbors[2] = chunk_a;

    _ = computeChunkLight(chunk_b, b_neighbors, b_borders, lm_b, 0, null);

    const received = lm_b.block_light.get(chunkIndex(0, 16, 16));
    try testing.expectEqual(@as(u8, 255 - ATTENUATION), received[0]);

    const further = lm_b.block_light.get(chunkIndex(1, 16, 16));
    try testing.expectEqual(@as(u8, 255 - 2 * ATTENUATION), further[0]);
}

test "sky light propagates vertically via surface height map" {
    // Chunk at cy=-1 (world y -32 to -1), no surface above → all sky
    const chunk = try allocChunk();
    defer testing.allocator.destroy(chunk);

    const lm = try allocLightMap();
    defer freeLightMap(lm);
    // Surface height = MIN means no opaque blocks anywhere → sky open everywhere
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm, -1, null);

    try testing.expectEqual(@as(u8, 255), lm.sky_light.get(chunkIndex(16, CHUNK_SIZE - 1, 16)));
    try testing.expectEqual(@as(u8, 255), lm.sky_light.get(chunkIndex(16, 0, 16)));
}

test "surface height blocks sky in chunk below surface" {
    // Chunk at cy=0 (world y 0-31), surface height at y=50 → all blocks below surface
    const chunk = try allocChunk();
    defer testing.allocator.destroy(chunk);

    var surface: [CHUNK_SIZE * CHUNK_SIZE]i32 = undefined;
    @memset(&surface, 50); // surface at y=50, entire chunk is below

    const lm = try allocLightMap();
    defer freeLightMap(lm);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm, 0, &surface);

    // All blocks are below surface height → no sky light from column scan
    try testing.expectEqual(@as(u8, 0), lm.sky_light.get(chunkIndex(16, CHUNK_SIZE - 1, 16)));
    try testing.expectEqual(@as(u8, 0), lm.sky_light.get(chunkIndex(16, 0, 16)));
}

test "surface height partially blocks chunk" {
    // Chunk at cy=1 (world y 32-63), surface at y=40 → blocks below 40, open above
    const chunk = try allocChunk();
    defer testing.allocator.destroy(chunk);

    var surface: [CHUNK_SIZE * CHUNK_SIZE]i32 = undefined;
    @memset(&surface, 40); // surface at world y=40

    const lm = try allocLightMap();
    defer freeLightMap(lm);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm, 1, &surface);

    // y=31 → world_y=63, above surface → sky light
    try testing.expectEqual(@as(u8, 255), lm.sky_light.get(chunkIndex(16, 31, 16)));
    // y=10 → world_y=42, above surface → sky light
    try testing.expectEqual(@as(u8, 255), lm.sky_light.get(chunkIndex(16, 10, 16)));
    // y=9 → world_y=41, above surface → sky light
    try testing.expectEqual(@as(u8, 255), lm.sky_light.get(chunkIndex(16, 9, 16)));
    // y=8 → world_y=40, AT surface → no direct sky, but gets BFS from y=9 (255-8=247)
    try testing.expectEqual(@as(u8, 255 - ATTENUATION), lm.sky_light.get(chunkIndex(16, 8, 16)));
    // y=0 → world_y=32, below surface → only BFS propagation (255 - 9*8 = 183)
    try testing.expectEqual(@as(u8, 255 - 9 * ATTENUATION), lm.sky_light.get(chunkIndex(16, 0, 16)));
}

test "sky light propagates laterally across chunk boundary" {
    // Chunk A has full skylight (no surface heights → all sky open)
    const chunk_a = try allocChunk();
    defer testing.allocator.destroy(chunk_a);
    const lm_a = try allocLightMap();
    defer freeLightMap(lm_a);
    _ = computeChunkLight(chunk_a, no_neighbors, no_borders, lm_a, 0, null);

    // Chunk B: surface height blocks sky from above, but chunk A is its -X neighbor
    // Use surface heights that indicate opaque blocks above this chunk
    const chunk_b = try allocChunk();
    defer testing.allocator.destroy(chunk_b);

    // Surface height = 100 means opaque block at world Y=100, well above cy=0 chunk (y 0-31)
    var b_surface: [CHUNK_SIZE * CHUNK_SIZE]i32 = undefined;
    @memset(&b_surface, 100);

    var b_neighbors = no_neighbors;
    b_neighbors[2] = chunk_a; // -X neighbor has sky light
    var b_neighbor_lights = no_light_neighbors;
    b_neighbor_lights[2] = lm_a;
    const b_borders = LightMapMod.snapshotNeighborBorders(b_neighbor_lights);

    const lm_b = try allocLightMap();
    defer freeLightMap(lm_b);
    _ = computeChunkLight(chunk_b, b_neighbors, b_borders, lm_b, 0, &b_surface);

    // x=0 in chunk B should receive sky from chunk A's x=31 (255 - 8 = 247)
    const received = lm_b.sky_light.get(chunkIndex(0, 16, 16));
    try testing.expectEqual(@as(u8, 255 - ATTENUATION), received);

    // Should propagate further into chunk B
    const further = lm_b.sky_light.get(chunkIndex(1, 16, 16));
    try testing.expectEqual(@as(u8, 255 - 2 * ATTENUATION), further);
}

test "boundary mask set for face with light above attenuation" {
    const chunk = try allocChunk();
    defer testing.allocator.destroy(chunk);
    chunk.blocks[chunkIndex(CHUNK_SIZE - 1, 16, 16)] = .glowstone;

    const lm = try allocLightMap();
    defer freeLightMap(lm);
    const mask = computeChunkLight(chunk, no_neighbors, no_borders, lm, 0, null);

    try testing.expect(mask & (1 << 3) != 0);
}

test "boundary mask not set for face with no light" {
    const chunk = try allocChunk();
    defer testing.allocator.destroy(chunk);
    chunk.blocks[chunkIndex(16, 16, 16)] = .glowstone;

    const lm = try allocLightMap();
    defer freeLightMap(lm);
    const mask = computeChunkLight(chunk, no_neighbors, no_borders, lm, 0, null);

    // Red channel 255 reaches all boundaries (255 - 16*8 = 127 > 8)
    try testing.expectEqual(@as(u6, 0b111111), mask);
}

test "dirty flag cleared after compute" {
    const chunk = try allocChunk();
    defer testing.allocator.destroy(chunk);
    const lm = try allocLightMap();
    defer freeLightMap(lm);
    try testing.expect(lm.dirty);

    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm, 0, null);
    try testing.expect(!lm.dirty);
}

test "bidirectional boundary propagation" {
    const chunk_a = try allocChunk();
    defer testing.allocator.destroy(chunk_a);
    chunk_a.blocks[chunkIndex(CHUNK_SIZE - 2, 16, 16)] = .glowstone;

    const lm_a = try allocLightMap();
    defer freeLightMap(lm_a);
    _ = computeChunkLight(chunk_a, no_neighbors, no_borders, lm_a, 0, null);

    const chunk_b = try allocChunk();
    defer testing.allocator.destroy(chunk_b);
    const lm_b = try allocLightMap();
    defer freeLightMap(lm_b);
    var b_neighbor_lights = no_light_neighbors;
    b_neighbor_lights[2] = lm_a;
    const b_borders = LightMapMod.snapshotNeighborBorders(b_neighbor_lights);
    var b_neighbors = no_neighbors;
    b_neighbors[2] = chunk_a;

    _ = computeChunkLight(chunk_b, b_neighbors, b_borders, lm_b, 0, null);

    // Light at chunk A boundary (x=31): 255 - 1*8 = 247
    // Light entering chunk B at x=0: 247 - 8 = 239
    const at_b_0 = lm_b.block_light.get(chunkIndex(0, 16, 16));
    try testing.expectEqual(@as(u8, 255 - 2 * ATTENUATION), at_b_0[0]);

    // Light at x=5 in chunk B: 255 - 7*8 = 199
    const at_b_5 = lm_b.block_light.get(chunkIndex(5, 16, 16));
    try testing.expectEqual(@as(u8, 255 - 7 * ATTENUATION), at_b_5[0]);
}
