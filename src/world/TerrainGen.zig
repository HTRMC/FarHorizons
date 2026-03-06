const std = @import("std");
const WorldState = @import("WorldState.zig");
const Noise = @import("Noise.zig");

const Chunk = WorldState.Chunk;
const ChunkKey = WorldState.ChunkKey;
const BlockType = WorldState.BlockType;
const CHUNK_SIZE = WorldState.CHUNK_SIZE;
const CS = CHUNK_SIZE;

// ============================================================
// Infdev-exact terrain parameters (from inf-20100618 a.java)
// ============================================================

// Noise generators in Infdev:
//   this.b = 16-octave Perlin, density A, scale 684.412
//   this.c = 16-octave Perlin, density B, scale 684.412
//   this.d = 8-octave Perlin, selector,  scale 8.555 (xz), 4.278 (y)
//   this.g = 10-octave Perlin, height modifier (2D), scale 1.0
//   this.h = 16-octave Perlin, roughness (2D), scale 100.0
const DENSITY_SCALE: f32 = 684.412;
const SELECTOR_SCALE_XZ: f32 = 8.555;
const SELECTOR_SCALE_Y: f32 = 4.278;
const DENSITY_OCTAVES: u32 = 16;
const SELECTOR_OCTAVES: u32 = 8;
const HEIGHT_MOD_OCTAVES: u32 = 10;
const ROUGHNESS_OCTAVES: u32 = 16;

// Infdev sea level = 64, world height = 128.
// We map: Infdev y=0 → our y=-64, Infdev y=64 → our y=0, Infdev y=127 → our y=63.
const SEA_LEVEL: i32 = 0;
const INFDEV_SEA_LEVEL: f32 = 64.0;

// Infdev's coarse vertical step is 8 blocks (17 samples for 128 blocks).
// Our chunks use STEP=4 for XZ, but vertical bias must use Infdev's scale.
const INFDEV_Y_STEP: f32 = 8.0;

// Measured: FN2 raw Perlin range ~[-0.595, 0.791] (via outputMinMax over large grids).
// Java improved Perlin range ~[-1.0, 1.0] (theoretical max after trilinear interpolation).
// Scale FN2 output by ~1.27 to match Java's amplitude.
const FN2_SCALE: f32 = 1.27;

// --- Cave parameters (matching Infdev) ---
const CAVE_SCAN_RANGE: i32 = 4; // Infdev scans ±8 for 16-block chunks; ±4 for 32-block
const CAVE_LAVA_Y: i32 = -54; // Infdev y=10 → our y = 10-64 = -54

// --- Biomes ---
const Biome = enum { plains, desert, tundra, mountains };

pub fn generateChunk(chunk: *Chunk, key: ChunkKey, seed: u64) void {
    var noise = Noise.init() orelse {
        std.log.err("[TerrainGen] FastNoise2 init failed, falling back to flat chunk", .{});
        WorldState.generateFlatChunk(chunk, key);
        return;
    };
    defer noise.deinit();

    const seed_i32: i32 = @truncate(@as(i64, @bitCast(seed)));
    const origin = key.position();

    // Infdev coarse grid: world pos / 4 = grid index.
    // Our grid starts at chunk origin / STEP.
    const gx_start: i32 = @divFloor(origin[0], Noise.STEP);
    const gy_start: i32 = @divFloor(origin[1], Noise.STEP);
    const gz_start: i32 = @divFloor(origin[2], Noise.STEP);

    // --- 2D grids: height modifier and roughness ---
    var height_mod: [Noise.SC2]f32 = undefined;
    var roughness: [Noise.SC2]f32 = undefined;
    noise.infdevFbm2D(&height_mod, gx_start, gz_start, seed_i32 +% 100, 1.0, HEIGHT_MOD_OCTAVES);
    noise.infdevFbm2D(&roughness, gx_start, gz_start, seed_i32 +% 200, 100.0, ROUGHNESS_OCTAVES);

    // --- 3D grids: density A, density B, selector ---
    var density_a: [Noise.SC3]f32 = undefined;
    var density_b: [Noise.SC3]f32 = undefined;
    var selector: [Noise.SC3]f32 = undefined;
    noise.infdevFbm3D(&density_a, gx_start, gy_start, gz_start, seed_i32, DENSITY_SCALE, DENSITY_SCALE, DENSITY_OCTAVES);
    noise.infdevFbm3D(&density_b, gx_start, gy_start, gz_start, seed_i32 +% 9999, DENSITY_SCALE, DENSITY_SCALE, DENSITY_OCTAVES);
    noise.infdevFbm3D(&selector, gx_start, gy_start, gz_start, seed_i32 +% 55555, SELECTOR_SCALE_XZ, SELECTOR_SCALE_Y, SELECTOR_OCTAVES);

    // --- Fill chunk ---
    chunk.blocks = .{.air} ** WorldState.BLOCKS_PER_CHUNK;

    const oy_i32 = origin[1];

    for (0..CS) |bz| {
        for (0..CS) |bx| {
            // 2D height modifiers scaled for FN2 (Infdev lines 70-98)
            const hmod_raw = Noise.bilerp2D(&height_mod, bx, bz) * FN2_SCALE;
            const rough_raw = Noise.bilerp2D(&roughness, bx, bz) * FN2_SCALE;

            // var65 = height scale factor (Infdev lines 70-73, 87, 96)
            var var65 = @min((hmod_raw + 256.0) / 512.0, 1.0);

            // var67 = terrain type (Infdev lines 76-97)
            var var67 = @abs(rough_raw / 8000.0) * 3.0 - 3.0;
            if (var67 < 0.0) {
                // Infdev: var67 /= 2, clamp to -1, then /= 1.4, then /= 2
                var67 = @max(var67 / 2.0, -1.0);
                var67 = var67 / 1.4 / 2.0;
                var65 = 0.0; // Infdev line 87: reset when terrain is low
            } else {
                var67 = @min(var67, 1.0) / 6.0;
            }

            var65 += 0.5; // Infdev line 96
            var67 = var67 * 17.0 / 16.0; // Infdev line 97

            // Surface level in coarse grid units (Infdev's 8-block vertical step)
            const surface_grid = 8.5 + var67 * 4.0;

            for (0..CS) |by| {
                const wy = oy_i32 + @as(i32, @intCast(by));
                const wy_f: f32 = @floatFromInt(wy);
                const idx = WorldState.chunkIndex(bx, by, bz);

                // Trilinear interpolation of 3D noise, scaled for FN2
                const da = Noise.trilerp3D(&density_a, bx, by, bz) * FN2_SCALE / 512.0;
                const db = Noise.trilerp3D(&density_b, bx, by, bz) * FN2_SCALE / 512.0;
                const sel_raw = Noise.trilerp3D(&selector, bx, by, bz) * FN2_SCALE;

                // Selector: Infdev line 111 — (sel/10 + 1) / 2
                const sel = std.math.clamp((sel_raw / 10.0 + 1.0) / 2.0, 0.0, 1.0);
                const blended = da * (1.0 - sel) + db * sel;

                // Vertical bias (Infdev lines 103-105)
                // grid_y uses Infdev's vertical step of 8 blocks (not our STEP=4)
                const grid_y = (wy_f + INFDEV_SEA_LEVEL) / INFDEV_Y_STEP;
                var bias = (grid_y - surface_grid) * 12.0 / var65;
                if (bias < 0.0) bias *= 4.0; // stronger below surface (Infdev line 104)

                const density = blended - bias;

                if (density > 0.0) {
                    chunk.blocks[idx] = .stone;
                } else if (wy <= SEA_LEVEL) {
                    chunk.blocks[idx] = .water;
                }
            }
        }
    }

    // --- Surface pass ---
    surfacePass(chunk, oy_i32, seed);

    // --- Bedrock floor ---
    bedrockPass(chunk, oy_i32, seed);

    // --- Worm-carve caves ---
    carveCaves(chunk, key, seed);
}

fn surfacePass(chunk: *Chunk, oy_i32: i32, seed: u64) void {
    // Simple surface decoration: grass on top, dirt below, sand near sea level
    const seed_i32: i32 = @truncate(@as(i64, @bitCast(seed)));
    var noise = Noise.init() orelse return;
    defer noise.deinit();

    for (0..CS) |bz| {
        for (0..CS) |bx| {
            var depth: i32 = -1;
            var by_rev: usize = CS;
            while (by_rev > 0) {
                by_rev -= 1;
                const idx = WorldState.chunkIndex(bx, by_rev, bz);
                const block = chunk.blocks[idx];
                const wy = oy_i32 + @as(i32, @intCast(by_rev));

                if (block == .air or block == .water) {
                    depth = 0;
                    continue;
                }

                if (depth < 0) continue;

                chunk.blocks[idx] = selectBlock(depth, wy, seed_i32);
                depth += 1;
            }
        }
    }
}

fn selectBlock(depth: i32, wy: i32, seed: i32) BlockType {
    _ = seed;
    if (depth == 0) {
        if (wy >= SEA_LEVEL) return .grass_block;
        return .dirt; // underwater surface
    }
    if (depth <= 3) return .dirt;
    return .stone;
}

fn bedrockPass(chunk: *Chunk, oy_i32: i32, seed: u64) void {
    // Infdev: bedrock at y <= random(6)-1 (Infdev y=0..5 → our y=-64..-59)
    var rng = CaveRng.init(seed +% 0xBEDBEDBED);
    for (0..CS) |by| {
        const wy = oy_i32 + @as(i32, @intCast(by));
        if (wy > -58) continue;
        for (0..CS) |bz| {
            for (0..CS) |bx| {
                const idx = WorldState.chunkIndex(bx, by, bz);
                if (chunk.blocks[idx] != .air and chunk.blocks[idx] != .water) {
                    // Random bedrock top boundary (Infdev line 187)
                    const threshold: i32 = -64 + @as(i32, @intCast(rng.bounded(6)));
                    if (wy <= threshold) {
                        chunk.blocks[idx] = .bedrock;
                    }
                }
            }
        }
    }
}

// ============================================================
// Worm-carve caves
// ============================================================

const CaveRng = struct {
    state: u64,

    fn init(seed: u64) CaveRng {
        return .{ .state = seed };
    }

    fn next(self: *CaveRng) u64 {
        self.state +%= 0x9e3779b97f4a7c15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        return z ^ (z >> 31);
    }

    fn float(self: *CaveRng) f32 {
        return @as(f32, @floatFromInt(self.next() >> 40)) / @as(f32, @floatFromInt(@as(u64, 1) << 24));
    }

    fn signedFloat(self: *CaveRng) f32 {
        return self.float() * 2.0 - 1.0;
    }

    fn bounded(self: *CaveRng, max: u32) u32 {
        return @intCast(self.next() % max);
    }
};

fn carveCaves(chunk: *Chunk, key: ChunkKey, seed: u64) void {
    const origin = key.position();

    // Infdev scans ±8 chunks (16-block chunks). For 32-block chunks, ±4 gives similar world range.
    var cx = key.cx - CAVE_SCAN_RANGE;
    while (cx <= key.cx + CAVE_SCAN_RANGE) : (cx += 1) {
        var cz = key.cz - CAVE_SCAN_RANGE;
        while (cz <= key.cz + CAVE_SCAN_RANGE) : (cz += 1) {
            // Infdev seeds per XZ column (caves span full Y)
            const chunk_seed = seed +%
                @as(u64, @bitCast(@as(i64, cx) *% 341873128712)) +%
                @as(u64, @bitCast(@as(i64, cz) *% 132897987541));

            var rng = CaveRng.init(chunk_seed);

            // Infdev: triple-random(40), then 90% chance of zero
            var num_caves = rng.bounded(rng.bounded(rng.bounded(40) + 1) + 1);
            if (rng.bounded(10) != 0) num_caves = 0;

            for (0..num_caves) |_| {
                // Infdev: start XZ within 16-block chunk, Y = double-random biased low
                const start_x = @as(f32, @floatFromInt(cx * CS)) + rng.float() * @as(f32, CS);
                // Double-random Y: heavily biased toward bottom (Infdev line 255)
                const max_y: u32 = @intCast(@max(1, rng.bounded(120) + 8));
                const start_y = @as(f32, @floatFromInt(rng.bounded(max_y))) - INFDEV_SEA_LEVEL;
                const start_z = @as(f32, @floatFromInt(cz * CS)) + rng.float() * @as(f32, CS);

                // Infdev: 25% chance of a "room" cave (large sphere, half-height)
                if (rng.bounded(4) == 0) {
                    const room_radius = 1.0 + rng.float() * 6.0;
                    carveWorm(chunk, origin, &rng, start_x, start_y, start_z, room_radius, 0, 0, true);
                }

                // Infdev: 1-4 normal worms per cave system (more if room cave)
                const num_worms = 1 + rng.bounded(4);
                for (0..num_worms) |_| {
                    const yaw_init = rng.float() * std.math.pi * 2.0;
                    // Infdev: very small initial pitch (line 265)
                    const pitch_init = (rng.float() - 0.5) * 2.0 / 8.0;
                    const worm_radius = rng.float() * 2.0 + rng.float();
                    carveWorm(chunk, origin, &rng, start_x, start_y, start_z, worm_radius, yaw_init, pitch_init, false);
                }
            }
        }
    }
}

fn carveWorm(
    chunk: *Chunk,
    origin: [3]i32,
    rng: *CaveRng,
    start_x: f32,
    start_y: f32,
    start_z: f32,
    base_radius: f32,
    init_yaw: f32,
    init_pitch: f32,
    is_room: bool,
) void {
    var px = start_x;
    var py = start_y;
    var pz = start_z;

    // Infdev: length = 112 - random(28) = 84-112 segments
    const total_len: u32 = 112 - rng.bounded(28);
    // Room caves start at midpoint and only carve one sphere
    const start_seg: u32 = if (is_room) total_len / 2 else 0;

    var yaw = init_yaw;
    var pitch = init_pitch;
    var yaw_delta: f32 = 0;
    var pitch_delta: f32 = 0;

    // Infdev: 1/6 chance of "steep" caves (slower pitch decay)
    const steep = rng.bounded(6) == 0;

    // Branch point (Infdev line 295)
    const branch_seg = rng.bounded(total_len / 2) + total_len / 4;

    const chunk_min_x: f32 = @floatFromInt(origin[0]);
    const chunk_min_y: f32 = @floatFromInt(origin[1]);
    const chunk_min_z: f32 = @floatFromInt(origin[2]);
    const chunk_max_x = chunk_min_x + CS;
    const chunk_max_y = chunk_min_y + CS;
    const chunk_max_z = chunk_min_z + CS;

    // Height squish for room caves (Infdev: var15 = 0.5 for rooms, 1.0 for normal)
    const height_scale: f32 = if (is_room) 0.5 else 1.0;

    var seg: u32 = start_seg;
    while (seg < total_len) : (seg += 1) {
        // Infdev line 299: radius = 1.5 + sin(progress * PI / length) * base_radius
        const progress: f32 = @floatFromInt(seg);
        const length: f32 = @floatFromInt(total_len);
        const xz_radius = 1.5 + @sin(progress * std.math.pi / length) * base_radius;
        const y_radius = xz_radius * height_scale;

        // Advance position (Infdev lines 300-304)
        const cos_pitch = @cos(pitch);
        px += @cos(yaw) * cos_pitch;
        py += @sin(pitch);
        pz += @sin(yaw) * cos_pitch;

        // Pitch decay (Infdev lines 305-309)
        if (steep) {
            pitch *= 0.92;
        } else {
            pitch *= 0.7;
        }

        // Random walk (Infdev lines 311-316)
        pitch += pitch_delta * 0.1;
        yaw += yaw_delta * 0.1;
        pitch_delta *= 0.9;
        yaw_delta *= 0.75;
        pitch_delta += rng.signedFloat() * rng.float() * 2.0;
        yaw_delta += rng.signedFloat() * rng.float() * 4.0;

        // Branching at branch point (Infdev lines 317-336)
        if (!is_room and seg == branch_seg and base_radius > 1.0) {
            // Fork: two sub-worms diverging ±PI/2
            const sub_radius = rng.float() * 0.5 + 0.5;
            const sub_pitch = pitch / 3.0;
            carveWorm(chunk, origin, rng, px, py, pz, sub_radius, yaw - std.math.pi / 2.0, sub_pitch, false);
            carveWorm(chunk, origin, rng, px, py, pz, sub_radius, yaw + std.math.pi / 2.0, sub_pitch, false);
            return;
        }

        // Room caves only carve one sphere at start, then done
        if (is_room) {
            carveEllipsoid(chunk, origin, px, py, pz, xz_radius, y_radius, chunk_min_x, chunk_min_y, chunk_min_z, chunk_max_x, chunk_max_y, chunk_max_z);
            return;
        }

        // Infdev line 338: skip 75% of segments randomly (creates gaps)
        if (rng.bounded(4) == 0) continue;

        // Early out: too far from target chunk
        const margin = xz_radius * 2.0 + 16.0;
        if (px < chunk_min_x - margin or px > chunk_max_x + margin) continue;
        if (py < chunk_min_y - margin or py > chunk_max_y + margin) continue;
        if (pz < chunk_min_z - margin or pz > chunk_max_z + margin) continue;

        carveEllipsoid(chunk, origin, px, py, pz, xz_radius, y_radius, chunk_min_x, chunk_min_y, chunk_min_z, chunk_max_x, chunk_max_y, chunk_max_z);
    }
}

fn carveEllipsoid(
    chunk: *Chunk,
    origin: [3]i32,
    cx: f32,
    cy: f32,
    cz: f32,
    xz_radius: f32,
    y_radius: f32,
    chunk_min_x: f32,
    chunk_min_y: f32,
    chunk_min_z: f32,
    chunk_max_x: f32,
    chunk_max_y: f32,
    chunk_max_z: f32,
) void {
    _ = chunk_min_x;
    _ = chunk_min_y;
    _ = chunk_min_z;
    _ = chunk_max_x;
    _ = chunk_max_y;
    _ = chunk_max_z;

    const r_ceil_xz: i32 = @intFromFloat(@ceil(xz_radius));
    const r_ceil_y: i32 = @intFromFloat(@ceil(y_radius));

    const ox: f32 = @floatFromInt(origin[0]);
    const oy: f32 = @floatFromInt(origin[1]);
    const oz: f32 = @floatFromInt(origin[2]);

    var dy: i32 = -r_ceil_y;
    while (dy <= r_ceil_y) : (dy += 1) {
        const wy_f = cy + @as(f32, @floatFromInt(dy));
        // Infdev: don't carve below y=10 (our y=-54) — would be lava
        if (wy_f < @as(f32, @floatFromInt(CAVE_LAVA_Y))) continue;
        // Infdev line 408: y_dist > -0.7 (skip bottom of ellipsoid)
        const y_dist = @as(f32, @floatFromInt(dy)) / y_radius;
        if (y_dist <= -0.7) continue;
        const by_f = wy_f - oy;
        if (by_f < 0 or by_f >= CS) continue;
        const by: usize = @intFromFloat(by_f);

        var dz: i32 = -r_ceil_xz;
        while (dz <= r_ceil_xz) : (dz += 1) {
            const wz_f = cz + @as(f32, @floatFromInt(dz));
            const bz_f = wz_f - oz;
            if (bz_f < 0 or bz_f >= CS) continue;
            const bz: usize = @intFromFloat(bz_f);

            var dx: i32 = -r_ceil_xz;
            while (dx <= r_ceil_xz) : (dx += 1) {
                const wx_f = cx + @as(f32, @floatFromInt(dx));
                const bx_f = wx_f - ox;
                if (bx_f < 0 or bx_f >= CS) continue;
                const bx: usize = @intFromFloat(bx_f);

                // Infdev: ellipsoid test (x/xz_r)^2 + (y/y_r)^2 + (z/xz_r)^2 < 1
                const fdx = @as(f32, @floatFromInt(dx)) / xz_radius;
                const fdy = @as(f32, @floatFromInt(dy)) / y_radius;
                const fdz = @as(f32, @floatFromInt(dz)) / xz_radius;
                if (fdx * fdx + fdy * fdy + fdz * fdz >= 1.0) continue;

                const idx = WorldState.chunkIndex(bx, by, bz);
                const block = chunk.blocks[idx];
                if (block != .air and block != .water and block != .bedrock) {
                    chunk.blocks[idx] = .air;
                }
            }
        }
    }
}

// ============================================================
// Height sampling (for spawn point)
// ============================================================

pub fn sampleHeight(wx: i32, wz: i32, seed: u64) i32 {
    var noise = Noise.init() orelse return 0;
    defer noise.deinit();

    const seed_i32: i32 = @truncate(@as(i64, @bitCast(seed)));
    const fx: f32 = @floatFromInt(wx);
    const fz: f32 = @floatFromInt(wz);

    // Grid-space coordinates
    const gx: f32 = fx / Noise.STEP;
    const gz: f32 = fz / Noise.STEP;

    // Height modifier and roughness (2D) — sampleFbm2D is standard FBm, not inverted
    // For spawn height we use a rough approximation
    const hmod_raw = noise.sampleFbm2D(gx, gz, seed_i32 +% 100, 1.0, HEIGHT_MOD_OCTAVES) * FN2_SCALE;
    const rough_raw = noise.sampleFbm2D(gx, gz, seed_i32 +% 200, 100.0, ROUGHNESS_OCTAVES) * FN2_SCALE;

    var var65 = @min((hmod_raw + 256.0) / 512.0, 1.0);
    var var67 = @abs(rough_raw / 8000.0) * 3.0 - 3.0;
    if (var67 < 0.0) {
        var67 = @max(var67 / 2.0, -1.0);
        var67 = var67 / 1.4 / 2.0;
        var65 = 0.0;
    } else {
        var67 = @min(var67, 1.0) / 6.0;
    }
    var65 += 0.5;
    var67 = var67 * 17.0 / 16.0;

    const surface_grid = 8.5 + var67 * 4.0;
    // Convert from Infdev grid units (step=8) to world Y
    const surface_y = surface_grid * INFDEV_Y_STEP - INFDEV_SEA_LEVEL;

    // Walk down from above surface to find where density > 0
    var y: f32 = surface_y + 40.0;
    while (y > surface_y - 40.0) : (y -= 1.0) {
        const gy: f32 = (y + INFDEV_SEA_LEVEL) / INFDEV_Y_STEP;
        const da = noise.sampleInfdevFbm3D(gx, gy, gz, seed_i32, DENSITY_SCALE, DENSITY_SCALE, DENSITY_OCTAVES) * FN2_SCALE / 512.0;
        const db = noise.sampleInfdevFbm3D(gx, gy, gz, seed_i32 +% 9999, DENSITY_SCALE, DENSITY_SCALE, DENSITY_OCTAVES) * FN2_SCALE / 512.0;
        const sel_raw = noise.sampleInfdevFbm3D(gx, gy, gz, seed_i32 +% 55555, SELECTOR_SCALE_XZ, SELECTOR_SCALE_Y, SELECTOR_OCTAVES) * FN2_SCALE;
        const sel = std.math.clamp((sel_raw / 10.0 + 1.0) / 2.0, 0.0, 1.0);
        const blended = da * (1.0 - sel) + db * sel;

        var bias = (gy - surface_grid) * 12.0 / var65;
        if (bias < 0.0) bias *= 4.0;

        if (blended - bias > 0.0) return @intFromFloat(y + 1.0);
    }
    return @intFromFloat(surface_y);
}
