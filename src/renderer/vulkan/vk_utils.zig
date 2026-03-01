const std = @import("std");
const vk = @import("../../platform/volk.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const tracy = @import("../../platform/tracy.zig");
const gpu_alloc_mod = @import("../../allocators/GpuAllocator.zig");
const GpuAllocator = gpu_alloc_mod.GpuAllocator;
const BufferAllocation = gpu_alloc_mod.BufferAllocation;

pub fn findMemoryType(physical_device: vk.VkPhysicalDevice, type_filter: u32, properties: c_uint) !u32 {
    var mem_properties: vk.VkPhysicalDeviceMemoryProperties = undefined;
    vk.getPhysicalDeviceMemoryProperties(physical_device, &mem_properties);

    for (0..mem_properties.memoryTypeCount) |i| {
        const type_bit = @as(u32, 1) << (std.math.cast(u5, i) orelse unreachable);
        const has_type = (type_filter & type_bit) != 0;
        const has_properties = (mem_properties.memoryTypes[i].propertyFlags & properties) == properties;

        if (has_type and has_properties) {
            return std.math.cast(u32, i) orelse unreachable;
        }
    }

    return error.NoSuitableMemoryType;
}

pub fn createBuffer(
    ctx: *const VulkanContext,
    size: vk.VkDeviceSize,
    usage: c_uint,
    properties: c_uint,
    buffer: *vk.VkBuffer,
    buffer_memory: *vk.VkDeviceMemory,
) !void {
    const tz = tracy.zone(@src(), "createBuffer");
    defer tz.end();

    const buffer_info = vk.VkBufferCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .size = size,
        .usage = usage,
        .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
    };

    buffer.* = try vk.createBuffer(ctx.device, &buffer_info, null);
    errdefer vk.destroyBuffer(ctx.device, buffer.*, null);

    var mem_requirements: vk.VkMemoryRequirements = undefined;
    vk.getBufferMemoryRequirements(ctx.device, buffer.*, &mem_requirements);

    const memory_type_index = try findMemoryType(
        ctx.physical_device,
        mem_requirements.memoryTypeBits,
        properties,
    );

    const alloc_info = vk.VkMemoryAllocateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = mem_requirements.size,
        .memoryTypeIndex = memory_type_index,
    };

    buffer_memory.* = try vk.allocateMemory(ctx.device, &alloc_info, null);
    errdefer vk.freeMemory(ctx.device, buffer_memory.*, null);
    try vk.bindBufferMemory(ctx.device, buffer.*, buffer_memory.*, 0);
}

pub fn copyBuffer(
    ctx: *const VulkanContext,
    src_buffer: vk.VkBuffer,
    dst_buffer: vk.VkBuffer,
    size: vk.VkDeviceSize,
) !void {
    const tz = tracy.zone(@src(), "copyBuffer");
    defer tz.end();

    const alloc_info = vk.VkCommandBufferAllocateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = null,
        .commandPool = ctx.command_pool,
        .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };

    var command_buffers: [1]vk.VkCommandBuffer = undefined;
    try vk.allocateCommandBuffers(ctx.device, &alloc_info, &command_buffers);
    defer vk.freeCommandBuffers(ctx.device, ctx.command_pool, 1, &command_buffers);
    const command_buffer = command_buffers[0];

    const begin_info = vk.VkCommandBufferBeginInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = null,
    };

    try vk.beginCommandBuffer(command_buffer, &begin_info);

    const copy_regions = [_]vk.VkBufferCopy{.{
        .srcOffset = 0,
        .dstOffset = 0,
        .size = size,
    }};

    vk.cmdCopyBuffer(command_buffer, src_buffer, dst_buffer, 1, &copy_regions);
    try vk.endCommandBuffer(command_buffer);

    const submit_infos = [_]vk.VkSubmitInfo{.{
        .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext = null,
        .waitSemaphoreCount = 0,
        .pWaitSemaphores = null,
        .pWaitDstStageMask = null,
        .commandBufferCount = 1,
        .pCommandBuffers = &command_buffer,
        .signalSemaphoreCount = 0,
        .pSignalSemaphores = null,
    }};

    try vk.queueSubmit(ctx.graphics_queue, 1, &submit_infos, null);
    try vk.queueWaitIdle(ctx.graphics_queue);
}

pub fn copyBufferRegion(
    ctx: *const VulkanContext,
    src_buffer: vk.VkBuffer,
    src_offset: vk.VkDeviceSize,
    dst_buffer: vk.VkBuffer,
    dst_offset: vk.VkDeviceSize,
    size: vk.VkDeviceSize,
) !void {
    const tz = tracy.zone(@src(), "copyBufferRegion");
    defer tz.end();

    const alloc_info = vk.VkCommandBufferAllocateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = null,
        .commandPool = ctx.command_pool,
        .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };

    var command_buffers: [1]vk.VkCommandBuffer = undefined;
    try vk.allocateCommandBuffers(ctx.device, &alloc_info, &command_buffers);
    defer vk.freeCommandBuffers(ctx.device, ctx.command_pool, 1, &command_buffers);
    const command_buffer = command_buffers[0];

    const begin_info = vk.VkCommandBufferBeginInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = null,
    };

    try vk.beginCommandBuffer(command_buffer, &begin_info);

    const copy_regions = [_]vk.VkBufferCopy{.{
        .srcOffset = src_offset,
        .dstOffset = dst_offset,
        .size = size,
    }};

    vk.cmdCopyBuffer(command_buffer, src_buffer, dst_buffer, 1, &copy_regions);
    try vk.endCommandBuffer(command_buffer);

    const submit_infos = [_]vk.VkSubmitInfo{.{
        .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext = null,
        .waitSemaphoreCount = 0,
        .pWaitSemaphores = null,
        .pWaitDstStageMask = null,
        .commandBufferCount = 1,
        .pCommandBuffers = &command_buffer,
        .signalSemaphoreCount = 0,
        .pSignalSemaphores = null,
    }};

    try vk.queueSubmit(ctx.graphics_queue, 1, &submit_infos, null);
    try vk.queueWaitIdle(ctx.graphics_queue);
}

pub const TransferBatch = struct {
    const MAX_STAGING = 32;

    cmd: vk.VkCommandBuffer,
    ctx: *const VulkanContext,
    gpu_alloc: *GpuAllocator,
    staging_allocs: [MAX_STAGING]BufferAllocation = undefined,
    staging_count: u32 = 0,
    has_commands: bool = false,

    pub fn begin(ctx: *const VulkanContext, gpu_alloc: *GpuAllocator) !TransferBatch {
        const cb_alloc_info = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = ctx.command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };

        var cmd_buffers: [1]vk.VkCommandBuffer = undefined;
        try vk.allocateCommandBuffers(ctx.device, &cb_alloc_info, &cmd_buffers);
        errdefer vk.freeCommandBuffers(ctx.device, ctx.command_pool, 1, &cmd_buffers);

        try vk.beginCommandBuffer(cmd_buffers[0], &.{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        });

        return .{ .cmd = cmd_buffers[0], .ctx = ctx, .gpu_alloc = gpu_alloc };
    }

    pub fn allocStaging(self: *TransferBatch, size: vk.VkDeviceSize) !BufferAllocation {
        const alloc = try self.gpu_alloc.createBuffer(size, vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT, .staging);
        self.staging_allocs[self.staging_count] = alloc;
        self.staging_count += 1;
        return alloc;
    }

    pub fn copyRegion(
        self: *TransferBatch,
        src: vk.VkBuffer,
        src_offset: vk.VkDeviceSize,
        dst: vk.VkBuffer,
        dst_offset: vk.VkDeviceSize,
        size: vk.VkDeviceSize,
    ) void {
        const regions = [_]vk.VkBufferCopy{.{
            .srcOffset = src_offset,
            .dstOffset = dst_offset,
            .size = size,
        }};
        vk.cmdCopyBuffer(self.cmd, src, dst, 1, &regions);
        self.has_commands = true;
    }

    pub fn submitAndWait(self: *TransferBatch) !void {
        defer {
            const cmds = [1]vk.VkCommandBuffer{self.cmd};
            vk.freeCommandBuffers(self.ctx.device, self.ctx.command_pool, 1, &cmds);
            for (0..self.staging_count) |i| {
                self.gpu_alloc.destroyBuffer(self.staging_allocs[i]);
            }
        }

        if (!self.has_commands) return;

        try vk.endCommandBuffer(self.cmd);

        const submit_infos = [_]vk.VkSubmitInfo{.{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = null,
            .pWaitDstStageMask = null,
            .commandBufferCount = 1,
            .pCommandBuffers = &self.cmd,
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = null,
        }};

        try vk.queueSubmit(self.ctx.graphics_queue, 1, &submit_infos, null);
        try vk.queueWaitIdle(self.ctx.graphics_queue);
    }
};
