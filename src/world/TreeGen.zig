const WorldState = @import("WorldState.zig");
const BlockState = WorldState.BlockState;
const TerrainGen = @import("TerrainGen.zig");
const Noise = @import("Noise.zig");

const Chunk = WorldState.Chunk;
const ChunkKey = WorldState.ChunkKey;
const CHUNK_SIZE = WorldState.CHUNK_SIZE;
const CS: i32 = CHUNK_SIZE;

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
            const num_attempts = rng.bounded(6) + 2;

            for (0..num_attempts) |_| {
                const local_x: i32 = @intCast(rng.bounded(@intCast(CS)));
                const local_z: i32 = @intCast(rng.bounded(@intCast(CS)));
                const wx = scan_cx * CS + local_x;
                const wz = scan_cz * CS + local_z;
                const height: i32 = @intCast(rng.bounded(3) + 4);
                const corner_seed = rng.next();

                // Grid-interpolated height matches chunk gen exactly.
                // All chunks compute the same value, so trees are seamless.
                const wy = TerrainGen.sampleGridSurfaceHeight(wx, wz, &ng);
                if (wy < 0) continue;

                if (wy + height + 1 < chunk_min_y or wy - 1 >= chunk_max_y) continue;

                placeTree(chunk, origin, wx, wy, wz, height, corner_seed);
            }
        }
    }
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
                if (!BlockState.isOpaque(chunk.blocks[idx])) {
                    chunk.blocks[idx] = BlockState.defaultState(.oak_leaves);
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
        const blk = BlockState.getBlock(chunk.blocks[idx]);
        if (blk == .air or blk == .oak_leaves) {
            chunk.blocks[idx] = BlockState.defaultState(.oak_log);
        }
    }

    // Set ground block to dirt
    {
        const bx = wx - origin[0];
        const by = wy - 1 - origin[1];
        const bz = wz - origin[2];
        if (bx >= 0 and bx < CS and by >= 0 and by < CS and bz >= 0 and bz < CS) {
            const idx = WorldState.chunkIndex(@intCast(bx), @intCast(by), @intCast(bz));
            if (BlockState.getBlock(chunk.blocks[idx]) == .grass_block) {
                chunk.blocks[idx] = BlockState.defaultState(.dirt);
            }
        }
    }
}
