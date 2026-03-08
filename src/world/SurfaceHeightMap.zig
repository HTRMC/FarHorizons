const std = @import("std");
const WorldState = @import("WorldState.zig");
const ChunkMap = @import("ChunkMap.zig").ChunkMap;
const block_properties = WorldState.block_properties;
const CHUNK_SIZE = WorldState.CHUNK_SIZE;

pub const SurfaceHeightMap = struct {
    pub const ColumnKey = struct { cx: i32, cz: i32 };
    /// Per-column surface heights: [z * CHUNK_SIZE + x] → world Y of highest opaque block.
    /// MIN_HEIGHT means no opaque block exists in this column.
    pub const HeightColumn = [CHUNK_SIZE * CHUNK_SIZE]i32;
    pub const MIN_HEIGHT: i32 = std.math.minInt(i32);
    const SCAN_RANGE: i32 = 20;

    columns: std.AutoHashMap(ColumnKey, *HeightColumn),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SurfaceHeightMap {
        return .{
            .columns = std.AutoHashMap(ColumnKey, *HeightColumn).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SurfaceHeightMap) void {
        var it = self.columns.iterator();
        while (it.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.columns.deinit();
    }

    /// Get the height column for a chunk column (cx, cz). Returns null if not tracked.
    pub fn getHeights(self: *const SurfaceHeightMap, cx: i32, cz: i32) ?*const HeightColumn {
        return self.columns.get(.{ .cx = cx, .cz = cz });
    }

    /// Update surface heights from a newly loaded chunk. Takes the max of existing
    /// heights and the highest opaque block in each (x,z) column of this chunk.
    pub fn updateFromChunk(self: *SurfaceHeightMap, key: WorldState.ChunkKey, chunk: *const WorldState.Chunk) void {
        const col_key = ColumnKey{ .cx = key.cx, .cz = key.cz };
        const col = self.columns.get(col_key) orelse blk: {
            const new_col = self.allocator.create(HeightColumn) catch return;
            @memset(new_col, MIN_HEIGHT);
            self.columns.put(col_key, new_col) catch {
                self.allocator.destroy(new_col);
                return;
            };
            break :blk new_col;
        };

        const base_y: i32 = key.cy * @as(i32, CHUNK_SIZE);
        for (0..CHUNK_SIZE) |z| {
            for (0..CHUNK_SIZE) |x| {
                // Scan from top to find highest opaque block in this chunk column
                var y: i32 = CHUNK_SIZE - 1;
                while (y >= 0) : (y -= 1) {
                    const idx = @as(usize, @intCast(y)) * CHUNK_SIZE * CHUNK_SIZE + z * CHUNK_SIZE + x;
                    if (block_properties.isOpaque(chunk.blocks[idx])) {
                        const world_y = base_y + y;
                        const col_idx = z * CHUNK_SIZE + x;
                        if (world_y > col[col_idx]) {
                            col[col_idx] = world_y;
                        }
                        break;
                    }
                }
            }
        }
    }

    /// Rebuild the surface height for a single (x,z) column by scanning all loaded
    /// chunks in the chunk column. Used after block break when the height may decrease.
    pub fn rebuildColumnAt(self: *SurfaceHeightMap, cx: i32, cz: i32, local_x: usize, local_z: usize, chunk_map: *const ChunkMap) void {
        const col_key = ColumnKey{ .cx = cx, .cz = cz };
        const col = self.columns.get(col_key) orelse return;
        const col_idx = local_z * CHUNK_SIZE + local_x;

        // Reset and rescan all loaded chunks in this column
        col[col_idx] = MIN_HEIGHT;

        var cy: i32 = -SCAN_RANGE;
        while (cy <= SCAN_RANGE) : (cy += 1) {
            const key = WorldState.ChunkKey{ .cx = cx, .cy = cy, .cz = cz };
            const chunk = chunk_map.get(key) orelse continue;
            const base_y: i32 = cy * @as(i32, CHUNK_SIZE);

            var y: i32 = CHUNK_SIZE - 1;
            while (y >= 0) : (y -= 1) {
                const idx = @as(usize, @intCast(y)) * CHUNK_SIZE * CHUNK_SIZE + local_z * CHUNK_SIZE + local_x;
                if (block_properties.isOpaque(chunk.blocks[idx])) {
                    const world_y = base_y + y;
                    if (world_y > col[col_idx]) {
                        col[col_idx] = world_y;
                    }
                    break;
                }
            }
        }
    }

    /// Update surface height after placing an opaque block.
    pub fn updateBlockPlaced(self: *SurfaceHeightMap, cx: i32, cz: i32, local_x: usize, local_z: usize, world_y: i32) void {
        const col_key = ColumnKey{ .cx = cx, .cz = cz };
        const col = self.columns.get(col_key) orelse return;
        const col_idx = local_z * CHUNK_SIZE + local_x;
        if (world_y > col[col_idx]) {
            col[col_idx] = world_y;
        }
    }

    /// Remove a chunk column entry when no chunks remain at that (cx,cz).
    pub fn removeColumn(self: *SurfaceHeightMap, cx: i32, cz: i32) void {
        const col_key = ColumnKey{ .cx = cx, .cz = cz };
        if (self.columns.fetchRemove(col_key)) |kv| {
            self.allocator.destroy(kv.value);
        }
    }

    /// Check if any chunks still exist in this column.
    pub fn hasChunksInColumn(cx: i32, cz: i32, chunk_map: *const ChunkMap) bool {
        var cy: i32 = -SCAN_RANGE;
        while (cy <= SCAN_RANGE) : (cy += 1) {
            if (chunk_map.get(.{ .cx = cx, .cy = cy, .cz = cz }) != null) return true;
        }
        return false;
    }
};

// ─── Tests ───

const testing = std.testing;
const Chunk = WorldState.Chunk;
const BLOCKS_PER_CHUNK = WorldState.BLOCKS_PER_CHUNK;

fn chunkIndex(x: usize, y: usize, z: usize) usize {
    return y * CHUNK_SIZE * CHUNK_SIZE + z * CHUNK_SIZE + x;
}

fn allocChunk() !*Chunk {
    const chunk = try testing.allocator.create(Chunk);
    chunk.* = .{ .blocks = .{.air} ** BLOCKS_PER_CHUNK };
    return chunk;
}

test "empty chunk produces no surface height" {
    var shm = SurfaceHeightMap.init(testing.allocator);
    defer shm.deinit();

    const chunk = try allocChunk();
    defer testing.allocator.destroy(chunk);

    const key = WorldState.ChunkKey{ .cx = 0, .cy = 0, .cz = 0 };
    shm.updateFromChunk(key, chunk);

    const col = shm.getHeights(0, 0).?;
    // All air — heights should remain MIN_HEIGHT
    for (col) |h| {
        try testing.expectEqual(SurfaceHeightMap.MIN_HEIGHT, h);
    }
}

test "single opaque block sets surface height" {
    var shm = SurfaceHeightMap.init(testing.allocator);
    defer shm.deinit();

    const chunk = try allocChunk();
    defer testing.allocator.destroy(chunk);
    chunk.blocks[chunkIndex(5, 10, 7)] = .stone;

    const key = WorldState.ChunkKey{ .cx = 0, .cy = 0, .cz = 0 };
    shm.updateFromChunk(key, chunk);

    const col = shm.getHeights(0, 0).?;
    // world_y = cy * 32 + local_y = 0 * 32 + 10 = 10
    try testing.expectEqual(@as(i32, 10), col[7 * CHUNK_SIZE + 5]);
    // Other columns should remain MIN_HEIGHT
    try testing.expectEqual(SurfaceHeightMap.MIN_HEIGHT, col[0]);
}

test "higher chunk overrides lower surface height" {
    var shm = SurfaceHeightMap.init(testing.allocator);
    defer shm.deinit();

    const chunk_low = try allocChunk();
    defer testing.allocator.destroy(chunk_low);
    chunk_low.blocks[chunkIndex(3, 5, 3)] = .stone;

    const chunk_high = try allocChunk();
    defer testing.allocator.destroy(chunk_high);
    chunk_high.blocks[chunkIndex(3, 20, 3)] = .stone;

    // Load low chunk first (cy=0, world_y=5)
    shm.updateFromChunk(.{ .cx = 0, .cy = 0, .cz = 0 }, chunk_low);
    const col = shm.getHeights(0, 0).?;
    try testing.expectEqual(@as(i32, 5), col[3 * CHUNK_SIZE + 3]);

    // Load high chunk (cy=1, world_y=32+20=52) — should override
    shm.updateFromChunk(.{ .cx = 0, .cy = 1, .cz = 0 }, chunk_high);
    try testing.expectEqual(@as(i32, 52), col[3 * CHUNK_SIZE + 3]);
}

test "updateBlockPlaced updates height" {
    var shm = SurfaceHeightMap.init(testing.allocator);
    defer shm.deinit();

    const chunk = try allocChunk();
    defer testing.allocator.destroy(chunk);
    chunk.blocks[chunkIndex(0, 5, 0)] = .stone;

    shm.updateFromChunk(.{ .cx = 0, .cy = 0, .cz = 0 }, chunk);
    const col = shm.getHeights(0, 0).?;
    try testing.expectEqual(@as(i32, 5), col[0]);

    // Place a block higher
    shm.updateBlockPlaced(0, 0, 0, 0, 15);
    try testing.expectEqual(@as(i32, 15), col[0]);

    // Place below — should not change
    shm.updateBlockPlaced(0, 0, 0, 0, 3);
    try testing.expectEqual(@as(i32, 15), col[0]);
}

test "rebuildColumnAt rescans after break" {
    var shm = SurfaceHeightMap.init(testing.allocator);
    defer shm.deinit();

    var chunk_map = ChunkMap.init(testing.allocator);
    defer chunk_map.deinit();

    const chunk = try allocChunk();
    chunk.blocks[chunkIndex(2, 10, 2)] = .stone;
    chunk.blocks[chunkIndex(2, 5, 2)] = .stone;

    const key = WorldState.ChunkKey{ .cx = 0, .cy = 0, .cz = 0 };
    chunk_map.put(key, chunk);
    shm.updateFromChunk(key, chunk);

    const col = shm.getHeights(0, 0).?;
    try testing.expectEqual(@as(i32, 10), col[2 * CHUNK_SIZE + 2]);

    // Simulate breaking the top block
    chunk.blocks[chunkIndex(2, 10, 2)] = .air;
    shm.rebuildColumnAt(0, 0, 2, 2, &chunk_map);

    // Should now show the lower block
    try testing.expectEqual(@as(i32, 5), col[2 * CHUNK_SIZE + 2]);
}

test "negative chunk cy produces correct world heights" {
    var shm = SurfaceHeightMap.init(testing.allocator);
    defer shm.deinit();

    const chunk = try allocChunk();
    defer testing.allocator.destroy(chunk);
    chunk.blocks[chunkIndex(0, 0, 0)] = .stone;

    // cy = -1, so world_y = -1 * 32 + 0 = -32
    shm.updateFromChunk(.{ .cx = 0, .cy = -1, .cz = 0 }, chunk);

    const col = shm.getHeights(0, 0).?;
    try testing.expectEqual(@as(i32, -32), col[0]);
}
