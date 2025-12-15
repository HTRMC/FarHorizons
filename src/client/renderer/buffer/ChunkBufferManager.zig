/// ChunkBufferManager - Coordinates vertex/index arenas for chunk rendering
/// Manages large GPU buffers with sub-allocation for individual chunks
const std = @import("std");
const volk = @import("volk");
const vk = volk.c;
const shared = @import("Shared");
const Logger = shared.Logger;
const ChunkPos = shared.ChunkPos;

const BufferArena = @import("BufferArena.zig").BufferArena;
const BufferSlice = @import("BufferArena.zig").BufferSlice;
const StagingRing = @import("StagingRing.zig").StagingRing;

/// Allocation handle for a chunk's GPU buffers
pub const ChunkBufferAllocation = struct {
    /// Slice in the vertex buffer arena
    vertex_slice: BufferSlice,
    /// Slice in the index buffer arena
    index_slice: BufferSlice,
    /// Whether this allocation is valid
    valid: bool = true,

    pub const INVALID = ChunkBufferAllocation{
        .vertex_slice = .{ .offset = 0, .size = 0, .count = 0 },
        .index_slice = .{ .offset = 0, .size = 0, .count = 0 },
        .valid = false,
    };
};

/// Configuration for the chunk buffer manager
pub const ChunkBufferConfig = struct {
    /// Size of the vertex buffer arena (default 256 MB)
    vertex_arena_size: u64 = 256 * 1024 * 1024,
    /// Size of the index buffer arena (default 128 MB)
    index_arena_size: u64 = 128 * 1024 * 1024,
    /// Size of the staging ring buffer (default 64 MB)
    staging_size: u64 = 64 * 1024 * 1024,
    /// Vertex size in bytes (should match Vertex struct)
    vertex_size: u64 = 36,
    /// Index size in bytes
    index_size: u64 = 4, // u32 indices
};

/// Manages GPU buffer allocation for chunks
pub const ChunkBufferManager = struct {
    const Self = @This();
    const logger = Logger.init("ChunkBufferManager");

    /// Vertex buffer arena
    vertex_arena: BufferArena,
    /// Index buffer arena
    index_arena: BufferArena,
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

        // Create vertex buffer arena (device local, vertex buffer usage)
        const vertex_arena = try BufferArena.init(
            allocator,
            device,
            physical_device,
            config.vertex_arena_size,
            vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
            config.vertex_size, // Align to vertex size
        );
        errdefer {
            var va = vertex_arena;
            va.deinit();
        }

        // Create index buffer arena (device local, index buffer usage)
        const index_arena = try BufferArena.init(
            allocator,
            device,
            physical_device,
            config.index_arena_size,
            vk.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
            config.index_size, // Align to index size
        );
        errdefer {
            var ia = index_arena;
            ia.deinit();
        }

        // Create staging ring
        const staging = try StagingRing.init(
            allocator,
            device,
            physical_device,
            config.staging_size,
        );

        logger.info("ChunkBufferManager initialized: vertex={} MB, index={} MB, staging={} MB", .{
            config.vertex_arena_size / (1024 * 1024),
            config.index_arena_size / (1024 * 1024),
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
    /// Returns null if arenas don't have enough space
    pub fn allocate(
        self: *Self,
        vertex_count: u32,
        index_count: u32,
    ) ?ChunkBufferAllocation {
        const vertex_size = @as(u64, vertex_count) * self.config.vertex_size;
        const index_size = @as(u64, index_count) * self.config.index_size;

        // Try to allocate vertex space
        const vertex_slice = self.vertex_arena.alloc(vertex_size, vertex_count) orelse {
            logger.warn("Failed to allocate vertex buffer space: {} vertices ({} bytes)", .{ vertex_count, vertex_size });
            return null;
        };

        // Try to allocate index space
        const index_slice = self.index_arena.alloc(index_size, index_count) orelse {
            // Rollback vertex allocation
            self.vertex_arena.free(vertex_slice);
            logger.warn("Failed to allocate index buffer space: {} indices ({} bytes)", .{ index_count, index_size });
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

        _ = try self.staging.stage(
            vertex_data,
            self.vertex_arena.getBuffer(),
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

        _ = try self.staging.stage(
            index_data,
            self.index_arena.getBuffer(),
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

    /// Get the vertex buffer for binding
    pub fn getVertexBuffer(self: *const Self) vk.VkBuffer {
        return self.vertex_arena.getBuffer();
    }

    /// Get the index buffer for binding
    pub fn getIndexBuffer(self: *const Self) vk.VkBuffer {
        return self.index_arena.getBuffer();
    }

    /// Get usage statistics
    pub fn getStats(self: *const Self) struct {
        vertex_used: u64,
        vertex_free: u64,
        vertex_capacity: u64,
        vertex_fragments: usize,
        index_used: u64,
        index_free: u64,
        index_capacity: u64,
        index_fragments: usize,
    } {
        const vertex_stats = self.vertex_arena.getStats();
        const index_stats = self.index_arena.getStats();
        return .{
            .vertex_used = vertex_stats.used,
            .vertex_free = vertex_stats.free,
            .vertex_capacity = vertex_stats.capacity,
            .vertex_fragments = vertex_stats.fragments,
            .index_used = index_stats.used,
            .index_free = index_stats.free,
            .index_capacity = index_stats.capacity,
            .index_fragments = index_stats.fragments,
        };
    }
};
