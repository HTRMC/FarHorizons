const std = @import("std");
const WorldState = @import("WorldState.zig");
const Noise = @import("Noise.zig");

const Chunk = WorldState.Chunk;
const ChunkKey = WorldState.ChunkKey;
const BlockType = WorldState.BlockType;
const CHUNK_SIZE = WorldState.CHUNK_SIZE;
const CS = CHUNK_SIZE;

const SEA_LEVEL: i32 = 0;
const BASE_HEIGHT: f32 = 20.0;
const CAVE_THRESHOLD: f32 = 0.6;
const CAVE_MIN_DEPTH: i32 = 5;

const TERRAIN_FREQ: f32 = 0.1;
const BIOME_FREQ: f32 = 0.004;
const CAVE_FREQ: f32 = 0.04;

const Biome = enum {
    plains,
    desert,
    tundra,
    mountains,
};

pub fn generateChunk(chunk: *Chunk, key: ChunkKey, seed: u64) void {
    var noise = Noise.init() orelse {
        std.log.err("[TerrainGen] FastNoise2 init failed, falling back to flat chunk", .{});
        WorldState.generateFlatChunk(chunk, key);
        return;
    };
    defer noise.deinit();

    const seed_i32: i32 = @truncate(@as(i64, @bitCast(seed)));
    const cave_seed: i32 = seed_i32 +% 73856;

    const origin = key.position();
    const ox: f32 = @floatFromInt(origin[0]);
    const oy: f32 = @floatFromInt(origin[1]);
    const oz: f32 = @floatFromInt(origin[2]);

    // Bulk sample all noise grids using SIMD uniform grid functions
    var terrain_grid: [CS * CS]f32 = undefined;
    var biome_grid: [CS * CS]f32 = undefined;
    var cave_grid: [CS * CS * CS]f32 = undefined;

    noise.gridFbm2D(&terrain_grid, ox, oz, seed_i32, TERRAIN_FREQ, 5);
    noise.gridFbm2D(&biome_grid, ox, oz, seed_i32 +% 31337, BIOME_FREQ, 3);
    noise.gridFbm3D(&cave_grid, ox, oy, oz, cave_seed, CAVE_FREQ, 3);

    chunk.blocks = .{.air} ** WorldState.BLOCKS_PER_CHUNK;

    const oy_i32 = origin[1];

    for (0..CHUNK_SIZE) |bz| {
        for (0..CHUNK_SIZE) |bx| {
            const idx_2d = bz * CS + bx;
            const biome = classifyBiome(biome_grid[idx_2d]);

            const amplitude: f32 = switch (biome) {
                .plains => 20.0,
                .desert => 12.0,
                .tundra => 15.0,
                .mountains => 60.0,
            };
            const surface_height: i32 = @intFromFloat(BASE_HEIGHT + terrain_grid[idx_2d] * amplitude);

            for (0..CHUNK_SIZE) |by| {
                const wy = oy_i32 + @as(i32, @intCast(by));

                if (wy > surface_height) {
                    if (wy <= SEA_LEVEL) {
                        chunk.blocks[WorldState.chunkIndex(bx, by, bz)] = .water;
                    }
                    continue;
                }

                const depth = surface_height - wy;

                // Cave carving
                if (depth >= CAVE_MIN_DEPTH) {
                    const cave_val = cave_grid[WorldState.chunkIndex(bx, by, bz)];
                    if (cave_val > CAVE_THRESHOLD) {
                        continue;
                    }
                }

                chunk.blocks[WorldState.chunkIndex(bx, by, bz)] = selectBlock(biome, depth);
            }
        }
    }
}

/// Sample the heightmap at a single world position (for spawn height).
pub fn sampleHeight(wx: i32, wz: i32, seed: u64) i32 {
    var noise = Noise.init() orelse return @intFromFloat(BASE_HEIGHT);
    defer noise.deinit();

    const seed_i32: i32 = @truncate(@as(i64, @bitCast(seed)));
    const fx: f32 = @floatFromInt(wx);
    const fz: f32 = @floatFromInt(wz);

    const biome_val = noise.sampleFbm2D(fx, fz, seed_i32 +% 31337, BIOME_FREQ, 3);
    const biome = classifyBiome(biome_val);
    const terrain_val = noise.sampleFbm2D(fx, fz, seed_i32, TERRAIN_FREQ, 5);
    const amplitude: f32 = switch (biome) {
        .plains => 20.0,
        .desert => 12.0,
        .tundra => 15.0,
        .mountains => 60.0,
    };
    return @intFromFloat(BASE_HEIGHT + terrain_val * amplitude);
}

fn classifyBiome(val: f32) Biome {
    if (val < -0.3) return .tundra;
    if (val < 0.1) return .plains;
    if (val < 0.4) return .desert;
    return .mountains;
}

fn selectBlock(biome: Biome, depth: i32) BlockType {
    return switch (biome) {
        .plains => if (depth == 0) .grass_block else if (depth <= 3) .dirt else .stone,
        .desert => if (depth <= 3) .sand else .stone,
        .tundra => if (depth == 0) .snow else if (depth <= 3) .dirt else .stone,
        .mountains => if (depth <= 1) .gravel else .stone,
    };
}
