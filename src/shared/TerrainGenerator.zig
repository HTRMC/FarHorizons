/// TerrainGenerator - Procedural terrain generation using FastNoise2
///
/// Generates height-based terrain with stone, dirt, and grass layers.
/// Uses FastNoise2's SIMD-optimized noise generation for maximum performance.
const std = @import("std");
const chunk_mod = @import("Chunk.zig");
const Chunk = chunk_mod.Chunk;
const BlockEntry = chunk_mod.BlockEntry;
const CHUNK_SIZE = chunk_mod.CHUNK_SIZE;
const fastnoise2 = @import("fastnoise2.zig");

/// Block IDs for terrain generation
const STONE_ID: u8 = 1;
const DIRT_ID: u8 = 3;
const GRASS_ID: u8 = 4;

/// Terrain generation parameters
const BASE_HEIGHT: i32 = 64;
const HEIGHT_VARIATION: f32 = 20.0;
const NOISE_FREQUENCY: f32 = 0.02;

pub const TerrainGenerator = struct {
    seed: i32,
    height_noise: fastnoise2.Node,

    const Self = @This();

    /// Initialize the terrain generator with a seed
    /// Returns null if FastNoise2 initialization fails
    pub fn init(seed: i32) ?Self {
        // Try to create a simple noise node from metadata
        // Common metadata IDs:
        // 0 = OpenSimplex2
        // 1 = OpenSimplex2S
        // 2 = Perlin
        // 3 = Value
        // 4 = ValueCubic
        // 5 = Cellular

        // Try OpenSimplex2 first (ID 0), then Perlin (ID 2), then others
        const preferred_ids = [_]i32{ 0, 2, 1, 3, 4 };

        for (preferred_ids) |id| {
            if (fastnoise2.Node.fromMetadata(id, .auto)) |node| {
                return Self{
                    .seed = seed,
                    .height_noise = node,
                };
            }
        }

        // Last resort: try all available metadata types
        const count = fastnoise2.getMetadataCount();
        var i: i32 = 0;
        while (i < count) : (i += 1) {
            if (fastnoise2.Node.fromMetadata(i, .auto)) |node| {
                return Self{
                    .seed = seed,
                    .height_noise = node,
                };
            }
        }

        return null;
    }

    /// Free resources
    pub fn deinit(self: *Self) void {
        self.height_noise.deinit();
    }

    /// Generate a chunk at the given chunk coordinates
    /// chunk_x, chunk_z: horizontal chunk position
    /// section_y: vertical section index (each section is 16 blocks tall)
    pub fn generateChunk(self: *const Self, chunk_x: i32, section_y: i32, chunk_z: i32) Chunk {
        var chunk = Chunk.init();

        // World Y range for this section
        const section_base_y = section_y * @as(i32, CHUNK_SIZE);

        // Calculate world offset for this chunk (in noise space)
        const world_x_base: f32 = @floatFromInt(chunk_x * @as(i32, CHUNK_SIZE));
        const world_z_base: f32 = @floatFromInt(chunk_z * @as(i32, CHUNK_SIZE));

        // Generate 16x16 height values using SIMD-optimized batch generation
        var height_noise: [CHUNK_SIZE * CHUNK_SIZE]f32 = undefined;

        // GenUniformGrid2D parameters:
        // - xOffset/yOffset: starting position (we scale by frequency here)
        // - xCount/yCount: number of samples (16x16)
        // - xStepSize/yStepSize: distance between samples in noise space (frequency)
        _ = self.height_noise.genUniformGrid2D(
            &height_noise,
            world_x_base * NOISE_FREQUENCY, // x offset in noise space
            world_z_base * NOISE_FREQUENCY, // z mapped to y in 2D noise
            CHUNK_SIZE, // x count
            CHUNK_SIZE, // y count (z in world)
            NOISE_FREQUENCY, // step size applies frequency scaling
            self.seed,
        );

        // Generate blocks for each column
        var local_x: u32 = 0;
        while (local_x < CHUNK_SIZE) : (local_x += 1) {
            var local_z: u32 = 0;
            while (local_z < CHUNK_SIZE) : (local_z += 1) {
                // Get height from pre-computed noise array
                // FastNoise2 outputs in row-major order: x + z * xCount
                const noise_idx = local_x + local_z * CHUNK_SIZE;
                const noise_val = height_noise[noise_idx];

                // Convert noise (-1 to 1) to terrain height
                const terrain_height = BASE_HEIGHT + @as(i32, @intFromFloat(noise_val * HEIGHT_VARIATION));

                // Fill column based on height
                var local_y: u32 = 0;
                while (local_y < CHUNK_SIZE) : (local_y += 1) {
                    const world_y = section_base_y + @as(i32, @intCast(local_y));

                    const block = getBlockForHeight(world_y, terrain_height);
                    chunk.setBlockEntry(local_x, local_y, local_z, block);
                }
            }
        }

        return chunk;
    }

    /// Determine which block to place based on world Y and terrain height
    fn getBlockForHeight(world_y: i32, terrain_height: i32) BlockEntry {
        if (world_y > terrain_height) {
            // Above terrain: air
            return BlockEntry.AIR;
        } else if (world_y == terrain_height) {
            // Surface: grass
            return BlockEntry.simple(GRASS_ID);
        } else if (world_y >= terrain_height - 3) {
            // 3 blocks below surface: dirt
            return BlockEntry.simple(DIRT_ID);
        } else {
            // Deep underground: stone
            return BlockEntry.simple(STONE_ID);
        }
    }
};
