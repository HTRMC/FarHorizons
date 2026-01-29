/// AllocationArena - Tracks free/used regions within a buffer
/// Uses a sorted free list for O(log n) best-fit allocation
const std = @import("std");
const shared = @import("Shared");
const Logger = shared.Logger;

/// Represents an allocated or free region
pub const Region = struct {
    offset: u64,
    size: u64,

    pub fn end(self: Region) u64 {
        return self.offset + self.size;
    }

    /// Merge two adjacent regions
    pub fn merge(self: Region, other: Region) Region {
        const min_offset = @min(self.offset, other.offset);
        const max_end = @max(self.end(), other.end());
        return .{
            .offset = min_offset,
            .size = max_end - min_offset,
        };
    }
};

/// Result of an allocation
pub const Allocation = struct {
    offset: u64,
    size: u64,
};

/// Arena allocator for sub-allocating within a buffer
pub const AllocationArena = struct {
    const Self = @This();
    const logger = Logger.scoped(Self);

    /// Free regions sorted by offset
    free_list: std.ArrayListUnmanaged(Region),
    /// Total capacity of the arena
    capacity: u64,
    /// Currently allocated bytes
    used: u64,
    /// Minimum alignment for allocations
    alignment: u64,
    /// Allocator for internal data structures
    allocator: std.mem.Allocator,

    /// Initialize an arena with the given capacity
    pub fn init(allocator: std.mem.Allocator, capacity: u64, alignment: u64) !Self {
        var arena = Self{
            .free_list = .{},
            .capacity = capacity,
            .used = 0,
            .alignment = if (alignment == 0) 1 else alignment,
            .allocator = allocator,
        };

        // Start with entire capacity as free
        try arena.free_list.append(allocator, .{ .offset = 0, .size = capacity });

        return arena;
    }

    pub fn deinit(self: *Self) void {
        self.free_list.deinit(self.allocator);
    }

    /// Allocate a region of the given size
    /// Returns null if no suitable region is found
    pub fn alloc(self: *Self, size: u64) ?Allocation {
        if (size == 0) return null;

        // Align size up
        const aligned_size = alignUp(size, self.alignment);

        // Find best-fit free region (smallest region that fits)
        var best_idx: ?usize = null;
        var best_waste: u64 = std.math.maxInt(u64);

        for (self.free_list.items, 0..) |region, i| {
            const aligned_offset = alignUp(region.offset, self.alignment);
            const padding = aligned_offset - region.offset;
            const total_needed = padding + aligned_size;

            if (region.size >= total_needed) {
                const waste = region.size - total_needed;
                if (waste < best_waste) {
                    best_idx = i;
                    best_waste = waste;
                    if (waste == 0) break; // Perfect fit
                }
            }
        }

        const idx = best_idx orelse return null;
        const region = self.free_list.items[idx];
        const aligned_offset = alignUp(region.offset, self.alignment);
        const padding = aligned_offset - region.offset;
        const total_needed = padding + aligned_size;

        // Remove or shrink the free region
        if (region.size == total_needed) {
            // Exact fit - remove the region
            _ = self.free_list.orderedRemove(idx);
        } else {
            // Shrink the region (move start forward)
            self.free_list.items[idx] = .{
                .offset = aligned_offset + aligned_size,
                .size = region.size - total_needed,
            };

            // If there was padding, add it back as a free region
            if (padding > 0) {
                self.insertFreeRegion(.{ .offset = region.offset, .size = padding });
            }
        }

        self.used += aligned_size;

        return Allocation{
            .offset = aligned_offset,
            .size = aligned_size,
        };
    }

    /// Free a previously allocated region
    pub fn free(self: *Self, allocation: Allocation) void {
        if (allocation.size == 0) return;

        const region = Region{
            .offset = allocation.offset,
            .size = allocation.size,
        };

        self.used -= @min(allocation.size, self.used);
        self.insertFreeRegion(region);
    }

    /// Insert a free region and merge with adjacent regions
    fn insertFreeRegion(self: *Self, new_region: Region) void {
        // Find insertion point (sorted by offset)
        var insert_idx: usize = 0;
        for (self.free_list.items, 0..) |region, i| {
            if (region.offset > new_region.offset) {
                insert_idx = i;
                break;
            }
            insert_idx = i + 1;
        }

        // Check for merge with previous region
        var merged = new_region;
        if (insert_idx > 0) {
            const prev = self.free_list.items[insert_idx - 1];
            if (prev.end() == merged.offset) {
                merged = prev.merge(merged);
                _ = self.free_list.orderedRemove(insert_idx - 1);
                insert_idx -= 1;
            }
        }

        // Check for merge with next region
        if (insert_idx < self.free_list.items.len) {
            const next = self.free_list.items[insert_idx];
            if (merged.end() == next.offset) {
                merged = merged.merge(next);
                _ = self.free_list.orderedRemove(insert_idx);
            }
        }

        // Insert the (possibly merged) region
        self.free_list.insert(self.allocator, insert_idx, merged) catch {
            logger.err("Failed to insert free region", .{});
        };
    }

    /// Get current usage statistics
    pub fn getStats(self: *const Self) struct { used: u64, free: u64, capacity: u64, fragments: usize } {
        return .{
            .used = self.used,
            .free = self.capacity - self.used,
            .capacity = self.capacity,
            .fragments = self.free_list.items.len,
        };
    }

    /// Check if the arena can fit an allocation of the given size
    pub fn canFit(self: *const Self, size: u64) bool {
        const aligned_size = alignUp(size, self.alignment);
        for (self.free_list.items) |region| {
            const aligned_offset = alignUp(region.offset, self.alignment);
            const padding = aligned_offset - region.offset;
            if (region.size >= padding + aligned_size) {
                return true;
            }
        }
        return false;
    }

    /// Reset the arena to initial state (all free)
    pub fn reset(self: *Self) void {
        self.free_list.clearRetainingCapacity();
        // Should not fail - we just cleared and are using retained capacity
        self.free_list.append(self.allocator, .{ .offset = 0, .size = self.capacity }) catch |err| {
            logger.err("Arena reset failed: {} - arena may be corrupted", .{err});
        };
        self.used = 0;
    }

    fn alignUp(value: u64, alignment: u64) u64 {
        // Use division for non-power-of-2 alignments (e.g., LCM of vertex size and Vulkan alignment)
        return ((value + alignment - 1) / alignment) * alignment;
    }
};
