/// StagingRing - Ring buffer for staging GPU uploads
/// Uses persistent mapping and frame-based fence synchronization
const std = @import("std");
const volk = @import("volk");
const vk = volk.c;
const shared = @import("Shared");
const Logger = shared.Logger;

const BufferArena = @import("BufferArena.zig").BufferArena;
const BufferSlice = @import("BufferArena.zig").BufferSlice;

/// Pending copy operation to be executed
/// RenderSystem.StagingCopy is aliased to this type (single source of truth)
pub const PendingCopy = struct {
    src_buffer: vk.VkBuffer,
    src_offset: u64,
    dst_buffer: vk.VkBuffer,
    dst_offset: u64,
    size: u64,
};

/// Ring buffer for staging uploads
pub const StagingRing = struct {
    const Self = @This();
    const logger = Logger.scoped(Self);

    /// Default staging buffer size (64 MB)
    pub const DEFAULT_SIZE: u64 = 64 * 1024 * 1024;

    /// The staging buffer
    buffer: vk.VkBuffer,
    buffer_memory: vk.VkDeviceMemory,

    /// Persistent mapped pointer
    mapped_ptr: [*]u8,

    /// Total size of the buffer
    capacity: u64,

    /// Current write position in the ring
    write_pos: u64,

    /// Pending copy operations
    pending_copies: std.ArrayListUnmanaged(PendingCopy),

    /// Vulkan device reference
    device: vk.VkDevice,

    allocator: std.mem.Allocator,

    /// Create a new staging ring buffer
    pub fn init(
        allocator: std.mem.Allocator,
        device: vk.VkDevice,
        physical_device: vk.VkPhysicalDevice,
        size: u64,
    ) !Self {
        const vkCreateBuffer = vk.vkCreateBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkGetBufferMemoryRequirements = vk.vkGetBufferMemoryRequirements orelse return error.VulkanFunctionNotLoaded;
        const vkAllocateMemory = vk.vkAllocateMemory orelse return error.VulkanFunctionNotLoaded;
        const vkBindBufferMemory = vk.vkBindBufferMemory orelse return error.VulkanFunctionNotLoaded;
        const vkMapMemory = vk.vkMapMemory orelse return error.VulkanFunctionNotLoaded;

        // Create staging buffer (host visible, transfer source)
        const buffer_info = vk.VkBufferCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = size,
            .usage = vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };

        var buffer: vk.VkBuffer = null;
        if (vkCreateBuffer(device, &buffer_info, null, &buffer) != vk.VK_SUCCESS) {
            return error.BufferCreationFailed;
        }
        const vkDestroyBuffer = vk.vkDestroyBuffer orelse return error.VulkanFunctionNotLoaded;
        errdefer vkDestroyBuffer(device, buffer, null);

        // Get memory requirements
        var mem_requirements: vk.VkMemoryRequirements = undefined;
        vkGetBufferMemoryRequirements(device, buffer, &mem_requirements);

        // Find host-visible, host-coherent memory type
        const mem_type_index = findMemoryType(
            physical_device,
            mem_requirements.memoryTypeBits,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        ) orelse return error.NoSuitableMemoryType;

        // Allocate memory
        const alloc_info = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = mem_requirements.size,
            .memoryTypeIndex = mem_type_index,
        };

        var buffer_memory: vk.VkDeviceMemory = null;
        if (vkAllocateMemory(device, &alloc_info, null, &buffer_memory) != vk.VK_SUCCESS) {
            return error.MemoryAllocationFailed;
        }
        const vkFreeMemory = vk.vkFreeMemory orelse return error.VulkanFunctionNotLoaded;
        errdefer vkFreeMemory(device, buffer_memory, null);

        // Bind buffer to memory
        if (vkBindBufferMemory(device, buffer, buffer_memory, 0) != vk.VK_SUCCESS) {
            return error.BufferBindFailed;
        }

        // Persistent map the buffer
        var mapped_ptr: ?*anyopaque = null;
        if (vkMapMemory(device, buffer_memory, 0, size, 0, &mapped_ptr) != vk.VK_SUCCESS) {
            return error.MemoryMapFailed;
        }

        logger.info("Created StagingRing: {} MB", .{size / (1024 * 1024)});

        return Self{
            .buffer = buffer,
            .buffer_memory = buffer_memory,
            .mapped_ptr = @ptrCast(mapped_ptr),
            .capacity = size,
            .write_pos = 0,
            .pending_copies = .{},
            .device = device,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        const vkDestroyBuffer = vk.vkDestroyBuffer orelse return;
        const vkFreeMemory = vk.vkFreeMemory orelse return;
        const vkUnmapMemory = vk.vkUnmapMemory orelse return;

        // Unmap memory
        vkUnmapMemory(self.device, self.buffer_memory);

        // Destroy buffer and free memory
        if (self.buffer != null) {
            vkDestroyBuffer(self.device, self.buffer, null);
        }
        if (self.buffer_memory != null) {
            vkFreeMemory(self.device, self.buffer_memory, null);
        }

        self.pending_copies.deinit(self.allocator);

        logger.info("StagingRing destroyed", .{});
    }

    /// Stage data for upload to a destination buffer
    /// Returns the offset in the staging buffer where data was written
    pub fn stage(
        self: *Self,
        data: []const u8,
        dst_buffer: vk.VkBuffer,
        dst_offset: u64,
    ) !u64 {
        const size: u64 = @intCast(data.len);
        if (size == 0) return self.write_pos;

        // Check if we have space (simple linear allocation, wraps around)
        const aligned_size = alignUp(size, 256); // Align to 256 bytes for transfers

        // Check if we need to wrap around
        if (self.write_pos + aligned_size > self.capacity) {
            // Wrap to beginning
            self.write_pos = 0;
        }

        // TODO: More sophisticated space checking with frame boundaries
        // For now, assume we have space (64MB is usually enough)

        const src_offset = self.write_pos;

        // Copy data to mapped memory
        @memcpy(self.mapped_ptr[src_offset..][0..data.len], data);

        // Record pending copy
        try self.pending_copies.append(self.allocator, PendingCopy{
            .src_buffer = self.buffer,
            .src_offset = src_offset,
            .dst_buffer = dst_buffer,
            .dst_offset = dst_offset,
            .size = size,
        });

        // Advance write position
        self.write_pos += aligned_size;

        return src_offset;
    }

    /// Get pending copies
    pub fn getPendingCopies(self: *const Self) []const PendingCopy {
        return self.pending_copies.items;
    }

    /// Clear pending copies after they've been committed
    pub fn clearPendingCopies(self: *Self) void {
        self.pending_copies.clearRetainingCapacity();
    }

    /// Get the current number of pending copies (for tracking before staging)
    pub fn getPendingCount(self: *const Self) usize {
        return self.pending_copies.items.len;
    }

    /// Cancel pending copies added after a certain point (used when staging fails partway)
    /// This prevents copy commands referencing freed buffer regions
    pub fn cancelPendingCopiesAfter(self: *Self, count: usize) void {
        if (count < self.pending_copies.items.len) {
            self.pending_copies.shrinkRetainingCapacity(count);
        }
    }

    fn findMemoryType(
        physical_device: vk.VkPhysicalDevice,
        type_filter: u32,
        properties: vk.VkMemoryPropertyFlags,
    ) ?u32 {
        const vkGetPhysicalDeviceMemoryProperties = vk.vkGetPhysicalDeviceMemoryProperties orelse return null;

        var mem_properties: vk.VkPhysicalDeviceMemoryProperties = undefined;
        vkGetPhysicalDeviceMemoryProperties(physical_device, &mem_properties);

        for (0..mem_properties.memoryTypeCount) |i| {
            const type_bit: u32 = @as(u32, 1) << @intCast(i);
            if ((type_filter & type_bit) != 0) {
                if ((mem_properties.memoryTypes[i].propertyFlags & properties) == properties) {
                    return @intCast(i);
                }
            }
        }

        return null;
    }

    fn alignUp(value: u64, alignment: u64) u64 {
        // Use division for non-power-of-2 alignments
        return ((value + alignment - 1) / alignment) * alignment;
    }
};
