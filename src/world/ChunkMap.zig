const std = @import("std");
const WorldState = @import("WorldState.zig");
const BlockState = @import("BlockState.zig");
const Chunk = WorldState.Chunk;
const ChunkKey = WorldState.ChunkKey;
const CHUNK_SIZE = WorldState.CHUNK_SIZE;

/// Pre-allocated capacity to avoid hash map resizes during gameplay.
/// Sized for unload-distance sphere: 4/3 * π * 18³ ≈ 24,429 with 2× headroom.
pub const PREALLOCATED_CAPACITY: u32 = 50_000;

pub const ChunkMap = struct {
    allocator: std.mem.Allocator,
    chunks: std.AutoHashMap(ChunkKey, *Chunk),
    main_thread_id: std.Thread.Id,

    pub fn init(allocator: std.mem.Allocator) ChunkMap {
        var chunks = std.AutoHashMap(ChunkKey, *Chunk).init(allocator);
        chunks.ensureTotalCapacity(PREALLOCATED_CAPACITY) catch {};
        return .{
            .allocator = allocator,
            .chunks = chunks,
            .main_thread_id = std.Thread.getCurrentId(),
        };
    }

    pub fn deinit(self: *ChunkMap) void {
        var it = self.chunks.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.blocks.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.chunks.deinit();
    }

    pub fn get(self: *const ChunkMap, key: ChunkKey) ?*Chunk {
        return self.chunks.get(key);
    }

    pub fn getConst(self: *const ChunkMap, key: ChunkKey) ?*const Chunk {
        if (self.chunks.get(key)) |ptr| return ptr;
        return null;
    }

    pub fn put(self: *ChunkMap, key: ChunkKey, chunk: *Chunk) void {
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread_id);
        self.chunks.put(key, chunk) catch {};
    }

    pub fn remove(self: *ChunkMap, key: ChunkKey) ?*Chunk {
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread_id);
        if (self.chunks.fetchRemove(key)) |kv| {
            return kv.value;
        }
        return null;
    }

    pub fn count(self: *const ChunkMap) usize {
        return self.chunks.count();
    }

    pub fn iterator(self: *const ChunkMap) std.AutoHashMap(ChunkKey, *Chunk).Iterator {
        return self.chunks.iterator();
    }

    /// Get block state at world coordinates. Missing chunks return air.
    pub fn getBlock(self: *const ChunkMap, pos: WorldState.WorldBlockPos) BlockState.StateId {
        const chunk = self.get(pos.toChunkKey()) orelse return BlockState.defaultState(.air);
        return chunk.blocks.get(pos.toLocal().toIndex());
    }

    /// Set block state at world coordinates. Does nothing if chunk is not loaded.
    /// Locks the chunk mutex to prevent IO threads from reading during modification.
    pub fn setBlock(self: *const ChunkMap, pos: WorldState.WorldBlockPos, block: BlockState.StateId) void {
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread_id);
        const chunk = self.get(pos.toChunkKey()) orelse return;
        const io = std.Io.Threaded.global_single_threaded.io();
        chunk.mutex.lockUncancelable(io);
        chunk.blocks.set(pos.toLocal().toIndex(), block);
        chunk.mutex.unlock(io);
    }

    /// Get the 6 face neighbors for a chunk key.
    pub fn getNeighbors(self: *const ChunkMap, key: ChunkKey) [6]?*const Chunk {
        var neighbors: [6]?*const Chunk = .{ null, null, null, null, null, null };
        const offsets = WorldState.face_neighbor_offsets;
        for (0..6) |i| {
            const nk = ChunkKey{
                .cx = key.cx + offsets[i][0],
                .cy = key.cy + offsets[i][1],
                .cz = key.cz + offsets[i][2],
            };
            neighbors[i] = self.getConst(nk);
        }
        return neighbors;
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn makeTestChunk(allocator: std.mem.Allocator, fill: BlockState.Block) !*Chunk {
    const chunk = try allocator.create(Chunk);
    chunk.* = .{ .blocks = WorldState.PaletteBlocks.init(allocator) };
    chunk.blocks.fillUniform(BlockState.defaultState(fill));
    return chunk;
}

test "ChunkMap: put and get" {
    var map = ChunkMap.init(testing.allocator);
    defer map.deinit();

    const chunk = try makeTestChunk(testing.allocator, .stone);
    // Don't defer destroy — map.deinit handles it

    const key = ChunkKey{ .cx = 0, .cy = 0, .cz = 0 };
    map.put(key, chunk);

    try testing.expect(map.get(key) != null);
    try testing.expectEqual(chunk, map.get(key).?);
    try testing.expectEqual(@as(usize, 1), map.count());
}

test "ChunkMap: get missing chunk returns null" {
    var map = ChunkMap.init(testing.allocator);
    defer map.deinit();

    try testing.expect(map.get(ChunkKey{ .cx = 99, .cy = 99, .cz = 99 }) == null);
}

test "ChunkMap: remove returns chunk" {
    var map = ChunkMap.init(testing.allocator);
    defer map.deinit();

    const chunk = try makeTestChunk(testing.allocator, .air);
    const key = ChunkKey{ .cx = 1, .cy = 2, .cz = 3 };
    map.put(key, chunk);

    const removed = map.remove(key);
    try testing.expect(removed != null);
    try testing.expectEqual(chunk, removed.?);
    try testing.expect(map.get(key) == null);
    try testing.expectEqual(@as(usize, 0), map.count());

    // Clean up manually since we removed it from map
    removed.?.blocks.deinit();
    testing.allocator.destroy(removed.?);
}

test "ChunkMap: remove missing returns null" {
    var map = ChunkMap.init(testing.allocator);
    defer map.deinit();

    try testing.expect(map.remove(ChunkKey{ .cx = 0, .cy = 0, .cz = 0 }) == null);
}

test "ChunkMap: getBlock returns air for missing chunk" {
    var map = ChunkMap.init(testing.allocator);
    defer map.deinit();

    try testing.expectEqual(BlockState.defaultState(.air), map.getBlock(WorldState.WorldBlockPos.init(100, 200, 300)));
}

test "ChunkMap: getBlock returns correct block from loaded chunk" {
    var map = ChunkMap.init(testing.allocator);
    defer map.deinit();

    const chunk = try makeTestChunk(testing.allocator, .air);
    chunk.blocks.set(WorldState.chunkIndex(5, 10, 15), BlockState.defaultState(.stone));
    map.put(ChunkKey{ .cx = 0, .cy = 0, .cz = 0 }, chunk);

    try testing.expectEqual(BlockState.Block.stone, BlockState.getBlock(map.getBlock(WorldState.WorldBlockPos.init(5, 10, 15))));
    try testing.expectEqual(BlockState.Block.air, BlockState.getBlock(map.getBlock(WorldState.WorldBlockPos.init(0, 0, 0))));
}

test "ChunkMap: getBlock with negative world coordinates" {
    var map = ChunkMap.init(testing.allocator);
    defer map.deinit();

    const chunk = try makeTestChunk(testing.allocator, .air);
    // Chunk at (-1,-1,-1) covers world coords [-32, -1]
    // Block at local (31,31,31) = world (-1,-1,-1)
    chunk.blocks.set(WorldState.chunkIndex(31, 31, 31), BlockState.defaultState(.dirt));
    map.put(ChunkKey{ .cx = -1, .cy = -1, .cz = -1 }, chunk);

    try testing.expectEqual(BlockState.Block.dirt, BlockState.getBlock(map.getBlock(WorldState.WorldBlockPos.init(-1, -1, -1))));
    try testing.expectEqual(BlockState.Block.air, BlockState.getBlock(map.getBlock(WorldState.WorldBlockPos.init(-32, -32, -32))));
}

test "ChunkMap: setBlock modifies loaded chunk" {
    var map = ChunkMap.init(testing.allocator);
    defer map.deinit();

    const chunk = try makeTestChunk(testing.allocator, .air);
    map.put(ChunkKey{ .cx = 0, .cy = 0, .cz = 0 }, chunk);

    map.setBlock(WorldState.WorldBlockPos.init(5, 5, 5), BlockState.defaultState(.gold_block));
    try testing.expectEqual(BlockState.Block.gold_block, BlockState.getBlock(map.getBlock(WorldState.WorldBlockPos.init(5, 5, 5))));
}

test "ChunkMap: setBlock on missing chunk does nothing" {
    var map = ChunkMap.init(testing.allocator);
    defer map.deinit();

    // Should not crash
    map.setBlock(WorldState.WorldBlockPos.init(100, 100, 100), BlockState.defaultState(.stone));
    try testing.expectEqual(BlockState.defaultState(.air), map.getBlock(WorldState.WorldBlockPos.init(100, 100, 100)));
}

test "ChunkMap: getNeighbors returns loaded neighbors" {
    var map = ChunkMap.init(testing.allocator);
    defer map.deinit();

    const center_key = ChunkKey{ .cx = 0, .cy = 0, .cz = 0 };
    const center = try makeTestChunk(testing.allocator, .air);
    map.put(center_key, center);

    // Add one neighbor: east (+x)
    const east_key = ChunkKey{ .cx = 1, .cy = 0, .cz = 0 };
    const east = try makeTestChunk(testing.allocator, .stone);
    map.put(east_key, east);

    const neighbors = map.getNeighbors(center_key);

    // Count non-null neighbors
    var loaded: u32 = 0;
    for (neighbors) |n| {
        if (n != null) loaded += 1;
    }
    try testing.expectEqual(@as(u32, 1), loaded);
}

test "ChunkMap: multiple chunks at different keys" {
    var map = ChunkMap.init(testing.allocator);
    defer map.deinit();

    const keys = [_]ChunkKey{
        .{ .cx = 0, .cy = 0, .cz = 0 },
        .{ .cx = 1, .cy = 0, .cz = 0 },
        .{ .cx = -1, .cy = -1, .cz = -1 },
        .{ .cx = 100, .cy = -50, .cz = 200 },
    };

    for (keys) |key| {
        const chunk = try makeTestChunk(testing.allocator, .air);
        map.put(key, chunk);
    }

    try testing.expectEqual(@as(usize, 4), map.count());
    for (keys) |key| {
        try testing.expect(map.get(key) != null);
    }
}
