/// BufferArena - Sub-allocates within a single large VkBuffer
/// Uses AllocationArena to track free/used regions
const std = @import("std");
const volk = @import("volk");
const vk = volk.c;
const shared = @import("Shared");
const Logger = shared.Logger;

const AllocationArena = @import("AllocationArena.zig").AllocationArena;
const Allocation = @import("AllocationArena.zig").Allocation;

/// A handle to a sub-allocation within the buffer
pub const BufferSlice = struct {
    /// Offset into the buffer
    offset: u64,
    /// Size of the allocation
    size: u64,
    /// For vertex buffers: number of vertices
    /// For index buffers: number of indices
    count: u32,
};

/// Arena-based buffer allocator
pub const BufferArena = struct {
    const Self = @This();
    const logger = Logger.scoped(Self);

    /// The backing Vulkan buffer
    buffer: vk.VkBuffer,
    buffer_memory: vk.VkDeviceMemory,

    /// Allocation tracker
    arena: AllocationArena,

    /// Total size of the buffer
    size: u64,

    /// Vulkan device reference
    device: vk.VkDevice,

    /// Buffer usage flags
    usage: vk.VkBufferUsageFlags,

    allocator: std.mem.Allocator,

    /// Create a new buffer arena with the specified size
    pub fn init(
        allocator: std.mem.Allocator,
        device: vk.VkDevice,
        physical_device: vk.VkPhysicalDevice,
        size: u64,
        usage: vk.VkBufferUsageFlags,
        alignment: u64,
    ) !Self {
        const vkCreateBuffer = vk.vkCreateBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkGetBufferMemoryRequirements = vk.vkGetBufferMemoryRequirements orelse return error.VulkanFunctionNotLoaded;
        const vkAllocateMemory = vk.vkAllocateMemory orelse return error.VulkanFunctionNotLoaded;
        const vkBindBufferMemory = vk.vkBindBufferMemory orelse return error.VulkanFunctionNotLoaded;

        // Create buffer
        const buffer_info = vk.VkBufferCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = size,
            .usage = usage | vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
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

        // Find suitable memory type (device local)
        const mem_type_index = findMemoryType(
            physical_device,
            mem_requirements.memoryTypeBits,
            vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
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

        // Use LCM of specified alignment and memory requirements alignment
        // This ensures allocations are aligned for both Vulkan AND vertex/index access
        const effective_alignment = lcm(alignment, mem_requirements.alignment);

        logger.info("Created BufferArena: {} bytes, alignment {} (requested={}, mem_req={})", .{
            size,
            effective_alignment,
            alignment,
            mem_requirements.alignment,
        });

        return Self{
            .buffer = buffer,
            .buffer_memory = buffer_memory,
            .arena = try AllocationArena.init(allocator, size, effective_alignment),
            .size = size,
            .device = device,
            .usage = usage,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        const vkDestroyBuffer = vk.vkDestroyBuffer orelse return;
        const vkFreeMemory = vk.vkFreeMemory orelse return;

        self.arena.deinit();

        if (self.buffer != null) {
            vkDestroyBuffer(self.device, self.buffer, null);
        }
        if (self.buffer_memory != null) {
            vkFreeMemory(self.device, self.buffer_memory, null);
        }

        logger.info("BufferArena destroyed", .{});
    }

    /// Allocate a slice from the arena
    /// Returns null if no space available
    pub fn alloc(self: *Self, size: u64, count: u32) ?BufferSlice {
        const allocation = self.arena.alloc(size) orelse return null;

        return BufferSlice{
            .offset = allocation.offset,
            .size = allocation.size,
            .count = count,
        };
    }

    /// Free a previously allocated slice
    pub fn free(self: *Self, slice: BufferSlice) void {
        self.arena.free(.{
            .offset = slice.offset,
            .size = slice.size,
        });
    }

    /// Check if the arena can fit an allocation
    pub fn canFit(self: *const Self, size: u64) bool {
        return self.arena.canFit(size);
    }

    /// Get the underlying VkBuffer
    pub fn getBuffer(self: *const Self) vk.VkBuffer {
        return self.buffer;
    }

    /// Get usage statistics
    pub fn getStats(self: *const Self) struct { used: u64, free: u64, capacity: u64, fragments: usize } {
        const inner_stats = self.arena.getStats();
        return .{
            .used = inner_stats.used,
            .free = inner_stats.free,
            .capacity = inner_stats.capacity,
            .fragments = inner_stats.fragments,
        };
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
};

/// Greatest common divisor
fn gcd(a: u64, b: u64) u64 {
    var x = a;
    var y = b;
    while (y != 0) {
        const t = y;
        y = x % y;
        x = t;
    }
    return x;
}

/// Least common multiple
fn lcm(a: u64, b: u64) u64 {
    return (a / gcd(a, b)) * b;
}
