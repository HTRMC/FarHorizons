/// OcclusionCache - LRU cache for face occlusion results
///
/// Caches the results of face occlusion tests to avoid repeated
/// expensive shape comparisons. Uses a simple hash-indexed array
/// with LRU-like eviction.
const std = @import("std");
const voxel_shape = @import("VoxelShape.zig");
const VoxelShape = voxel_shape.VoxelShape;
const Direction = voxel_shape.Direction;
const shapes = @import("Shapes.zig");

/// Cache size (number of entries)
pub const CACHE_SIZE: usize = 256;

/// Cache key combining block shape pair and direction
pub const CacheKey = packed struct {
    /// Hash of first shape
    shape1_hash: u16,
    /// Hash of second shape
    shape2_hash: u16,
    /// Direction being tested
    direction: u3,
    /// Padding
    _padding: u5 = 0,

    pub fn init(shape1: *const VoxelShape, shape2: *const VoxelShape, direction: Direction) CacheKey {
        return .{
            .shape1_hash = hashShape(shape1),
            .shape2_hash = hashShape(shape2),
            .direction = @intFromEnum(direction),
        };
    }

    fn hashShape(shape: *const VoxelShape) u16 {
        // Simple hash based on shape type and bounds
        var h: u32 = 0;

        // Mix in shape type
        h = switch (shape.*) {
            .empty => 0,
            .block => 0xFFFF,
            .cube => |*c| blk: {
                var hash: u32 = c.shape.base.x_size;
                hash = hash *% 31 +% c.shape.base.y_size;
                hash = hash *% 31 +% c.shape.base.z_size;
                hash = hash *% 31 +% c.shape.base.x_min;
                hash = hash *% 31 +% c.shape.base.y_min;
                hash = hash *% 31 +% c.shape.base.z_min;
                break :blk hash;
            },
            .array => |*a| blk: {
                var hash: u32 = a.shape.base.x_size;
                hash = hash *% 31 +% a.shape.base.y_size;
                hash = hash *% 31 +% a.shape.base.z_size;
                break :blk hash;
            },
        };

        return @truncate(h);
    }
};

/// Cache entry
pub const CacheEntry = struct {
    key: CacheKey,
    /// Cached result: true = should cull (not render), false = should render
    should_cull: bool,
    /// Access counter for LRU
    last_access: u32,
    /// Whether this entry is valid
    valid: bool,
};

/// Thread-local occlusion cache
/// Note: In Zig, we use a simple global for single-threaded use
/// For multi-threaded use, this should be wrapped in ThreadLocal
pub const OcclusionCache = struct {
    const Self = @This();

    entries: [CACHE_SIZE]CacheEntry,
    access_counter: u32,
    hits: u64,
    misses: u64,

    pub fn init() Self {
        var self = Self{
            .entries = undefined,
            .access_counter = 0,
            .hits = 0,
            .misses = 0,
        };

        for (&self.entries) |*entry| {
            entry.valid = false;
            entry.last_access = 0;
        }

        return self;
    }

    /// Look up cached occlusion result
    /// Returns null if not cached
    pub fn get(self: *Self, key: CacheKey) ?bool {
        const index = self.getIndex(key);
        const entry = &self.entries[index];

        if (entry.valid and std.meta.eql(entry.key, key)) {
            self.access_counter += 1;
            entry.last_access = self.access_counter;
            self.hits += 1;
            return entry.should_cull;
        }

        self.misses += 1;
        return null;
    }

    /// Store occlusion result in cache
    pub fn put(self: *Self, key: CacheKey, should_cull: bool) void {
        const index = self.getIndex(key);
        self.access_counter += 1;

        self.entries[index] = .{
            .key = key,
            .should_cull = should_cull,
            .last_access = self.access_counter,
            .valid = true,
        };
    }

    /// Get or compute occlusion result
    pub fn getOrCompute(
        self: *Self,
        shape1: *const VoxelShape,
        shape2: *const VoxelShape,
        direction: Direction,
    ) bool {
        const key = CacheKey.init(shape1, shape2, direction);

        // Try cache first
        if (self.get(key)) |cached| {
            return cached;
        }

        // Compute result
        const should_cull = shape1.faceOccludedBy(direction, shape2);

        // Cache it
        self.put(key, should_cull);

        return should_cull;
    }

    /// Check if face should be rendered (convenience method)
    pub fn shouldRenderFace(
        self: *Self,
        block_shape: *const VoxelShape,
        neighbor_shape: *const VoxelShape,
        direction: Direction,
    ) bool {
        return !self.getOrCompute(block_shape, neighbor_shape, direction);
    }

    fn getIndex(self: *const Self, key: CacheKey) usize {
        _ = self;
        const raw: u40 = @bitCast(key);
        return raw % CACHE_SIZE;
    }

    /// Get cache statistics
    pub fn getStats(self: *const Self) CacheStats {
        const total = self.hits + self.misses;
        return .{
            .hits = self.hits,
            .misses = self.misses,
            .hit_rate = if (total > 0) @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total)) else 0.0,
        };
    }

    /// Clear the cache
    pub fn clear(self: *Self) void {
        for (&self.entries) |*entry| {
            entry.valid = false;
        }
        self.hits = 0;
        self.misses = 0;
    }
};

pub const CacheStats = struct {
    hits: u64,
    misses: u64,
    hit_rate: f64,
};

/// Global occlusion cache instance
/// For multi-threaded use, wrap in ThreadLocal or use per-thread instances
var global_cache: ?OcclusionCache = null;

/// Get the global cache, initializing if needed
pub fn getGlobalCache() *OcclusionCache {
    if (global_cache == null) {
        global_cache = OcclusionCache.init();
    }
    return &global_cache.?;
}

/// Convenience function: check if face should render using global cache
pub fn shouldRenderFace(
    block_shape: *const VoxelShape,
    neighbor_shape: *const VoxelShape,
    direction: Direction,
) bool {
    return getGlobalCache().shouldRenderFace(block_shape, neighbor_shape, direction);
}

// Tests
test "OcclusionCache basic operations" {
    var cache = OcclusionCache.init();

    const block_shape = shapes.Shapes.BLOCK;
    const empty_shape = shapes.Shapes.EMPTY;

    // First lookup should be a miss and compute
    const result1 = cache.shouldRenderFace(&block_shape, &empty_shape, .north);
    try std.testing.expect(result1); // Block next to air: should render

    // Check stats
    var stats = cache.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.hits);
    try std.testing.expectEqual(@as(u64, 1), stats.misses);

    // Second lookup should be a hit
    const result2 = cache.shouldRenderFace(&block_shape, &empty_shape, .north);
    try std.testing.expect(result2);

    stats = cache.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.hits);
    try std.testing.expectEqual(@as(u64, 1), stats.misses);
}

test "OcclusionCache block-to-block" {
    var cache = OcclusionCache.init();

    const block_shape = shapes.Shapes.BLOCK;

    // Block next to block: should NOT render (fully occluded)
    const result = cache.shouldRenderFace(&block_shape, &block_shape, .north);
    try std.testing.expect(!result);
}
