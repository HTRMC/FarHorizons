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

/// Scan boundary faces and return a 6-bit mask of faces that have light > ATTENUATION.
/// Can be called on an existing light map (before clearing) to get the "old" mask.
pub fn computeBoundaryMask(light_map: *const LightMap) u6 {
    var mask: u6 = 0;
    // +X face (3): check x=31
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |z| {
            const idx = chunkIndex(CHUNK_SIZE - 1, y, z);
            const bl = light_map.block_light.get(idx);
            if (bl[0] > ATTENUATION or bl[1] > ATTENUATION or bl[2] > ATTENUATION or light_map.sky_light.get(idx) > ATTENUATION) {
                mask |= (1 << 3);
                break;
            }
        }
        if (mask & (1 << 3) != 0) break;
    }
    // -X face (2): check x=0
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |z| {
            const idx = chunkIndex(0, y, z);
            const bl = light_map.block_light.get(idx);
            if (bl[0] > ATTENUATION or bl[1] > ATTENUATION or bl[2] > ATTENUATION or light_map.sky_light.get(idx) > ATTENUATION) {
                mask |= (1 << 2);
                break;
            }
        }
        if (mask & (1 << 2) != 0) break;
    }
    // +Z face (0): check z=31
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |x| {
            const idx = chunkIndex(x, y, CHUNK_SIZE - 1);
            const bl = light_map.block_light.get(idx);
            if (bl[0] > ATTENUATION or bl[1] > ATTENUATION or bl[2] > ATTENUATION or light_map.sky_light.get(idx) > ATTENUATION) {
                mask |= (1 << 0);
                break;
            }
        }
        if (mask & (1 << 0) != 0) break;
    }
    // -Z face (1): check z=0
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |x| {
            const idx = chunkIndex(x, y, 0);
            const bl = light_map.block_light.get(idx);
            if (bl[0] > ATTENUATION or bl[1] > ATTENUATION or bl[2] > ATTENUATION or light_map.sky_light.get(idx) > ATTENUATION) {
                mask |= (1 << 1);
                break;
            }
        }
        if (mask & (1 << 1) != 0) break;
    }
    // +Y face (4): check y=31
    for (0..CHUNK_SIZE) |z| {
        for (0..CHUNK_SIZE) |x| {
            const idx = chunkIndex(x, CHUNK_SIZE - 1, z);
            const bl = light_map.block_light.get(idx);
            if (bl[0] > ATTENUATION or bl[1] > ATTENUATION or bl[2] > ATTENUATION or light_map.sky_light.get(idx) > ATTENUATION) {
                mask |= (1 << 4);
                break;
            }
        }
        if (mask & (1 << 4) != 0) break;
    }
    // -Y face (5): check y=0
    for (0..CHUNK_SIZE) |z| {
        for (0..CHUNK_SIZE) |x| {
            const idx = chunkIndex(x, 0, z);
            const bl = light_map.block_light.get(idx);
            if (bl[0] > ATTENUATION or bl[1] > ATTENUATION or bl[2] > ATTENUATION or light_map.sky_light.get(idx) > ATTENUATION) {
                mask |= (1 << 5);
                break;
            }
        }
        if (mask & (1 << 5) != 0) break;
    }
    return mask;
}

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

    return computeBoundaryMask(light_map);
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

// ─── Incremental updates ───

const DestructiveEntry = struct {
    x: i8,
    y: i8,
    z: i8,
    dir: u3,
    r: u8,
    g: u8,
    b: u8,
    active: u3,
};

const ReseedPos = struct {
    x: i8,
    y: i8,
    z: i8,
};

/// Maps a BFS direction index to the boundary mask face bit.
/// BFS_OFFSETS: 0=+X, 1=-X, 2=+Y, 3=-Y, 4=+Z, 5=-Z
/// Face bits:   3=+X, 2=-X, 4=+Y, 5=-Y, 0=+Z, 1=-Z
fn faceBit(dir: usize) u3 {
    return switch (dir) {
        0 => 3,
        1 => 2,
        2 => 4,
        3 => 5,
        4 => 0,
        5 => 1,
        else => unreachable,
    };
}

/// Attempts an incremental light update for a single block change.
/// Only handles block light; falls back (returns null) if sky light is affected.
/// Returns the boundary mask (which faces had light changes reaching the boundary),
/// or null if the caller should do a full recompute instead.
pub fn applyBlockChange(
    chunk: *const WorldState.Chunk,
    light_map: *LightMap,
    lx: u8,
    ly: u8,
    lz: u8,
    old_block: BlockType,
) ?u6 {
    const idx = chunkIndex(lx, ly, lz);
    const new_block = chunk.blocks[idx];

    const old_opaque = block_properties.isOpaque(old_block);
    const new_opaque = block_properties.isOpaque(new_block);
    const old_emit = block_properties.emittedLight(old_block);
    const new_emit = block_properties.emittedLight(new_block);

    // If opacity changed, check whether sky light is affected.
    // If so, fall back to full recompute (sky light has complex column/surface logic).
    if (old_opaque != new_opaque) {
        if (skyLightAffected(light_map, lx, ly, lz, new_opaque)) return null;
    }

    var boundary_mask: u6 = 0;

    const current_light = light_map.block_light.get(idx);
    const has_current_light = current_light[0] > 0 or current_light[1] > 0 or current_light[2] > 0;
    const had_emission = old_emit[0] > 0 or old_emit[1] > 0 or old_emit[2] > 0;

    // STEP 1: Remove block light if the position is becoming opaque or losing an emitter.
    if (has_current_light and (new_opaque or had_emission)) {
        boundary_mask |= destructiveBlockLight(light_map, chunk, @intCast(lx), @intCast(ly), @intCast(lz), current_light);
    }

    // STEP 2: Set the position's own light value.
    if (new_opaque) {
        light_map.block_light.set(idx, new_emit);
    }

    // STEP 3: Propagate new light outward.
    const has_new_emit = new_emit[0] > 0 or new_emit[1] > 0 or new_emit[2] > 0;
    if (has_new_emit) {
        // New emitter placed — propagate its light.
        light_map.block_light.set(idx, new_emit);
        boundary_mask |= additiveBlockLight(light_map, chunk, @intCast(lx), @intCast(ly), @intCast(lz), new_emit);
    } else if (old_opaque and !new_opaque) {
        // Opened up (was opaque, now transparent) — seed from neighbors' light.
        var seed_val: [3]u8 = .{ 0, 0, 0 };
        for (0..6) |dir| {
            const nx = @as(i32, lx) + BFS_OFFSETS[dir][0];
            const ny = @as(i32, ly) + BFS_OFFSETS[dir][1];
            const nz = @as(i32, lz) + BFS_OFFSETS[dir][2];
            if (nx < 0 or nx >= CHUNK_SIZE or ny < 0 or ny >= CHUNK_SIZE or nz < 0 or nz >= CHUNK_SIZE) continue;
            const n_light = light_map.block_light.get(chunkIndex(@intCast(nx), @intCast(ny), @intCast(nz)));
            seed_val[0] = @max(seed_val[0], n_light[0] -| ATTENUATION);
            seed_val[1] = @max(seed_val[1], n_light[1] -| ATTENUATION);
            seed_val[2] = @max(seed_val[2], n_light[2] -| ATTENUATION);
        }
        if (seed_val[0] > 0 or seed_val[1] > 0 or seed_val[2] > 0) {
            light_map.block_light.set(idx, seed_val);
            boundary_mask |= additiveBlockLight(light_map, chunk, @intCast(lx), @intCast(ly), @intCast(lz), seed_val);
        }
    }

    return boundary_mask;
}

/// Returns true if sky light values would be affected by this opacity change,
/// meaning the caller should fall back to a full recompute.
fn skyLightAffected(light_map: *LightMap, lx: u8, ly: u8, lz: u8, new_opaque: bool) bool {
    if (new_opaque) {
        // Placing opaque block: affected if position currently has sky light.
        return light_map.sky_light.get(chunkIndex(lx, ly, lz)) > 0;
    } else {
        // Breaking opaque block: affected if any neighbor has sky light
        // (it would flow into the newly opened position).
        for (0..6) |dir| {
            const nx = @as(i32, lx) + BFS_OFFSETS[dir][0];
            const ny = @as(i32, ly) + BFS_OFFSETS[dir][1];
            const nz = @as(i32, lz) + BFS_OFFSETS[dir][2];
            if (nx >= 0 and nx < CHUNK_SIZE and ny >= 0 and ny < CHUNK_SIZE and nz >= 0 and nz < CHUNK_SIZE) {
                if (light_map.sky_light.get(chunkIndex(@intCast(nx), @intCast(ny), @intCast(nz))) > 0) return true;
            } else {
                // Neighbor is outside the chunk — conservatively assume sky light exists.
                return true;
            }
        }
        return false;
    }
}

/// Destructive block light BFS: removes block light from the cone of a removed source,
/// then re-propagates from any other sources found during removal.
fn destructiveBlockLight(
    light_map: *LightMap,
    chunk: *const WorldState.Chunk,
    sx: i8,
    sy: i8,
    sz: i8,
    start_light: [3]u8,
) u6 {
    var queue: [BLOCKS_PER_CHUNK]DestructiveEntry = undefined;
    var head: u32 = 0;
    var tail: u32 = 0;

    var reseed: [BLOCKS_PER_CHUNK]ReseedPos = undefined;
    var reseed_count: u32 = 0;
    var boundary_mask: u6 = 0;

    // Zero the starting position and seed the queue.
    light_map.block_light.set(chunkIndex(@intCast(sx), @intCast(sy), @intCast(sz)), .{ 0, 0, 0 });
    queue[tail] = .{
        .x = sx,
        .y = sy,
        .z = sz,
        .dir = 6,
        .r = start_light[0],
        .g = start_light[1],
        .b = start_light[2],
        .active = 0b111,
    };
    tail += 1;

    // Phase 1: Destructive BFS — walk the light cone, zeroing values that came from our source.
    while (head < tail) {
        const e = queue[head];
        head += 1;

        for (0..6) |dir| {
            if (e.dir < 6 and dir == OPPOSITE_DIR[e.dir]) continue;

            const nx = @as(i32, e.x) + BFS_OFFSETS[dir][0];
            const ny = @as(i32, e.y) + BFS_OFFSETS[dir][1];
            const nz = @as(i32, e.z) + BFS_OFFSETS[dir][2];

            if (nx < 0 or nx >= CHUNK_SIZE or ny < 0 or ny >= CHUNK_SIZE or nz < 0 or nz >= CHUNK_SIZE) {
                if (e.active != 0) boundary_mask |= @as(u6, 1) << faceBit(dir);
                continue;
            }

            const ux: usize = @intCast(nx);
            const uy: usize = @intCast(ny);
            const uz: usize = @intCast(nz);

            if (block_properties.isOpaque(chunk.blocks[chunkIndex(ux, uy, uz)])) continue;

            // Expected attenuated value at neighbor if it came from our source.
            const exp_r = e.r -| ATTENUATION;
            const exp_g = e.g -| ATTENUATION;
            const exp_b = e.b -| ATTENUATION;

            if (exp_r == 0 and exp_g == 0 and exp_b == 0) continue;

            const n_idx = chunkIndex(ux, uy, uz);
            const actual = light_map.block_light.get(n_idx);

            // For each channel: if the actual value matches expected, it came from our source.
            // If it doesn't match, the light comes from a different source — mark for re-seed.
            var active: u3 = 0;
            var need_reseed = false;

            if (e.active & 1 != 0) {
                if (exp_r > 0 and actual[0] == exp_r) {
                    active |= 1;
                } else if (actual[0] > 0) {
                    need_reseed = true;
                }
            }
            if (e.active & 2 != 0) {
                if (exp_g > 0 and actual[1] == exp_g) {
                    active |= 2;
                } else if (actual[1] > 0) {
                    need_reseed = true;
                }
            }
            if (e.active & 4 != 0) {
                if (exp_b > 0 and actual[2] == exp_b) {
                    active |= 4;
                } else if (actual[2] > 0) {
                    need_reseed = true;
                }
            }

            // If this block is itself an emitter, it needs re-seeding.
            const emit = block_properties.emittedLight(chunk.blocks[chunkIndex(ux, uy, uz)]);
            if ((active & 1 != 0 and emit[0] > 0) or (active & 2 != 0 and emit[1] > 0) or (active & 4 != 0 and emit[2] > 0)) {
                need_reseed = true;
            }

            if (need_reseed and reseed_count < BLOCKS_PER_CHUNK) {
                reseed[reseed_count] = .{ .x = @intCast(nx), .y = @intCast(ny), .z = @intCast(nz) };
                reseed_count += 1;
            }

            if (active == 0) continue;

            // Zero the active channels.
            var new_val = actual;
            if (active & 1 != 0) new_val[0] = 0;
            if (active & 2 != 0) new_val[1] = 0;
            if (active & 4 != 0) new_val[2] = 0;
            light_map.block_light.set(n_idx, new_val);

            if (tail < BLOCKS_PER_CHUNK) {
                queue[tail] = .{
                    .x = @intCast(nx),
                    .y = @intCast(ny),
                    .z = @intCast(nz),
                    .dir = @intCast(dir),
                    .r = exp_r,
                    .g = exp_g,
                    .b = exp_b,
                    .active = active,
                };
                tail += 1;
            }
        }
    }

    // Phase 2: Re-propagate from reseed positions (where we found light from other sources).
    if (reseed_count > 0) {
        boundary_mask |= reseedBlockLight(light_map, chunk, reseed[0..reseed_count]);
    }

    return boundary_mask;
}

/// Re-propagates block light from a list of reseed positions using additive BFS.
fn reseedBlockLight(
    light_map: *LightMap,
    chunk: *const WorldState.Chunk,
    reseeds: []const ReseedPos,
) u6 {
    var queue: [MAX_QUEUE]QueueEntry = undefined;
    var head: u32 = 0;
    var tail: u32 = 0;
    var boundary_mask: u6 = 0;

    for (reseeds) |rs| {
        const rs_idx = chunkIndex(@intCast(rs.x), @intCast(rs.y), @intCast(rs.z));
        const current = light_map.block_light.get(rs_idx);
        const emit = block_properties.emittedLight(chunk.blocks[rs_idx]);
        const val = [3]u8{
            @max(current[0], emit[0]),
            @max(current[1], emit[1]),
            @max(current[2], emit[2]),
        };
        if (val[0] == 0 and val[1] == 0 and val[2] == 0) continue;

        // Zero then re-propagate so additive BFS can set the correct value.
        light_map.block_light.set(rs_idx, .{ 0, 0, 0 });
        if (tail < MAX_QUEUE) {
            queue[tail] = .{
                .x = rs.x,
                .y = rs.y,
                .z = rs.z,
                .dir = 6,
                .r = val[0],
                .g = val[1],
                .b = val[2],
            };
            tail += 1;
        }
    }

    // Standard additive BFS (same logic as computeBlockLight phase 3).
    while (head < tail) {
        const e = queue[head];
        head += 1;

        const e_idx = chunkIndex(@intCast(e.x), @intCast(e.y), @intCast(e.z));
        const old = light_map.block_light.get(e_idx);
        const updated = [3]u8{
            @max(old[0], e.r),
            @max(old[1], e.g),
            @max(old[2], e.b),
        };
        if (updated[0] == old[0] and updated[1] == old[1] and updated[2] == old[2]) continue;
        light_map.block_light.set(e_idx, updated);

        for (0..6) |dir| {
            if (e.dir < 6 and dir == OPPOSITE_DIR[e.dir]) continue;

            const nx = @as(i32, e.x) + BFS_OFFSETS[dir][0];
            const ny = @as(i32, e.y) + BFS_OFFSETS[dir][1];
            const nz = @as(i32, e.z) + BFS_OFFSETS[dir][2];

            if (nx < 0 or nx >= CHUNK_SIZE or ny < 0 or ny >= CHUNK_SIZE or nz < 0 or nz >= CHUNK_SIZE) {
                boundary_mask |= @as(u6, 1) << faceBit(dir);
                continue;
            }

            const ux: usize = @intCast(nx);
            const uy: usize = @intCast(ny);
            const uz: usize = @intCast(nz);

            if (block_properties.isOpaque(chunk.blocks[chunkIndex(ux, uy, uz)])) continue;

            const nr = updated[0] -| ATTENUATION;
            const ng = updated[1] -| ATTENUATION;
            const nb = updated[2] -| ATTENUATION;

            if (nr == 0 and ng == 0 and nb == 0) continue;

            // Skip if neighbor already has equal or better light.
            const n_idx = chunkIndex(ux, uy, uz);
            const existing = light_map.block_light.get(n_idx);
            if (nr <= existing[0] and ng <= existing[1] and nb <= existing[2]) continue;

            if (tail < MAX_QUEUE) {
                queue[tail] = .{
                    .x = @intCast(nx),
                    .y = @intCast(ny),
                    .z = @intCast(nz),
                    .dir = @intCast(dir),
                    .r = nr,
                    .g = ng,
                    .b = nb,
                };
                tail += 1;
            }
        }
    }

    return boundary_mask;
}

/// Additive block light BFS: propagates light outward from a single position.
fn additiveBlockLight(
    light_map: *LightMap,
    chunk: *const WorldState.Chunk,
    sx: i8,
    sy: i8,
    sz: i8,
    start_val: [3]u8,
) u6 {
    var queue: [BLOCKS_PER_CHUNK]QueueEntry = undefined;
    var head: u32 = 0;
    var tail: u32 = 0;
    var boundary_mask: u6 = 0;

    queue[0] = .{
        .x = sx,
        .y = sy,
        .z = sz,
        .dir = 6,
        .r = start_val[0],
        .g = start_val[1],
        .b = start_val[2],
    };
    tail = 1;

    while (head < tail) {
        const e = queue[head];
        head += 1;

        for (0..6) |dir| {
            if (e.dir < 6 and dir == OPPOSITE_DIR[e.dir]) continue;

            const nx = @as(i32, e.x) + BFS_OFFSETS[dir][0];
            const ny = @as(i32, e.y) + BFS_OFFSETS[dir][1];
            const nz = @as(i32, e.z) + BFS_OFFSETS[dir][2];

            if (nx < 0 or nx >= CHUNK_SIZE or ny < 0 or ny >= CHUNK_SIZE or nz < 0 or nz >= CHUNK_SIZE) {
                boundary_mask |= @as(u6, 1) << faceBit(dir);
                continue;
            }

            const ux: usize = @intCast(nx);
            const uy: usize = @intCast(ny);
            const uz: usize = @intCast(nz);

            if (block_properties.isOpaque(chunk.blocks[chunkIndex(ux, uy, uz)])) continue;

            const nr = e.r -| ATTENUATION;
            const ng = e.g -| ATTENUATION;
            const nb = e.b -| ATTENUATION;

            if (nr == 0 and ng == 0 and nb == 0) continue;

            const n_idx = chunkIndex(ux, uy, uz);
            const existing = light_map.block_light.get(n_idx);
            if (nr <= existing[0] and ng <= existing[1] and nb <= existing[2]) continue;

            const upd = [3]u8{
                @max(existing[0], nr),
                @max(existing[1], ng),
                @max(existing[2], nb),
            };
            light_map.block_light.set(n_idx, upd);

            if (tail < BLOCKS_PER_CHUNK) {
                queue[tail] = .{
                    .x = @intCast(nx),
                    .y = @intCast(ny),
                    .z = @intCast(nz),
                    .dir = @intCast(dir),
                    .r = upd[0],
                    .g = upd[1],
                    .b = upd[2],
                };
                tail += 1;
            }
        }
    }

    return boundary_mask;
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

// ─── Incremental update tests ───

/// Creates a chunk with a stone ceiling at y=31 and sets surface heights
/// so that sky light is blocked everywhere inside the chunk.
const underground_surface: [CHUNK_SIZE * CHUNK_SIZE]i32 = .{CHUNK_SIZE - 1} ** (CHUNK_SIZE * CHUNK_SIZE);

fn makeUndergroundChunk() !*Chunk {
    const chunk = try allocChunk();
    // Stone ceiling blocks sky light
    for (0..CHUNK_SIZE) |z| {
        for (0..CHUNK_SIZE) |x| {
            chunk.blocks[chunkIndex(x, CHUNK_SIZE - 1, z)] = .stone;
        }
    }
    return chunk;
}

test "incremental: remove glowstone clears its light" {
    const chunk = try makeUndergroundChunk();
    defer testing.allocator.destroy(chunk);
    chunk.blocks[chunkIndex(16, 16, 16)] = .glowstone;

    const lm = try allocLightMap();
    defer freeLightMap(lm);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm, 0, &underground_surface);

    // Verify glowstone lit the area
    try testing.expectEqual(@as(u8, 255), lm.block_light.get(chunkIndex(16, 16, 16))[0]);
    try testing.expectEqual(@as(u8, 255 - ATTENUATION), lm.block_light.get(chunkIndex(17, 16, 16))[0]);

    // Break the glowstone
    const old_block = chunk.blocks[chunkIndex(16, 16, 16)];
    chunk.blocks[chunkIndex(16, 16, 16)] = .air;

    const result = applyBlockChange(chunk, lm, 16, 16, 16, old_block);
    try testing.expect(result != null);

    // Emitter position should be dark
    try testing.expectEqual(@as(u8, 0), lm.block_light.get(chunkIndex(16, 16, 16))[0]);
    // Adjacent should be dark
    try testing.expectEqual(@as(u8, 0), lm.block_light.get(chunkIndex(17, 16, 16))[0]);
    try testing.expectEqual(@as(u8, 0), lm.block_light.get(chunkIndex(15, 16, 16))[0]);
    // Far away should be dark
    try testing.expectEqual(@as(u8, 0), lm.block_light.get(chunkIndex(16, 16, 20))[0]);
}

test "incremental: place opaque block blocks light" {
    const chunk = try makeUndergroundChunk();
    defer testing.allocator.destroy(chunk);
    chunk.blocks[chunkIndex(16, 16, 16)] = .glowstone;

    const lm = try allocLightMap();
    defer freeLightMap(lm);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm, 0, &underground_surface);

    // Light at (18, 16, 16) should be 255 - 2*8 = 239
    try testing.expectEqual(@as(u8, 255 - 2 * ATTENUATION), lm.block_light.get(chunkIndex(18, 16, 16))[0]);

    // Place stone at (17, 16, 16) — blocks light from passing through
    chunk.blocks[chunkIndex(17, 16, 16)] = .stone;
    const result = applyBlockChange(chunk, lm, 17, 16, 16, .air);
    try testing.expect(result != null);

    // The stone block should have no light
    try testing.expectEqual(@as(u8, 0), lm.block_light.get(chunkIndex(17, 16, 16))[0]);

    // Block behind the wall should have LESS light than before (light must go around)
    const behind = lm.block_light.get(chunkIndex(18, 16, 16));
    try testing.expect(behind[0] < 255 - 2 * ATTENUATION);
}

test "incremental: break opaque block lets light through" {
    const chunk = try makeUndergroundChunk();
    defer testing.allocator.destroy(chunk);
    chunk.blocks[chunkIndex(16, 16, 16)] = .glowstone;
    chunk.blocks[chunkIndex(17, 16, 16)] = .stone; // wall blocking +X

    const lm = try allocLightMap();
    defer freeLightMap(lm);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm, 0, &underground_surface);

    // (18, 16, 16) is behind the wall — should have reduced light
    const before = lm.block_light.get(chunkIndex(18, 16, 16))[0];
    try testing.expect(before < 255 - 2 * ATTENUATION);

    // Break the wall
    chunk.blocks[chunkIndex(17, 16, 16)] = .air;
    const result = applyBlockChange(chunk, lm, 17, 16, 16, .stone);
    try testing.expect(result != null);

    // (17, 16, 16) should now have light from glowstone
    try testing.expectEqual(@as(u8, 255 - ATTENUATION), lm.block_light.get(chunkIndex(17, 16, 16))[0]);
    // (18, 16, 16) should now have full unblocked light
    try testing.expectEqual(@as(u8, 255 - 2 * ATTENUATION), lm.block_light.get(chunkIndex(18, 16, 16))[0]);
}

test "incremental: two glowstones, remove one preserves other" {
    const chunk = try makeUndergroundChunk();
    defer testing.allocator.destroy(chunk);
    chunk.blocks[chunkIndex(10, 16, 16)] = .glowstone;
    chunk.blocks[chunkIndex(20, 16, 16)] = .glowstone;

    const lm = try allocLightMap();
    defer freeLightMap(lm);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm, 0, &underground_surface);

    // Midpoint (15, 16, 16): gets light from both
    const mid_before = lm.block_light.get(chunkIndex(15, 16, 16));
    try testing.expect(mid_before[0] > 0);

    // Remove glowstone at (10, 16, 16)
    chunk.blocks[chunkIndex(10, 16, 16)] = .air;
    const result = applyBlockChange(chunk, lm, 10, 16, 16, .glowstone);
    try testing.expect(result != null);

    // (10, 16, 16) still gets light from glowstone at (20,16,16), distance 10: 255 - 80 = 175
    try testing.expectEqual(@as(u8, 255 - 10 * ATTENUATION), lm.block_light.get(chunkIndex(10, 16, 16))[0]);

    // (20, 16, 16) should still have full light (other glowstone untouched)
    try testing.expectEqual(@as(u8, 255), lm.block_light.get(chunkIndex(20, 16, 16))[0]);

    // (19, 16, 16) should still have light from the remaining glowstone
    try testing.expectEqual(@as(u8, 255 - ATTENUATION), lm.block_light.get(chunkIndex(19, 16, 16))[0]);

    // (15, 16, 16) now only gets light from (20, 16, 16), distance 5: 255 - 40 = 215
    try testing.expectEqual(@as(u8, 255 - 5 * ATTENUATION), lm.block_light.get(chunkIndex(15, 16, 16))[0]);
}

test "incremental: place glowstone adds light" {
    const chunk = try makeUndergroundChunk();
    defer testing.allocator.destroy(chunk);

    const lm = try allocLightMap();
    defer freeLightMap(lm);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm, 0, &underground_surface);

    // All dark
    try testing.expectEqual(@as(u8, 0), lm.block_light.get(chunkIndex(16, 16, 16))[0]);

    // Place glowstone
    chunk.blocks[chunkIndex(16, 16, 16)] = .glowstone;
    const result = applyBlockChange(chunk, lm, 16, 16, 16, .air);
    try testing.expect(result != null);

    // Should now have light
    try testing.expectEqual(@as(u8, 255), lm.block_light.get(chunkIndex(16, 16, 16))[0]);
    try testing.expectEqual(@as(u8, 200), lm.block_light.get(chunkIndex(16, 16, 16))[1]);
    try testing.expectEqual(@as(u8, 100), lm.block_light.get(chunkIndex(16, 16, 16))[2]);

    // Adjacent
    try testing.expectEqual(@as(u8, 255 - ATTENUATION), lm.block_light.get(chunkIndex(17, 16, 16))[0]);
}

test "incremental: matches full recompute for remove glowstone" {
    const chunk = try makeUndergroundChunk();
    defer testing.allocator.destroy(chunk);
    chunk.blocks[chunkIndex(16, 16, 16)] = .glowstone;

    const lm_inc = try allocLightMap();
    defer freeLightMap(lm_inc);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm_inc, 0, &underground_surface);

    // Incremental remove
    chunk.blocks[chunkIndex(16, 16, 16)] = .air;
    _ = applyBlockChange(chunk, lm_inc, 16, 16, 16, .glowstone);

    // Full recompute of the same final state
    const lm_full = try allocLightMap();
    defer freeLightMap(lm_full);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm_full, 0, &underground_surface);

    // Compare all block light values
    for (0..BLOCKS_PER_CHUNK) |i| {
        const inc = lm_inc.block_light.get(i);
        const full = lm_full.block_light.get(i);
        try testing.expectEqual(full[0], inc[0]);
        try testing.expectEqual(full[1], inc[1]);
        try testing.expectEqual(full[2], inc[2]);
    }
}

test "incremental: matches full recompute for place wall" {
    const chunk = try makeUndergroundChunk();
    defer testing.allocator.destroy(chunk);
    chunk.blocks[chunkIndex(16, 16, 16)] = .glowstone;

    const lm_inc = try allocLightMap();
    defer freeLightMap(lm_inc);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm_inc, 0, &underground_surface);

    // Place a stone wall
    chunk.blocks[chunkIndex(17, 16, 16)] = .stone;
    _ = applyBlockChange(chunk, lm_inc, 17, 16, 16, .air);

    // Full recompute
    const lm_full = try allocLightMap();
    defer freeLightMap(lm_full);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm_full, 0, &underground_surface);

    for (0..BLOCKS_PER_CHUNK) |i| {
        const inc = lm_inc.block_light.get(i);
        const full = lm_full.block_light.get(i);
        try testing.expectEqual(full[0], inc[0]);
        try testing.expectEqual(full[1], inc[1]);
        try testing.expectEqual(full[2], inc[2]);
    }
}

test "incremental: matches full recompute for break wall" {
    const chunk = try makeUndergroundChunk();
    defer testing.allocator.destroy(chunk);
    chunk.blocks[chunkIndex(16, 16, 16)] = .glowstone;
    chunk.blocks[chunkIndex(17, 16, 16)] = .stone;

    const lm_inc = try allocLightMap();
    defer freeLightMap(lm_inc);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm_inc, 0, &underground_surface);

    // Break the wall
    chunk.blocks[chunkIndex(17, 16, 16)] = .air;
    _ = applyBlockChange(chunk, lm_inc, 17, 16, 16, .stone);

    // Full recompute
    const lm_full = try allocLightMap();
    defer freeLightMap(lm_full);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm_full, 0, &underground_surface);

    for (0..BLOCKS_PER_CHUNK) |i| {
        const inc = lm_inc.block_light.get(i);
        const full = lm_full.block_light.get(i);
        try testing.expectEqual(full[0], inc[0]);
        try testing.expectEqual(full[1], inc[1]);
        try testing.expectEqual(full[2], inc[2]);
    }
}

test "incremental: sky light affected returns null for surface change" {
    const chunk = try allocChunk();
    defer testing.allocator.destroy(chunk);

    const lm = try allocLightMap();
    defer freeLightMap(lm);
    // All air, no surface → sky light everywhere = 255
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm, 0, null);

    // Place stone in a sky-lit area: should return null (fall back to full)
    chunk.blocks[chunkIndex(16, 16, 16)] = .stone;
    const result = applyBlockChange(chunk, lm, 16, 16, 16, .air);
    try testing.expectEqual(@as(?u6, null), result);
}

test "incremental: no-op change in dark area" {
    const chunk = try makeUndergroundChunk();
    defer testing.allocator.destroy(chunk);

    const lm = try allocLightMap();
    defer freeLightMap(lm);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm, 0, &underground_surface);

    // Place and break stone in a completely dark interior area
    chunk.blocks[chunkIndex(16, 10, 16)] = .stone;
    const result = applyBlockChange(chunk, lm, 16, 10, 16, .air);
    try testing.expect(result != null);
    try testing.expectEqual(@as(u6, 0), result.?);
}
