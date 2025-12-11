/// Cross-chunk block access
/// Provides a way to query blocks across chunk boundaries during mesh generation
const std = @import("std");
const chunk_mod = @import("chunk.zig");
const Chunk = chunk_mod.Chunk;
const BlockType = chunk_mod.BlockType;
const BlockEntry = chunk_mod.BlockEntry;
const CHUNK_SIZE = chunk_mod.CHUNK_SIZE;
const voxel_shape = @import("voxel_shape.zig");
const Direction = voxel_shape.Direction;

/// Interface for accessing blocks across chunk boundaries
/// Used during mesh generation to properly cull faces at chunk edges
pub const ChunkAccess = struct {
    const Self = @This();

    /// The center chunk being meshed
    center: *const Chunk,
    /// Adjacent chunks indexed by Direction (null if not loaded)
    /// Order: down, up, north, south, west, east
    neighbors: [6]?*const Chunk,

    pub fn init(center: *const Chunk) Self {
        return .{
            .center = center,
            .neighbors = [_]?*const Chunk{null} ** 6,
        };
    }

    /// Set a neighbor chunk
    pub fn setNeighbor(self: *Self, direction: Direction, neighbor: *const Chunk) void {
        self.neighbors[@intFromEnum(direction)] = neighbor;
    }

    /// Set all neighbors at once
    pub fn setNeighbors(
        self: *Self,
        down: ?*const Chunk,
        up: ?*const Chunk,
        north: ?*const Chunk,
        south: ?*const Chunk,
        west: ?*const Chunk,
        east: ?*const Chunk,
    ) void {
        self.neighbors[@intFromEnum(Direction.down)] = down;
        self.neighbors[@intFromEnum(Direction.up)] = up;
        self.neighbors[@intFromEnum(Direction.north)] = north;
        self.neighbors[@intFromEnum(Direction.south)] = south;
        self.neighbors[@intFromEnum(Direction.west)] = west;
        self.neighbors[@intFromEnum(Direction.east)] = east;
    }

    /// Get block entry at potentially cross-chunk coordinates
    /// Coordinates are relative to center chunk (can be negative or >= CHUNK_SIZE)
    pub fn getBlockEntry(self: *const Self, x: i32, y: i32, z: i32) BlockEntry {
        // Check if within center chunk
        if (x >= 0 and x < CHUNK_SIZE and
            y >= 0 and y < CHUNK_SIZE and
            z >= 0 and z < CHUNK_SIZE)
        {
            return self.center.getBlockEntry(@intCast(x), @intCast(y), @intCast(z));
        }

        // Determine which neighbor chunk and convert to local coordinates
        return self.getBlockEntryFromNeighbor(x, y, z);
    }

    /// Legacy: Get block type (ignores state)
    pub fn getBlock(self: *const Self, x: i32, y: i32, z: i32) BlockType {
        const entry = self.getBlockEntry(x, y, z);
        return @enumFromInt(entry.id);
    }

    fn getBlockEntryFromNeighbor(self: *const Self, x: i32, y: i32, z: i32) BlockEntry {
        // Y axis (down/up)
        if (y < 0) {
            if (self.neighbors[@intFromEnum(Direction.down)]) |chunk| {
                const local_y: u32 = @intCast(y + CHUNK_SIZE);
                if (x >= 0 and x < CHUNK_SIZE and z >= 0 and z < CHUNK_SIZE) {
                    return chunk.getBlockEntry(@intCast(x), local_y, @intCast(z));
                }
            }
            return BlockEntry.AIR;
        }
        if (y >= CHUNK_SIZE) {
            if (self.neighbors[@intFromEnum(Direction.up)]) |chunk| {
                const local_y: u32 = @intCast(y - CHUNK_SIZE);
                if (x >= 0 and x < CHUNK_SIZE and z >= 0 and z < CHUNK_SIZE) {
                    return chunk.getBlockEntry(@intCast(x), local_y, @intCast(z));
                }
            }
            return BlockEntry.AIR;
        }

        // Z axis (north/south)
        if (z < 0) {
            if (self.neighbors[@intFromEnum(Direction.north)]) |chunk| {
                const local_z: u32 = @intCast(z + CHUNK_SIZE);
                if (x >= 0 and x < CHUNK_SIZE and y >= 0 and y < CHUNK_SIZE) {
                    return chunk.getBlockEntry(@intCast(x), @intCast(y), local_z);
                }
            }
            return BlockEntry.AIR;
        }
        if (z >= CHUNK_SIZE) {
            if (self.neighbors[@intFromEnum(Direction.south)]) |chunk| {
                const local_z: u32 = @intCast(z - CHUNK_SIZE);
                if (x >= 0 and x < CHUNK_SIZE and y >= 0 and y < CHUNK_SIZE) {
                    return chunk.getBlockEntry(@intCast(x), @intCast(y), local_z);
                }
            }
            return BlockEntry.AIR;
        }

        // X axis (west/east)
        if (x < 0) {
            if (self.neighbors[@intFromEnum(Direction.west)]) |chunk| {
                const local_x: u32 = @intCast(x + CHUNK_SIZE);
                if (y >= 0 and y < CHUNK_SIZE and z >= 0 and z < CHUNK_SIZE) {
                    return chunk.getBlockEntry(local_x, @intCast(y), @intCast(z));
                }
            }
            return BlockEntry.AIR;
        }
        if (x >= CHUNK_SIZE) {
            if (self.neighbors[@intFromEnum(Direction.east)]) |chunk| {
                const local_x: u32 = @intCast(x - CHUNK_SIZE);
                if (y >= 0 and y < CHUNK_SIZE and z >= 0 and z < CHUNK_SIZE) {
                    return chunk.getBlockEntry(local_x, @intCast(y), @intCast(z));
                }
            }
            return BlockEntry.AIR;
        }

        // Shouldn't reach here if logic is correct
        return BlockEntry.AIR;
    }

    /// Check if a neighbor chunk is loaded for the given direction
    pub fn hasNeighbor(self: *const Self, direction: Direction) bool {
        return self.neighbors[@intFromEnum(direction)] != null;
    }

    /// Get the number of loaded neighbor chunks
    pub fn loadedNeighborCount(self: *const Self) u8 {
        var count: u8 = 0;
        for (self.neighbors) |n| {
            if (n != null) count += 1;
        }
        return count;
    }
};

// Tests
test "ChunkAccess basic operations" {
    var center = Chunk.init();
    center.setBlock(0, 0, 0, .stone);
    center.setBlock(15, 15, 15, .oak_slab);

    var access = ChunkAccess.init(&center);

    // Within center chunk
    try std.testing.expectEqual(BlockType.stone, access.getBlock(0, 0, 0));
    try std.testing.expectEqual(BlockType.oak_slab, access.getBlock(15, 15, 15));
    try std.testing.expectEqual(BlockType.air, access.getBlock(8, 8, 8));

    // Outside bounds without neighbors - returns air
    try std.testing.expectEqual(BlockType.air, access.getBlock(-1, 0, 0));
    try std.testing.expectEqual(BlockType.air, access.getBlock(16, 0, 0));
    try std.testing.expectEqual(BlockType.air, access.getBlock(0, -1, 0));
    try std.testing.expectEqual(BlockType.air, access.getBlock(0, 16, 0));
}

test "ChunkAccess with neighbors" {
    var center = Chunk.init();
    var west_chunk = Chunk.init();
    west_chunk.setBlock(15, 0, 0, .stone); // Block at east edge of west chunk

    var access = ChunkAccess.init(&center);
    access.setNeighbor(.west, &west_chunk);

    // Query position -1,0,0 should get block from west chunk at 15,0,0
    try std.testing.expectEqual(BlockType.stone, access.getBlock(-1, 0, 0));

    // Position -2,0,0 maps to west chunk 14,0,0 which is air
    try std.testing.expectEqual(BlockType.air, access.getBlock(-2, 0, 0));
}
