/// ChunkBufferManager - Coordinates vertex/index arenas for chunk rendering
/// Uses growable buffer arenas for AAA-quality smooth frame times
const std = @import("std");
const Io = std.Io;
const volk = @import("volk");
const vk = volk.c;
const shared = @import("Shared");
const Logger = shared.Logger;
const ChunkPos = shared.ChunkPos;

const GrowableBufferArena = @import("GrowableBufferArena.zig").GrowableBufferArena;
const ExtendedBufferSlice = @import("GrowableBufferArena.zig").ExtendedBufferSlice;

/// Allocation handle for a chunk's GPU buffers
pub const ChunkBufferAllocation = struct {
    /// Slice in the vertex buffer arena (includes arena index)
    vertex_slice: ExtendedBufferSlice,
    /// Slice in the index buffer arena (includes arena index)
    index_slice: ExtendedBufferSlice,
    /// Whether this allocation is valid
    valid: bool = true,

    pub const INVALID = ChunkBufferAllocation{
        .vertex_slice = ExtendedBufferSlice.INVALID,
        .index_slice = ExtendedBufferSlice.INVALID,
        .valid = false,
    };

    /// Check if this allocation uses the same buffers as another
    /// Used for batching draw calls by buffer
    pub fn sameBuffers(self: ChunkBufferAllocation, other: ChunkBufferAllocation) bool {
        return self.vertex_slice.arena_index == other.vertex_slice.arena_index and
            self.index_slice.arena_index == other.index_slice.arena_index;
    }
};

/// Configuration for the chunk buffer manager
pub const ChunkBufferConfig = struct {
    /// Size of vertex buffer (single buffer for GPU-driven rendering)
    vertex_arena_size: u64 = 1024 * 1024 * 1024, // 1 GB default for GPU-driven
    /// Size of index buffer (single buffer for GPU-driven rendering)
    index_arena_size: u64 = 512 * 1024 * 1024, // 512 MB default for GPU-driven
    /// Vertex size in bytes (should match Vertex struct)
    vertex_size: u64 = 36,
    /// Index size in bytes
    index_size: u64 = 4, // u32 indices
    /// View distance (used for logging/stats only in single-buffer mode)
    view_distance: u32 = 0,
    /// Vertical view distance (used for logging/stats only)
    vertical_view_distance: u32 = 0,
    /// Average chunk mesh size estimate (for pre-allocation)
    avg_chunk_vertex_size: u64 = 64 * 1024, // 64 KB average
    avg_chunk_index_size: u64 = 32 * 1024, // 32 KB average
    /// Expansion threshold percentage (0-100) - not used in single-buffer mode
    expansion_threshold: u8 = 75,
    /// Buffer sharing mode (EXCLUSIVE or CONCURRENT for multi-queue access)
    sharing_mode: vk.VkSharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
    /// Queue family indices for CONCURRENT sharing (null = exclusive)
    queue_family_indices: ?[]const u32 = null,
};

/// Deferred free entry - allocation to be freed after GPU is done with it
const DeferredFree = struct {
    allocation: ChunkBufferAllocation,
    frame_count: u64,
};

/// Manages GPU buffer allocation for chunks with dynamic growth
pub const ChunkBufferManager = struct {
    const Self = @This();
    const logger = Logger.scoped(Self);

    /// Number of frames to wait before actually freeing (ensures GPU is done)
    const DEFERRED_FREE_FRAMES: u64 = 3;

    /// Growable vertex buffer arena
    vertex_arena: GrowableBufferArena,
    /// Growable index buffer arena
    index_arena: GrowableBufferArena,

    /// Vulkan device
    device: vk.VkDevice,
    /// Physical device for memory type queries
    physical_device: vk.VkPhysicalDevice,

    /// Configuration
    config: ChunkBufferConfig,

    allocator: std.mem.Allocator,

    /// Pending frees - allocations waiting to be freed after GPU is done
    pending_frees: std.ArrayListUnmanaged(DeferredFree) = .{},
    /// Current frame counter for deferred free tracking
    frame_counter: u64 = 0,

    /// Initialize the chunk buffer manager
    /// Uses single large buffers for GPU-driven rendering (Voxy approach)
    pub fn init(
        allocator: std.mem.Allocator,
        device: vk.VkDevice,
        physical_device: vk.VkPhysicalDevice,
        config: ChunkBufferConfig,
        io: Io,
    ) !Self {
        logger.info("Initializing ChunkBufferManager (single-buffer mode for GPU-driven rendering)...", .{});
        logger.info("  Vertex buffer: {} MB, Index buffer: {} MB", .{
            config.vertex_arena_size / (1024 * 1024),
            config.index_arena_size / (1024 * 1024),
        });

        // Single large buffer for vertices (no multi-arena, no expansion)
        // This is required for GPU-driven rendering where all geometry must be in one buffer
        var vertex_arena = try GrowableBufferArena.init(
            allocator,
            device,
            physical_device,
            .{
                .arena_size = config.vertex_arena_size,
                .initial_arena_count = 1,
                .max_arena_count = 1, // Enforce single buffer - no expansion to multiple arenas
                .usage = vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                .alignment = config.vertex_size,
                .expansion_threshold_percent = 100, // Disable expansion threshold
                .sharing_mode = config.sharing_mode,
                .queue_family_indices = config.queue_family_indices,
            },
            io,
        );
        errdefer vertex_arena.deinit();

        // Single large buffer for indices
        var index_arena = try GrowableBufferArena.init(
            allocator,
            device,
            physical_device,
            .{
                .arena_size = config.index_arena_size,
                .initial_arena_count = 1,
                .max_arena_count = 1, // Enforce single buffer
                .usage = vk.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
                .alignment = config.index_size,
                .expansion_threshold_percent = 100, // Disable expansion threshold
                .sharing_mode = config.sharing_mode,
                .queue_family_indices = config.queue_family_indices,
            },
            io,
        );
        errdefer index_arena.deinit();

        const vertex_stats = vertex_arena.getStats();
        const index_stats = index_arena.getStats();
        logger.info("ChunkBufferManager initialized: vertex={} MB ({} arenas), index={} MB ({} arenas)", .{
            vertex_stats.total_capacity / (1024 * 1024),
            vertex_stats.arena_count,
            index_stats.total_capacity / (1024 * 1024),
            index_stats.arena_count,
        });

        return Self{
            .vertex_arena = vertex_arena,
            .index_arena = index_arena,
            .device = device,
            .physical_device = physical_device,
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        logger.info("Shutting down ChunkBufferManager...", .{});

        // Process any remaining deferred frees
        for (self.pending_frees.items) |entry| {
            self.vertex_arena.free(entry.allocation.vertex_slice);
            self.index_arena.free(entry.allocation.index_slice);
        }
        self.pending_frees.deinit(self.allocator);

        self.index_arena.deinit();
        self.vertex_arena.deinit();

        logger.info("ChunkBufferManager shut down", .{});
    }

    /// Allocate buffer space for a chunk's mesh
    /// Returns null if arenas don't have enough space (caller should retry next frame)
    pub fn allocate(
        self: *Self,
        vertex_count: u32,
        index_count: u32,
    ) ?ChunkBufferAllocation {
        const vertex_size = @as(u64, vertex_count) * self.config.vertex_size;
        const index_size = @as(u64, index_count) * self.config.index_size;

        const vertex_slice = self.vertex_arena.alloc(vertex_size, vertex_count) orelse {
            logger.warn("Failed to allocate vertex buffer space: {} vertices ({} bytes) - will retry", .{ vertex_count, vertex_size });
            return null;
        };

        const index_slice = self.index_arena.alloc(index_size, index_count) orelse {
            self.vertex_arena.free(vertex_slice);
            logger.warn("Failed to allocate index buffer space: {} indices ({} bytes) - will retry", .{ index_count, index_size });
            return null;
        };

        return ChunkBufferAllocation{
            .vertex_slice = vertex_slice,
            .index_slice = index_slice,
            .valid = true,
        };
    }

    /// Free a chunk's buffer allocation (deferred to ensure GPU is done with it)
    pub fn free(self: *Self, allocation: ChunkBufferAllocation) void {
        if (!allocation.valid) return;

        // Defer the free until the GPU is definitely done with this memory
        self.pending_frees.append(self.allocator, DeferredFree{
            .allocation = allocation,
            .frame_count = self.frame_counter,
        }) catch {
            // If we can't defer, log warning but still free immediately
            // This could cause visual glitches but won't crash
            logger.warn("Failed to defer buffer free, freeing immediately (may cause visual artifacts)", .{});
            self.vertex_arena.free(allocation.vertex_slice);
            self.index_arena.free(allocation.index_slice);
        };
    }

    /// Advance frame and process deferred frees (for upload thread use)
    /// Does NOT touch staging ring - use when only deferred free processing is needed
    pub fn advanceFrameAndProcessFrees(self: *Self) void {
        self.frame_counter += 1;
        self.processDeferredFrees();
    }

    /// Process deferred frees - frees allocations that are old enough
    /// Call this at the start of each frame
    fn processDeferredFrees(self: *Self) void {
        // Process from end to beginning so we can swap-remove
        var i: usize = self.pending_frees.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.pending_frees.items[i];
            if (self.frame_counter >= entry.frame_count + DEFERRED_FREE_FRAMES) {
                // This allocation is old enough, safe to free now
                self.vertex_arena.free(entry.allocation.vertex_slice);
                self.index_arena.free(entry.allocation.index_slice);
                _ = self.pending_frees.swapRemove(i);
            }
        }
    }

    /// Get the vertex buffer for a specific arena
    pub fn getVertexBuffer(self: *const Self, arena_index: u16) ?vk.VkBuffer {
        return self.vertex_arena.getBuffer(arena_index);
    }

    /// Get the index buffer for a specific arena
    pub fn getIndexBuffer(self: *const Self, arena_index: u16) ?vk.VkBuffer {
        return self.index_arena.getBuffer(arena_index);
    }

    /// Get the primary vertex buffer (arena 0) for backwards compatibility
    pub fn getPrimaryVertexBuffer(self: *const Self) vk.VkBuffer {
        return self.vertex_arena.getBuffer(0) orelse unreachable;
    }

    /// Get the primary index buffer (arena 0) for backwards compatibility
    pub fn getPrimaryIndexBuffer(self: *const Self) vk.VkBuffer {
        return self.index_arena.getBuffer(0) orelse unreachable;
    }

    /// Get the number of vertex arenas
    pub fn getVertexArenaCount(self: *const Self) usize {
        return self.vertex_arena.getArenaCount();
    }

    /// Get the number of index arenas
    pub fn getIndexArenaCount(self: *const Self) usize {
        return self.index_arena.getArenaCount();
    }

    /// Get a version number that changes when arenas are added
    /// Used for cache invalidation in ChunkManager
    /// Note: Each u16 counter wraps at 65535. In the unlikely event of wrap-around,
    /// the cache may not invalidate. This would require 65535+ arena expansions
    /// (each expansion adds ~1GB), which far exceeds practical memory limits.
    pub fn getArenaVersion(self: *const Self) u32 {
        const vertex_version: u32 = self.vertex_arena.getExpansionCount();
        const index_version: u32 = self.index_arena.getExpansionCount();
        return (vertex_version << 16) | index_version;
    }

    /// Get usage statistics
    pub fn getStats(self: *const Self) struct {
        vertex_used: u64,
        vertex_free: u64,
        vertex_capacity: u64,
        vertex_arena_count: usize,
        vertex_expansion_pending: bool,
        index_used: u64,
        index_free: u64,
        index_capacity: u64,
        index_arena_count: usize,
        index_expansion_pending: bool,
    } {
        const vertex_stats = self.vertex_arena.getStats();
        const index_stats = self.index_arena.getStats();
        return .{
            .vertex_used = vertex_stats.total_used,
            .vertex_free = vertex_stats.total_free,
            .vertex_capacity = vertex_stats.total_capacity,
            .vertex_arena_count = vertex_stats.arena_count,
            .vertex_expansion_pending = vertex_stats.expansion_pending,
            .index_used = index_stats.total_used,
            .index_free = index_stats.total_free,
            .index_capacity = index_stats.total_capacity,
            .index_arena_count = index_stats.arena_count,
            .index_expansion_pending = index_stats.expansion_pending,
        };
    }
};
