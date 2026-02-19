const std = @import("std");
const vk = @import("../../platform/volk.zig");
const ShaderCompiler = @import("ShaderCompiler.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const vk_utils = @import("vk_utils.zig");
const types = @import("types.zig");
const GpuVertex = types.GpuVertex;
const tracy = @import("../../platform/tracy.zig");
pub const TextureManager = @import("TextureManager.zig").TextureManager;
pub const PipelineBuilder = @import("PipelineBuilder.zig").PipelineBuilder;
pub const DebugLines = @import("DebugLines.zig").DebugLines;

pub const MAX_FRAMES_IN_FLIGHT = 2;

pub const RenderState = struct {
    texture_manager: TextureManager,
    pipelines: PipelineBuilder,
    debug_lines: DebugLines,
    // Command buffers and sync
    command_buffers: [MAX_FRAMES_IN_FLIGHT]vk.VkCommandBuffer,
    image_available_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.VkSemaphore,
    in_flight_fences: [MAX_FRAMES_IN_FLIGHT]vk.VkFence,
    current_frame: u32,
    // Vertex/index buffers
    vertex_buffer: vk.VkBuffer,
    vertex_buffer_memory: vk.VkDeviceMemory,
    index_buffer: vk.VkBuffer,
    index_buffer_memory: vk.VkDeviceMemory,
    chunk_index_count: u32,

    pub fn create(allocator: std.mem.Allocator, ctx: *const VulkanContext, swapchain_format: vk.VkFormat) !RenderState {
        const create_zone = tracy.zone(@src(), "RenderState.create");
        defer create_zone.end();

        var shader_compiler = try ShaderCompiler.init(allocator);
        defer shader_compiler.deinit();

        var texture_manager = try TextureManager.init(allocator, ctx);
        errdefer texture_manager.deinit(ctx.device);

        var pipeline_builder = try PipelineBuilder.init(&shader_compiler, ctx, swapchain_format, texture_manager.bindless_descriptor_set_layout);
        errdefer pipeline_builder.deinit(ctx.device);

        var debug_lines = try DebugLines.init(&shader_compiler, ctx, swapchain_format);
        errdefer debug_lines.deinit(ctx.device);

        var self = RenderState{
            .texture_manager = texture_manager,
            .pipelines = pipeline_builder,
            .debug_lines = debug_lines,
            .command_buffers = [_]vk.VkCommandBuffer{null} ** MAX_FRAMES_IN_FLIGHT,
            .image_available_semaphores = [_]vk.VkSemaphore{null} ** MAX_FRAMES_IN_FLIGHT,
            .in_flight_fences = [_]vk.VkFence{null} ** MAX_FRAMES_IN_FLIGHT,
            .current_frame = 0,
            .vertex_buffer = null,
            .vertex_buffer_memory = null,
            .index_buffer = null,
            .index_buffer_memory = null,
            .chunk_index_count = 0,
        };

        try self.createCommandBuffers(ctx);
        try self.createSyncObjects(ctx.device);

        return self;
    }

    pub fn deinit(self: *RenderState, device: vk.VkDevice) void {
        const tz = tracy.zone(@src(), "RenderState.deinit");
        defer tz.end();

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            vk.destroySemaphore(device, self.image_available_semaphores[i], null);
            vk.destroyFence(device, self.in_flight_fences[i], null);
        }

        self.pipelines.deinit(device);
        self.debug_lines.deinit(device);
        self.texture_manager.deinit(device);

        if (self.vertex_buffer != null) {
            vk.destroyBuffer(device, self.vertex_buffer, null);
            vk.freeMemory(device, self.vertex_buffer_memory, null);
        }
        if (self.index_buffer != null) {
            vk.destroyBuffer(device, self.index_buffer, null);
            vk.freeMemory(device, self.index_buffer_memory, null);
        }
    }

    pub fn uploadChunkMesh(
        self: *RenderState,
        ctx: *const VulkanContext,
        vertices: []const GpuVertex,
        indices: []const u32,
        vertex_count: u32,
        index_count: u32,
    ) !void {
        const tz = tracy.zone(@src(), "uploadChunkMesh");
        defer tz.end();

        // Free old buffers if re-uploading
        if (self.vertex_buffer != null) {
            vk.destroyBuffer(ctx.device, self.vertex_buffer, null);
            vk.freeMemory(ctx.device, self.vertex_buffer_memory, null);
        }
        if (self.index_buffer != null) {
            vk.destroyBuffer(ctx.device, self.index_buffer, null);
            vk.freeMemory(ctx.device, self.index_buffer_memory, null);
        }

        // Create vertex buffer via staging
        const vb_size: vk.VkDeviceSize = @intCast(@as(u64, vertex_count) * @sizeOf(GpuVertex));
        {
            var staging_buffer: vk.VkBuffer = undefined;
            var staging_memory: vk.VkDeviceMemory = undefined;
            try vk_utils.createBuffer(
                ctx,
                vb_size,
                vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                &staging_buffer,
                &staging_memory,
            );

            var data: ?*anyopaque = null;
            try vk.mapMemory(ctx.device, staging_memory, 0, vb_size, 0, &data);
            const dst: [*]GpuVertex = @ptrCast(@alignCast(data));
            @memcpy(dst[0..vertex_count], vertices[0..vertex_count]);
            vk.unmapMemory(ctx.device, staging_memory);

            try vk_utils.createBuffer(
                ctx,
                vb_size,
                vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT | vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
                vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
                &self.vertex_buffer,
                &self.vertex_buffer_memory,
            );

            try vk_utils.copyBuffer(ctx, staging_buffer, self.vertex_buffer, vb_size);
            vk.destroyBuffer(ctx.device, staging_buffer, null);
            vk.freeMemory(ctx.device, staging_memory, null);
        }

        // Create index buffer via staging
        const ib_size: vk.VkDeviceSize = @intCast(@as(u64, index_count) * @sizeOf(u32));
        {
            var staging_buffer: vk.VkBuffer = undefined;
            var staging_memory: vk.VkDeviceMemory = undefined;
            try vk_utils.createBuffer(
                ctx,
                ib_size,
                vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                &staging_buffer,
                &staging_memory,
            );

            var data: ?*anyopaque = null;
            try vk.mapMemory(ctx.device, staging_memory, 0, ib_size, 0, &data);
            const dst: [*]u32 = @ptrCast(@alignCast(data));
            @memcpy(dst[0..index_count], indices[0..index_count]);
            vk.unmapMemory(ctx.device, staging_memory);

            try vk_utils.createBuffer(
                ctx,
                ib_size,
                vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT | vk.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
                vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
                &self.index_buffer,
                &self.index_buffer_memory,
            );

            try vk_utils.copyBuffer(ctx, staging_buffer, self.index_buffer, ib_size);
            vk.destroyBuffer(ctx.device, staging_buffer, null);
            vk.freeMemory(ctx.device, staging_memory, null);
        }

        self.chunk_index_count = index_count;

        // Update binding 0 (vertex SSBO) in bindless descriptor set
        self.texture_manager.updateVertexDescriptor(ctx, self.vertex_buffer, vb_size);

        std.log.info("Chunk mesh uploaded ({} vertices, {} indices)", .{ vertex_count, index_count });
    }

    fn createCommandBuffers(self: *RenderState, ctx: *const VulkanContext) !void {
        const tz = tracy.zone(@src(), "createCommandBuffers");
        defer tz.end();

        const alloc_info = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = ctx.command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = MAX_FRAMES_IN_FLIGHT,
        };

        try vk.allocateCommandBuffers(ctx.device, &alloc_info, &self.command_buffers);
        std.log.info("Command buffers allocated ({} frames in flight)", .{MAX_FRAMES_IN_FLIGHT});
    }

    fn createSyncObjects(self: *RenderState, device: vk.VkDevice) !void {
        const tz = tracy.zone(@src(), "createSyncObjects");
        defer tz.end();

        const semaphore_info = vk.VkSemaphoreCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
        };

        const fence_info = vk.VkFenceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .pNext = null,
            .flags = vk.VK_FENCE_CREATE_SIGNALED_BIT,
        };

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            self.image_available_semaphores[i] = try vk.createSemaphore(device, &semaphore_info, null);
            self.in_flight_fences[i] = try vk.createFence(device, &fence_info, null);
        }

        std.log.info("Synchronization objects created", .{});
    }
};
