const std = @import("std");
const WorldState = @import("WorldState.zig");
const Noise = @import("Noise.zig");
const TreeGen = @import("TreeGen.zig");

const Chunk = WorldState.Chunk;
const ChunkKey = WorldState.ChunkKey;
const BlockState = WorldState.BlockState;
const StateId = WorldState.StateId;
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
// Octave counts now defined by NoiseGen.init() in Noise.zig

// Infdev sea level = 64, world height = 128.
// We map: Infdev y=0 → our y=-64, Infdev y=64 → our y=0, Infdev y=127 → our y=63.
const SEA_LEVEL: i32 = 0;
const INFDEV_SEA_LEVEL: f32 = 64.0;

// Infdev's coarse vertical step is 8 blocks (17 samples for 128 blocks).
// Our chunks use STEP=4 for XZ, but vertical bias must use Infdev's scale.
const INFDEV_Y_STEP: f32 = 8.0;

// --- Cave parameters (matching Infdev) ---
const CAVE_SCAN_RANGE: i32 = 4; // Infdev scans ±8 for 16-block chunks; ±4 for 32-block
const CAVE_LAVA_Y: i32 = -54; // Infdev y=10 → our y = 10-64 = -54

// --- Biomes ---
const Biome = enum { plains, desert, tundra, mountains };

pub fn generateChunk(chunk: *Chunk, key: ChunkKey, seed: u64) void {
    const ng = Noise.NoiseGen.init(seed);
    const origin = key.position();

    // Infdev coarse grid: world pos / 4 = grid index.
    const gx_start: i32 = @divFloor(origin[0], Noise.STEP);
    const gy_start: i32 = @divFloor(origin[1], Noise.STEP);
    const gz_start: i32 = @divFloor(origin[2], Noise.STEP);

    // --- 2D grids: height modifier and roughness ---
    var height_mod: [Noise.SC2]f32 = undefined;
    var roughness: [Noise.SC2]f32 = undefined;
    ng.height_mod.fillGrid2D(&height_mod, gx_start, gz_start, 1.0, 1.0);
    ng.roughness.fillGrid2D(&roughness, gx_start, gz_start, 100.0, 100.0);

    // --- 3D grids: density A, density B, selector ---
    var density_a: [Noise.SC3]f32 = undefined;
    var density_b: [Noise.SC3]f32 = undefined;
    var selector: [Noise.SC3]f32 = undefined;
    ng.density_a.fillGrid3D(&density_a, gx_start, gy_start, gz_start, DENSITY_SCALE, DENSITY_SCALE, DENSITY_SCALE);
    ng.density_b.fillGrid3D(&density_b, gx_start, gy_start, gz_start, DENSITY_SCALE, DENSITY_SCALE, DENSITY_SCALE);
    ng.selector.fillGrid3D(&selector, gx_start, gy_start, gz_start, SELECTOR_SCALE_XZ, SELECTOR_SCALE_Y, SELECTOR_SCALE_XZ);

    // --- Fill chunk ---
    @memset(&chunk.blocks, @as(StateId, 0));

    const oy_i32 = origin[1];

    for (0..CS) |bz| {
        for (0..CS) |bx| {
            // 2D height modifiers (Infdev lines 70-98)
            const hmod_raw = Noise.bilerp2D(&height_mod, bx, bz);
            const rough_raw = Noise.bilerp2D(&roughness, bx, bz);

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

            // Precompute bilinear XZ-interpolated values at each Y grid level.
            // Reduces per-block trilerp to a single Y-axis lerp.
            const sx = bx / Noise.STEP;
            const sz = bz / Noise.STEP;
            const fx: f32 = @as(f32, @floatFromInt(bx % Noise.STEP)) / Noise.STEP;
            const fz: f32 = @as(f32, @floatFromInt(bz % Noise.STEP)) / Noise.STEP;

            var da_col: [Noise.SC]f32 = undefined;
            var db_col: [Noise.SC]f32 = undefined;
            var sel_col: [Noise.SC]f32 = undefined;
            for (0..Noise.SC) |sy| {
                const base = sy * Noise.SC2 + sz * Noise.SC + sx;
                const v00 = density_a[base];
                const v10 = density_a[base + 1];
                const v01 = density_a[base + Noise.SC];
                const v11 = density_a[base + Noise.SC + 1];
                da_col[sy] = (v00 + (v10 - v00) * fx) + ((v01 + (v11 - v01) * fx) - (v00 + (v10 - v00) * fx)) * fz;

                const b00 = density_b[base];
                const b10 = density_b[base + 1];
                const b01 = density_b[base + Noise.SC];
                const b11 = density_b[base + Noise.SC + 1];
                db_col[sy] = (b00 + (b10 - b00) * fx) + ((b01 + (b11 - b01) * fx) - (b00 + (b10 - b00) * fx)) * fz;

                const s00 = selector[base];
                const s10 = selector[base + 1];
                const s01 = selector[base + Noise.SC];
                const s11 = selector[base + Noise.SC + 1];
                sel_col[sy] = (s00 + (s10 - s00) * fx) + ((s01 + (s11 - s01) * fx) - (s00 + (s10 - s00) * fx)) * fz;
            }

            for (0..CS) |by| {
                const wy = oy_i32 + @as(i32, @intCast(by));
                const wy_f: f32 = @floatFromInt(wy);
                const idx = WorldState.chunkIndex(bx, by, bz);

                // Y-axis lerp from precomputed column values
                const sy = by / Noise.STEP;
                const fy: f32 = @as(f32, @floatFromInt(by % Noise.STEP)) / Noise.STEP;
                const da = (da_col[sy] + (da_col[sy + 1] - da_col[sy]) * fy) / 512.0;
                const db = (db_col[sy] + (db_col[sy + 1] - db_col[sy]) * fy) / 512.0;
                const sel_raw = sel_col[sy] + (sel_col[sy + 1] - sel_col[sy]) * fy;

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
                    chunk.blocks[idx] = BlockState.defaultState(.stone);
                } else if (wy <= SEA_LEVEL) {
                    chunk.blocks[idx] = BlockState.defaultState(.water);
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

    // --- Plant trees ---
    TreeGen.plantTrees(chunk, key, seed);
}

fn surfacePass(chunk: *Chunk, oy_i32: i32, seed: u64) void {
    _ = seed;
    for (0..CS) |bz| {
        for (0..CS) |bx| {
            var depth: i32 = -1;
            var by_rev: usize = CS;
            while (by_rev > 0) {
                by_rev -= 1;
                const idx = WorldState.chunkIndex(bx, by_rev, bz);
                const block = chunk.blocks[idx];
                const wy = oy_i32 + @as(i32, @intCast(by_rev));

                const blk = BlockState.getBlock(block);
                if (blk == .air or blk == .water) {
                    depth = 0;
                    continue;
                }

                if (depth < 0) continue;

                chunk.blocks[idx] = selectBlock(depth, wy, 0);
                depth += 1;
            }
        }
    }
}

fn selectBlock(depth: i32, wy: i32, seed: i32) StateId {
    _ = seed;
    if (depth == 0) {
        if (wy >= SEA_LEVEL) return BlockState.defaultState(.grass_block);
        return BlockState.defaultState(.dirt); // underwater surface
    }
    if (depth <= 3) return BlockState.defaultState(.dirt);
    return BlockState.defaultState(.stone);
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
                const bed_blk = BlockState.getBlock(chunk.blocks[idx]);
                if (bed_blk != .air and bed_blk != .water) {
                    // Random bedrock top boundary (Infdev line 187)
                    const threshold: i32 = -64 + @as(i32, @intCast(rng.bounded(6)));
                    if (wy <= threshold) {
                        chunk.blocks[idx] = BlockState.defaultState(.bedrock);
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
                const cave_blk = BlockState.getBlock(chunk.blocks[idx]);
                if (cave_blk != .air and cave_blk != .water and cave_blk != .bedrock) {
                    chunk.blocks[idx] = BlockState.defaultState(.air);
                }
            }
        }
    }
}

// ============================================================
// Height sampling (for spawn point)
// ============================================================

pub fn sampleHeight(wx: i32, wz: i32, seed: u64) i32 {
    const ng = Noise.NoiseGen.init(seed);
    return sampleHeightWithNoise(wx, wz, &ng);
}

/// Grid-interpolated surface height from seed (matches actual chunk generation).
pub fn sampleGridHeight(wx: i32, wz: i32, seed: u64) i32 {
    const ng = Noise.NoiseGen.init(seed);
    return sampleGridSurfaceHeight(wx, wz, &ng);
}

pub fn sampleHeightWithNoise(wx: i32, wz: i32, ng: *const Noise.NoiseGen) i32 {
    // Grid-space coordinates (coarse grid index, not block coords)
    const gx: f64 = @as(f64, @floatFromInt(wx)) / Noise.STEP;
    const gz: f64 = @as(f64, @floatFromInt(wz)) / Noise.STEP;

    // Height modifier and roughness (2D) — now using proper inverted FBm
    const hmod_raw: f32 = @floatCast(ng.height_mod.sample3D(gx * 1.0, 0, gz * 1.0));
    const rough_raw: f32 = @floatCast(ng.roughness.sample3D(gx * 100.0, 0, gz * 100.0));

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
    const surface_y = surface_grid * INFDEV_Y_STEP - INFDEV_SEA_LEVEL;

    // Walk down from above surface to find where density > 0
    var y: f32 = surface_y + 40.0;
    while (y > surface_y - 40.0) : (y -= 1.0) {
        const gy: f64 = @as(f64, y + INFDEV_SEA_LEVEL) / INFDEV_Y_STEP;
        const da: f32 = @floatCast(ng.density_a.sample3D(gx * DENSITY_SCALE, gy * DENSITY_SCALE, gz * DENSITY_SCALE) / 512.0);
        const db: f32 = @floatCast(ng.density_b.sample3D(gx * DENSITY_SCALE, gy * DENSITY_SCALE, gz * DENSITY_SCALE) / 512.0);
        const sel_raw: f32 = @floatCast(ng.selector.sample3D(gx * SELECTOR_SCALE_XZ, gy * SELECTOR_SCALE_Y, gz * SELECTOR_SCALE_XZ));
        const sel = std.math.clamp((sel_raw / 10.0 + 1.0) / 2.0, 0.0, 1.0);
        const blended = da * (1.0 - sel) + db * sel;

        const sg: f32 = @floatCast(surface_grid);
        const gyf: f32 = @floatCast(gy);
        var bias = (gyf - sg) * 12.0 / var65;
        if (bias < 0.0) bias *= 4.0;

        if (blended - bias > 0.0) return @intFromFloat(y + 1.0);
    }
    return @intFromFloat(surface_y);
}

// ============================================================
// Grid-interpolated surface height (matches chunk gen exactly)
// ============================================================

/// Sample surface height using the same grid-interpolated noise as generateChunk.
/// Returns the world Y of the first air block above the noise surface.
/// All chunks compute identical results for the same (wx, wz), enabling
/// seamless cross-chunk tree placement.
pub fn sampleGridSurfaceHeight(wx: i32, wz: i32, ng: *const Noise.NoiseGen) i32 {
    const STEP: i32 = Noise.STEP;
    const GRID: i32 = @divExact(@as(i32, CS), STEP);

    // Determine grid cell for this column
    const home_cx = @divFloor(wx, @as(i32, CS));
    const home_cz = @divFloor(wz, @as(i32, CS));
    const bx: u32 = @intCast(wx - home_cx * @as(i32, CS));
    const bz: u32 = @intCast(wz - home_cz * @as(i32, CS));

    const sx: i32 = @intCast(bx / Noise.STEP);
    const sz: i32 = @intCast(bz / Noise.STEP);
    const fx: f32 = @as(f32, @floatFromInt(bx % Noise.STEP)) / @as(f32, Noise.STEP);
    const fz: f32 = @as(f32, @floatFromInt(bz % Noise.STEP)) / @as(f32, Noise.STEP);

    const gx0 = home_cx * GRID + sx;
    const gx1 = gx0 + 1;
    const gz0 = home_cz * GRID + sz;
    const gz1 = gz0 + 1;

    // 2D noise at 4 XZ corners (matches fillGrid2D)
    const hm = gridSample2D(&ng.height_mod, gx0, gx1, gz0, gz1, 1.0);
    const rg = gridSample2D(&ng.roughness, gx0, gx1, gz0, gz1, 100.0);
    const hmod_raw = bilerp4(hm, fx, fz);
    const rough_raw = bilerp4(rg, fx, fz);

    // Surface parameters (identical to generateChunk lines 73-94)
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

    // Search range around 2D surface estimate
    const surface_est: f32 = surface_grid * INFDEV_Y_STEP - INFDEV_SEA_LEVEL;
    const search_top: i32 = @as(i32, @intFromFloat(@ceil(surface_est))) + 16;
    const search_bot: i32 = @as(i32, @intFromFloat(@floor(surface_est))) - 16;

    // Cache 3D grid values; resample when crossing a Y grid cell boundary
    var prev_gy0: i32 = std.math.maxInt(i32);
    var corners_lo: [3][4]f32 = undefined;
    var corners_hi: [3][4]f32 = undefined;

    var wy = search_top;
    while (wy >= search_bot) : (wy -= 1) {
        const cky = @divFloor(wy, @as(i32, CS));
        const by: u32 = @intCast(wy - cky * @as(i32, CS));
        const sy: i32 = @intCast(by / Noise.STEP);
        const fy: f32 = @as(f32, @floatFromInt(by % Noise.STEP)) / @as(f32, Noise.STEP);
        const gy0 = cky * GRID + sy;

        if (gy0 != prev_gy0) {
            prev_gy0 = gy0;
            const gy1 = gy0 + 1;
            corners_lo[0] = gridSample3D(&ng.density_a, gx0, gx1, gy0, gz0, gz1, DENSITY_SCALE, DENSITY_SCALE, DENSITY_SCALE);
            corners_hi[0] = gridSample3D(&ng.density_a, gx0, gx1, gy1, gz0, gz1, DENSITY_SCALE, DENSITY_SCALE, DENSITY_SCALE);
            corners_lo[1] = gridSample3D(&ng.density_b, gx0, gx1, gy0, gz0, gz1, DENSITY_SCALE, DENSITY_SCALE, DENSITY_SCALE);
            corners_hi[1] = gridSample3D(&ng.density_b, gx0, gx1, gy1, gz0, gz1, DENSITY_SCALE, DENSITY_SCALE, DENSITY_SCALE);
            corners_lo[2] = gridSample3D(&ng.selector, gx0, gx1, gy0, gz0, gz1, SELECTOR_SCALE_XZ, SELECTOR_SCALE_Y, SELECTOR_SCALE_XZ);
            corners_hi[2] = gridSample3D(&ng.selector, gx0, gx1, gy1, gz0, gz1, SELECTOR_SCALE_XZ, SELECTOR_SCALE_Y, SELECTOR_SCALE_XZ);
        }

        const da = trilerp8(corners_lo[0], corners_hi[0], fx, fy, fz) / 512.0;
        const db = trilerp8(corners_lo[1], corners_hi[1], fx, fy, fz) / 512.0;
        const sel_raw = trilerp8(corners_lo[2], corners_hi[2], fx, fy, fz);

        const sel = std.math.clamp((sel_raw / 10.0 + 1.0) / 2.0, 0.0, 1.0);
        const blended = da * (1.0 - sel) + db * sel;

        const wy_f: f32 = @floatFromInt(wy);
        const grid_y = (wy_f + INFDEV_SEA_LEVEL) / INFDEV_Y_STEP;
        var bias = (grid_y - surface_grid) * 12.0 / var65;
        if (bias < 0.0) bias *= 4.0;

        if (blended - bias > 0.0) return wy + 1;
    }
    return @intFromFloat(surface_est);
}

/// Sample OctavePerlin at an integer grid point, matching fillGrid3D exactly.
fn octaveAt(octave: *const Noise.OctavePerlin, gx: i32, gy: i32, gz: i32, x_scale: f64, y_scale: f64, z_scale: f64) f32 {
    var total: f32 = 0;
    var freq: f64 = 1.0;
    const gx_f: f64 = @floatFromInt(gx);
    const gy_f: f64 = @floatFromInt(gy);
    const gz_f: f64 = @floatFromInt(gz);
    for (0..octave.num_octaves) |i| {
        const amp: f32 = @floatCast(1.0 / freq);
        total += @as(f32, @floatCast(octave.perlin[i].sample3D(
            gx_f * x_scale * freq,
            gy_f * y_scale * freq,
            gz_f * z_scale * freq,
        ))) * amp;
        freq /= 2.0;
    }
    return total;
}

/// Sample 2D noise at 4 XZ grid corners (y=0), matching fillGrid2D.
fn gridSample2D(octave: *const Noise.OctavePerlin, gx0: i32, gx1: i32, gz0: i32, gz1: i32, scale: f64) [4]f32 {
    return .{
        octaveAt(octave, gx0, 0, gz0, scale, 0, scale),
        octaveAt(octave, gx1, 0, gz0, scale, 0, scale),
        octaveAt(octave, gx0, 0, gz1, scale, 0, scale),
        octaveAt(octave, gx1, 0, gz1, scale, 0, scale),
    };
}

/// Sample 3D noise at 4 XZ corners for a single Y level, matching fillGrid3D.
fn gridSample3D(octave: *const Noise.OctavePerlin, gx0: i32, gx1: i32, gy: i32, gz0: i32, gz1: i32, x_scale: f64, y_scale: f64, z_scale: f64) [4]f32 {
    return .{
        octaveAt(octave, gx0, gy, gz0, x_scale, y_scale, z_scale),
        octaveAt(octave, gx1, gy, gz0, x_scale, y_scale, z_scale),
        octaveAt(octave, gx0, gy, gz1, x_scale, y_scale, z_scale),
        octaveAt(octave, gx1, gy, gz1, x_scale, y_scale, z_scale),
    };
}

fn bilerp4(c: [4]f32, fx: f32, fz: f32) f32 {
    const top = c[0] + (c[1] - c[0]) * fx;
    const bot = c[2] + (c[3] - c[2]) * fx;
    return top + (bot - top) * fz;
}

fn trilerp8(lo: [4]f32, hi: [4]f32, fx: f32, fy: f32, fz: f32) f32 {
    const c00 = lo[0] + (lo[1] - lo[0]) * fx;
    const c01 = lo[2] + (lo[3] - lo[2]) * fx;
    const c10 = hi[0] + (hi[1] - hi[0]) * fx;
    const c11 = hi[2] + (hi[3] - hi[2]) * fx;
    const c0 = c00 + (c01 - c00) * fz;
    const c1 = c10 + (c11 - c10) * fz;
    return c0 + (c1 - c0) * fy;
}

// ============================================================
// LOD chunk generation (2D heightmap only, no caves/trees/bedrock)
// ============================================================

pub fn generateLodChunk(chunk: *Chunk, key: ChunkKey, seed: u64, voxel_size: u32) void {
    const ng = Noise.NoiseGen.init(seed);
    const vs: i32 = @intCast(voxel_size);
    const step_f: f64 = @floatFromInt(Noise.STEP);

    // Clear chunk to air
    @memset(&chunk.blocks, @as(StateId, 0));

    for (0..CS) |bz| {
        for (0..CS) |bx| {
            // World position at voxel center
            const wx: i32 = key.cx * @as(i32, CS) * vs + @as(i32, @intCast(bx)) * vs + @divTrunc(vs, 2);
            const wz: i32 = key.cz * @as(i32, CS) * vs + @as(i32, @intCast(bz)) * vs + @divTrunc(vs, 2);

            // Convert to grid-space
            const gx: f64 = @as(f64, @floatFromInt(wx)) / step_f;
            const gz: f64 = @as(f64, @floatFromInt(wz)) / step_f;

            // Sample 2D roughness noise
            const rough_raw: f32 = @floatCast(ng.roughness.sample3D(gx * 100.0, 0, gz * 100.0));

            // Compute surface_y (same 2D formula as generateChunk lines 73-95)
            // Note: height_mod / var65 are omitted — they only affect the 3D density bias
            var var67 = @abs(rough_raw / 8000.0) * 3.0 - 3.0;
            if (var67 < 0.0) {
                var67 = @max(var67 / 2.0, -1.0);
                var67 = var67 / 1.4 / 2.0;
            } else {
                var67 = @min(var67, 1.0) / 6.0;
            }
            var67 = var67 * 17.0 / 16.0;

            const surface_grid = 8.5 + var67 * 4.0;
            const surface_y = surface_grid * INFDEV_Y_STEP - INFDEV_SEA_LEVEL;

            for (0..CS) |by| {
                const wy: i32 = key.cy * @as(i32, CS) * vs + @as(i32, @intCast(by)) * vs;
                const depth: i32 = @as(i32, @intFromFloat(@floor(surface_y))) - wy;
                const idx = WorldState.chunkIndex(bx, by, bz);

                if (depth >= 4 * vs) {
                    chunk.blocks[idx] = BlockState.defaultState(.stone);
                } else if (depth >= 1 * vs) {
                    chunk.blocks[idx] = BlockState.defaultState(.dirt);
                } else if (depth >= 0) {
                    chunk.blocks[idx] = if (wy < SEA_LEVEL) BlockState.defaultState(.sand) else BlockState.defaultState(.grass_block);
                } else if (wy <= SEA_LEVEL) {
                    chunk.blocks[idx] = BlockState.defaultState(.water);
                }
                // else: already air
            }
        }
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "generateChunk: deterministic output (same seed same blocks)" {
    const alloc = testing.allocator;
    const chunk1 = try alloc.create(Chunk);
    defer alloc.destroy(chunk1);
    const chunk2 = try alloc.create(Chunk);
    defer alloc.destroy(chunk2);

    const key = ChunkKey{ .cx = 0, .cy = 0, .cz = 0 };
    const seed: u64 = 12345;

    generateChunk(chunk1, key, seed);
    generateChunk(chunk2, key, seed);

    try testing.expectEqualSlices(StateId, &chunk1.blocks, &chunk2.blocks);
}

test "generateChunk: different seeds produce different chunks" {
    const alloc = testing.allocator;
    const chunk1 = try alloc.create(Chunk);
    defer alloc.destroy(chunk1);
    const chunk2 = try alloc.create(Chunk);
    defer alloc.destroy(chunk2);

    const key = ChunkKey{ .cx = 0, .cy = 0, .cz = 0 };

    generateChunk(chunk1, key, 111);
    generateChunk(chunk2, key, 222);

    // At least some blocks should differ
    var diffs: u32 = 0;
    for (&chunk1.blocks, &chunk2.blocks) |a, b| {
        if (a != b) diffs += 1;
    }
    try testing.expect(diffs > 0);
}

test "generateChunk: surface chunks have stone and air" {
    const alloc = testing.allocator;
    const chunk = try alloc.create(Chunk);
    defer alloc.destroy(chunk);

    // Surface-level chunk (cy=0 straddles sea level)
    generateChunk(chunk, .{ .cx = 0, .cy = 0, .cz = 0 }, 42);

    var has_stone = false;
    var has_air = false;
    for (&chunk.blocks) |b| {
        const blk = BlockState.getBlock(b);
        if (blk == .stone) has_stone = true;
        if (blk == .air) has_air = true;
    }
    try testing.expect(has_stone);
    try testing.expect(has_air);
}

test "generateChunk: deep underground is mostly solid" {
    const alloc = testing.allocator;
    const chunk = try alloc.create(Chunk);
    defer alloc.destroy(chunk);

    // Very deep chunk (cy=-4 → y=-128 to -97)
    generateChunk(chunk, .{ .cx = 0, .cy = -4, .cz = 0 }, 42);

    var solid: u32 = 0;
    for (&chunk.blocks) |b| {
        const blk = BlockState.getBlock(b);
        if (blk != .air and blk != .water) solid += 1;
    }
    // Should be mostly solid (bedrock + stone), at least 90%
    try testing.expect(solid > WorldState.BLOCKS_PER_CHUNK * 9 / 10);
}

test "sampleHeight: deterministic for same seed" {
    const h1 = sampleHeight(0, 0, 42);
    const h2 = sampleHeight(0, 0, 42);
    try testing.expectEqual(h1, h2);
}

test "sampleHeight: surface near sea level" {
    const h = sampleHeight(0, 0, 42);
    // Surface should be within reasonable range of sea level (0)
    try testing.expect(h > -40 and h < 40);
}

test "CaveRng: deterministic" {
    var rng1 = CaveRng.init(42);
    var rng2 = CaveRng.init(42);

    for (0..100) |_| {
        try testing.expectEqual(rng1.next(), rng2.next());
    }
}

test "CaveRng.float: values in [0, 1)" {
    var rng = CaveRng.init(12345);
    for (0..1000) |_| {
        const f = rng.float();
        try testing.expect(f >= 0.0 and f < 1.0);
    }
}

test "selectBlock: surface blocks" {
    // At sea level, depth 0 = grass
    try testing.expectEqual(BlockState.defaultState(.grass_block), selectBlock(0, SEA_LEVEL, 0));
    // Below sea level, depth 0 = dirt (underwater)
    try testing.expectEqual(BlockState.defaultState(.dirt), selectBlock(0, SEA_LEVEL - 1, 0));
    // Depth 1-3 = dirt
    try testing.expectEqual(BlockState.defaultState(.dirt), selectBlock(1, SEA_LEVEL, 0));
    try testing.expectEqual(BlockState.defaultState(.dirt), selectBlock(3, SEA_LEVEL, 0));
    // Depth 4+ = stone
    try testing.expectEqual(BlockState.defaultState(.stone), selectBlock(4, SEA_LEVEL, 0));
}

// ============================================================
// Benchmarks
// ============================================================

fn printBenchResult(comptime name: []const u8, samples: []const u64, face_count: ?u32) void {
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    var total_ns: u64 = 0;
    for (samples) |s| {
        total_ns += s;
        if (s < min_ns) min_ns = s;
        if (s > max_ns) max_ns = s;
    }
    const avg = total_ns / samples.len;
    if (face_count) |fc| {
        std.debug.print("\n  {s}: min={d}us avg={d}us max={d}us (n={d}) faces={d}\n", .{ name, min_ns / 1000, avg / 1000, max_ns / 1000, samples.len, fc });
    } else {
        std.debug.print("\n  {s}: min={d}us avg={d}us max={d}us (n={d})\n", .{ name, min_ns / 1000, avg / 1000, max_ns / 1000, samples.len });
    }
}

test "bench: generateChunk" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const ITERS = 10;
    var samples: [ITERS]u64 = undefined;
    var chunk: Chunk = undefined;

    for (&samples, 0..) |*sample, i| {
        const start = std.Io.Clock.now(.awake, io);
        generateChunk(&chunk, .{ .cx = @intCast(i), .cy = 0, .cz = 0 }, 42);
        sample.* = @intCast(start.durationTo(std.Io.Clock.now(.awake, io)).nanoseconds);
    }

    printBenchResult("generateChunk", &samples, null);
}

test "bench: generateLodChunk" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const ITERS = 10;
    var samples: [ITERS]u64 = undefined;
    var chunk: Chunk = undefined;

    for (&samples, 0..) |*sample, i| {
        const start = std.Io.Clock.now(.awake, io);
        generateLodChunk(&chunk, .{ .cx = @intCast(i), .cy = 0, .cz = 0 }, 42, 2);
        sample.* = @intCast(start.durationTo(std.Io.Clock.now(.awake, io)).nanoseconds);
    }

    printBenchResult("generateLodChunk (voxel_size=2)", &samples, null);
}

test "bench: full pipeline (terrain + mesh)" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const ITERS = 10;
    var samples: [ITERS]u64 = undefined;
    var chunk: Chunk = undefined;
    var face_count: u32 = 0;
    const no_neighbors: [6]?*const Chunk = .{ null, null, null, null, null, null };
    const LightBorderSnapshot = @import("LightMap.zig").LightBorderSnapshot;
    const no_borders: [6]LightBorderSnapshot = .{LightBorderSnapshot.empty} ** 6;

    for (&samples, 0..) |*sample, i| {
        const start = std.Io.Clock.now(.awake, io);
        generateChunk(&chunk, .{ .cx = @intCast(i), .cy = 0, .cz = 0 }, 42);
        const result = WorldState.generateChunkMesh(testing.allocator, &chunk, no_neighbors, null, no_borders) catch unreachable;
        sample.* = @intCast(start.durationTo(std.Io.Clock.now(.awake, io)).nanoseconds);
        face_count = result.total_face_count;
        testing.allocator.free(result.faces);
        testing.allocator.free(result.lights);
    }

    printBenchResult("full pipeline (terrain + mesh)", &samples, face_count);
}
