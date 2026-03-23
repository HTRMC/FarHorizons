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

            // Infdev tree count (a.java line 494):
            // (int)(this.i.a(blockX * 0.5, blockZ * 0.5) / 8 + random * 4 + 4)
            const block_x: f64 = @floatFromInt(@as(i32, scan_cx) * CS);
            const block_z: f64 = @floatFromInt(@as(i32, scan_cz) * CS);
            const tree_noise = ng.tree_count.sample2D(block_x * 0.5, block_z * 0.5);
            const rand_f: f64 = @as(f64, @floatFromInt(rng.bounded(1000))) / 250.0; // 0..4
            const raw_count_f = tree_noise / 8.0 + rand_f + 4.0;
            // Infdev uses 16x16 chunks; ours are 32x32 (4x area), scale count by 4
            const scaled = raw_count_f * 4.0;
            // 10% chance of +1 (Infdev line 499-501)
            const bonus: f64 = if (rng.bounded(10) == 0) 1.0 else 0.0;
            const raw_count: i32 = @intFromFloat(@max(0.0, scaled + bonus));
            const num_attempts: u32 = @intCast(@min(raw_count, 40));

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
                if (wy <= 0) continue; // skip at or below sea level

                if (wy + height + 1 < chunk_min_y or wy - 1 >= chunk_max_y) continue;

                // Infdev e.java line 40: only place trees on grass or dirt
                const ground_bx = wx - origin[0];
                const ground_by = wy - 1 - origin[1];
                const ground_bz = wz - origin[2];
                if (ground_bx >= 0 and ground_bx < CS and ground_by >= 0 and ground_by < CS and ground_bz >= 0 and ground_bz < CS) {
                    const ground_blk = BlockState.getBlock(chunk.blocks[WorldState.chunkIndex(@intCast(ground_bx), @intCast(ground_by), @intCast(ground_bz))]);
                    if (ground_blk != .grass_block and ground_blk != .dirt) continue;
                }

                // Infdev e.java lines 12-34: validate space for tree
                if (!validateTreeSpace(chunk, origin, wx, wy, wz, height)) continue;

                placeTree(chunk, origin, wx, wy, wz, height, corner_seed);
            }
        }
    }
}

/// Infdev e.java lines 12-34: check the space around a tree for obstructions.
/// Returns false if any opaque non-leaf block occupies the tree's footprint.
fn validateTreeSpace(chunk: *Chunk, origin: [3]i32, wx: i32, wy: i32, wz: i32, height: i32) bool {
    const top = wy + height;
    var check_y = wy;
    while (check_y <= top + 1) : (check_y += 1) {
        // Infdev radius: 0 at base, 1 in middle, 2 at top 2 layers
        var radius: i32 = 1;
        if (check_y == wy) radius = 0;
        if (check_y >= top - 1) radius = 2;

        var dx: i32 = -radius;
        while (dx <= radius) : (dx += 1) {
            var dz: i32 = -radius;
            while (dz <= radius) : (dz += 1) {
                const bx = wx + dx - origin[0];
                const by = check_y - origin[1];
                const bz = wz + dz - origin[2];
                if (bx < 0 or bx >= CS or by < 0 or by >= CS or bz < 0 or bz >= CS) continue;

                const blk = BlockState.getBlock(chunk.blocks[WorldState.chunkIndex(@intCast(bx), @intCast(by), @intCast(bz))]);
                // Fail if occupied by anything other than air, water, or leaves
                if (blk != .air and blk != .water and blk != .oak_leaves) return false;
            }
        }
    }
    return true;
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
