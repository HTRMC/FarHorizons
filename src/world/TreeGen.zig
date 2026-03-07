const std = @import("std");
const WorldState = @import("WorldState.zig");
const TerrainGen = @import("TerrainGen.zig");
const Noise = @import("Noise.zig");

const Chunk = WorldState.Chunk;
const ChunkKey = WorldState.ChunkKey;
const BlockType = WorldState.BlockType;
const CHUNK_SIZE = WorldState.CHUNK_SIZE;
const CS: i32 = CHUNK_SIZE;

// Trees can extend ~3 blocks beyond their base chunk, well within 1-chunk range for 32-block chunks.
const TREE_SCAN_RANGE: i32 = 1;

const TreeRng = struct {
    state: u64,

    fn init(seed: u64) TreeRng {
        return .{ .state = seed };
    }

    fn next(self: *TreeRng) u64 {
        self.state +%= 0x9e3779b97f4a7c15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        return z ^ (z >> 31);
    }

    fn bounded(self: *TreeRng, max: u32) u32 {
        return @intCast(self.next() % max);
    }
};

pub fn plantTrees(chunk: *Chunk, key: ChunkKey, seed: u64) void {
    const origin = key.position();
    const chunk_min_y = origin[1];
    const chunk_max_y = origin[1] + CS;
    const ng = Noise.NoiseGen.init(seed);

    var scan_cx = key.cx - TREE_SCAN_RANGE;
    while (scan_cx <= key.cx + TREE_SCAN_RANGE) : (scan_cx += 1) {
        var scan_cz = key.cz - TREE_SCAN_RANGE;
        while (scan_cz <= key.cz + TREE_SCAN_RANGE) : (scan_cz += 1) {
            const col_seed = seed +%
                @as(u64, @bitCast(@as(i64, scan_cx) *% 198491317)) +%
                @as(u64, @bitCast(@as(i64, scan_cz) *% 776531419)) +%
                0x54524545;

            var rng = TreeRng.init(col_seed);
            const num_attempts = rng.bounded(6) + 2; // 2-7 trees per 32x32 column

            for (0..num_attempts) |_| {
                const local_x: i32 = @intCast(rng.bounded(@intCast(CS)));
                const local_z: i32 = @intCast(rng.bounded(@intCast(CS)));
                const wx = scan_cx * CS + local_x;
                const wz = scan_cz * CS + local_z;
                const height: i32 = @intCast(rng.bounded(3) + 4); // 4-6, matches MC
                const corner_seed = rng.next();

                // Find the actual surface by scanning chunk data when possible,
                // fall back to noise-based height for cross-chunk trees.
                const bx = wx - origin[0];
                const bz = wz - origin[2];
                const in_chunk_xz = bx >= 0 and bx < CS and bz >= 0 and bz < CS;

                const wy = if (in_chunk_xz)
                    findSurface(chunk, origin, @intCast(bx), @intCast(bz))
                else
                    TerrainGen.sampleHeightWithNoise(wx, wz, &ng);

                if (wy < 0) continue; // don't place below sea level

                // Tree spans [wy-1, wy+height+1]; skip if outside chunk Y range
                if (wy + height + 1 < chunk_min_y or wy - 1 >= chunk_max_y) continue;

                placeTree(chunk, origin, wx, wy, wz, height, corner_seed);
            }
        }
    }
}

/// Scan a column in the chunk data top-down to find the first air/water block
/// above a grass_block or dirt. Returns world Y of the air block (tree base),
/// or -1 if no valid surface found.
fn findSurface(chunk: *Chunk, origin: [3]i32, bx: usize, bz: usize) i32 {
    var by: usize = CHUNK_SIZE;
    while (by > 0) {
        by -= 1;
        const block = chunk.blocks[WorldState.chunkIndex(bx, by, bz)];
        if (block == .grass_block or block == .dirt) {
            return origin[1] + @as(i32, @intCast(by)) + 1;
        }
    }
    return -1;
}

fn placeTree(chunk: *Chunk, origin: [3]i32, wx: i32, wy: i32, wz: i32, height: i32, corner_seed: u64) void {
    var corner_rng = TreeRng.init(corner_seed);
    const top = wy + height;

    // Place leaves: 4 layers from (top-3) to top
    // MC radius pattern: 2, 2, 1, 1 (bottom to top of crown)
    var ly = top - 3;
    while (ly <= top) : (ly += 1) {
        const layer_offset = ly - top; // -3, -2, -1, 0
        const radius: i32 = 1 - @divTrunc(layer_offset, 2);

        var dx: i32 = -radius;
        while (dx <= radius) : (dx += 1) {
            var dz: i32 = -radius;
            while (dz <= radius) : (dz += 1) {
                const is_corner = @abs(dx) == radius and @abs(dz) == radius;
                var place = true;
                if (is_corner) {
                    // MC: nextInt(2) != 0 && var19 != 0
                    // Always consume RNG at corners for consistency across chunks
                    const rand_val = corner_rng.bounded(2);
                    if (rand_val == 0 or layer_offset == 0) {
                        place = false;
                    }
                }

                if (!place) continue;

                const bx = wx + dx - origin[0];
                const by = ly - origin[1];
                const bz = wz + dz - origin[2];
                if (bx < 0 or bx >= CS or by < 0 or by >= CS or bz < 0 or bz >= CS) continue;

                const idx = WorldState.chunkIndex(@intCast(bx), @intCast(by), @intCast(bz));
                if (!WorldState.block_properties.isOpaque(chunk.blocks[idx])) {
                    chunk.blocks[idx] = .oak_leaves;
                }
            }
        }
    }

    // Place trunk (log blocks from base to base+height-1)
    var ty = wy;
    while (ty < wy + height) : (ty += 1) {
        const bx = wx - origin[0];
        const by = ty - origin[1];
        const bz = wz - origin[2];
        if (bx < 0 or bx >= CS or by < 0 or by >= CS or bz < 0 or bz >= CS) continue;

        const idx = WorldState.chunkIndex(@intCast(bx), @intCast(by), @intCast(bz));
        const block = chunk.blocks[idx];
        if (block == .air or block == .oak_leaves) {
            chunk.blocks[idx] = .oak_log;
        }
    }

    // Set ground block to dirt
    {
        const bx = wx - origin[0];
        const by = wy - 1 - origin[1];
        const bz = wz - origin[2];
        if (bx >= 0 and bx < CS and by >= 0 and by < CS and bz >= 0 and bz < CS) {
            const idx = WorldState.chunkIndex(@intCast(bx), @intCast(by), @intCast(bz));
            if (chunk.blocks[idx] == .grass_block) {
                chunk.blocks[idx] = .dirt;
            }
        }
    }
}
