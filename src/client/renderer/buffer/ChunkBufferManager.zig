/// ChunkBufferManager - Coordinates vertex/index arenas for chunk rendering
/// Uses growable buffer arenas for AAA-quality smooth frame times
const std = @import("std");
const volk = @import("volk");
const vk = volk.c;
const shared = @import("Shared");
const Logger = shared.Logger;
const ChunkPos = shared.ChunkPos;

const GrowableBufferArena = @import("GrowableBufferArena.zig").GrowableBufferArena;
const ExtendedBufferSlice = @import("GrowableBufferArena.zig").ExtendedBufferSlice;
const staging_ring_module = @import("StagingRing.zig");
const StagingRing = staging_ring_module.StagingRing;
const PendingCopy = staging_ring_module.PendingCopy;

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
    /// Size of each vertex buffer arena (default 256 MB)
    vertex_arena_size: u64 = 256 * 1024 * 1024,
    /// Size of each index buffer arena (default 128 MB)
    index_arena_size: u64 = 128 * 1024 * 1024,
    /// Size of the staging ring buffer (default 64 MB)
    staging_size: u64 = 64 * 1024 * 1024,
    /// Vertex size in bytes (should match Vertex struct)
    vertex_size: u64 = 36,
    /// Index size in bytes
    index_size: u64 = 4, // u32 indices
    /// View distance for pre-allocation (0 = use fixed arena count)
    view_distance: u32 = 0,
    /// Vertical view distance for pre-allocation
    vertical_view_distance: u32 = 0,
    /// Average chunk mesh size estimate (for pre-allocation)
    avg_chunk_vertex_size: u64 = 64 * 1024, // 64 KB average
    avg_chunk_index_size: u64 = 32 * 1024, // 32 KB average
    /// Expansion threshold percentage (0-100)
    expansion_threshold: u8 = 75,
};

/// Manages GPU buffer allocation for chunks with dynamic growth
pub const ChunkBufferManager = struct {
    const Self = @This();
    const logger = Logger.scoped(Self);

    /// Growable vertex buffer arena
    vertex_arena: GrowableBufferArena,
    /// Growable index buffer arena
    index_arena: GrowableBufferArena,
    /// Staging ring for uploads
    staging: StagingRing,

    /// Vulkan device
    device: vk.VkDevice,
    /// Physical device for memory type queries
    physical_device: vk.VkPhysicalDevice,

    /// Configuration
    config: ChunkBufferConfig,

    allocator: std.mem.Allocator,

    /// Initialize the chunk buffer manager
    pub fn init(
        allocator: std.mem.Allocator,
        device: vk.VkDevice,
        physical_device: vk.VkPhysicalDevice,
        config: ChunkBufferConfig,
    ) !Self {
        logger.info("Initializing ChunkBufferManager...", .{});

        // Determine if we should use view distance-based pre-allocation
        const use_view_distance = config.view_distance > 0;

        var vertex_arena: GrowableBufferArena = undefined;
        var index_arena: GrowableBufferArena = undefined;

        if (use_view_distance) {
            // Pre-allocate based on view distance for smooth gameplay
            logger.info("Using view distance-based pre-allocation: {}x{}", .{
                config.view_distance,
                config.vertical_view_distance,
            });

            vertex_arena = try GrowableBufferArena.initForViewDistance(
                allocator,
                device,
                physical_device,
                config.view_distance,
                config.vertical_view_distance,
                vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                config.vertex_size,
                config.avg_chunk_vertex_size,
            );
            errdefer vertex_arena.deinit();

            index_arena = try GrowableBufferArena.initForViewDistance(
                allocator,
                device,
                physical_device,
                config.view_distance,
                config.vertical_view_distance,
                vk.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
                config.index_size,
                config.avg_chunk_index_size,
            );
        } else {
            // Use fixed arena sizes
            vertex_arena = try GrowableBufferArena.init(
                allocator,
                device,
                physical_device,
                .{
                    .arena_size = config.vertex_arena_size,
                    .initial_arena_count = 1,
                    .usage = vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                    .alignment = config.vertex_size,
                    .expansion_threshold_percent = config.expansion_threshold,
                },
            );
            errdefer vertex_arena.deinit();

            index_arena = try GrowableBufferArena.init(
                allocator,
                device,
                physical_device,
                .{
                    .arena_size = config.index_arena_size,
                    .initial_arena_count = 1,
                    .usage = vk.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
                    .alignment = config.index_size,
                    .expansion_threshold_percent = config.expansion_threshold,
                },
            );
        }
        errdefer index_arena.deinit();

        // Create staging ring
        const staging = try StagingRing.init(
            allocator,
            device,
            physical_device,
            config.staging_size,
        );

        const vertex_stats = vertex_arena.getStats();
        const index_stats = index_arena.getStats();
        logger.info("ChunkBufferManager initialized: vertex={} MB ({} arenas), index={} MB ({} arenas), staging={} MB", .{
            vertex_stats.total_capacity / (1024 * 1024),
            vertex_stats.arena_count,
            index_stats.total_capacity / (1024 * 1024),
            index_stats.arena_count,
            config.staging_size / (1024 * 1024),
        });

        return Self{
            .vertex_arena = vertex_arena,
            .index_arena = index_arena,
            .staging = staging,
            .device = device,
            .physical_device = physical_device,
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        logger.info("Shutting down ChunkBufferManager...", .{});

        self.staging.deinit();
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

        // Try to allocate vertex space
        const vertex_slice = self.vertex_arena.alloc(vertex_size, vertex_count) orelse {
            logger.warn("Failed to allocate vertex buffer space: {} vertices ({} bytes) - will retry", .{ vertex_count, vertex_size });
            return null;
        };

        // Try to allocate index space
        const index_slice = self.index_arena.alloc(index_size, index_count) orelse {
            // Rollback vertex allocation
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

    /// Free a chunk's buffer allocation
    pub fn free(self: *Self, allocation: ChunkBufferAllocation) void {
        if (!allocation.valid) return;

        self.vertex_arena.free(allocation.vertex_slice);
        self.index_arena.free(allocation.index_slice);
    }

    /// Stage vertex data for upload
    pub fn stageVertices(
        self: *Self,
        allocation: ChunkBufferAllocation,
        vertex_data: []const u8,
    ) !void {
        if (!allocation.valid) return error.InvalidAllocation;

        const buffer = self.vertex_arena.getBuffer(allocation.vertex_slice.arena_index) orelse {
            return error.InvalidArenaIndex;
        };

        _ = try self.staging.stage(
            vertex_data,
            buffer,
            allocation.vertex_slice.offset,
        );
    }

    /// Stage index data for upload
    pub fn stageIndices(
        self: *Self,
        allocation: ChunkBufferAllocation,
        index_data: []const u8,
    ) !void {
        if (!allocation.valid) return error.InvalidAllocation;

        const buffer = self.index_arena.getBuffer(allocation.index_slice.arena_index) orelse {
            return error.InvalidArenaIndex;
        };

        _ = try self.staging.stage(
            index_data,
            buffer,
            allocation.index_slice.offset,
        );
    }

    /// Begin a new frame (call before staging)
    pub fn beginFrame(self: *Self, frame_fence: vk.VkFence) !void {
        try self.staging.beginFrame(frame_fence);
    }

    /// Commit all staged uploads to a command buffer
    pub fn commitUploads(self: *Self, cmd_buffer: vk.VkCommandBuffer) void {
        self.staging.commit(cmd_buffer);
    }

    /// Check if there are pending uploads
    pub fn hasPendingUploads(self: *const Self) bool {
        return self.staging.hasPending();
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

    /// Get the staging buffer for copy commands
    pub fn getStagingBuffer(self: *const Self) vk.VkBuffer {
        return self.staging.getBuffer();
    }

    /// Get pending staging copies
    pub fn getPendingCopies(self: *const Self) []const PendingCopy {
        return self.staging.getPendingCopies();
    }

    /// Clear pending copies after they've been committed
    pub fn clearPendingCopies(self: *Self) void {
        self.staging.clearPendingCopies();
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
