/// GrowableBufferArena - Dynamic buffer pool with pre-allocation and async expansion
/// Designed for AAA-quality smooth frame times with zero runtime stalls.
///
/// Features:
/// - Pre-allocates arenas at startup based on expected usage
/// - Async background expansion when capacity threshold reached
/// - Batched rendering support (groups draw calls by buffer)
const std = @import("std");
const Io = std.Io;
const volk = @import("volk");
const vk = volk.c;
const shared = @import("Shared");
const Logger = shared.Logger;

const buffer_arena_mod = @import("BufferArena.zig");
const BufferArena = buffer_arena_mod.BufferArena;
const BufferSlice = buffer_arena_mod.BufferSlice;

/// Extended buffer slice that tracks which arena it belongs to
pub const ExtendedBufferSlice = struct {
    /// Offset into the buffer
    offset: u64,
    /// Size of the allocation
    size: u64,
    /// For vertex buffers: number of vertices
    /// For index buffers: number of indices
    count: u32,
    /// Which arena this slice belongs to
    arena_index: u16,

    pub const INVALID = ExtendedBufferSlice{
        .offset = 0,
        .size = 0,
        .count = 0,
        .arena_index = 0xFFFF,
    };

    pub fn isValid(self: ExtendedBufferSlice) bool {
        return self.arena_index != 0xFFFF;
    }
};

/// Configuration for the growable buffer arena
pub const GrowableBufferConfig = struct {
    /// Size of each individual arena (default 256 MB)
    arena_size: u64 = 256 * 1024 * 1024,
    /// Number of arenas to pre-allocate at startup
    initial_arena_count: u16 = 1,
    /// Maximum number of arenas (0 = unlimited)
    max_arena_count: u16 = 0,
    /// Capacity threshold (0-100) to trigger async expansion
    expansion_threshold_percent: u8 = 75,
    /// Buffer usage flags
    usage: vk.VkBufferUsageFlags = vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
    /// Alignment requirement for allocations
    alignment: u64 = 16,
};

/// Growable buffer arena with async expansion
pub const GrowableBufferArena = struct {
    const Self = @This();
    const logger = Logger.scoped(Self);

    /// List of buffer arenas
    arenas: std.ArrayListUnmanaged(BufferArena),

    /// Async expansion state
    expansion_thread: ?std.Thread = null,
    pending_arena: ?BufferArena = null,
    expansion_mutex: Io.Mutex = Io.Mutex.init,
    expansion_failed: bool = false,

    /// I/O subsystem (needed for mutex operations)
    io: Io,

    /// Vulkan handles needed for creating new arenas
    device: vk.VkDevice,
    physical_device: vk.VkPhysicalDevice,

    /// Configuration
    config: GrowableBufferConfig,

    /// Allocator
    allocator: std.mem.Allocator,

    /// Statistics
    total_allocations: u64 = 0,
    total_frees: u64 = 0,
    expansion_count: u16 = 0,

    /// Initialize with pre-allocated arenas
    pub fn init(
        allocator: std.mem.Allocator,
        device: vk.VkDevice,
        physical_device: vk.VkPhysicalDevice,
        config: GrowableBufferConfig,
        io: Io,
    ) !Self {
        var self = Self{
            .arenas = .{},
            .device = device,
            .physical_device = physical_device,
            .config = config,
            .allocator = allocator,
            .io = io,
        };

        // Pre-allocate initial arenas
        const initial_count = if (config.initial_arena_count == 0) 1 else config.initial_arena_count;
        logger.info("Pre-allocating {} buffer arenas ({} MB each)", .{
            initial_count,
            config.arena_size / (1024 * 1024),
        });

        for (0..initial_count) |i| {
            const arena = try BufferArena.init(
                allocator,
                device,
                physical_device,
                config.arena_size,
                config.usage,
                config.alignment,
            );
            try self.arenas.append(self.allocator, arena);
            logger.info("  Arena {} pre-allocated", .{i});
        }

        logger.info("GrowableBufferArena initialized: {} arenas, {} MB total", .{
            self.arenas.items.len,
            self.arenas.items.len * config.arena_size / (1024 * 1024),
        });

        return self;
    }

    /// Initialize with automatic sizing based on view distance
    pub fn initForViewDistance(
        allocator: std.mem.Allocator,
        device: vk.VkDevice,
        physical_device: vk.VkPhysicalDevice,
        view_distance: u32,
        vertical_view_distance: u32,
        usage: vk.VkBufferUsageFlags,
        alignment: u64,
        avg_chunk_size: u64,
        io: Io,
    ) !Self {
        // Calculate expected chunk count
        const h_chunks = @as(u64, view_distance) * 2 + 1;
        const v_chunks = @as(u64, vertical_view_distance) * 2 + 1;
        const total_chunks = h_chunks * h_chunks * v_chunks;

        // Estimate total memory needed (with 20% headroom)
        const estimated_memory = total_chunks * avg_chunk_size * 120 / 100;

        // Calculate arena count (256 MB each, minimum 1)
        const arena_size: u64 = 256 * 1024 * 1024;
        var arena_count = estimated_memory / arena_size;
        if (arena_count == 0) arena_count = 1;
        if (arena_count > 16) arena_count = 16; // Cap at 4 GB

        // Only pre-allocate a small number of arenas to avoid memory exhaustion
        // Remaining arenas will be allocated on-demand as chunks are loaded
        // This is critical for large view distances (e.g., 64 chunks = 32 GB estimated)
        const initial_arenas = @min(arena_count, 2);

        logger.info("View distance {} x {} -> {} chunks, estimated {} MB, {} arenas (pre-allocating {})", .{
            view_distance,
            vertical_view_distance,
            total_chunks,
            estimated_memory / (1024 * 1024),
            arena_count,
            initial_arenas,
        });

        return init(allocator, device, physical_device, .{
            .arena_size = arena_size,
            .initial_arena_count = @intCast(initial_arenas),
            .usage = usage,
            .alignment = alignment,
        }, io);
    }

    pub fn deinit(self: *Self) void {
        // Wait for any pending expansion to complete
        if (self.expansion_thread) |thread| {
            thread.join();
        }

        // Clean up pending arena if any
        if (self.pending_arena) |*arena| {
            arena.deinit();
        }

        // Destroy all arenas
        for (self.arenas.items) |*arena| {
            arena.deinit();
        }
        self.arenas.deinit(self.allocator);

        logger.info("GrowableBufferArena destroyed: {} allocations, {} frees, {} expansions", .{
            self.total_allocations,
            self.total_frees,
            self.expansion_count,
        });
    }

    /// Allocate a slice from the arena pool
    /// Returns null if no space available (caller should retry next frame)
    pub fn alloc(self: *Self, size: u64, count: u32) ?ExtendedBufferSlice {
        // First, check if async expansion completed
        self.collectPendingArena();

        // Try allocating from existing arenas (prefer less fragmented ones)
        for (self.arenas.items, 0..) |*arena, idx| {
            if (arena.alloc(size, count)) |slice| {
                self.total_allocations += 1;

                // Check if we should start async expansion
                self.maybeStartAsyncExpansion();

                return ExtendedBufferSlice{
                    .offset = slice.offset,
                    .size = slice.size,
                    .count = slice.count,
                    .arena_index = @intCast(idx),
                };
            }
        }

        // No space available - trigger expansion if not already running
        if (self.expansion_thread == null and !self.expansion_failed) {
            self.startAsyncExpansion();
        }

        // Return null - caller should retry next frame
        return null;
    }

    /// Free a previously allocated slice
    pub fn free(self: *Self, slice: ExtendedBufferSlice) void {
        if (!slice.isValid()) return;
        if (slice.arena_index >= self.arenas.items.len) return;

        self.arenas.items[slice.arena_index].free(.{
            .offset = slice.offset,
            .size = slice.size,
            .count = slice.count,
        });
        self.total_frees += 1;
    }

    /// Get the VkBuffer for a specific arena
    pub fn getBuffer(self: *const Self, arena_index: u16) ?vk.VkBuffer {
        if (arena_index >= self.arenas.items.len) return null;
        return self.arenas.items[arena_index].getBuffer();
    }

    /// Get total number of arenas
    pub fn getArenaCount(self: *const Self) usize {
        return self.arenas.items.len;
    }

    /// Get the expansion count (incremented each time an arena is added)
    /// Used for cache invalidation - only rebuild buffer lists when this changes
    pub fn getExpansionCount(self: *const Self) u16 {
        return self.expansion_count;
    }

    /// Get statistics for all arenas
    pub fn getStats(self: *const Self) struct {
        total_capacity: u64,
        total_used: u64,
        total_free: u64,
        arena_count: usize,
        expansion_pending: bool,
    } {
        var total_capacity: u64 = 0;
        var total_used: u64 = 0;
        var total_free: u64 = 0;

        for (self.arenas.items) |*arena| {
            const stats = arena.getStats();
            total_capacity += stats.capacity;
            total_used += stats.used;
            total_free += stats.free;
        }

        return .{
            .total_capacity = total_capacity,
            .total_used = total_used,
            .total_free = total_free,
            .arena_count = self.arenas.items.len,
            .expansion_pending = self.expansion_thread != null,
        };
    }

    /// Check usage and maybe start async expansion
    fn maybeStartAsyncExpansion(self: *Self) void {
        // Don't start if already expanding or failed previously
        if (self.expansion_thread != null or self.expansion_failed) return;

        // Check if max arena count reached
        if (self.config.max_arena_count > 0 and
            self.arenas.items.len >= self.config.max_arena_count)
        {
            return;
        }

        // Check capacity of the last arena
        const last_arena = &self.arenas.items[self.arenas.items.len - 1];
        const stats = last_arena.getStats();
        const usage_percent = if (stats.capacity > 0)
            stats.used * 100 / stats.capacity
        else
            100;

        if (usage_percent >= self.config.expansion_threshold_percent) {
            self.startAsyncExpansion();
        }
    }

    /// Start async arena allocation
    fn startAsyncExpansion(self: *Self) void {
        logger.info("Starting async arena expansion (arena {})", .{self.arenas.items.len});

        self.expansion_thread = std.Thread.spawn(.{}, asyncAllocateArena, .{self}) catch |err| {
            logger.err("Failed to spawn expansion thread: {}", .{err});
            self.expansion_failed = true;
            return;
        };
    }

    /// Background thread function to allocate a new arena
    fn asyncAllocateArena(self: *Self) void {
        const new_arena = BufferArena.init(
            self.allocator,
            self.device,
            self.physical_device,
            self.config.arena_size,
            self.config.usage,
            self.config.alignment,
        ) catch |err| {
            logger.err("Async arena allocation failed: {}", .{err});
            self.expansion_mutex.lockUncancelable(self.io);
            self.expansion_failed = true;
            self.expansion_mutex.unlock(self.io);
            return;
        };

        self.expansion_mutex.lockUncancelable(self.io);
        self.pending_arena = new_arena;
        self.expansion_mutex.unlock(self.io);

        logger.info("Async arena allocation complete", .{});
    }

    /// Collect a pending arena if ready
    fn collectPendingArena(self: *Self) void {
        self.expansion_mutex.lockUncancelable(self.io);
        defer self.expansion_mutex.unlock(self.io);

        if (self.pending_arena) |arena| {
            self.arenas.append(self.allocator, arena) catch |err| {
                logger.err("Failed to add pending arena: {}", .{err});
                var mutable_arena = arena;
                mutable_arena.deinit();
                return;
            };

            self.pending_arena = null;
            self.expansion_count += 1;

            // Join the expansion thread
            if (self.expansion_thread) |thread| {
                thread.join();
                self.expansion_thread = null;
            }

            logger.info("Arena {} added to pool (total: {} MB)", .{
                self.arenas.items.len - 1,
                self.arenas.items.len * self.config.arena_size / (1024 * 1024),
            });
        }
    }
};
