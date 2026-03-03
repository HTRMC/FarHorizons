const std = @import("std");
const WorldState = @import("WorldState.zig");
const Chunk = WorldState.Chunk;
const ChunkKey = WorldState.ChunkKey;
const CHUNK_SIZE = WorldState.CHUNK_SIZE;
const BlockType = WorldState.BlockType;

pub const ChunkMap = struct {
    allocator: std.mem.Allocator,
    chunks: std.AutoHashMap(ChunkKey, *Chunk),

    pub fn init(allocator: std.mem.Allocator) ChunkMap {
        return .{
            .allocator = allocator,
            .chunks = std.AutoHashMap(ChunkKey, *Chunk).init(allocator),
        };
    }

    pub fn deinit(self: *ChunkMap) void {
        var it = self.chunks.iterator();
        while (it.next()) |entry| {
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
        self.chunks.put(key, chunk) catch {};
    }

    pub fn remove(self: *ChunkMap, key: ChunkKey) ?*Chunk {
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

    /// Get block type at world coordinates. Missing chunks return .air.
    pub fn getBlock(self: *const ChunkMap, wx: i32, wy: i32, wz: i32) BlockType {
        const key = ChunkKey.fromWorldPos(wx, wy, wz);
        const chunk = self.get(key) orelse return .air;
        const lx: usize = @intCast(@mod(wx, @as(i32, CHUNK_SIZE)));
        const ly: usize = @intCast(@mod(wy, @as(i32, CHUNK_SIZE)));
        const lz: usize = @intCast(@mod(wz, @as(i32, CHUNK_SIZE)));
        return chunk.blocks[WorldState.chunkIndex(lx, ly, lz)];
    }

    /// Set block type at world coordinates. Does nothing if chunk is not loaded.
    pub fn setBlock(self: *const ChunkMap, wx: i32, wy: i32, wz: i32, block: BlockType) void {
        const key = ChunkKey.fromWorldPos(wx, wy, wz);
        const chunk = self.get(key) orelse return;
        const lx: usize = @intCast(@mod(wx, @as(i32, CHUNK_SIZE)));
        const ly: usize = @intCast(@mod(wy, @as(i32, CHUNK_SIZE)));
        const lz: usize = @intCast(@mod(wz, @as(i32, CHUNK_SIZE)));
        chunk.blocks[WorldState.chunkIndex(lx, ly, lz)] = block;
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
