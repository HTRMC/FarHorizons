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

/// FastNoise2 metadata IDs (sequential based on registration order in FastSIMD_Build.inl)
const NoiseType = enum(i32) {
    constant = 0,
    white = 1,
    checkerboard = 2,
    sine_wave = 3,
    gradient = 4,
    distance_to_point = 5,
    simplex = 6,
    super_simplex = 7,
    perlin = 8,
    value = 9,
    cellular_value = 10,
    cellular_distance = 11,
    cellular_lookup = 12,
    fractal_fbm = 13,
    ping_pong = 14,
    fractal_ridged = 15,
    domain_warp_simplex = 16,
    domain_warp_super_simplex = 17,
    domain_warp_gradient = 18,
    domain_warp_fractal_progressive = 19,
    domain_warp_fractal_independent = 20,
    add = 21,
    subtract = 22,
    multiply = 23,
    divide = 24,
    abs = 25,
    min = 26,
    max = 27,
    min_smooth = 28,
    max_smooth = 29,
    signed_square_root = 30,
    pow_float = 31,
    pow_int = 32,
    domain_scale = 33,
    domain_offset = 34,
    domain_rotate = 35,
    domain_axis_scale = 36,
    seed_offset = 37,
    convert_rgba8 = 38,
    generator_cache = 39,
    fade = 40,
    remap = 41,
    terrace = 42,
    add_dimension = 43,
    remove_dimension = 44,
    modulus = 45,
    domain_rotate_plane = 46,
};

/// Block IDs for terrain generation
const STONE_ID: u8 = 1;
const DIRT_ID: u8 = 3;
const GRASS_ID: u8 = 4;

/// Terrain configuration parameters
pub const TerrainConfig = struct {
    seed: i32 = 12345,
    base_height: i32 = 64,
    height_variation: f32 = 32.0,
    frequency: f32 = 1.0,
};

pub const TerrainGenerator = struct {
    config: TerrainConfig,
    height_noise: fastnoise2.Node,

    const Self = @This();

    /// Initialize the terrain generator with a config
    /// Returns null if FastNoise2 initialization fails
    pub fn init(config: TerrainConfig) ?Self {
        // Use Perlin noise for terrain generation
        const node = fastnoise2.Node.fromMetadata(@intFromEnum(NoiseType.perlin), .auto) orelse {
            return null;
        };

        return Self{
            .config = config,
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

        const freq = self.config.frequency;

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
            world_x_base * freq,
            world_z_base * freq,
            CHUNK_SIZE, // x count
            CHUNK_SIZE, // y count (z in world)
            freq, // step size applies frequency scaling
            self.config.seed,
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
                const terrain_height = self.config.base_height + @as(i32, @intFromFloat(noise_val * self.config.height_variation));

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
