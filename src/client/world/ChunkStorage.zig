/// ChunkStorage - Ring buffer-based chunk storage following Minecraft's ClientChunkCache.Storage pattern
/// Uses 3D floor modulo indexing for O(1) guaranteed access with no hash collisions
const std = @import("std");
const shared = @import("Shared");
const ChunkPos = shared.ChunkPos;

const render_chunk = @import("RenderChunk.zig");
const RenderChunk = render_chunk.RenderChunk;

/// Ring buffer storage for loaded chunks
/// Fixed-size array with direct indexing - no hash collisions, no resizing
pub const ChunkStorage = struct {
    const Self = @This();

    /// Fixed-size array of chunk slots
    /// Each slot contains either null (empty) or a chunk pointer
    chunks: []?*RenderChunk,

    /// Horizontal size (unload_distance * 2 + 1)
    horizontal_size: u32,

    /// Vertical size (vertical_view_distance * 2 + 1)
    vertical_size: u32,

    /// Total capacity (horizontal_size^2 * vertical_size)
    capacity: usize,

    /// Current number of occupied slots
    count: usize,

    /// Allocator for the chunks array
    allocator: std.mem.Allocator,

    /// Initialize the chunk storage with pre-allocated fixed-size array
    pub fn init(allocator: std.mem.Allocator, unload_distance: u8, vertical_view_distance: u8) !Self {
        const h_size: u32 = @as(u32, unload_distance) * 2 + 1;
        const v_size: u32 = @as(u32, vertical_view_distance) * 2 + 1;
        const cap = @as(usize, h_size) * h_size * v_size;

        const chunks = try allocator.alloc(?*RenderChunk, cap);
        @memset(chunks, null);

        return Self{
            .chunks = chunks,
            .horizontal_size = h_size,
            .vertical_size = v_size,
            .capacity = cap,
            .count = 0,
            .allocator = allocator,
        };
    }

    /// Clean up the chunks array (does not free the chunks themselves)
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.chunks);
        self.chunks = &.{};
        self.count = 0;
    }

    /// Floor modulo that handles negative numbers correctly
    /// Unlike Zig's @mod which is remainder, this gives true mathematical floor mod
    inline fn floorMod(value: i32, divisor: u32) u32 {
        const d: i32 = @intCast(divisor);
        // This handles negative values correctly:
        // floorMod(-1, 13) = 12, not -1
        const result = @mod(value, d);
        return @intCast(result);
    }

    /// Calculate array index from chunk position using 3D floor modulo
    inline fn getIndex(self: *const Self, pos: ChunkPos) usize {
        const x = floorMod(pos.x, self.horizontal_size);
        const z = floorMod(pos.z, self.horizontal_size);
        const y = floorMod(pos.section_y, self.vertical_size);

        // 3D index: y * h_size * h_size + z * h_size + x
        return @as(usize, y) * self.horizontal_size * self.horizontal_size +
            @as(usize, z) * self.horizontal_size +
            @as(usize, x);
    }

    /// Get a chunk at the given position
    /// Returns null if the slot is empty OR if the stored chunk's position doesn't match
    /// (position mismatch happens when player moves far and index wraps)
    pub fn get(self: *const Self, pos: ChunkPos) ?*RenderChunk {
        const index = self.getIndex(pos);
        const chunk = self.chunks[index] orelse return null;

        // CRITICAL: Validate that the stored chunk's position matches the requested position
        // When the player moves far, the same index can map to a different world position
        if (!chunk.pos.eql(pos)) {
            return null;
        }

        return chunk;
    }

    /// Check if a chunk exists at the given position
    pub fn contains(self: *const Self, pos: ChunkPos) bool {
        return self.get(pos) != null;
    }

    /// Store a chunk at the given position
    /// Returns the previous occupant if the slot was occupied (for cleanup)
    /// The caller is responsible for freeing the returned chunk if not null
    pub fn put(self: *Self, pos: ChunkPos, chunk: *RenderChunk) !?*RenderChunk {
        const index = self.getIndex(pos);
        const previous = self.chunks[index];

        self.chunks[index] = chunk;

        // Update count
        if (previous == null) {
            self.count += 1;
        }

        return previous;
    }

    /// Remove a chunk at the given position
    /// Returns the removed chunk (for cleanup) or null if not found
    pub fn remove(self: *Self, pos: ChunkPos) ?*RenderChunk {
        const index = self.getIndex(pos);
        const chunk = self.chunks[index] orelse return null;

        // Validate position matches before removing
        if (!chunk.pos.eql(pos)) {
            return null;
        }

        self.chunks[index] = null;
        self.count -= 1;

        return chunk;
    }

    /// Iterator over all non-null chunks
    pub const Iterator = struct {
        storage: *const Self,
        index: usize,

        pub const Entry = struct {
            key_ptr: *const ChunkPos,
            value_ptr: *const *RenderChunk,
        };

        pub fn next(self: *Iterator) ?Entry {
            while (self.index < self.storage.capacity) {
                const i = self.index;
                self.index += 1;

                if (self.storage.chunks[i]) |_| {
                    // Return pointers to the chunk's position and the slot
                    const chunk_ptr = &self.storage.chunks[i];
                    const chunk = chunk_ptr.*.?;
                    return Entry{
                        .key_ptr = &chunk.pos,
                        .value_ptr = @ptrCast(chunk_ptr),
                    };
                }
            }
            return null;
        }
    };

    /// Get an iterator over all stored chunks
    pub fn iterator(self: *const Self) Iterator {
        return Iterator{
            .storage = self,
            .index = 0,
        };
    }
};

test "ChunkStorage basic operations" {
    const allocator = std.testing.allocator;

    var storage = try ChunkStorage.init(allocator, 6, 4);
    defer storage.deinit();

    // Test capacity
    try std.testing.expectEqual(@as(usize, 13 * 13 * 9), storage.capacity);
    try std.testing.expectEqual(@as(usize, 0), storage.count);
}

test "ChunkStorage floor modulo" {
    // Test that floor mod handles negative numbers correctly
    try std.testing.expectEqual(@as(u32, 12), ChunkStorage.floorMod(-1, 13));
    try std.testing.expectEqual(@as(u32, 0), ChunkStorage.floorMod(0, 13));
    try std.testing.expectEqual(@as(u32, 1), ChunkStorage.floorMod(1, 13));
    try std.testing.expectEqual(@as(u32, 0), ChunkStorage.floorMod(13, 13));
    try std.testing.expectEqual(@as(u32, 1), ChunkStorage.floorMod(14, 13));
    try std.testing.expectEqual(@as(u32, 11), ChunkStorage.floorMod(-2, 13));
}
