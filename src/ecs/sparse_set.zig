const std = @import("std");
const EntityId = @import("entity.zig").EntityId;

/// A sparse set for efficient component storage
/// Provides O(1) insert, remove, and lookup while maintaining dense iteration
pub fn SparseSet(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Sparse array: entity index -> dense index (or null)
        sparse: std.ArrayList(?u32),

        /// Dense array of components
        dense: std.ArrayList(T),

        /// Dense array of entity IDs (parallel to dense components)
        dense_ids: std.ArrayList(EntityId),

        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .sparse = .empty,
                .dense = .empty,
                .dense_ids = .empty,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.sparse.deinit(self.allocator);
            self.dense.deinit(self.allocator);
            self.dense_ids.deinit(self.allocator);
        }

        /// Ensure sparse array can hold the given entity index
        fn ensureSparseCapacity(self: *Self, index: u32) !void {
            const needed = index + 1;
            if (self.sparse.items.len < needed) {
                try self.sparse.appendNTimes(self.allocator, null, needed - self.sparse.items.len);
            }
        }

        /// Insert or update a component for an entity
        pub fn set(self: *Self, id: EntityId, component: T) !void {
            try self.ensureSparseCapacity(id.index);

            if (self.sparse.items[id.index]) |dense_idx| {
                // Update existing component
                self.dense.items[dense_idx] = component;
                self.dense_ids.items[dense_idx] = id;
            } else {
                // Insert new component
                const dense_idx: u32 = @intCast(self.dense.items.len);
                try self.dense.append(self.allocator, component);
                try self.dense_ids.append(self.allocator, id);
                self.sparse.items[id.index] = dense_idx;
            }
        }

        /// Get a component for an entity (returns null if not present)
        pub fn get(self: *const Self, id: EntityId) ?*const T {
            if (id.index >= self.sparse.items.len) {
                return null;
            }
            if (self.sparse.items[id.index]) |dense_idx| {
                // Verify generation matches
                if (self.dense_ids.items[dense_idx].eql(id)) {
                    return &self.dense.items[dense_idx];
                }
            }
            return null;
        }

        /// Get a mutable component for an entity
        pub fn getMut(self: *Self, id: EntityId) ?*T {
            if (id.index >= self.sparse.items.len) {
                return null;
            }
            if (self.sparse.items[id.index]) |dense_idx| {
                // Verify generation matches
                if (self.dense_ids.items[dense_idx].eql(id)) {
                    return &self.dense.items[dense_idx];
                }
            }
            return null;
        }

        /// Check if entity has this component
        pub fn contains(self: *const Self, id: EntityId) bool {
            return self.get(id) != null;
        }

        /// Remove a component from an entity
        /// Uses swap-remove to maintain dense array compactness
        pub fn remove(self: *Self, id: EntityId) bool {
            if (id.index >= self.sparse.items.len) {
                return false;
            }

            const maybe_dense_idx = self.sparse.items[id.index];
            if (maybe_dense_idx == null) {
                return false;
            }

            const dense_idx = maybe_dense_idx.?;

            // Verify generation
            if (!self.dense_ids.items[dense_idx].eql(id)) {
                return false;
            }

            // Clear sparse entry
            self.sparse.items[id.index] = null;

            // Swap-remove from dense arrays
            const last_idx = self.dense.items.len - 1;
            if (dense_idx != last_idx) {
                // Swap with last element
                self.dense.items[dense_idx] = self.dense.items[last_idx];
                self.dense_ids.items[dense_idx] = self.dense_ids.items[last_idx];

                // Update sparse entry for swapped entity
                const swapped_id = self.dense_ids.items[dense_idx];
                self.sparse.items[swapped_id.index] = dense_idx;
            }

            _ = self.dense.pop();
            _ = self.dense_ids.pop();

            return true;
        }

        /// Get the number of components stored
        pub fn count(self: *const Self) usize {
            return self.dense.items.len;
        }

        /// Get slice of all components (for dense iteration)
        pub fn components(self: *Self) []T {
            return self.dense.items;
        }

        /// Get slice of all components (const)
        pub fn componentsConst(self: *const Self) []const T {
            return self.dense.items;
        }

        /// Get slice of all entity IDs (parallel to components)
        pub fn entities(self: *const Self) []const EntityId {
            return self.dense_ids.items;
        }

        /// Iterator for iterating over (EntityId, *T) pairs
        pub const Iterator = struct {
            set: *Self,
            index: usize,

            pub fn next(self: *Iterator) ?struct { id: EntityId, component: *T } {
                if (self.index >= self.set.dense.items.len) {
                    return null;
                }
                const idx = self.index;
                self.index += 1;
                return .{
                    .id = self.set.dense_ids.items[idx],
                    .component = &self.set.dense.items[idx],
                };
            }
        };

        /// Get an iterator over all (EntityId, *T) pairs
        pub fn iterator(self: *Self) Iterator {
            return .{
                .set = self,
                .index = 0,
            };
        }

        /// Const iterator
        pub const ConstIterator = struct {
            set: *const Self,
            index: usize,

            pub fn next(self: *ConstIterator) ?struct { id: EntityId, component: *const T } {
                if (self.index >= self.set.dense.items.len) {
                    return null;
                }
                const idx = self.index;
                self.index += 1;
                return .{
                    .id = self.set.dense_ids.items[idx],
                    .component = &self.set.dense.items[idx],
                };
            }
        };

        pub fn constIterator(self: *const Self) ConstIterator {
            return .{
                .set = self,
                .index = 0,
            };
        }

        /// Clear all components
        pub fn clear(self: *Self) void {
            for (self.sparse.items) |*entry| {
                entry.* = null;
            }
            self.dense.clearRetainingCapacity();
            self.dense_ids.clearRetainingCapacity();
        }
    };
}

test "SparseSet basic operations" {
    const TestComponent = struct {
        value: i32,
    };

    var set = SparseSet(TestComponent).init(std.testing.allocator);
    defer set.deinit();

    const e1 = EntityId{ .index = 0, .generation = 0 };
    const e2 = EntityId{ .index = 5, .generation = 0 };
    const e3 = EntityId{ .index = 2, .generation = 0 };

    // Insert components
    try set.set(e1, .{ .value = 100 });
    try set.set(e2, .{ .value = 200 });
    try set.set(e3, .{ .value = 300 });

    try std.testing.expectEqual(@as(usize, 3), set.count());

    // Get components
    try std.testing.expectEqual(@as(i32, 100), set.get(e1).?.value);
    try std.testing.expectEqual(@as(i32, 200), set.get(e2).?.value);
    try std.testing.expectEqual(@as(i32, 300), set.get(e3).?.value);

    // Remove middle component
    try std.testing.expect(set.remove(e2));
    try std.testing.expectEqual(@as(usize, 2), set.count());
    try std.testing.expect(set.get(e2) == null);

    // Other components still accessible
    try std.testing.expectEqual(@as(i32, 100), set.get(e1).?.value);
    try std.testing.expectEqual(@as(i32, 300), set.get(e3).?.value);
}

test "SparseSet generation validation" {
    const TestComponent = struct { value: i32 };

    var set = SparseSet(TestComponent).init(std.testing.allocator);
    defer set.deinit();

    const e1_gen0 = EntityId{ .index = 0, .generation = 0 };
    const e1_gen1 = EntityId{ .index = 0, .generation = 1 };

    // Insert with generation 0
    try set.set(e1_gen0, .{ .value = 100 });
    try std.testing.expectEqual(@as(i32, 100), set.get(e1_gen0).?.value);

    // Query with wrong generation should fail
    try std.testing.expect(set.get(e1_gen1) == null);

    // Update to generation 1
    try set.set(e1_gen1, .{ .value = 200 });
    try std.testing.expectEqual(@as(i32, 200), set.get(e1_gen1).?.value);

    // Old generation should now fail
    try std.testing.expect(set.get(e1_gen0) == null);
}

test "SparseSet iteration" {
    const TestComponent = struct { value: i32 };

    var set = SparseSet(TestComponent).init(std.testing.allocator);
    defer set.deinit();

    try set.set(EntityId{ .index = 0, .generation = 0 }, .{ .value = 1 });
    try set.set(EntityId{ .index = 5, .generation = 0 }, .{ .value = 2 });
    try set.set(EntityId{ .index = 2, .generation = 0 }, .{ .value = 3 });

    var sum: i32 = 0;
    var iter = set.iterator();
    while (iter.next()) |entry| {
        sum += entry.component.value;
    }

    try std.testing.expectEqual(@as(i32, 6), sum);
}
