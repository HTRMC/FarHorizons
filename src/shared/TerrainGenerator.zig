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

/// FastNoise2 metadata IDs
const NoiseType = enum(i32) {
    constant = 0,
    checkerboard = 2,
    gradient = 4,
    simplex = 6,
    perlin = 8,
    cellular_value = 10,
    cellular_lookup = 12,
    ping_pong = 14,
    domain_warp_simplex = 16,
    domain_warp_gradient = 18,
    domain_warp_fractal_independent = 20,
    subtract = 22,
    divide = 24,
    min = 26,
    min_smooth = 28,
    signed_square_root = 30,
    pow_int = 32,
    domain_offset = 34,
    domain_axis_scale = 36,
    convert_rgba8 = 38,
    fade = 40,
    terrace = 42,
    remove_dimension = 44,
    domain_rotate_plane = 46,
};

/// Block IDs for terrain generation
const STONE_ID: u8 = 1;
const DIRT_ID: u8 = 3;
const GRASS_ID: u8 = 4;

/// Terrain generation parameters
const BASE_HEIGHT: i32 = 64;
const HEIGHT_VARIATION: f32 = 30.0;
const NOISE_FREQUENCY: f32 = 0.02; // Controls terrain feature size

pub const TerrainGenerator = struct {
    seed: i32,
    height_noise: fastnoise2.Node,

    const Self = @This();

    /// Initialize the terrain generator with a seed
    /// Returns null if FastNoise2 initialization fails
    pub fn init(seed: i32) ?Self {
        // Use Perlin noise for terrain generation
        const node = fastnoise2.Node.fromMetadata(@intFromEnum(NoiseType.perlin), .auto) orelse {
            return null;
        };

        return Self{
            .seed = seed,
            .height_noise = node,
        };
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
            world_x_base * NOISE_FREQUENCY,
            world_z_base * NOISE_FREQUENCY,
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
