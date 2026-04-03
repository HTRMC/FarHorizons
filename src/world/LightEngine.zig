const std = @import("std");
const WorldState = @import("WorldState.zig");
const LightMapMod = @import("LightMap.zig");
const LightMap = LightMapMod.LightMap;
const LightBorderSnapshot = LightMapMod.LightBorderSnapshot;
const BlockState = WorldState.BlockState;
const StateId = WorldState.StateId;
const ChunkMap = @import("ChunkMap.zig").ChunkMap;
const tracy = @import("../platform/tracy.zig");
const Io = std.Io;

const ChunkKey = WorldState.ChunkKey;
const LightMaps = std.AutoHashMap(ChunkKey, *LightMap);

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

const AIR: StateId = BlockState.defaultState(.air);

fn getBlock(chunk: *const WorldState.Chunk, neighbors: [6]?*const WorldState.Chunk, x: i32, y: i32, z: i32) StateId {
    if (x >= 0 and x < CHUNK_SIZE and y >= 0 and y < CHUNK_SIZE and z >= 0 and z < CHUNK_SIZE) {
        return chunk.blocks.get(chunkIndex(@intCast(x), @intCast(y), @intCast(z)));
    }
    // Check neighbor chunks
    if (x >= CHUNK_SIZE) {
        const n = neighbors[3] orelse return AIR; // +X
        return n.blocks.get(chunkIndex(0, @intCast(y), @intCast(z)));
    }
    if (x < 0) {
        const n = neighbors[2] orelse return AIR; // -X
        return n.blocks.get(chunkIndex(CHUNK_SIZE - 1, @intCast(y), @intCast(z)));
    }
    if (y >= CHUNK_SIZE) {
        const n = neighbors[4] orelse return AIR; // +Y
        return n.blocks.get(chunkIndex(@intCast(x), 0, @intCast(z)));
    }
    if (y < 0) {
        const n = neighbors[5] orelse return AIR; // -Y
        return n.blocks.get(chunkIndex(@intCast(x), CHUNK_SIZE - 1, @intCast(z)));
    }
    if (z >= CHUNK_SIZE) {
        const n = neighbors[0] orelse return AIR; // +Z
        return n.blocks.get(chunkIndex(@intCast(x), @intCast(y), 0));
    }
    if (z < 0) {
        const n = neighbors[1] orelse return AIR; // -Z
        return n.blocks.get(chunkIndex(@intCast(x), @intCast(y), CHUNK_SIZE - 1));
    }
    return AIR;
}

fn getNeighborLight(comptime is_sun: bool, neighbor_borders: [6]LightBorderSnapshot, face: usize, border_idx: usize) [3]u8 {
    if (!neighbor_borders[face].valid) return .{ 0, 0, 0 };
    if (is_sun) {
        const v = neighbor_borders[face].sky[border_idx];
        return .{ v, v, v };
    } else {
        return neighbor_borders[face].block[border_idx];
    }
}

/// Unified BFS queue entry for both constructive and destructive propagation
/// (matches Cubyz's single Entry type). For constructive BFS, active is unused.
/// For destructive BFS, active tracks which RGB channels are still being cleared.
const LightQueueEntry = struct {
    x: i8,
    y: i8,
    z: i8,
    dir: u3,
    r: u8,
    g: u8,
    b: u8,
    active: u3 = 0,
};

/// Comptime helper: read light value from the appropriate storage channel.
/// Sky light returns {v, v, v} to match Cubyz's LightValue representation
/// where sunlight is (255, 255, 255) for the column rule check.
fn getStoredLight(comptime is_sun: bool, light_map: *const LightMap, idx: usize) [3]u8 {
    if (is_sun) {
        const v = light_map.sky_light.get(idx);
        return .{ v, v, v };
    } else {
        return light_map.block_light.get(idx);
    }
}

/// Comptime helper: write light value to the appropriate storage channel.
fn setStoredLight(comptime is_sun: bool, light_map: *LightMap, idx: usize, val: [3]u8) void {
    if (is_sun) {
        light_map.sky_light.set(idx, val[0]);
    } else {
        light_map.block_light.set(idx, val);
    }
}

const MAX_QUEUE = BLOCKS_PER_CHUNK * 2;
const DESTRUCTIVE_QUEUE_SIZE = BLOCKS_PER_CHUNK * 6;

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
    const tz = tracy.zone(@src(), "computeChunkLight");
    defer tz.end();

    // Fast path: all-air chunk fully above the surface.
    // Fill uniform max sky light, zero block light — skip all BFS.
    if (chunk.blocks.palette_len == 1 and chunk.blocks.get(0) == AIR) {
        if (surface_heights) |sh| {
            const chunk_base_y: i32 = chunk_cy * @as(i32, CHUNK_SIZE);
            var all_above = true;
            for (sh) |h| {
                if (chunk_base_y <= h) {
                    all_above = false;
                    break;
                }
            }
            if (all_above) {
                light_map.sky_light.fillUniform(255);
                light_map.block_light.fillUniform(.{ 0, 0, 0 });
                light_map.dirty = false;
                return 0x3f; // all 6 faces have max sky light at boundary
            }
        }
    }

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
    // Fast path: if chunk is all air and entirely above the surface,
    // fill uniform max sky light and skip BFS entirely (Cubyz optimization).
    if (chunk.blocks.palette_len == 1 and chunk.blocks.get(0) == AIR) {
        if (surface_heights) |sh| {
            const chunk_base_y: i32 = chunk_cy * @as(i32, CHUNK_SIZE);
            var all_above = true;
            for (sh) |h| {
                if (chunk_base_y <= h) {
                    all_above = false;
                    break;
                }
            }
            if (all_above) {
                light_map.sky_light.fillUniform(255);
                return;
            }
        }
    }

    var queue: [MAX_QUEUE]LightQueueEntry = undefined;
    var head: u32 = 0;
    var tail: u32 = 0;

    // Phase 1: Column fill using pre-computed surface height map.
    const chunk_base_y: i32 = chunk_cy * @as(i32, CHUNK_SIZE);
    for (0..CHUNK_SIZE) |z| {
        for (0..CHUNK_SIZE) |x| {
            const col_idx = z * CHUNK_SIZE + x;
            const sh: i32 = if (surface_heights) |sh| sh[col_idx] else std.math.minInt(i32);

            var y: i32 = CHUNK_SIZE - 1;
            while (y >= 0) : (y -= 1) {
                const world_y = chunk_base_y + y;
                if (world_y <= sh) break;
                const uy: usize = @intCast(y);
                if (BlockState.isOpaque(chunk.blocks.get(chunkIndex(x, uy, z)))) break;
                light_map.sky_light.set(chunkIndex(x, uy, z), 255);
                if (tail < MAX_QUEUE) {
                    queue[tail] = .{ .x = @intCast(x), .y = @intCast(y), .z = @intCast(z), .dir = 6, .r = 255, .g = 255, .b = 255 };
                    tail += 1;
                }
            }
        }
    }

    // Phase 2: Seed from neighbor chunks' sky light at boundaries
    seedAllBoundaries(true, &queue, &tail, chunk, light_map, neighbor_borders);

    // Phase 3: BFS propagation within chunk (with column rule via is_sun=true)
    propagateLightBFS(true, &queue, &head, &tail, chunk, light_map, false);
}

fn computeBlockLight(
    chunk: *const WorldState.Chunk,
    neighbors: [6]?*const WorldState.Chunk,
    neighbor_borders: [6]LightBorderSnapshot,
    light_map: *LightMap,
) void {
    _ = neighbors;

    var queue: [MAX_QUEUE]LightQueueEntry = undefined;
    var head: u32 = 0;
    var tail: u32 = 0;

    // Phase 1: Seed from emitters within chunk.
    // Fast path: check palette entries first — if no entry emits light, skip the full scan.
    var has_emitter = false;
    for (chunk.blocks.palette[0..chunk.blocks.palette_len]) |state| {
        const emit = BlockState.emittedLight(state);
        if (emit[0] > 0 or emit[1] > 0 or emit[2] > 0) {
            has_emitter = true;
            break;
        }
    }
    if (has_emitter) {
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |z| {
                for (0..CHUNK_SIZE) |x| {
                    const block = chunk.blocks.get(chunkIndex(x, y, z));
                    const emit = BlockState.emittedLight(block);
                    if (emit[0] > 0 or emit[1] > 0 or emit[2] > 0) {
                        light_map.block_light.set(chunkIndex(x, y, z), emit);
                        if (tail < MAX_QUEUE) {
                            queue[tail] = .{
                                .x = @intCast(x),
                                .y = @intCast(y),
                                .z = @intCast(z),
                                .dir = 6,
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
    }

    // Phase 2: Seed from neighbor chunks' block light at boundaries
    seedAllBoundaries(false, &queue, &tail, chunk, light_map, neighbor_borders);

    // Phase 3: BFS propagation within chunk
    propagateLightBFS(false, &queue, &head, &tail, chunk, light_map, false);
}

/// Unified boundary seeding for both block and sky light (ChannelChunk pattern).
fn seedBoundaryLight(
    comptime is_sun: bool,
    queue: *[MAX_QUEUE]LightQueueEntry,
    tail: *u32,
    chunk: *const WorldState.Chunk,
    light_map: *LightMap,
    x: i8,
    y: i8,
    z: i8,
    dir: u3,
    nl: [3]u8,
) void {
    // Sun column rule: no attenuation for sunlight coming from above at max brightness
    // (Cubyz: `if (!self.isSun or neighbor != .dirUp or value[0] != 255 ...)`)
    const sun_col = is_sun and dir == 3 and nl[0] == 255 and nl[1] == 255 and nl[2] == 255;
    const nr = if (sun_col) @as(u8, 255) else nl[0] -| ATTENUATION;
    const ng = if (sun_col) @as(u8, 255) else nl[1] -| ATTENUATION;
    const nb = if (sun_col) @as(u8, 255) else nl[2] -| ATTENUATION;
    if (nr == 0 and ng == 0 and nb == 0) return;

    const ux: usize = @intCast(x);
    const uy: usize = @intCast(y);
    const uz: usize = @intCast(z);
    const idx = chunkIndex(ux, uy, uz);

    const target_block = chunk.blocks.get(idx);
    if (BlockState.isOpaque(target_block)) return;

    // Apply absorption of target block (Cubyz incoming occlusion)
    const absorb = BlockState.absorption(target_block);
    const ar = nr -| absorb[0];
    const ag = ng -| absorb[1];
    const ab = nb -| absorb[2];
    if (ar == 0 and ag == 0 and ab == 0) return;

    const existing = getStoredLight(is_sun, light_map, idx);
    if (ar <= existing[0] and ag <= existing[1] and ab <= existing[2]) return;

    const updated = [3]u8{
        @max(existing[0], ar),
        @max(existing[1], ag),
        @max(existing[2], ab),
    };
    setStoredLight(is_sun, light_map, idx, updated);

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

/// Seeds all 6 boundary faces from neighbor border snapshots (ChannelChunk pattern).
fn seedAllBoundaries(
    comptime is_sun: bool,
    queue: *[MAX_QUEUE]LightQueueEntry,
    tail: *u32,
    chunk: *const WorldState.Chunk,
    light_map: *LightMap,
    neighbor_borders: [6]LightBorderSnapshot,
) void {
    // +X boundary: neighbor[3], their x=0 face → light travels -X (dir=1)
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |z| {
            seedBoundaryLight(is_sun, queue, tail, chunk, light_map, @intCast(CHUNK_SIZE - 1), @intCast(y), @intCast(z), 1, getNeighborLight(is_sun, neighbor_borders, 3, y * CHUNK_SIZE + z));
        }
    }
    // -X boundary: neighbor[2], their x=31 face → light travels +X (dir=0)
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |z| {
            seedBoundaryLight(is_sun, queue, tail, chunk, light_map, 0, @intCast(y), @intCast(z), 0, getNeighborLight(is_sun, neighbor_borders, 2, y * CHUNK_SIZE + z));
        }
    }
    // +Z boundary: neighbor[0], their z=0 face → light travels -Z (dir=5)
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |x| {
            seedBoundaryLight(is_sun, queue, tail, chunk, light_map, @intCast(x), @intCast(y), @intCast(CHUNK_SIZE - 1), 5, getNeighborLight(is_sun, neighbor_borders, 0, y * CHUNK_SIZE + x));
        }
    }
    // -Z boundary: neighbor[1], their z=31 face → light travels +Z (dir=4)
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |x| {
            seedBoundaryLight(is_sun, queue, tail, chunk, light_map, @intCast(x), @intCast(y), 0, 4, getNeighborLight(is_sun, neighbor_borders, 1, y * CHUNK_SIZE + x));
        }
    }
    // +Y boundary: neighbor[4], their y=0 face → light travels -Y (dir=3)
    for (0..CHUNK_SIZE) |z| {
        for (0..CHUNK_SIZE) |x| {
            seedBoundaryLight(is_sun, queue, tail, chunk, light_map, @intCast(x), @intCast(CHUNK_SIZE - 1), @intCast(z), 3, getNeighborLight(is_sun, neighbor_borders, 4, z * CHUNK_SIZE + x));
        }
    }
    // -Y boundary: neighbor[5], their y=31 face → light travels +Y (dir=2)
    for (0..CHUNK_SIZE) |z| {
        for (0..CHUNK_SIZE) |x| {
            seedBoundaryLight(is_sun, queue, tail, chunk, light_map, @intCast(x), 0, @intCast(z), 2, getNeighborLight(is_sun, neighbor_borders, 5, z * CHUNK_SIZE + x));
        }
    }
}

/// Unified light BFS propagation (ChannelChunk pattern).
/// Drains queue entries, attenuating and spreading light to non-opaque
/// neighbors within chunk bounds. When `is_sun`, applies the column rule
/// (no attenuation going downward at max brightness 255).
/// When `track_boundary` is true, returns a 6-bit mask of faces reached.
fn propagateLightBFS(
    comptime is_sun: bool,
    queue: []LightQueueEntry,
    head: *u32,
    tail: *u32,
    chunk: *const WorldState.Chunk,
    light_map: *LightMap,
    comptime track_boundary: bool,
) if (track_boundary) u6 else void {
    var boundary_mask: u6 = 0;

    while (head.* < tail.*) {
        const e = queue[head.*];
        head.* += 1;

        for (0..6) |dir| {
            if (e.dir < 6 and dir == OPPOSITE_DIR[e.dir]) continue;

            const nx = @as(i32, e.x) + BFS_OFFSETS[dir][0];
            const ny = @as(i32, e.y) + BFS_OFFSETS[dir][1];
            const nz = @as(i32, e.z) + BFS_OFFSETS[dir][2];

            if (nx < 0 or nx >= CHUNK_SIZE or ny < 0 or ny >= CHUNK_SIZE or nz < 0 or nz >= CHUNK_SIZE) {
                if (track_boundary) boundary_mask |= @as(u6, 1) << faceBit(dir);
                continue;
            }

            const ux: usize = @intCast(nx);
            const uy: usize = @intCast(ny);
            const uz: usize = @intCast(nz);

            const nidx = chunkIndex(ux, uy, uz);
            const neighbor_block = chunk.blocks.get(nidx);
            if (BlockState.isOpaque(neighbor_block)) continue;

            // Column rule: no attenuation going downward (-Y, dir=3) at max brightness (sky only).
            const sun_col = is_sun and dir == 3 and e.r == 255 and e.g == 255 and e.b == 255;
            // Attenuation + absorption (Cubyz occlusion model)
            const absorb = BlockState.absorption(neighbor_block);
            const nr = if (sun_col) @as(u8, 255) -| absorb[0] else e.r -| ATTENUATION -| absorb[0];
            const ng = if (sun_col) @as(u8, 255) -| absorb[1] else e.g -| ATTENUATION -| absorb[1];
            const nb = if (sun_col) @as(u8, 255) -| absorb[2] else e.b -| ATTENUATION -| absorb[2];

            if (nr == 0 and ng == 0 and nb == 0) continue;

            const existing = getStoredLight(is_sun, light_map, nidx);
            if (nr <= existing[0] and ng <= existing[1] and nb <= existing[2]) continue;

            const updated = [3]u8{
                @max(existing[0], nr),
                @max(existing[1], ng),
                @max(existing[2], nb),
            };
            setStoredLight(is_sun, light_map, nidx, updated);

            if (tail.* < queue.len) {
                queue[tail.*] = .{
                    .x = @intCast(nx),
                    .y = @intCast(ny),
                    .z = @intCast(nz),
                    .dir = @intCast(dir),
                    .r = updated[0],
                    .g = updated[1],
                    .b = updated[2],
                };
                tail.* += 1;
            }
        }
    }

    if (track_boundary) return boundary_mask;
}


/// Fast check: would propagateFromNeighbor actually change any light values?
/// Replicates the seeding conditions without allocating BFS queues.
/// Returns true if any neighbor border value would seed new light that
/// exceeds the existing light map at the corresponding boundary position.
pub fn needsPropagation(
    chunk: *const WorldState.Chunk,
    neighbor_borders: [6]LightBorderSnapshot,
    light_map: *const LightMap,
) bool {
    return needsPropagationChannel(false, chunk, neighbor_borders, light_map) or
        needsPropagationChannel(true, chunk, neighbor_borders, light_map);
}

/// Per-channel propagation check (ChannelChunk pattern).
fn needsPropagationChannel(
    comptime is_sun: bool,
    chunk: *const WorldState.Chunk,
    neighbor_borders: [6]LightBorderSnapshot,
    light_map: *const LightMap,
) bool {
    // Check all 6 face pairs using the same boundary index layout as seedAllBoundaries.
    // +X (face 3) and -X (face 2): iterate y,z
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |z| {
            const bi = y * CHUNK_SIZE + z;
            if (checkBorderExceeds(is_sun, neighbor_borders, light_map, chunk, 3, bi, chunkIndex(CHUNK_SIZE - 1, y, z))) return true;
            if (checkBorderExceeds(is_sun, neighbor_borders, light_map, chunk, 2, bi, chunkIndex(0, y, z))) return true;
        }
    }
    // +Z (face 0) and -Z (face 1): iterate y,x
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |x| {
            const bi = y * CHUNK_SIZE + x;
            if (checkBorderExceeds(is_sun, neighbor_borders, light_map, chunk, 0, bi, chunkIndex(x, y, CHUNK_SIZE - 1))) return true;
            if (checkBorderExceeds(is_sun, neighbor_borders, light_map, chunk, 1, bi, chunkIndex(x, y, 0))) return true;
        }
    }
    // +Y (face 4) and -Y (face 5): iterate z,x
    for (0..CHUNK_SIZE) |z| {
        for (0..CHUNK_SIZE) |x| {
            const bi = z * CHUNK_SIZE + x;
            if (checkBorderExceeds(is_sun, neighbor_borders, light_map, chunk, 4, bi, chunkIndex(x, CHUNK_SIZE - 1, z))) return true;
            if (checkBorderExceeds(is_sun, neighbor_borders, light_map, chunk, 5, bi, chunkIndex(x, 0, z))) return true;
        }
    }
    return false;
}

fn checkBorderExceeds(
    comptime is_sun: bool,
    neighbor_borders: [6]LightBorderSnapshot,
    light_map: *const LightMap,
    chunk: *const WorldState.Chunk,
    face: usize,
    bi: usize,
    idx: usize,
) bool {
    const nl = getNeighborLight(is_sun, neighbor_borders, face, bi);
    // Sun column rule: face 4 (+Y) = above neighbor, light travels -Y (downward)
    const sun_col = is_sun and face == 4 and nl[0] == 255 and nl[1] == 255 and nl[2] == 255;
    const nr = if (sun_col) @as(u8, 255) else nl[0] -| ATTENUATION;
    const ng = if (sun_col) @as(u8, 255) else nl[1] -| ATTENUATION;
    const nb = if (sun_col) @as(u8, 255) else nl[2] -| ATTENUATION;
    if (nr == 0 and ng == 0 and nb == 0) return false;
    const target_block = chunk.blocks.get(idx);
    if (BlockState.isOpaque(target_block)) return false;
    const absorb = BlockState.absorption(target_block);
    const ar = nr -| absorb[0];
    const ag = ng -| absorb[1];
    const ab = nb -| absorb[2];
    if (ar == 0 and ag == 0 and ab == 0) return false;
    const ex = getStoredLight(is_sun, light_map, idx);
    return ar > ex[0] or ag > ex[1] or ab > ex[2];
}

/// Additively propagate light from neighbor borders into an already-computed
/// light map. Seeds from all 6 borders and runs BFS for both sky and block
/// light, but only updates positions where incoming light exceeds existing
/// values. Does not clear existing light or re-scan emitters. Used by the
/// light-only refresh path so that light crossing chunk borders propagates
/// inward (like Cubyz's propagateFromNeighbor).
pub fn propagateFromNeighbor(
    chunk: *const WorldState.Chunk,
    neighbor_borders: [6]LightBorderSnapshot,
    light_map: *LightMap,
) void {
    const tz = tracy.zone(@src(), "propagateFromNeighbor");
    defer tz.end();

    // ── Block light ──
    {
        var queue: [MAX_QUEUE]LightQueueEntry = undefined;
        var head: u32 = 0;
        var tail: u32 = 0;
        seedAllBoundaries(false, &queue, &tail, chunk, light_map, neighbor_borders);
        propagateLightBFS(false, &queue, &head, &tail, chunk, light_map, false);
    }

    // ── Sky light ──
    {
        var queue: [MAX_QUEUE]LightQueueEntry = undefined;
        var head: u32 = 0;
        var tail: u32 = 0;
        seedAllBoundaries(true, &queue, &tail, chunk, light_map, neighbor_borders);
        propagateLightBFS(true, &queue, &head, &tail, chunk, light_map, false);
    }
}

// ─── Incremental updates ───

const ReseedPos = struct {
    x: i8,
    y: i8,
    z: i8,
};

/// Collected entries that spill across chunk boundaries during destructive BFS.
/// Each face has its own buffer of entries that need to be processed in the
/// neighbor chunk (Cubyz-style propagateDestructiveFromNeighbor).
pub const BorderSpill = struct {
    pub const MAX_PER_FACE = 1024;
    entries: [6][MAX_PER_FACE]LightQueueEntry = undefined,
    counts: [6]u32 = .{0} ** 6,
};

/// Collected reseed positions from destructive BFS (Cubyz-style deferred reconstruction).
/// Instead of reseeding immediately per-chunk, all reseeds are collected across chunks
/// and batch-reconstructed after ALL destructive passes complete.
pub const ReseedBuffer = struct {
    pub const MAX_RESEEDS = BLOCKS_PER_CHUNK;
    positions: [MAX_RESEEDS]ReseedPos = undefined,
    count: u32 = 0,
};

/// Collected results from recursive cross-chunk destructive BFS.
const SpillContext = struct {
    const MAX_AFFECTED = 32;
    affected_lms: [MAX_AFFECTED]*LightMap = undefined,
    affected_chunks: [MAX_AFFECTED]*const WorldState.Chunk = undefined,
    affected_reseeds: [MAX_AFFECTED]ReseedBuffer = undefined,
    affected_keys: [MAX_AFFECTED]ChunkKey = undefined,
    affected_count: u32 = 0,

    light_maps: *const LightMaps,
    chunk_map: *const ChunkMap,

    fn record(self: *SpillContext, nk: ChunkKey, nlm: *LightMap, nchunk: *const WorldState.Chunk, reseeds: ReseedBuffer) void {
        if (self.affected_count >= MAX_AFFECTED) return;
        self.affected_lms[self.affected_count] = nlm;
        self.affected_chunks[self.affected_count] = nchunk;
        self.affected_reseeds[self.affected_count] = reseeds;
        self.affected_keys[self.affected_count] = nk;
        self.affected_count += 1;
    }
};

/// Process border spill into neighbor chunks (Cubyz-style propagateLightsDestructive).
/// Handles recursive cross-chunk destructive BFS + deferred batch reconstruction.
/// Called after applyBlockChange has processed the source chunk and collected spill.
///
/// Returns the number of affected neighbor chunk keys written to `affected_keys_out`.
/// The caller should submit mesh tasks for each affected key and light-only refreshes
/// for faces indicated by `affected_masks_out` (reseed boundary propagation).
pub fn processNeighborSpill(
    comptime is_sun: bool,
    initial_spill: *const BorderSpill,
    source_key: ChunkKey,
    light_maps: *const LightMaps,
    chunk_map: *const ChunkMap,
    affected_keys_out: []ChunkKey,
    affected_masks_out: []u6,
) u32 {
    var ctx = SpillContext{
        .light_maps = light_maps,
        .chunk_map = chunk_map,
    };

    processSpillRecursive(is_sun, initial_spill, source_key, &ctx, 0);

    // Batch reconstruction — all stale values cleared, reseeds safe.
    // Track reseed boundary masks (Cubyz: propagateDirect crosses chunks;
    // we propagate via light-only refresh for faces the reseed reached).
    const io = Io.Threaded.global_single_threaded.io();
    for (0..ctx.affected_count) |ai| {
        ctx.affected_lms[ai].mutex.lockUncancelable(io);
        const mask = reseedLight(is_sun, ctx.affected_lms[ai], ctx.affected_chunks[ai], ctx.affected_reseeds[ai].positions[0..ctx.affected_reseeds[ai].count]);
        ctx.affected_lms[ai].mutex.unlock(io);
        if (ai < affected_masks_out.len) {
            affected_masks_out[ai] = mask;
        }
    }

    // Copy keys to output
    var key_count: u32 = 0;
    for (0..ctx.affected_count) |ai| {
        if (key_count >= affected_keys_out.len) break;
        affected_keys_out[key_count] = ctx.affected_keys[ai];
        key_count += 1;
    }
    return key_count;
}

/// Recursive cross-chunk destructive BFS. Each call correctly uses `from_key`
/// (the chunk that produced the spill) to compute neighbor keys.
fn processSpillRecursive(
    comptime is_sun: bool,
    spill: *const BorderSpill,
    from_key: ChunkKey,
    ctx: *SpillContext,
    depth: u32,
) void {
    const MAX_DEPTH = 4;
    if (depth >= MAX_DEPTH) return;

    const io = Io.Threaded.global_single_threaded.io();
    const face_offsets = WorldState.face_neighbor_offsets;

    for (0..6) |face| {
        if (spill.counts[face] == 0) continue;
        const nk = ChunkKey{
            .cx = from_key.cx + face_offsets[face][0],
            .cy = from_key.cy + face_offsets[face][1],
            .cz = from_key.cz + face_offsets[face][2],
        };
        const nlm = ctx.light_maps.get(nk) orelse continue;
        const nchunk = ctx.chunk_map.get(nk) orelse continue;

        var new_spill = BorderSpill{};
        var reseeds = ReseedBuffer{};
        nlm.mutex.lockUncancelable(io);
        _ = propagateDestructive(is_sun, nlm, nchunk, spill.entries[face][0..spill.counts[face]], &new_spill, &reseeds);
        nlm.mutex.unlock(io);

        ctx.record(nk, nlm, nchunk, reseeds);

        // Recurse: new_spill is relative to nk (the chunk we just processed)
        var has_next = false;
        for (new_spill.counts) |c| {
            if (c > 0) { has_next = true; break; }
        }
        if (has_next) {
            processSpillRecursive(is_sun, &new_spill, nk, ctx, depth + 1);
        }
    }
}

/// Maps a BFS direction to the entry position in the neighbor chunk.
/// Maps a local position + BFS direction to the 2D border index for reading
/// from LightBorderSnapshot. The index layout matches snapshotNeighborBorders.
fn borderIndex(dir: usize, lx: u8, ly: u8, lz: u8) usize {
    return switch (faceBit(dir)) {
        0, 1 => @as(usize, ly) * CHUNK_SIZE + @as(usize, lx), // +Z/-Z face: y*CS+x
        2, 3 => @as(usize, ly) * CHUNK_SIZE + @as(usize, lz), // -X/+X face: y*CS+z
        4, 5 => @as(usize, lz) * CHUNK_SIZE + @as(usize, lx), // +Y/-Y face: z*CS+x
        else => unreachable,
    };
}

fn borderEntryPos(dir: usize, x: i8, y: i8, z: i8) struct { x: i8, y: i8, z: i8 } {
    const S: i8 = CHUNK_SIZE - 1;
    return switch (dir) {
        0 => .{ .x = 0, .y = y, .z = z },     // +X → neighbor x=0
        1 => .{ .x = S, .y = y, .z = z },      // -X → neighbor x=31
        2 => .{ .x = x, .y = 0, .z = z },      // +Y → neighbor y=0
        3 => .{ .x = x, .y = S, .z = z },      // -Y → neighbor y=31
        4 => .{ .x = x, .y = y, .z = 0 },      // +Z → neighbor z=0
        5 => .{ .x = x, .y = y, .z = S },      // -Z → neighbor z=31
        else => unreachable,
    };
}

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
/// Handles both block light and sky light destructively (no full recompute needed).
/// Returns the boundary mask (which faces had light changes reaching the boundary).
pub fn applyBlockChange(
    chunk: *const WorldState.Chunk,
    light_map: *LightMap,
    local: WorldState.ChunkLocalPos,
    old_block: StateId,
    border_spill: ?*BorderSpill,
    sky_border_spill: ?*BorderSpill,
    neighbor_borders: [6]LightBorderSnapshot,
) u6 {
    const tz = tracy.zone(@src(), "applyBlockChange");
    defer tz.end();
    const lx: u8 = local.x;
    const ly: u8 = local.y;
    const lz: u8 = local.z;
    const idx = chunkIndex(lx, ly, lz);
    const new_block = chunk.blocks.get(idx);

    const old_opaque = BlockState.isOpaque(old_block);
    const new_opaque = BlockState.isOpaque(new_block);
    const old_emit = BlockState.emittedLight(old_block);
    const new_emit = BlockState.emittedLight(new_block);

    var boundary_mask: u6 = 0;

    // ── Block light (Cubyz propagateLightsDestructive pattern) ──

    const current_light = light_map.block_light.get(idx);
    const has_current_light = current_light[0] > 0 or current_light[1] > 0 or current_light[2] > 0;
    const had_emission = old_emit[0] > 0 or old_emit[1] > 0 or old_emit[2] > 0;

    // Destructive pass: remove light from removed/blocked source.
    // Uses deferred reseeds — batch reconstruction after destructive completes.
    if (has_current_light and (new_opaque or had_emission)) {
        var reseeds = ReseedBuffer{};
        const seed = [1]LightQueueEntry{.{
            .x = @intCast(lx), .y = @intCast(ly), .z = @intCast(lz),
            .dir = 6, .r = current_light[0], .g = current_light[1], .b = current_light[2],
            .active = 0b111,
        }};
        boundary_mask |= propagateDestructive(false, light_map, chunk, &seed, border_spill, &reseeds);

        // Batch reconstruction from reseed positions (Cubyz pattern)
        if (reseeds.count > 0) {
            boundary_mask |= reseedLight(false, light_map, chunk, reseeds.positions[0..reseeds.count]);
        }
    }

    // Constructive pass: propagate new emission or fill opened space.
    const has_new_emit = new_emit[0] > 0 or new_emit[1] > 0 or new_emit[2] > 0;
    if (has_new_emit) {
        light_map.block_light.set(idx, new_emit);
        boundary_mask |= additiveLight(false, light_map, chunk, @intCast(lx), @intCast(ly), @intCast(lz), new_emit);
    } else if (old_opaque and !new_opaque and !had_emission) {
        // Opened up (was opaque, now transparent, NOT an emitter) — seed from
        // neighbors' block light, including cross-chunk via border snapshots.
        var seed_val: [3]u8 = .{ 0, 0, 0 };
        for (0..6) |dir| {
            const nx = @as(i32, lx) + BFS_OFFSETS[dir][0];
            const ny = @as(i32, ly) + BFS_OFFSETS[dir][1];
            const nz = @as(i32, lz) + BFS_OFFSETS[dir][2];
            const n_light = if (nx < 0 or nx >= CHUNK_SIZE or ny < 0 or ny >= CHUNK_SIZE or nz < 0 or nz >= CHUNK_SIZE)
                // Cross-chunk: read from border snapshot
                getNeighborLight(false, neighbor_borders, faceBit(dir), borderIndex(dir, lx, ly, lz))
            else
                light_map.block_light.get(chunkIndex(@intCast(nx), @intCast(ny), @intCast(nz)));
            seed_val[0] = @max(seed_val[0], n_light[0] -| ATTENUATION);
            seed_val[1] = @max(seed_val[1], n_light[1] -| ATTENUATION);
            seed_val[2] = @max(seed_val[2], n_light[2] -| ATTENUATION);
        }
        if (seed_val[0] > 0 or seed_val[1] > 0 or seed_val[2] > 0) {
            light_map.block_light.set(idx, seed_val);
            boundary_mask |= additiveLight(false, light_map, chunk, @intCast(lx), @intCast(ly), @intCast(lz), seed_val);
        }
    }

    // ── Sky light (same destructive + constructive pattern) ──

    if (old_opaque != new_opaque) {
        const current_sky = light_map.sky_light.get(idx);
        if (new_opaque) {
            // Placing opaque block — destructively remove sky light.
            if (current_sky > 0) {
                var sky_reseeds = ReseedBuffer{};
                const sky_seed = [1]LightQueueEntry{.{
                    .x = @intCast(lx), .y = @intCast(ly), .z = @intCast(lz),
                    .dir = 6, .r = current_sky, .g = current_sky, .b = current_sky,
                    .active = 0b111,
                }};
                boundary_mask |= propagateDestructive(true, light_map, chunk, &sky_seed, sky_border_spill, &sky_reseeds);

                // Batch reconstruction for sky
                if (sky_reseeds.count > 0) {
                    boundary_mask |= reseedLight(true, light_map, chunk, sky_reseeds.positions[0..sky_reseeds.count]);
                }
            }
        } else {
            // Breaking opaque block — seed sky light from neighbors (including cross-chunk).
            var seed_sky: u8 = 0;
            for (0..6) |dir| {
                const nx = @as(i32, lx) + BFS_OFFSETS[dir][0];
                const ny = @as(i32, ly) + BFS_OFFSETS[dir][1];
                const nz = @as(i32, lz) + BFS_OFFSETS[dir][2];
                const n_sky = if (nx < 0 or nx >= CHUNK_SIZE or ny < 0 or ny >= CHUNK_SIZE or nz < 0 or nz >= CHUNK_SIZE)
                    getNeighborLight(true, neighbor_borders, faceBit(dir), borderIndex(dir, lx, ly, lz))[0]
                else
                    light_map.sky_light.get(chunkIndex(@intCast(nx), @intCast(ny), @intCast(nz)));
                // Column rule: if neighbor above has 255, light comes down with no attenuation.
                const attenuated: u8 = if (dir == 2 and n_sky == 255) 255 else n_sky -| ATTENUATION;
                seed_sky = @max(seed_sky, attenuated);
            }
            if (seed_sky > 0) {
                light_map.sky_light.set(idx, seed_sky);
                boundary_mask |= additiveLight(true, light_map, chunk, @intCast(lx), @intCast(ly), @intCast(lz), .{ seed_sky, seed_sky, seed_sky });
            }
        }
    }

    return boundary_mask;
}

/// Unified destructive block light BFS (Cubyz-style propagateDestructive).
/// Walks the light cone from seed entries, zeroing values that match the
/// expected propagation pattern (per-channel). Collects reseed positions
/// for reconstruction and border spill entries for cross-chunk propagation.
///
/// Used for both source chunk (seed from removed emitter position) and
/// neighbor chunks (seed from border spill entries). The only difference
/// is how `initial_entries` is populated.
/// Unified destructive light BFS (ChannelChunk pattern, Cubyz-style propagateDestructive).
/// Works for both block light and sky light via comptime is_sun.
/// Walks the light cone from seed entries, zeroing values that match the
/// expected propagation pattern (per-channel). Collects reseed positions
/// for reconstruction and border spill entries for cross-chunk propagation.
pub fn propagateDestructive(
    comptime is_sun: bool,
    light_map: *LightMap,
    chunk: *const WorldState.Chunk,
    initial_entries: []const LightQueueEntry,
    border_spill: ?*BorderSpill,
    deferred_reseeds: ?*ReseedBuffer,
) u6 {
    var queue: [DESTRUCTIVE_QUEUE_SIZE]LightQueueEntry = undefined;
    var head: u32 = 0;
    var tail: u32 = 0;

    var reseed: [DESTRUCTIVE_QUEUE_SIZE]ReseedPos = undefined;
    var reseed_count: u32 = 0;
    var boundary_mask: u6 = 0;

    // Seed the queue from initial entries
    for (initial_entries) |entry| {
        if (tail >= DESTRUCTIVE_QUEUE_SIZE) break;
        queue[tail] = entry;
        tail += 1;
    }

    // Phase 1: Destructive BFS — walk the light cone, zeroing values that came from our source.
    while (head < tail) {
        const e = queue[head];
        head += 1;

        const ux: usize = @intCast(e.x);
        const uy: usize = @intCast(e.y);
        const uz: usize = @intCast(e.z);
        const idx = chunkIndex(ux, uy, uz);

        // No opaque check here (matches Cubyz). The per-channel matching
        // naturally handles opaque blocks: stored value is 0 or mismatched,
        // causing all channels to deactivate.

        const actual = getStoredLight(is_sun, light_map, idx);

        // Per-channel: if actual matches expected, it came from our source → clear.
        // If it doesn't match but is non-zero, another source contributes → reseed.
        var active: u3 = 0;
        var need_reseed = false;

        // Cubyz isFirstBlock: initial seed entries (dir=6) force all channels
        // active regardless of match, ensuring the origin is always fully cleared.
        const is_first = (e.dir >= 6);

        if (e.active & 1 != 0) {
            if (is_first or (e.r > 0 and actual[0] == e.r)) {
                active |= 1;
            } else if (actual[0] > 0) {
                need_reseed = true;
            }
        }
        if (e.active & 2 != 0) {
            if (is_first or (e.g > 0 and actual[1] == e.g)) {
                active |= 2;
            } else if (actual[1] > 0) {
                need_reseed = true;
            }
        }
        if (e.active & 4 != 0) {
            if (is_first or (e.b > 0 and actual[2] == e.b)) {
                active |= 4;
            } else if (actual[2] > 0) {
                need_reseed = true;
            }
        }

        // Block emitters need re-seeding (sun channel has no block emission)
        if (!is_sun) {
            const emit = BlockState.emittedLight(chunk.blocks.get(idx));
            if ((active & 1 != 0 and emit[0] > 0) or (active & 2 != 0 and emit[1] > 0) or (active & 4 != 0 and emit[2] > 0)) {
                need_reseed = true;
            }
        }

        if (need_reseed and reseed_count < DESTRUCTIVE_QUEUE_SIZE) {
            reseed[reseed_count] = .{ .x = e.x, .y = e.y, .z = e.z };
            reseed_count += 1;
        }

        if (active == 0) continue;

        // Zero the active channels
        var new_val = actual;
        if (active & 1 != 0) new_val[0] = 0;
        if (active & 2 != 0) new_val[1] = 0;
        if (active & 4 != 0) new_val[2] = 0;
        setStoredLight(is_sun, light_map, idx, new_val);

        for (0..6) |dir| {
            if (e.dir < 6 and dir == OPPOSITE_DIR[e.dir]) continue;

            const nx = @as(i32, e.x) + BFS_OFFSETS[dir][0];
            const ny = @as(i32, e.y) + BFS_OFFSETS[dir][1];
            const nz = @as(i32, e.z) + BFS_OFFSETS[dir][2];

            if (nx < 0 or nx >= CHUNK_SIZE or ny < 0 or ny >= CHUNK_SIZE or nz < 0 or nz >= CHUNK_SIZE) {
                if (active != 0) {
                    boundary_mask |= @as(u6, 1) << faceBit(dir);
                    if (border_spill) |spill| {
                        const face = faceBit(dir);
                        if (spill.counts[face] < BorderSpill.MAX_PER_FACE) {
                            // Column rule: no attenuation going downward at max brightness (sky only)
                            const sc = is_sun and dir == 3 and e.r == 255 and e.g == 255 and e.b == 255;
                            const exp_r = if (sc) @as(u8, 255) else e.r -| ATTENUATION;
                            const exp_g = if (sc) @as(u8, 255) else e.g -| ATTENUATION;
                            const exp_b = if (sc) @as(u8, 255) else e.b -| ATTENUATION;
                            if (exp_r > 0 or exp_g > 0 or exp_b > 0) {
                                const pos = borderEntryPos(dir, e.x, e.y, e.z);
                                spill.entries[face][spill.counts[face]] = .{
                                    .x = pos.x, .y = pos.y, .z = pos.z,
                                    .dir = @intCast(dir),
                                    .r = exp_r, .g = exp_g, .b = exp_b,
                                    .active = active,
                                };
                                spill.counts[face] += 1;
                            }
                        }
                    }
                }
                continue;
            }

            // Column rule + absorption (must match additive BFS formula)
            const sc2 = is_sun and dir == 3 and e.r == 255 and e.g == 255 and e.b == 255;
            const d_absorb = BlockState.absorption(chunk.blocks.get(chunkIndex(@intCast(nx), @intCast(ny), @intCast(nz))));
            const exp_r = if (sc2) @as(u8, 255) -| d_absorb[0] else e.r -| ATTENUATION -| d_absorb[0];
            const exp_g = if (sc2) @as(u8, 255) -| d_absorb[1] else e.g -| ATTENUATION -| d_absorb[1];
            const exp_b = if (sc2) @as(u8, 255) -| d_absorb[2] else e.b -| ATTENUATION -| d_absorb[2];

            if (exp_r == 0 and exp_g == 0 and exp_b == 0) continue;

            if (tail < DESTRUCTIVE_QUEUE_SIZE) {
                queue[tail] = .{
                    .x = @intCast(nx), .y = @intCast(ny), .z = @intCast(nz),
                    .dir = @intCast(dir),
                    .r = exp_r, .g = exp_g, .b = exp_b,
                    .active = active,
                };
                tail += 1;
            }
        }
    }

    // Phase 2: Reseed or defer
    if (reseed_count > 0) {
        if (deferred_reseeds) |buf| {
            for (reseed[0..reseed_count]) |rs| {
                if (buf.count < ReseedBuffer.MAX_RESEEDS) {
                    buf.positions[buf.count] = rs;
                    buf.count += 1;
                }
            }
        } else {
            boundary_mask |= reseedLight(is_sun, light_map, chunk, reseed[0..reseed_count]);
        }
    }

    return boundary_mask;
}

/// Re-propagates light from reseed positions using Cubyz's constructive BFS pattern.
/// Zeros stored values, enqueues with the reconstruction value, then runs a BFS
/// that processes the entry position at dequeue time (max-merge + write) before
/// propagating to neighbors. This matches Cubyz's propagateLightsDestructive
/// constructive phase exactly.
pub fn reseedLight(
    comptime is_sun: bool,
    light_map: *LightMap,
    chunk: *const WorldState.Chunk,
    reseeds: []const ReseedPos,
) u6 {
    var queue: [MAX_QUEUE]LightQueueEntry = undefined;
    var head: u32 = 0;
    var tail: u32 = 0;

    for (reseeds) |rs| {
        const rs_idx = chunkIndex(@intCast(rs.x), @intCast(rs.y), @intCast(rs.z));
        const current = getStoredLight(is_sun, light_map, rs_idx);
        const val = if (is_sun) current else blk: {
            const emit = BlockState.emittedLight(chunk.blocks.get(rs_idx));
            break :blk [3]u8{
                @max(current[0], emit[0]),
                @max(current[1], emit[1]),
                @max(current[2], emit[2]),
            };
        };
        if (val[0] == 0 and val[1] == 0 and val[2] == 0) continue;

        // Zero stored value before enqueuing — BFS max-merge will re-write it
        // (Cubyz propagateLightsDestructive constructive phase pattern)
        setStoredLight(is_sun, light_map, rs_idx, .{ 0, 0, 0 });
        if (tail < MAX_QUEUE) {
            queue[tail] = .{ .x = rs.x, .y = rs.y, .z = rs.z, .dir = 6, .r = val[0], .g = val[1], .b = val[2] };
            tail += 1;
        }
    }

    // Cubyz propagateDirect-style BFS: process entry position at dequeue
    // (read existing, max-merge, write, then propagate to neighbors).
    var boundary_mask: u6 = 0;

    while (head < tail) {
        const e = queue[head];
        head += 1;

        const eidx = chunkIndex(@intCast(e.x), @intCast(e.y), @intCast(e.z));
        const existing = getStoredLight(is_sun, light_map, eidx);
        const val2 = [3]u8{
            @max(e.r, existing[0]),
            @max(e.g, existing[1]),
            @max(e.b, existing[2]),
        };
        if (val2[0] == existing[0] and val2[1] == existing[1] and val2[2] == existing[2]) continue;
        setStoredLight(is_sun, light_map, eidx, val2);

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

            const n_block = chunk.blocks.get(chunkIndex(ux, uy, uz));
            if (BlockState.isOpaque(n_block)) continue;

            const sun_col = is_sun and dir == 3 and val2[0] == 255 and val2[1] == 255 and val2[2] == 255;
            const absorb = BlockState.absorption(n_block);
            const nr = if (sun_col) @as(u8, 255) -| absorb[0] else val2[0] -| ATTENUATION -| absorb[0];
            const ng = if (sun_col) @as(u8, 255) -| absorb[1] else val2[1] -| ATTENUATION -| absorb[1];
            const nb = if (sun_col) @as(u8, 255) -| absorb[2] else val2[2] -| ATTENUATION -| absorb[2];

            if (nr == 0 and ng == 0 and nb == 0) continue;

            if (tail < queue.len) {
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

/// Additive light BFS: propagates light outward from a single position (ChannelChunk pattern).
fn additiveLight(
    comptime is_sun: bool,
    light_map: *LightMap,
    chunk: *const WorldState.Chunk,
    sx: i8,
    sy: i8,
    sz: i8,
    start_val: [3]u8,
) u6 {
    var queue: [BLOCKS_PER_CHUNK]LightQueueEntry = undefined;
    var head: u32 = 0;
    var tail: u32 = 0;

    queue[0] = .{ .x = sx, .y = sy, .z = sz, .dir = 6, .r = start_val[0], .g = start_val[1], .b = start_val[2] };
    tail = 1;

    return propagateLightBFS(is_sun, &queue, &head, &tail, chunk, light_map, true);
}

// ─── Tests ───

const testing = std.testing;

const Chunk = WorldState.Chunk;

const no_neighbors: [6]?*const Chunk = .{ null, null, null, null, null, null };
const no_light_neighbors: [6]?*LightMap = .{ null, null, null, null, null, null };
const no_borders: [6]LightBorderSnapshot = .{LightBorderSnapshot.empty} ** 6;

fn allocChunk() !*Chunk {
    const chunk = try testing.allocator.create(Chunk);
    chunk.blocks = WorldState.PaletteBlocks.init(testing.allocator);
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
    defer {
        chunk.blocks.deinit();
        testing.allocator.destroy(chunk);
    }
    chunk.blocks.set(chunkIndex(16, 16, 16), BlockState.defaultState(.glowstone));

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
    defer {
        chunk.blocks.deinit();
        testing.allocator.destroy(chunk);
    }
    chunk.blocks.set(chunkIndex(16, 16, 16), BlockState.defaultState(.glowstone));

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
    defer {
        chunk.blocks.deinit();
        testing.allocator.destroy(chunk);
    }
    chunk.blocks.set(chunkIndex(16, 16, 16), BlockState.defaultState(.glowstone));
    chunk.blocks.set(chunkIndex(17, 16, 16), BlockState.defaultState(.stone));

    const lm = try allocLightMap();
    defer freeLightMap(lm);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm, 0, null);

    const behind = lm.block_light.get(chunkIndex(18, 16, 16));
    const no_wall_level = 255 - 2 * ATTENUATION;
    try testing.expect(behind[0] < no_wall_level);
}

test "sky light fills air chunk with no above neighbor" {
    const chunk = try allocChunk();
    defer {
        chunk.blocks.deinit();
        testing.allocator.destroy(chunk);
    }

    const lm = try allocLightMap();
    defer freeLightMap(lm);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm, 0, null);

    try testing.expectEqual(@as(u8, 255), lm.sky_light.get(chunkIndex(0, 0, 0)));
    try testing.expectEqual(@as(u8, 255), lm.sky_light.get(chunkIndex(16, 16, 16)));
    try testing.expectEqual(@as(u8, 255), lm.sky_light.get(chunkIndex(CHUNK_SIZE - 1, CHUNK_SIZE - 1, CHUNK_SIZE - 1)));
}

test "sky light blocked by opaque block above" {
    const chunk = try allocChunk();
    defer {
        chunk.blocks.deinit();
        testing.allocator.destroy(chunk);
    }
    for (0..CHUNK_SIZE) |z| {
        for (0..CHUNK_SIZE) |x| {
            chunk.blocks.set(chunkIndex(x, CHUNK_SIZE - 1, z), BlockState.defaultState(.stone));
        }
    }

    const lm = try allocLightMap();
    defer freeLightMap(lm);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm, 0, null);

    try testing.expectEqual(@as(u8, 0), lm.sky_light.get(chunkIndex(16, 0, 16)));
}

test "block light propagates across chunk boundary via neighbor light map" {
    const chunk_a = try allocChunk();
    defer {
        chunk_a.blocks.deinit();
        testing.allocator.destroy(chunk_a);
    }
    chunk_a.blocks.set(chunkIndex(CHUNK_SIZE - 1, 16, 16), BlockState.defaultState(.glowstone));

    const lm_a = try allocLightMap();
    defer freeLightMap(lm_a);
    _ = computeChunkLight(chunk_a, no_neighbors, no_borders, lm_a, 0, null);

    try testing.expectEqual(@as(u8, 255), lm_a.block_light.get(chunkIndex(CHUNK_SIZE - 1, 16, 16))[0]);

    const chunk_b = try allocChunk();
    defer {
        chunk_b.blocks.deinit();
        testing.allocator.destroy(chunk_b);
    }
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
    defer {
        chunk.blocks.deinit();
        testing.allocator.destroy(chunk);
    }

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
    defer {
        chunk.blocks.deinit();
        testing.allocator.destroy(chunk);
    }

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
    defer {
        chunk.blocks.deinit();
        testing.allocator.destroy(chunk);
    }

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
    // y=8 → world_y=40, AT surface → column rule: sky light (255) propagates
    // straight down with no attenuation (Cubyz isSun behavior).
    try testing.expectEqual(@as(u8, 255), lm.sky_light.get(chunkIndex(16, 8, 16)));
    // y=0 → world_y=32, below surface → column rule gives 255 all the way down
    try testing.expectEqual(@as(u8, 255), lm.sky_light.get(chunkIndex(16, 0, 16)));
}

test "sky light propagates laterally across chunk boundary" {
    // Chunk A has full skylight (no surface heights → all sky open)
    const chunk_a = try allocChunk();
    defer {
        chunk_a.blocks.deinit();
        testing.allocator.destroy(chunk_a);
    }
    const lm_a = try allocLightMap();
    defer freeLightMap(lm_a);
    _ = computeChunkLight(chunk_a, no_neighbors, no_borders, lm_a, 0, null);

    // Chunk B: surface height blocks sky from above, but chunk A is its -X neighbor
    // Use surface heights that indicate opaque blocks above this chunk
    const chunk_b = try allocChunk();
    defer {
        chunk_b.blocks.deinit();
        testing.allocator.destroy(chunk_b);
    }

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
    defer {
        chunk.blocks.deinit();
        testing.allocator.destroy(chunk);
    }
    chunk.blocks.set(chunkIndex(CHUNK_SIZE - 1, 16, 16), BlockState.defaultState(.glowstone));

    const lm = try allocLightMap();
    defer freeLightMap(lm);
    const mask = computeChunkLight(chunk, no_neighbors, no_borders, lm, 0, null);

    try testing.expect(mask & (1 << 3) != 0);
}

test "boundary mask not set for face with no light" {
    const chunk = try allocChunk();
    defer {
        chunk.blocks.deinit();
        testing.allocator.destroy(chunk);
    }
    chunk.blocks.set(chunkIndex(16, 16, 16), BlockState.defaultState(.glowstone));

    const lm = try allocLightMap();
    defer freeLightMap(lm);
    const mask = computeChunkLight(chunk, no_neighbors, no_borders, lm, 0, null);

    // Red channel 255 reaches all boundaries (255 - 16*8 = 127 > 8)
    try testing.expectEqual(@as(u6, 0b111111), mask);
}

test "dirty flag cleared after compute" {
    const chunk = try allocChunk();
    defer {
        chunk.blocks.deinit();
        testing.allocator.destroy(chunk);
    }
    const lm = try allocLightMap();
    defer freeLightMap(lm);
    try testing.expect(lm.dirty);

    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm, 0, null);
    try testing.expect(!lm.dirty);
}

test "bidirectional boundary propagation" {
    const chunk_a = try allocChunk();
    defer {
        chunk_a.blocks.deinit();
        testing.allocator.destroy(chunk_a);
    }
    chunk_a.blocks.set(chunkIndex(CHUNK_SIZE - 2, 16, 16), BlockState.defaultState(.glowstone));

    const lm_a = try allocLightMap();
    defer freeLightMap(lm_a);
    _ = computeChunkLight(chunk_a, no_neighbors, no_borders, lm_a, 0, null);

    const chunk_b = try allocChunk();
    defer {
        chunk_b.blocks.deinit();
        testing.allocator.destroy(chunk_b);
    }
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
            chunk.blocks.set(chunkIndex(x, CHUNK_SIZE - 1, z), BlockState.defaultState(.stone));
        }
    }
    return chunk;
}

test "incremental: remove glowstone clears its light" {
    const chunk = try makeUndergroundChunk();
    defer {
        chunk.blocks.deinit();
        testing.allocator.destroy(chunk);
    }
    chunk.blocks.set(chunkIndex(16, 16, 16), BlockState.defaultState(.glowstone));

    const lm = try allocLightMap();
    defer freeLightMap(lm);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm, 0, &underground_surface);

    try testing.expectEqual(@as(u8, 255), lm.block_light.get(chunkIndex(16, 16, 16))[0]);
    try testing.expectEqual(@as(u8, 255 - ATTENUATION), lm.block_light.get(chunkIndex(17, 16, 16))[0]);

    const old_block = chunk.blocks.get(chunkIndex(16, 16, 16));
    chunk.blocks.set(chunkIndex(16, 16, 16), AIR);
    _ = applyBlockChange(chunk, lm, .{ .x = 16, .y = 16, .z = 16 }, old_block, null, null, no_borders);

    try testing.expectEqual(@as(u8, 0), lm.block_light.get(chunkIndex(16, 16, 16))[0]);
    try testing.expectEqual(@as(u8, 0), lm.block_light.get(chunkIndex(17, 16, 16))[0]);
    try testing.expectEqual(@as(u8, 0), lm.block_light.get(chunkIndex(15, 16, 16))[0]);
    try testing.expectEqual(@as(u8, 0), lm.block_light.get(chunkIndex(16, 16, 20))[0]);
}

test "incremental: place opaque block blocks light" {
    const chunk = try makeUndergroundChunk();
    defer {
        chunk.blocks.deinit();
        testing.allocator.destroy(chunk);
    }
    chunk.blocks.set(chunkIndex(16, 16, 16), BlockState.defaultState(.glowstone));

    const lm = try allocLightMap();
    defer freeLightMap(lm);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm, 0, &underground_surface);

    try testing.expectEqual(@as(u8, 255 - 2 * ATTENUATION), lm.block_light.get(chunkIndex(18, 16, 16))[0]);

    chunk.blocks.set(chunkIndex(17, 16, 16), BlockState.defaultState(.stone));
    _ = applyBlockChange(chunk, lm, .{ .x = 17, .y = 16, .z = 16 }, AIR, null, null, no_borders);

    try testing.expectEqual(@as(u8, 0), lm.block_light.get(chunkIndex(17, 16, 16))[0]);
    const behind = lm.block_light.get(chunkIndex(18, 16, 16));
    try testing.expect(behind[0] < 255 - 2 * ATTENUATION);
}

test "incremental: break opaque block lets light through" {
    const chunk = try makeUndergroundChunk();
    defer {
        chunk.blocks.deinit();
        testing.allocator.destroy(chunk);
    }
    chunk.blocks.set(chunkIndex(16, 16, 16), BlockState.defaultState(.glowstone));
    chunk.blocks.set(chunkIndex(17, 16, 16), BlockState.defaultState(.stone)); // wall blocking +X

    const lm = try allocLightMap();
    defer freeLightMap(lm);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm, 0, &underground_surface);

    // (18, 16, 16) is behind the wall — should have reduced light
    const before = lm.block_light.get(chunkIndex(18, 16, 16))[0];
    try testing.expect(before < 255 - 2 * ATTENUATION);

    // Break the wall
    chunk.blocks.set(chunkIndex(17, 16, 16), AIR);
    _ = applyBlockChange(chunk, lm, .{ .x = 17, .y = 16, .z = 16 }, BlockState.defaultState(.stone), null, null, no_borders);

    // (17, 16, 16) should now have light from glowstone
    try testing.expectEqual(@as(u8, 255 - ATTENUATION), lm.block_light.get(chunkIndex(17, 16, 16))[0]);
    // (18, 16, 16) should now have full unblocked light
    try testing.expectEqual(@as(u8, 255 - 2 * ATTENUATION), lm.block_light.get(chunkIndex(18, 16, 16))[0]);
}

test "incremental: two glowstones, remove one preserves other" {
    const chunk = try makeUndergroundChunk();
    defer {
        chunk.blocks.deinit();
        testing.allocator.destroy(chunk);
    }
    chunk.blocks.set(chunkIndex(10, 16, 16), BlockState.defaultState(.glowstone));
    chunk.blocks.set(chunkIndex(20, 16, 16), BlockState.defaultState(.glowstone));

    const lm = try allocLightMap();
    defer freeLightMap(lm);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm, 0, &underground_surface);

    const mid_before = lm.block_light.get(chunkIndex(15, 16, 16));
    try testing.expect(mid_before[0] > 0);

    chunk.blocks.set(chunkIndex(10, 16, 16), AIR);
    _ = applyBlockChange(chunk, lm, .{ .x = 10, .y = 16, .z = 16 }, BlockState.defaultState(.glowstone), null, null, no_borders);

    try testing.expectEqual(@as(u8, 255 - 10 * ATTENUATION), lm.block_light.get(chunkIndex(10, 16, 16))[0]);
    try testing.expectEqual(@as(u8, 255), lm.block_light.get(chunkIndex(20, 16, 16))[0]);
    try testing.expectEqual(@as(u8, 255 - ATTENUATION), lm.block_light.get(chunkIndex(19, 16, 16))[0]);
    try testing.expectEqual(@as(u8, 255 - 5 * ATTENUATION), lm.block_light.get(chunkIndex(15, 16, 16))[0]);
}

test "incremental: place glowstone adds light" {
    const chunk = try makeUndergroundChunk();
    defer {
        chunk.blocks.deinit();
        testing.allocator.destroy(chunk);
    }

    const lm = try allocLightMap();
    defer freeLightMap(lm);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm, 0, &underground_surface);

    // All dark
    try testing.expectEqual(@as(u8, 0), lm.block_light.get(chunkIndex(16, 16, 16))[0]);

    // Place glowstone
    chunk.blocks.set(chunkIndex(16, 16, 16), BlockState.defaultState(.glowstone));
    _ = applyBlockChange(chunk, lm, .{ .x = 16, .y = 16, .z = 16 }, AIR, null, null, no_borders);

    // Should now have light
    try testing.expectEqual(@as(u8, 255), lm.block_light.get(chunkIndex(16, 16, 16))[0]);
    try testing.expectEqual(@as(u8, 200), lm.block_light.get(chunkIndex(16, 16, 16))[1]);
    try testing.expectEqual(@as(u8, 100), lm.block_light.get(chunkIndex(16, 16, 16))[2]);

    // Adjacent
    try testing.expectEqual(@as(u8, 255 - ATTENUATION), lm.block_light.get(chunkIndex(17, 16, 16))[0]);
}

test "incremental: matches full recompute for remove glowstone" {
    const chunk = try makeUndergroundChunk();
    defer {
        chunk.blocks.deinit();
        testing.allocator.destroy(chunk);
    }
    chunk.blocks.set(chunkIndex(16, 16, 16), BlockState.defaultState(.glowstone));

    const lm_inc = try allocLightMap();
    defer freeLightMap(lm_inc);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm_inc, 0, &underground_surface);

    chunk.blocks.set(chunkIndex(16, 16, 16), AIR);
    _ = applyBlockChange(chunk, lm_inc, .{ .x = 16, .y = 16, .z = 16 }, BlockState.defaultState(.glowstone), null, null, no_borders);

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

test "incremental: matches full recompute for place wall" {
    const chunk = try makeUndergroundChunk();
    defer {
        chunk.blocks.deinit();
        testing.allocator.destroy(chunk);
    }
    chunk.blocks.set(chunkIndex(16, 16, 16), BlockState.defaultState(.glowstone));

    const lm_inc = try allocLightMap();
    defer freeLightMap(lm_inc);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm_inc, 0, &underground_surface);

    chunk.blocks.set(chunkIndex(17, 16, 16), BlockState.defaultState(.stone));
    _ = applyBlockChange(chunk, lm_inc, .{ .x = 17, .y = 16, .z = 16 }, AIR, null, null, no_borders);

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
    defer {
        chunk.blocks.deinit();
        testing.allocator.destroy(chunk);
    }
    chunk.blocks.set(chunkIndex(16, 16, 16), BlockState.defaultState(.glowstone));
    chunk.blocks.set(chunkIndex(17, 16, 16), BlockState.defaultState(.stone));

    const lm_inc = try allocLightMap();
    defer freeLightMap(lm_inc);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm_inc, 0, &underground_surface);

    // Break the wall
    chunk.blocks.set(chunkIndex(17, 16, 16), AIR);
    _ = applyBlockChange(chunk, lm_inc, .{ .x = 17, .y = 16, .z = 16 }, BlockState.defaultState(.stone), null, null, no_borders);

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

test "incremental: place stone in sky light removes sky destructively" {
    const chunk = try allocChunk();
    defer {
        chunk.blocks.deinit();
        testing.allocator.destroy(chunk);
    }

    const lm = try allocLightMap();
    defer freeLightMap(lm);
    // All air, no surface → sky light everywhere = 255
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm, 0, null);

    // Place stone in a sky-lit area: should handle destructively (not null)
    chunk.blocks.set(chunkIndex(16, 16, 16), BlockState.defaultState(.stone));
    const result = applyBlockChange(chunk, lm, .{ .x = 16, .y = 16, .z = 16 }, AIR, null, null, no_borders);
    try testing.expect(result != 0); // boundary reached

    // Stone block should have no sky light
    try testing.expectEqual(@as(u8, 0), lm.sky_light.get(chunkIndex(16, 16, 16)));
    // Block above should still have full sky
    try testing.expectEqual(@as(u8, 255), lm.sky_light.get(chunkIndex(16, 17, 16)));
    // Neighboring column should still have full sky
    try testing.expectEqual(@as(u8, 255), lm.sky_light.get(chunkIndex(17, 16, 16)));
    // Block below: column blocked, gets light from sides (255 - 8 = 247)
    try testing.expectEqual(@as(u8, 255 - ATTENUATION), lm.sky_light.get(chunkIndex(16, 15, 16)));
}

test "incremental: sky light matches full recompute for place stone" {
    const chunk = try allocChunk();
    defer {
        chunk.blocks.deinit();
        testing.allocator.destroy(chunk);
    }

    const lm_inc = try allocLightMap();
    defer freeLightMap(lm_inc);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm_inc, 0, null);

    // Incremental place
    chunk.blocks.set(chunkIndex(16, 16, 16), BlockState.defaultState(.stone));
    _ = applyBlockChange(chunk, lm_inc, .{ .x = 16, .y = 16, .z = 16 }, AIR, null, null, no_borders);

    // Full recompute
    const lm_full = try allocLightMap();
    defer freeLightMap(lm_full);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm_full, 0, null);

    // Compare all sky light values
    for (0..BLOCKS_PER_CHUNK) |i| {
        try testing.expectEqual(lm_full.sky_light.get(i), lm_inc.sky_light.get(i));
    }
    // Also compare block light
    for (0..BLOCKS_PER_CHUNK) |i| {
        const inc = lm_inc.block_light.get(i);
        const full = lm_full.block_light.get(i);
        try testing.expectEqual(full[0], inc[0]);
        try testing.expectEqual(full[1], inc[1]);
        try testing.expectEqual(full[2], inc[2]);
    }
}

test "incremental: break stone in sky column matches full recompute" {
    const chunk = try allocChunk();
    defer {
        chunk.blocks.deinit();
        testing.allocator.destroy(chunk);
    }
    // Start with a stone block blocking a column
    chunk.blocks.set(chunkIndex(16, 16, 16), BlockState.defaultState(.stone));

    const lm_inc = try allocLightMap();
    defer freeLightMap(lm_inc);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm_inc, 0, null);

    // Incremental break
    chunk.blocks.set(chunkIndex(16, 16, 16), AIR);
    _ = applyBlockChange(chunk, lm_inc, .{ .x = 16, .y = 16, .z = 16 }, BlockState.defaultState(.stone), null, null, no_borders);

    // Full recompute
    const lm_full = try allocLightMap();
    defer freeLightMap(lm_full);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm_full, 0, null);

    // Compare all sky light values
    for (0..BLOCKS_PER_CHUNK) |i| {
        try testing.expectEqual(lm_full.sky_light.get(i), lm_inc.sky_light.get(i));
    }
}

test "incremental: no-op change in dark area" {
    const chunk = try makeUndergroundChunk();
    defer {
        chunk.blocks.deinit();
        testing.allocator.destroy(chunk);
    }

    const lm = try allocLightMap();
    defer freeLightMap(lm);
    _ = computeChunkLight(chunk, no_neighbors, no_borders, lm, 0, &underground_surface);

    // Place and break stone in a completely dark interior area
    chunk.blocks.set(chunkIndex(16, 10, 16), BlockState.defaultState(.stone));
    const result = applyBlockChange(chunk, lm, .{ .x = 16, .y = 10, .z = 16 }, AIR, null, null, no_borders);
    try testing.expectEqual(@as(u6, 0), result);
}
