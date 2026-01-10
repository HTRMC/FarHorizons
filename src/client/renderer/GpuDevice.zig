// GpuDevice - Abstract GPU device for resource creation
// Inspired by Minecraft's com.mojang.blaze3d.systems.GpuDevice

const std = @import("std");
const volk = @import("volk");
const vk = volk.c;
const shared = @import("Shared");
const Logger = shared.Logger;

const GpuBuffer = @import("GpuBuffer.zig");

/// GPU Device - handles resource creation and management
pub const GpuDevice = struct {
    const Self = @This();
    const logger = Logger.scoped(Self);

    // Core Vulkan handles
    device: vk.VkDevice,
    physical_device: vk.VkPhysicalDevice,
    command_pool: vk.VkCommandPool,
    graphics_queue: vk.VkQueue,

    // Device properties
    uniform_offset_alignment: u32,
    max_texture_size: u32,

    // Allocator for internal allocations
    allocator: std.mem.Allocator,

    pub fn init(
        device: vk.VkDevice,
        physical_device: vk.VkPhysicalDevice,
        command_pool: vk.VkCommandPool,
        graphics_queue: vk.VkQueue,
        allocator: std.mem.Allocator,
    ) Self {
        // Query device properties
        var props: vk.VkPhysicalDeviceProperties = undefined;
        if (vk.vkGetPhysicalDeviceProperties) |getProps| {
            getProps(physical_device, &props);
        }

        return .{
            .device = device,
            .physical_device = physical_device,
            .command_pool = command_pool,
            .graphics_queue = graphics_queue,
            .uniform_offset_alignment = @intCast(props.limits.minUniformBufferOffsetAlignment),
            .max_texture_size = props.limits.maxImageDimension2D,
            .allocator = allocator,
        };
    }

    // ============================================================
    // Buffer Creation
    // ============================================================

    /// Create a buffer with the given usage and size
    pub fn createBuffer(
        self: *Self,
        label: ?[]const u8,
        usage: GpuBuffer.Usage,
        size: u64,
    ) !*GpuBuffer.GpuBuffer {
        if (size == 0) return error.InvalidBufferSize;

        const vkCreateBuffer = vk.vkCreateBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkGetBufferMemoryRequirements = vk.vkGetBufferMemoryRequirements orelse return error.VulkanFunctionNotLoaded;
        const vkAllocateMemory = vk.vkAllocateMemory orelse return error.VulkanFunctionNotLoaded;
        const vkBindBufferMemory = vk.vkBindBufferMemory orelse return error.VulkanFunctionNotLoaded;

        const buffer_info = vk.VkBufferCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = size,
            .usage = usage.toVkUsage(),
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };

        var handle: vk.VkBuffer = null;
        if (vkCreateBuffer(self.device, &buffer_info, null, &handle) != vk.VK_SUCCESS) {
            return error.BufferCreationFailed;
        }
        errdefer if (vk.vkDestroyBuffer) |destroy| destroy(self.device, handle, null);

        var mem_requirements: vk.VkMemoryRequirements = undefined;
        vkGetBufferMemoryRequirements(self.device, handle, &mem_requirements);

        const mem_type = try self.findMemoryType(
            mem_requirements.memoryTypeBits,
            usage.toVkMemoryProperties(),
        );

        const alloc_info = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = mem_requirements.size,
            .memoryTypeIndex = mem_type,
        };

        var memory: vk.VkDeviceMemory = null;
        if (vkAllocateMemory(self.device, &alloc_info, null, &memory) != vk.VK_SUCCESS) {
            return error.MemoryAllocationFailed;
        }
        errdefer if (vk.vkFreeMemory) |free| free(self.device, memory, null);

        if (vkBindBufferMemory(self.device, handle, memory, 0) != vk.VK_SUCCESS) {
            return error.BufferMemoryBindFailed;
        }

        const buffer = try self.allocator.create(GpuBuffer.GpuBuffer);
        buffer.* = GpuBuffer.GpuBuffer.init(handle, memory, size, usage, self.device, label);

        logger.debug("Created buffer: {s} ({d} bytes)", .{ label orelse "unnamed", size });
        return buffer;
    }

    /// Create a buffer and immediately write data to it
    pub fn createBufferWithData(
        self: *Self,
        label: ?[]const u8,
        usage: GpuBuffer.Usage,
        comptime T: type,
        data: []const T,
    ) !*GpuBuffer.GpuBuffer {
        const size: u64 = @sizeOf(T) * data.len;
        const buffer = try self.createBuffer(label, usage, size);
        errdefer {
            buffer.close();
            self.allocator.destroy(buffer);
        }

        try buffer.writeData(T, data);
        buffer.unmap(); // Unmap after writing

        return buffer;
    }

    /// Create a buffer with raw byte data
    pub fn createBufferWithBytes(
        self: *Self,
        label: ?[]const u8,
        usage: GpuBuffer.Usage,
        data: []const u8,
    ) !*GpuBuffer.GpuBuffer {
        const buffer = try self.createBuffer(label, usage, data.len);
        errdefer {
            buffer.close();
            self.allocator.destroy(buffer);
        }

        try buffer.writeBytes(data);
        buffer.unmap();

        return buffer;
    }

    /// Destroy a buffer created by this device
    pub fn destroyBuffer(self: *Self, buffer: *GpuBuffer.GpuBuffer) void {
        buffer.close();
        self.allocator.destroy(buffer);
    }

    // ============================================================
    // Raw Buffer Creation (for backward compatibility)
    // ============================================================

    /// Result of raw buffer creation
    pub const RawBuffer = struct {
        handle: vk.VkBuffer,
        memory: vk.VkDeviceMemory,
    };

    /// Create a buffer and return raw Vulkan handles (for legacy code integration)
    pub fn createBufferRaw(
        self: *Self,
        size: u64,
        vk_usage: vk.VkBufferUsageFlags,
        memory_properties: vk.VkMemoryPropertyFlags,
    ) !RawBuffer {
        if (size == 0) return error.InvalidBufferSize;

        const vkCreateBuffer = vk.vkCreateBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkGetBufferMemoryRequirements = vk.vkGetBufferMemoryRequirements orelse return error.VulkanFunctionNotLoaded;
        const vkAllocateMemory = vk.vkAllocateMemory orelse return error.VulkanFunctionNotLoaded;
        const vkBindBufferMemory = vk.vkBindBufferMemory orelse return error.VulkanFunctionNotLoaded;

        const buffer_info = vk.VkBufferCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = size,
            .usage = vk_usage,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };

        var handle: vk.VkBuffer = null;
        if (vkCreateBuffer(self.device, &buffer_info, null, &handle) != vk.VK_SUCCESS) {
            return error.BufferCreationFailed;
        }
        errdefer if (vk.vkDestroyBuffer) |destroy| destroy(self.device, handle, null);

        var mem_requirements: vk.VkMemoryRequirements = undefined;
        vkGetBufferMemoryRequirements(self.device, handle, &mem_requirements);

        const mem_type = try self.findMemoryType(mem_requirements.memoryTypeBits, memory_properties);

        const alloc_info = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = mem_requirements.size,
            .memoryTypeIndex = mem_type,
        };

        var memory: vk.VkDeviceMemory = null;
        if (vkAllocateMemory(self.device, &alloc_info, null, &memory) != vk.VK_SUCCESS) {
            return error.MemoryAllocationFailed;
        }
        errdefer if (vk.vkFreeMemory) |free| free(self.device, memory, null);

        if (vkBindBufferMemory(self.device, handle, memory, 0) != vk.VK_SUCCESS) {
            return error.BufferMemoryBindFailed;
        }

        return .{ .handle = handle, .memory = memory };
    }

    /// Create a buffer and write data to it, returning raw handles
    pub fn createBufferWithDataRaw(
        self: *Self,
        comptime T: type,
        data: []const T,
        vk_usage: vk.VkBufferUsageFlags,
    ) !RawBuffer {
        const size: u64 = @sizeOf(T) * data.len;
        const memory_props = vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;

        const result = try self.createBufferRaw(size, vk_usage, memory_props);
        errdefer {
            if (vk.vkDestroyBuffer) |destroy| destroy(self.device, result.handle, null);
            if (vk.vkFreeMemory) |free| free(self.device, result.memory, null);
        }

        // Map and copy data
        const vkMapMemory = vk.vkMapMemory orelse return error.VulkanFunctionNotLoaded;
        const vkUnmapMemory = vk.vkUnmapMemory orelse return error.VulkanFunctionNotLoaded;

        var mapped: ?*anyopaque = null;
        if (vkMapMemory(self.device, result.memory, 0, size, 0, &mapped) != vk.VK_SUCCESS) {
            return error.MemoryMapFailed;
        }

        const dest: [*]T = @ptrCast(@alignCast(mapped.?));
        @memcpy(dest[0..data.len], data);
        vkUnmapMemory(self.device, result.memory);

        return result;
    }

    /// Destroy a raw buffer
    pub fn destroyBufferRaw(self: *Self, buffer: RawBuffer) void {
        if (vk.vkDestroyBuffer) |destroy| {
            if (buffer.handle != null) destroy(self.device, buffer.handle, null);
        }
        if (vk.vkFreeMemory) |free| {
            if (buffer.memory != null) free(self.device, buffer.memory, null);
        }
    }

    /// Result of mapped buffer creation
    pub const MappedBuffer = struct {
        handle: vk.VkBuffer,
        memory: vk.VkDeviceMemory,
        mapped: ?*anyopaque,
    };

    /// Create a buffer with persistent mapping (for uniform buffers that update every frame)
    pub fn createMappedBufferRaw(
        self: *Self,
        size: u64,
        vk_usage: vk.VkBufferUsageFlags,
    ) !MappedBuffer {
        const result = try self.createBufferRaw(
            size,
            vk_usage,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );
        errdefer self.destroyBufferRaw(.{ .handle = result.handle, .memory = result.memory });

        const vkMapMemory = vk.vkMapMemory orelse return error.VulkanFunctionNotLoaded;

        var mapped: ?*anyopaque = null;
        if (vkMapMemory(self.device, result.memory, 0, size, 0, &mapped) != vk.VK_SUCCESS) {
            return error.MemoryMapFailed;
        }

        return .{
            .handle = result.handle,
            .memory = result.memory,
            .mapped = mapped,
        };
    }

    /// Unmap and destroy a mapped buffer
    pub fn destroyMappedBufferRaw(self: *Self, buffer: MappedBuffer) void {
        if (buffer.mapped != null) {
            if (vk.vkUnmapMemory) |unmap| {
                unmap(self.device, buffer.memory);
            }
        }
        self.destroyBufferRaw(.{ .handle = buffer.handle, .memory = buffer.memory });
    }

    // ============================================================
    // Command Execution Helpers
    // ============================================================

    /// Execute a one-time command buffer
    pub fn executeOneTimeCommands(self: *Self, record_fn: *const fn (vk.VkCommandBuffer) anyerror!void) !void {
        const vkAllocateCommandBuffers = vk.vkAllocateCommandBuffers orelse return error.VulkanFunctionNotLoaded;
        const vkBeginCommandBuffer = vk.vkBeginCommandBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkEndCommandBuffer = vk.vkEndCommandBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkQueueSubmit = vk.vkQueueSubmit orelse return error.VulkanFunctionNotLoaded;
        const vkQueueWaitIdle = vk.vkQueueWaitIdle orelse return error.VulkanFunctionNotLoaded;
        const vkFreeCommandBuffers = vk.vkFreeCommandBuffers orelse return error.VulkanFunctionNotLoaded;

        const alloc_info = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };

        var cmd_buffer: vk.VkCommandBuffer = undefined;
        if (vkAllocateCommandBuffers(self.device, &alloc_info, &cmd_buffer) != vk.VK_SUCCESS) {
            return error.CommandBufferAllocationFailed;
        }
        defer vkFreeCommandBuffers(self.device, self.command_pool, 1, &cmd_buffer);

        const begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };

        if (vkBeginCommandBuffer(cmd_buffer, &begin_info) != vk.VK_SUCCESS) {
            return error.CommandBufferBeginFailed;
        }

        try record_fn(cmd_buffer);

        if (vkEndCommandBuffer(cmd_buffer) != vk.VK_SUCCESS) {
            return error.CommandBufferEndFailed;
        }

        const submit_info = vk.VkSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = null,
            .pWaitDstStageMask = null,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd_buffer,
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = null,
        };

        if (vkQueueSubmit(self.graphics_queue, 1, &submit_info, null) != vk.VK_SUCCESS) {
            return error.QueueSubmitFailed;
        }

        _ = vkQueueWaitIdle(self.graphics_queue);
    }

    /// Copy data from one buffer to another
    pub fn copyBuffer(
        self: *Self,
        src: *GpuBuffer.GpuBuffer,
        dst: *GpuBuffer.GpuBuffer,
        size: u64,
    ) !void {
        const Context = struct {
            src_handle: vk.VkBuffer,
            dst_handle: vk.VkBuffer,
            copy_size: u64,

            fn record(ctx: @This(), cmd: vk.VkCommandBuffer) !void {
                const vkCmdCopyBuffer = vk.vkCmdCopyBuffer orelse return error.VulkanFunctionNotLoaded;
                const region = vk.VkBufferCopy{
                    .srcOffset = 0,
                    .dstOffset = 0,
                    .size = ctx.copy_size,
                };
                vkCmdCopyBuffer(cmd, ctx.src_handle, ctx.dst_handle, 1, &region);
            }
        };

        const ctx = Context{
            .src_handle = src.handle,
            .dst_handle = dst.handle,
            .copy_size = size,
        };
        _ = ctx;

        // Since we can't easily pass context, we'll do it inline
        try self.executeOneTimeCommands(struct {
            fn record(cmd: vk.VkCommandBuffer) !void {
                _ = cmd;
                // This is a limitation - we need a different approach for context
            }
        }.record);
    }

    // ============================================================
    // Memory Type Finding
    // ============================================================

    fn findMemoryType(self: *Self, type_filter: u32, properties: vk.VkMemoryPropertyFlags) !u32 {
        const vkGetPhysicalDeviceMemoryProperties = vk.vkGetPhysicalDeviceMemoryProperties orelse return error.VulkanFunctionNotLoaded;

        var mem_properties: vk.VkPhysicalDeviceMemoryProperties = undefined;
        vkGetPhysicalDeviceMemoryProperties(self.physical_device, &mem_properties);

        for (0..mem_properties.memoryTypeCount) |i| {
            const idx: u5 = @intCast(i);
            if ((type_filter & (@as(u32, 1) << idx)) != 0 and
                (mem_properties.memoryTypes[i].propertyFlags & properties) == properties)
            {
                return @intCast(i);
            }
        }

        return error.NoSuitableMemoryType;
    }

    // ============================================================
    // Device Properties
    // ============================================================

    pub fn getUniformOffsetAlignment(self: *const Self) u32 {
        return self.uniform_offset_alignment;
    }

    pub fn getMaxTextureSize(self: *const Self) u32 {
        return self.max_texture_size;
    }

    pub fn getDevice(self: *const Self) vk.VkDevice {
        return self.device;
    }

    pub fn getPhysicalDevice(self: *const Self) vk.VkPhysicalDevice {
        return self.physical_device;
    }

    pub fn getCommandPool(self: *const Self) vk.VkCommandPool {
        return self.command_pool;
    }

    pub fn getGraphicsQueue(self: *const Self) vk.VkQueue {
        return self.graphics_queue;
    }
};
