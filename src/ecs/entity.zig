const std = @import("std");

/// Generational entity identifier
/// Uses index + generation to prevent ABA problems with recycled IDs
pub const EntityId = packed struct {
    index: u32,
    generation: u32,

    pub const INVALID = EntityId{ .index = std.math.maxInt(u32), .generation = 0 };

    pub fn isValid(self: EntityId) bool {
        return self.index != std.math.maxInt(u32);
    }

    pub fn eql(self: EntityId, other: EntityId) bool {
        return self.index == other.index and self.generation == other.generation;
    }

    pub fn toU64(self: EntityId) u64 {
        return @as(u64, self.generation) << 32 | @as(u64, self.index);
    }

    pub fn fromU64(value: u64) EntityId {
        return .{
            .index = @truncate(value),
            .generation = @truncate(value >> 32),
        };
    }
};

/// Entry in the entity storage tracking generation and alive status
const EntityEntry = struct {
    generation: u32,
    alive: bool,
};

/// Manages entity IDs with generational indices
/// Supports entity creation, destruction, and ID validation
pub const EntityStorage = struct {
    const Self = @This();

    entries: std.ArrayList(EntityEntry),
    free_indices: std.ArrayList(u32),
    alive_count: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .entries = .empty,
            .free_indices = .empty,
            .alive_count = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.entries.deinit(self.allocator);
        self.free_indices.deinit(self.allocator);
    }

    /// Create a new entity and return its ID
    pub fn create(self: *Self) !EntityId {
        if (self.free_indices.items.len > 0) {
            // Reuse a freed index
            const index = self.free_indices.getLast();
            self.free_indices.shrinkRetainingCapacity(self.free_indices.items.len - 1);
            const entry = &self.entries.items[index];
            entry.alive = true;
            self.alive_count += 1;
            return .{
                .index = index,
                .generation = entry.generation,
            };
        } else {
            // Allocate a new index
            const index: u32 = @intCast(self.entries.items.len);
            try self.entries.append(self.allocator, .{
                .generation = 0,
                .alive = true,
            });
            self.alive_count += 1;
            return .{
                .index = index,
                .generation = 0,
            };
        }
    }

    /// Destroy an entity, making its ID invalid
    /// The index will be recycled with an incremented generation
    pub fn destroy(self: *Self, id: EntityId) bool {
        if (!self.isValid(id)) {
            return false;
        }

        const entry = &self.entries.items[id.index];
        entry.alive = false;
        entry.generation +%= 1; // Wrap on overflow

        self.free_indices.append(self.allocator, id.index) catch {
            // If we can't track the free index, it's lost forever
            // This is a memory leak but not a correctness issue
        };

        self.alive_count -= 1;
        return true;
    }

    /// Check if an entity ID is currently valid (exists and alive)
    pub fn isValid(self: *const Self, id: EntityId) bool {
        if (id.index >= self.entries.items.len) {
            return false;
        }
        const entry = self.entries.items[id.index];
        return entry.alive and entry.generation == id.generation;
    }

    /// Get the number of alive entities
    pub fn count(self: *const Self) u32 {
        return self.alive_count;
    }

    /// Iterator over all alive entity IDs
    pub const Iterator = struct {
        storage: *const EntityStorage,
        current_index: u32,

        pub fn next(self: *Iterator) ?EntityId {
            while (self.current_index < self.storage.entries.items.len) {
                const index = self.current_index;
                self.current_index += 1;

                const entry = self.storage.entries.items[index];
                if (entry.alive) {
                    return .{
                        .index = index,
                        .generation = entry.generation,
                    };
                }
            }
            return null;
        }
    };

    /// Get an iterator over all alive entities
    pub fn iterator(self: *const Self) Iterator {
        return .{
            .storage = self,
            .current_index = 0,
        };
    }
};

test "EntityStorage basic operations" {
    var storage = EntityStorage.init(std.testing.allocator);
    defer storage.deinit();

    // Create entities
    const e1 = try storage.create();
    const e2 = try storage.create();
    const e3 = try storage.create();

    try std.testing.expect(storage.isValid(e1));
    try std.testing.expect(storage.isValid(e2));
    try std.testing.expect(storage.isValid(e3));
    try std.testing.expectEqual(@as(u32, 3), storage.count());

    // Destroy entity
    try std.testing.expect(storage.destroy(e2));
    try std.testing.expect(!storage.isValid(e2));
    try std.testing.expectEqual(@as(u32, 2), storage.count());

    // Create new entity - should reuse index but with new generation
    const e4 = try storage.create();
    try std.testing.expectEqual(e2.index, e4.index);
    try std.testing.expect(e4.generation > e2.generation);
    try std.testing.expect(!storage.isValid(e2)); // Old ID still invalid
    try std.testing.expect(storage.isValid(e4)); // New ID valid
}

test "EntityId packing" {
    const id = EntityId{ .index = 12345, .generation = 67890 };
    const packed_value = id.toU64();
    const unpacked = EntityId.fromU64(packed_value);

    try std.testing.expectEqual(id.index, unpacked.index);
    try std.testing.expectEqual(id.generation, unpacked.generation);
}
