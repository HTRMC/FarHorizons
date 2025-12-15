/// Chunk position in world coordinates
/// Each chunk section is 16x16x16 blocks
const std = @import("std");

pub const CHUNK_SIZE: i32 = 16;

/// Represents the position of a chunk section in the world
pub const ChunkPos = struct {
    x: i32,
    z: i32,
    section_y: i32,

    const Self = @This();

    /// Create a ChunkPos from block coordinates
    pub fn fromBlockPos(block_x: i32, block_y: i32, block_z: i32) Self {
        return .{
            .x = @divFloor(block_x, CHUNK_SIZE),
            .z = @divFloor(block_z, CHUNK_SIZE),
            .section_y = @divFloor(block_y, CHUNK_SIZE),
        };
    }

    /// Create a ChunkPos from floating point world coordinates
    pub fn fromWorldPos(world_x: f32, world_y: f32, world_z: f32) Self {
        return fromBlockPos(
            @intFromFloat(@floor(world_x)),
            @intFromFloat(@floor(world_y)),
            @intFromFloat(@floor(world_z)),
        );
    }

    /// Get the minimum block coordinates for this chunk section
    pub fn getBlockPos(self: Self) struct { x: i32, y: i32, z: i32 } {
        return .{
            .x = self.x * CHUNK_SIZE,
            .y = self.section_y * CHUNK_SIZE,
            .z = self.z * CHUNK_SIZE,
        };
    }

    /// Get center position of this chunk section in world coordinates
    pub fn getCenterPos(self: Self) struct { x: f32, y: f32, z: f32 } {
        const block_pos = self.getBlockPos();
        const half: f32 = @as(f32, CHUNK_SIZE) / 2.0;
        return .{
            .x = @as(f32, @floatFromInt(block_pos.x)) + half,
            .y = @as(f32, @floatFromInt(block_pos.y)) + half,
            .z = @as(f32, @floatFromInt(block_pos.z)) + half,
        };
    }

    /// Compute squared distance to another ChunkPos (for comparison without sqrt)
    pub fn distanceSq(self: Self, other: Self) i64 {
        const dx: i64 = @as(i64, self.x) - @as(i64, other.x);
        const dy: i64 = @as(i64, self.section_y) - @as(i64, other.section_y);
        const dz: i64 = @as(i64, self.z) - @as(i64, other.z);
        return dx * dx + dy * dy + dz * dz;
    }

    /// Compute horizontal squared distance (ignores Y, useful for view distance)
    pub fn horizontalDistanceSq(self: Self, other: Self) i64 {
        const dx: i64 = @as(i64, self.x) - @as(i64, other.x);
        const dz: i64 = @as(i64, self.z) - @as(i64, other.z);
        return dx * dx + dz * dz;
    }

    /// Check if this chunk is within horizontal view distance of another
    pub fn isWithinDistance(self: Self, center: Self, distance: u8) bool {
        const dist_sq = self.horizontalDistanceSq(center);
        const max_dist: i64 = @intCast(distance);
        return dist_sq <= max_dist * max_dist;
    }

    /// Hash function for use in HashMaps
    pub fn hash(self: Self) u64 {
        // Combine coordinates into a single hash
        // Using FNV-1a style mixing
        var h: u64 = 14695981039346656037;
        h ^= @as(u64, @bitCast(@as(i64, self.x)));
        h *%= 1099511628211;
        h ^= @as(u64, @bitCast(@as(i64, self.section_y)));
        h *%= 1099511628211;
        h ^= @as(u64, @bitCast(@as(i64, self.z)));
        h *%= 1099511628211;
        return h;
    }

    /// Equality check
    pub fn eql(self: Self, other: Self) bool {
        return self.x == other.x and self.section_y == other.section_y and self.z == other.z;
    }

    /// Get neighbor in specified direction (0-5: -Y, +Y, -Z, +Z, -X, +X)
    pub fn getNeighbor(self: Self, direction: u3) Self {
        const offsets = [6][3]i32{
            .{ 0, -1, 0 }, // down
            .{ 0, 1, 0 }, // up
            .{ 0, 0, -1 }, // north
            .{ 0, 0, 1 }, // south
            .{ -1, 0, 0 }, // west
            .{ 1, 0, 0 }, // east
        };
        const off = offsets[direction];
        return .{
            .x = self.x + off[2],
            .section_y = self.section_y + off[1],
            .z = self.z + off[0],
        };
    }

    /// Get all 6 neighbor positions
    pub fn getNeighbors(self: Self) [6]Self {
        return .{
            self.getNeighbor(0),
            self.getNeighbor(1),
            self.getNeighbor(2),
            self.getNeighbor(3),
            self.getNeighbor(4),
            self.getNeighbor(5),
        };
    }

    /// Format for debug output
    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("ChunkPos({}, {}, {})", .{ self.x, self.section_y, self.z });
    }
};

/// Context for using ChunkPos in std.HashMap
pub const ChunkPosContext = struct {
    pub fn hash(_: ChunkPosContext, pos: ChunkPos) u64 {
        return pos.hash();
    }

    pub fn eql(_: ChunkPosContext, a: ChunkPos, b: ChunkPos) bool {
        return a.eql(b);
    }
};

test "ChunkPos.fromBlockPos" {
    const pos = ChunkPos.fromBlockPos(17, 32, -5);
    try std.testing.expectEqual(@as(i32, 1), pos.x);
    try std.testing.expectEqual(@as(i32, 2), pos.section_y);
    try std.testing.expectEqual(@as(i32, -1), pos.z);
}

test "ChunkPos.fromWorldPos" {
    const pos = ChunkPos.fromWorldPos(8.5, 20.0, -0.1);
    try std.testing.expectEqual(@as(i32, 0), pos.x);
    try std.testing.expectEqual(@as(i32, 1), pos.section_y);
    try std.testing.expectEqual(@as(i32, -1), pos.z);
}

test "ChunkPos.distanceSq" {
    const a = ChunkPos{ .x = 0, .section_y = 0, .z = 0 };
    const b = ChunkPos{ .x = 3, .section_y = 0, .z = 4 };
    try std.testing.expectEqual(@as(i64, 25), a.distanceSq(b));
}

test "ChunkPos.isWithinDistance" {
    const center = ChunkPos{ .x = 0, .section_y = 0, .z = 0 };
    const near = ChunkPos{ .x = 2, .section_y = 0, .z = 2 };
    const far = ChunkPos{ .x = 10, .section_y = 0, .z = 10 };

    try std.testing.expect(near.isWithinDistance(center, 4));
    try std.testing.expect(!far.isWithinDistance(center, 4));
}
