const std = @import("std");
const vk = @import("../../platform/volk.zig");
const c = @import("../../platform/c.zig").c;
const ShaderCompiler = @import("ShaderCompiler.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const vk_utils = @import("vk_utils.zig");
const types = @import("types.zig");
const GpuVertex = types.GpuVertex;
const LineVertex = types.LineVertex;
const WorldState = @import("../../world/WorldState.zig");
const app_config = @import("../../app_config.zig");
const tracy = @import("../../platform/tracy.zig");

const MAX_FRAMES_IN_FLIGHT = 2;
const MAX_TEXTURES = 256;
const DEBUG_LINE_MAX_VERTICES = 16384;

const CHUNK_SIZE = WorldState.CHUNK_SIZE;
const WORLD_CHUNKS_X = WorldState.WORLD_CHUNKS_X;
const WORLD_CHUNKS_Y = WorldState.WORLD_CHUNKS_Y;
const WORLD_CHUNKS_Z = WorldState.WORLD_CHUNKS_Z;
const WORLD_SIZE_X = WorldState.WORLD_SIZE_X;
const WORLD_SIZE_Y = WorldState.WORLD_SIZE_Y;
const WORLD_SIZE_Z = WorldState.WORLD_SIZE_Z;

pub const RenderState = struct {
    // Texture system
    texture_image: vk.VkImage,
    texture_image_memory: vk.VkDeviceMemory,
    texture_image_view: vk.VkImageView,
    texture_sampler: vk.VkSampler,
    // Bindless descriptors (graphics)
    bindless_descriptor_set_layout: vk.VkDescriptorSetLayout,
    bindless_descriptor_pool: vk.VkDescriptorPool,
    bindless_descriptor_set: vk.VkDescriptorSet,
    // Graphics pipeline
    pipeline_layout: vk.VkPipelineLayout,
    graphics_pipeline: vk.VkPipeline,
    // Compute pipeline (culling)
    descriptor_set_layout: vk.VkDescriptorSetLayout,
    descriptor_pool: vk.VkDescriptorPool,
    descriptor_set: vk.VkDescriptorSet,
    compute_pipeline_layout: vk.VkPipelineLayout,
    compute_pipeline: vk.VkPipeline,
    indirect_buffer: vk.VkBuffer,
    indirect_buffer_memory: vk.VkDeviceMemory,
    indirect_count_buffer: vk.VkBuffer,
    indirect_count_buffer_memory: vk.VkDeviceMemory,
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
    // Debug line rendering
    debug_line_pipeline: vk.VkPipeline,
    debug_line_pipeline_layout: vk.VkPipelineLayout,
    debug_line_compute_pipeline: vk.VkPipeline,
    debug_line_compute_pipeline_layout: vk.VkPipelineLayout,
    debug_line_descriptor_set_layout: vk.VkDescriptorSetLayout,
    debug_line_descriptor_pool: vk.VkDescriptorPool,
    debug_line_descriptor_set: vk.VkDescriptorSet,
    debug_line_compute_descriptor_set_layout: vk.VkDescriptorSetLayout,
    debug_line_compute_descriptor_pool: vk.VkDescriptorPool,
    debug_line_compute_descriptor_set: vk.VkDescriptorSet,
    debug_line_vertex_buffer: vk.VkBuffer,
    debug_line_vertex_buffer_memory: vk.VkDeviceMemory,
    debug_line_indirect_buffer: vk.VkBuffer,
    debug_line_indirect_buffer_memory: vk.VkDeviceMemory,
    debug_line_count_buffer: vk.VkBuffer,
    debug_line_count_buffer_memory: vk.VkDeviceMemory,
    debug_line_vertex_count: u32,

    pub fn create(allocator: std.mem.Allocator, ctx: *const VulkanContext, swapchain_format: vk.VkFormat) !RenderState {
        const create_zone = tracy.zone(@src(), "RenderState.create");
        defer create_zone.end();

        var self = RenderState{
            .texture_image = null,
            .texture_image_memory = null,
            .texture_image_view = null,
            .texture_sampler = null,
            .bindless_descriptor_set_layout = null,
            .bindless_descriptor_pool = null,
            .bindless_descriptor_set = null,
            .pipeline_layout = null,
            .graphics_pipeline = null,
            .descriptor_set_layout = null,
            .descriptor_pool = null,
            .descriptor_set = null,
            .compute_pipeline_layout = null,
            .compute_pipeline = null,
            .indirect_buffer = null,
            .indirect_buffer_memory = null,
            .indirect_count_buffer = null,
            .indirect_count_buffer_memory = null,
            .command_buffers = [_]vk.VkCommandBuffer{null} ** MAX_FRAMES_IN_FLIGHT,
            .image_available_semaphores = [_]vk.VkSemaphore{null} ** MAX_FRAMES_IN_FLIGHT,
            .in_flight_fences = [_]vk.VkFence{null} ** MAX_FRAMES_IN_FLIGHT,
            .current_frame = 0,
            .vertex_buffer = null,
            .vertex_buffer_memory = null,
            .index_buffer = null,
            .index_buffer_memory = null,
            .chunk_index_count = 0,
            .debug_line_pipeline = null,
            .debug_line_pipeline_layout = null,
            .debug_line_compute_pipeline = null,
            .debug_line_compute_pipeline_layout = null,
            .debug_line_descriptor_set_layout = null,
            .debug_line_descriptor_pool = null,
            .debug_line_descriptor_set = null,
            .debug_line_compute_descriptor_set_layout = null,
            .debug_line_compute_descriptor_pool = null,
            .debug_line_compute_descriptor_set = null,
            .debug_line_vertex_buffer = null,
            .debug_line_vertex_buffer_memory = null,
            .debug_line_indirect_buffer = null,
            .debug_line_indirect_buffer_memory = null,
            .debug_line_count_buffer = null,
            .debug_line_count_buffer_memory = null,
            .debug_line_vertex_count = 0,
        };

        var shader_compiler = try ShaderCompiler.init(allocator);
        defer shader_compiler.deinit();

        try self.createTextureImage(allocator, ctx);
        try self.createBindlessDescriptorSet(ctx);
        try self.createGraphicsPipeline(&shader_compiler, ctx.device, swapchain_format);
        try self.createIndirectBuffer(ctx);
        try self.createComputePipeline(&shader_compiler, ctx);
        try self.createDebugLineResources(ctx);
        try self.createDebugLinePipeline(&shader_compiler, ctx.device, swapchain_format);
        try self.createDebugLineComputePipeline(&shader_compiler, ctx);
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

        vk.destroyPipeline(device, self.compute_pipeline, null);
        vk.destroyPipelineLayout(device, self.compute_pipeline_layout, null);
        vk.destroyDescriptorPool(device, self.descriptor_pool, null);
        vk.destroyDescriptorSetLayout(device, self.descriptor_set_layout, null);

        vk.destroyBuffer(device, self.indirect_buffer, null);
        vk.freeMemory(device, self.indirect_buffer_memory, null);
        vk.destroyBuffer(device, self.indirect_count_buffer, null);
        vk.freeMemory(device, self.indirect_count_buffer_memory, null);

        // Destroy debug line resources
        vk.destroyPipeline(device, self.debug_line_compute_pipeline, null);
        vk.destroyPipelineLayout(device, self.debug_line_compute_pipeline_layout, null);
        vk.destroyDescriptorPool(device, self.debug_line_compute_descriptor_pool, null);
        vk.destroyDescriptorSetLayout(device, self.debug_line_compute_descriptor_set_layout, null);
        vk.destroyPipeline(device, self.debug_line_pipeline, null);
        vk.destroyPipelineLayout(device, self.debug_line_pipeline_layout, null);
        vk.destroyDescriptorPool(device, self.debug_line_descriptor_pool, null);
        vk.destroyDescriptorSetLayout(device, self.debug_line_descriptor_set_layout, null);
        vk.destroyBuffer(device, self.debug_line_vertex_buffer, null);
        vk.freeMemory(device, self.debug_line_vertex_buffer_memory, null);
        vk.destroyBuffer(device, self.debug_line_indirect_buffer, null);
        vk.freeMemory(device, self.debug_line_indirect_buffer_memory, null);
        vk.destroyBuffer(device, self.debug_line_count_buffer, null);
        vk.freeMemory(device, self.debug_line_count_buffer_memory, null);

        // Destroy bindless descriptor resources
        vk.destroyDescriptorPool(device, self.bindless_descriptor_pool, null);
        vk.destroyDescriptorSetLayout(device, self.bindless_descriptor_set_layout, null);

        // Destroy texture resources
        vk.destroySampler(device, self.texture_sampler, null);
        vk.destroyImageView(device, self.texture_image_view, null);
        vk.destroyImage(device, self.texture_image, null);
        vk.freeMemory(device, self.texture_image_memory, null);

        if (self.vertex_buffer != null) {
            vk.destroyBuffer(device, self.vertex_buffer, null);
            vk.freeMemory(device, self.vertex_buffer_memory, null);
        }
        if (self.index_buffer != null) {
            vk.destroyBuffer(device, self.index_buffer, null);
            vk.freeMemory(device, self.index_buffer_memory, null);
        }

        vk.destroyPipeline(device, self.graphics_pipeline, null);
        vk.destroyPipelineLayout(device, self.pipeline_layout, null);
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
        const vertex_buffer_info = vk.VkDescriptorBufferInfo{
            .buffer = self.vertex_buffer,
            .offset = 0,
            .range = vb_size,
        };

        const descriptor_write = vk.VkWriteDescriptorSet{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = self.bindless_descriptor_set,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = &vertex_buffer_info,
            .pTexelBufferView = null,
        };

        vk.updateDescriptorSets(ctx.device, 1, &[_]vk.VkWriteDescriptorSet{descriptor_write}, 0, null);

        std.log.info("Chunk mesh uploaded ({} vertices, {} indices)", .{ vertex_count, index_count });
    }

    fn createTextureImage(self: *RenderState, allocator: std.mem.Allocator, ctx: *const VulkanContext) !void {
        const tz = tracy.zone(@src(), "createTextureImage");
        defer tz.end();

        const base_path = try app_config.getAppDataPath(allocator);
        defer allocator.free(base_path);

        const sep = std.fs.path.sep_str;
        const texture_path = try std.fmt.allocPrintSentinel(allocator, "{s}" ++ sep ++ "assets" ++ sep ++ "farhorizons" ++ sep ++ "textures" ++ sep ++ "block" ++ sep ++ "glass.png", .{base_path}, 0);
        defer allocator.free(texture_path);

        var tex_width: c_int = 0;
        var tex_height: c_int = 0;
        var tex_channels: c_int = 0;
        const pixels = c.stbi_load(texture_path.ptr, &tex_width, &tex_height, &tex_channels, 4) orelse {
            std.log.err("Failed to load texture image from {s}", .{texture_path});
            return error.TextureLoadFailed;
        };
        defer c.stbi_image_free(pixels);

        const image_size: vk.VkDeviceSize = @intCast(@as(u64, @intCast(tex_width)) * @as(u64, @intCast(tex_height)) * 4);

        // Create staging buffer
        var staging_buffer: vk.VkBuffer = undefined;
        var staging_buffer_memory: vk.VkDeviceMemory = undefined;
        try vk_utils.createBuffer(
            ctx,
            image_size,
            vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &staging_buffer,
            &staging_buffer_memory,
        );

        var data: ?*anyopaque = null;
        try vk.mapMemory(ctx.device, staging_buffer_memory, 0, image_size, 0, &data);
        const dst: [*]u8 = @ptrCast(data.?);
        const src: [*]const u8 = @ptrCast(pixels);
        @memcpy(dst[0..@intCast(image_size)], src[0..@intCast(image_size)]);
        vk.unmapMemory(ctx.device, staging_buffer_memory);

        // Create the texture image
        const image_info = vk.VkImageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = vk.VK_IMAGE_TYPE_2D,
            .format = vk.VK_FORMAT_R8G8B8A8_SRGB,
            .extent = .{
                .width = @intCast(tex_width),
                .height = @intCast(tex_height),
                .depth = 1,
            },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
            .usage = vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT | vk.VK_IMAGE_USAGE_SAMPLED_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        };

        self.texture_image = try vk.createImage(ctx.device, &image_info, null);

        var mem_requirements: vk.VkMemoryRequirements = undefined;
        vk.getImageMemoryRequirements(ctx.device, self.texture_image, &mem_requirements);

        const memory_type_index = try vk_utils.findMemoryType(
            ctx.physical_device,
            mem_requirements.memoryTypeBits,
            vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        );

        const alloc_info = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = mem_requirements.size,
            .memoryTypeIndex = memory_type_index,
        };

        self.texture_image_memory = try vk.allocateMemory(ctx.device, &alloc_info, null);
        try vk.bindImageMemory(ctx.device, self.texture_image, self.texture_image_memory, 0);

        // Transition + copy via one-time command buffer
        const cmd_alloc_info = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = ctx.command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };

        var cmd_buffers: [1]vk.VkCommandBuffer = undefined;
        try vk.allocateCommandBuffers(ctx.device, &cmd_alloc_info, &cmd_buffers);
        const cmd = cmd_buffers[0];

        const cmd_begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };
        try vk.beginCommandBuffer(cmd, &cmd_begin_info);

        // Barrier: UNDEFINED -> TRANSFER_DST_OPTIMAL
        const to_transfer_barrier = vk.VkImageMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = 0,
            .dstAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = self.texture_image,
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        vk.cmdPipelineBarrier(
            cmd,
            vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &[_]vk.VkImageMemoryBarrier{to_transfer_barrier},
        );

        // Copy buffer to image
        const region = vk.VkBufferImageCopy{
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{
                .width = @intCast(tex_width),
                .height = @intCast(tex_height),
                .depth = 1,
            },
        };

        vk.cmdCopyBufferToImage(
            cmd,
            staging_buffer,
            self.texture_image,
            vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1,
            &[_]vk.VkBufferImageCopy{region},
        );

        // Barrier: TRANSFER_DST -> SHADER_READ_ONLY_OPTIMAL
        const to_shader_barrier = vk.VkImageMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = self.texture_image,
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        vk.cmdPipelineBarrier(
            cmd,
            vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &[_]vk.VkImageMemoryBarrier{to_shader_barrier},
        );

        try vk.endCommandBuffer(cmd);

        const submit_infos = [_]vk.VkSubmitInfo{.{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = null,
            .pWaitDstStageMask = null,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd,
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = null,
        }};

        try vk.queueSubmit(ctx.graphics_queue, 1, &submit_infos, null);
        try vk.queueWaitIdle(ctx.graphics_queue);
        vk.freeCommandBuffers(ctx.device, ctx.command_pool, 1, &cmd_buffers);

        // Clean up staging buffer
        vk.destroyBuffer(ctx.device, staging_buffer, null);
        vk.freeMemory(ctx.device, staging_buffer_memory, null);

        // Create image view
        const view_info = vk.VkImageViewCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = self.texture_image,
            .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
            .format = vk.VK_FORMAT_R8G8B8A8_SRGB,
            .components = .{
                .r = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        self.texture_image_view = try vk.createImageView(ctx.device, &view_info, null);

        // Create sampler (nearest for pixel-art style)
        const sampler_info = vk.VkSamplerCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .magFilter = vk.VK_FILTER_NEAREST,
            .minFilter = vk.VK_FILTER_NEAREST,
            .mipmapMode = vk.VK_SAMPLER_MIPMAP_MODE_NEAREST,
            .addressModeU = vk.VK_SAMPLER_ADDRESS_MODE_REPEAT,
            .addressModeV = vk.VK_SAMPLER_ADDRESS_MODE_REPEAT,
            .addressModeW = vk.VK_SAMPLER_ADDRESS_MODE_REPEAT,
            .mipLodBias = 0.0,
            .anisotropyEnable = vk.VK_FALSE,
            .maxAnisotropy = 1.0,
            .compareEnable = vk.VK_FALSE,
            .compareOp = 0,
            .minLod = 0.0,
            .maxLod = 0.0,
            .borderColor = vk.VK_BORDER_COLOR_INT_OPAQUE_BLACK,
            .unnormalizedCoordinates = vk.VK_FALSE,
        };

        self.texture_sampler = try vk.createSampler(ctx.device, &sampler_info, null);
        std.log.info("Texture image created ({}x{})", .{ tex_width, tex_height });
    }

    fn createChunkBuffers(self: *RenderState, allocator: std.mem.Allocator, ctx: *const VulkanContext) !void {
        const tz = tracy.zone(@src(), "createChunkBuffers");
        defer tz.end();

        const world = comptime WorldState.generateSphereWorld();
        const mesh = try WorldState.generateWorldMesh(allocator, &world);
        defer allocator.free(mesh.vertices);
        defer allocator.free(mesh.indices);

        self.chunk_index_count = mesh.index_count;

        // Create vertex buffer via staging (allocate at actual size)
        const vb_actual_size: vk.VkDeviceSize = @intCast(mesh.vertex_count * @sizeOf(GpuVertex));
        {
            var staging_buffer: vk.VkBuffer = undefined;
            var staging_memory: vk.VkDeviceMemory = undefined;
            try vk_utils.createBuffer(
                ctx,
                vb_actual_size,
                vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                &staging_buffer,
                &staging_memory,
            );

            var data: ?*anyopaque = null;
            try vk.mapMemory(ctx.device, staging_memory, 0, vb_actual_size, 0, &data);
            const dst: [*]GpuVertex = @ptrCast(@alignCast(data));
            @memcpy(dst[0..mesh.vertex_count], mesh.vertices[0..mesh.vertex_count]);
            vk.unmapMemory(ctx.device, staging_memory);

            try vk_utils.createBuffer(
                ctx,
                vb_actual_size,
                vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT | vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
                vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
                &self.vertex_buffer,
                &self.vertex_buffer_memory,
            );

            try vk_utils.copyBuffer(ctx, staging_buffer, self.vertex_buffer, vb_actual_size);
            vk.destroyBuffer(ctx.device, staging_buffer, null);
            vk.freeMemory(ctx.device, staging_memory, null);
        }

        // Create index buffer via staging (allocate at actual size)
        const ib_actual_size: vk.VkDeviceSize = @intCast(mesh.index_count * @sizeOf(u32));
        {
            var staging_buffer: vk.VkBuffer = undefined;
            var staging_memory: vk.VkDeviceMemory = undefined;
            try vk_utils.createBuffer(
                ctx,
                ib_actual_size,
                vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                &staging_buffer,
                &staging_memory,
            );

            var data: ?*anyopaque = null;
            try vk.mapMemory(ctx.device, staging_memory, 0, ib_actual_size, 0, &data);
            const dst: [*]u32 = @ptrCast(@alignCast(data));
            @memcpy(dst[0..mesh.index_count], mesh.indices[0..mesh.index_count]);
            vk.unmapMemory(ctx.device, staging_memory);

            try vk_utils.createBuffer(
                ctx,
                ib_actual_size,
                vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT | vk.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
                vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
                &self.index_buffer,
                &self.index_buffer_memory,
            );

            try vk_utils.copyBuffer(ctx, staging_buffer, self.index_buffer, ib_actual_size);
            vk.destroyBuffer(ctx.device, staging_buffer, null);
            vk.freeMemory(ctx.device, staging_memory, null);
        }

        std.log.info("Chunk buffers created ({} vertices, {} indices)", .{ mesh.vertex_count, mesh.index_count });
    }

    fn createBindlessDescriptorSet(self: *RenderState, ctx: *const VulkanContext) !void {
        const tz = tracy.zone(@src(), "createBindlessDescriptorSet");
        defer tz.end();

        // Layout: binding 0 = SSBO (vertex buffer), binding 1 = sampler2D array
        const bindings = [_]vk.VkDescriptorSetLayoutBinding{
            .{
                .binding = 0,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
                .pImmutableSamplers = null,
            },
            .{
                .binding = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .descriptorCount = MAX_TEXTURES,
                .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
                .pImmutableSamplers = null,
            },
        };

        // Binding flags: binding 0 = UPDATE_AFTER_BIND, binding 1 = PARTIALLY_BOUND | VARIABLE_COUNT | UPDATE_AFTER_BIND
        const binding_flags = [_]c.VkDescriptorBindingFlags{
            vk.VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT,
            vk.VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT |
                vk.VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT |
                vk.VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT,
        };

        const binding_flags_info = vk.VkDescriptorSetLayoutBindingFlagsCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
            .pNext = null,
            .bindingCount = bindings.len,
            .pBindingFlags = &binding_flags,
        };

        const layout_info = vk.VkDescriptorSetLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pNext = &binding_flags_info,
            .flags = vk.VK_DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT,
            .bindingCount = bindings.len,
            .pBindings = &bindings,
        };

        self.bindless_descriptor_set_layout = try vk.createDescriptorSetLayout(ctx.device, &layout_info, null);

        // Pool
        const pool_sizes = [_]vk.VkDescriptorPoolSize{
            .{
                .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1,
            },
            .{
                .type = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .descriptorCount = MAX_TEXTURES,
            },
        };

        const pool_info = vk.VkDescriptorPoolCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .pNext = null,
            .flags = vk.VK_DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT,
            .maxSets = 1,
            .poolSizeCount = pool_sizes.len,
            .pPoolSizes = &pool_sizes,
        };

        self.bindless_descriptor_pool = try vk.createDescriptorPool(ctx.device, &pool_info, null);

        // Allocate with variable descriptor count
        const actual_texture_count: u32 = 1;
        const variable_count_info = vk.VkDescriptorSetVariableDescriptorCountAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO,
            .pNext = null,
            .descriptorSetCount = 1,
            .pDescriptorCounts = &actual_texture_count,
        };

        const alloc_info = vk.VkDescriptorSetAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = &variable_count_info,
            .descriptorPool = self.bindless_descriptor_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &self.bindless_descriptor_set_layout,
        };

        var descriptor_sets: [1]vk.VkDescriptorSet = undefined;
        try vk.allocateDescriptorSets(ctx.device, &alloc_info, &descriptor_sets);
        self.bindless_descriptor_set = descriptor_sets[0];

        // Write texture descriptor only (binding 1) — vertex SSBO (binding 0) is written later by uploadChunkMesh
        const texture_image_info = vk.VkDescriptorImageInfo{
            .sampler = self.texture_sampler,
            .imageView = self.texture_image_view,
            .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };

        const descriptor_writes = [_]vk.VkWriteDescriptorSet{
            .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = self.bindless_descriptor_set,
                .dstBinding = 1,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .pImageInfo = &texture_image_info,
                .pBufferInfo = null,
                .pTexelBufferView = null,
            },
        };

        vk.updateDescriptorSets(ctx.device, descriptor_writes.len, &descriptor_writes, 0, null);
        std.log.info("Bindless descriptor set created", .{});
    }

    fn createGraphicsPipeline(self: *RenderState, shader_compiler: *ShaderCompiler, device: vk.VkDevice, swapchain_format: vk.VkFormat) !void {
        const tz = tracy.zone(@src(), "createGraphicsPipeline");
        defer tz.end();

        const vert_spirv = try shader_compiler.compile("test.vert", .vertex);
        defer shader_compiler.allocator.free(vert_spirv);

        const frag_spirv = try shader_compiler.compile("test.frag", .fragment);
        defer shader_compiler.allocator.free(frag_spirv);

        const vert_module_info = vk.VkShaderModuleCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = vert_spirv.len,
            .pCode = @ptrCast(@alignCast(vert_spirv.ptr)),
        };

        const frag_module_info = vk.VkShaderModuleCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = frag_spirv.len,
            .pCode = @ptrCast(@alignCast(frag_spirv.ptr)),
        };

        const vert_module = try vk.createShaderModule(device, &vert_module_info, null);
        defer vk.destroyShaderModule(device, vert_module, null);

        const frag_module = try vk.createShaderModule(device, &frag_module_info, null);
        defer vk.destroyShaderModule(device, frag_module, null);

        const vert_stage_info = vk.VkPipelineShaderStageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = vk.VK_SHADER_STAGE_VERTEX_BIT,
            .module = vert_module,
            .pName = "main",
            .pSpecializationInfo = null,
        };

        const frag_stage_info = vk.VkPipelineShaderStageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .module = frag_module,
            .pName = "main",
            .pSpecializationInfo = null,
        };

        const shader_stages = [_]vk.VkPipelineShaderStageCreateInfo{ vert_stage_info, frag_stage_info };

        // Empty vertex input -- vertex pulling from SSBO
        const vertex_input_info = vk.VkPipelineVertexInputStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .vertexBindingDescriptionCount = 0,
            .pVertexBindingDescriptions = null,
            .vertexAttributeDescriptionCount = 0,
            .pVertexAttributeDescriptions = null,
        };

        const input_assembly = vk.VkPipelineInputAssemblyStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .primitiveRestartEnable = vk.VK_FALSE,
        };

        const viewport_state = vk.VkPipelineViewportStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .viewportCount = 1,
            .pViewports = null,
            .scissorCount = 1,
            .pScissors = null,
        };

        const rasterizer = vk.VkPipelineRasterizationStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthClampEnable = vk.VK_FALSE,
            .rasterizerDiscardEnable = vk.VK_FALSE,
            .polygonMode = vk.VK_POLYGON_MODE_FILL,
            .cullMode = vk.VK_CULL_MODE_BACK_BIT,
            .frontFace = vk.VK_FRONT_FACE_COUNTER_CLOCKWISE,
            .depthBiasEnable = vk.VK_FALSE,
            .depthBiasConstantFactor = 0.0,
            .depthBiasClamp = 0.0,
            .depthBiasSlopeFactor = 0.0,
            .lineWidth = 1.0,
        };

        const multisampling = vk.VkPipelineMultisampleStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .rasterizationSamples = vk.VK_SAMPLE_COUNT_1_BIT,
            .sampleShadingEnable = vk.VK_FALSE,
            .minSampleShading = 1.0,
            .pSampleMask = null,
            .alphaToCoverageEnable = vk.VK_FALSE,
            .alphaToOneEnable = vk.VK_FALSE,
        };

        const depth_stencil = vk.VkPipelineDepthStencilStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthTestEnable = vk.VK_TRUE,
            .depthWriteEnable = vk.VK_TRUE,
            .depthCompareOp = vk.VK_COMPARE_OP_LESS,
            .depthBoundsTestEnable = vk.VK_FALSE,
            .stencilTestEnable = vk.VK_FALSE,
            .front = std.mem.zeroes(vk.VkStencilOpState),
            .back = std.mem.zeroes(vk.VkStencilOpState),
            .minDepthBounds = 0.0,
            .maxDepthBounds = 1.0,
        };

        const color_blend_attachment = vk.VkPipelineColorBlendAttachmentState{
            .blendEnable = vk.VK_TRUE,
            .srcColorBlendFactor = vk.VK_BLEND_FACTOR_SRC_ALPHA,
            .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .colorBlendOp = vk.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ZERO,
            .alphaBlendOp = vk.VK_BLEND_OP_ADD,
            .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT | vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT,
        };

        const color_blending = vk.VkPipelineColorBlendStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .logicOpEnable = vk.VK_FALSE,
            .logicOp = 0,
            .attachmentCount = 1,
            .pAttachments = &color_blend_attachment,
            .blendConstants = .{ 0.0, 0.0, 0.0, 0.0 },
        };

        const push_constant_range = vk.VkPushConstantRange{
            .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
            .offset = 0,
            .size = 64, // sizeof(mat4)
        };

        const pipeline_layout_info = vk.VkPipelineLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 1,
            .pSetLayouts = &self.bindless_descriptor_set_layout,
            .pushConstantRangeCount = 1,
            .pPushConstantRanges = &push_constant_range,
        };

        self.pipeline_layout = try vk.createPipelineLayout(device, &pipeline_layout_info, null);

        // Dynamic rendering pipeline info
        const color_attachment_format = [_]vk.VkFormat{swapchain_format};
        const rendering_create_info = vk.VkPipelineRenderingCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
            .pNext = null,
            .viewMask = 0,
            .colorAttachmentCount = 1,
            .pColorAttachmentFormats = &color_attachment_format,
            .depthAttachmentFormat = vk.VK_FORMAT_D32_SFLOAT,
            .stencilAttachmentFormat = vk.VK_FORMAT_UNDEFINED,
        };

        // Dynamic state for viewport and scissor
        const dynamic_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
        const dynamic_state_info = c.VkPipelineDynamicStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .dynamicStateCount = dynamic_states.len,
            .pDynamicStates = &dynamic_states,
        };

        const pipeline_info = vk.VkGraphicsPipelineCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = &rendering_create_info,
            .flags = 0,
            .stageCount = 2,
            .pStages = &shader_stages,
            .pVertexInputState = &vertex_input_info,
            .pInputAssemblyState = &input_assembly,
            .pTessellationState = null,
            .pViewportState = &viewport_state,
            .pRasterizationState = &rasterizer,
            .pMultisampleState = &multisampling,
            .pDepthStencilState = &depth_stencil,
            .pColorBlendState = &color_blending,
            .pDynamicState = &dynamic_state_info,
            .layout = self.pipeline_layout,
            .renderPass = null,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };

        const pipeline_infos = &[_]vk.VkGraphicsPipelineCreateInfo{pipeline_info};
        var pipelines: [1]vk.VkPipeline = undefined;
        try vk.createGraphicsPipelines(device, null, 1, pipeline_infos, null, &pipelines);
        self.graphics_pipeline = pipelines[0];

        std.log.info("Graphics pipeline created", .{});
    }

    fn createIndirectBuffer(self: *RenderState, ctx: *const VulkanContext) !void {
        const tz = tracy.zone(@src(), "createIndirectBuffer");
        defer tz.end();

        const buffer_size = @sizeOf(vk.VkDrawIndexedIndirectCommand);

        try vk_utils.createBuffer(
            ctx,
            buffer_size,
            vk.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT | vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &self.indirect_buffer,
            &self.indirect_buffer_memory,
        );

        var data: ?*anyopaque = null;
        try vk.mapMemory(ctx.device, self.indirect_buffer_memory, 0, buffer_size, 0, &data);
        const draw_ptr: *vk.VkDrawIndexedIndirectCommand = @ptrCast(@alignCast(data));
        draw_ptr.* = std.mem.zeroes(vk.VkDrawIndexedIndirectCommand);
        vk.unmapMemory(ctx.device, self.indirect_buffer_memory);

        const count_buffer_size = @sizeOf(u32);
        const count_buffer_info = vk.VkBufferCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = count_buffer_size,
            .usage = vk.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT | vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };

        self.indirect_count_buffer = try vk.createBuffer(ctx.device, &count_buffer_info, null);

        var count_mem_requirements: vk.VkMemoryRequirements = undefined;
        vk.getBufferMemoryRequirements(ctx.device, self.indirect_count_buffer, &count_mem_requirements);

        const count_memory_type_index = try vk_utils.findMemoryType(
            ctx.physical_device,
            count_mem_requirements.memoryTypeBits,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );

        const count_alloc_info = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = count_mem_requirements.size,
            .memoryTypeIndex = count_memory_type_index,
        };

        self.indirect_count_buffer_memory = try vk.allocateMemory(ctx.device, &count_alloc_info, null);
        try vk.bindBufferMemory(ctx.device, self.indirect_count_buffer, self.indirect_count_buffer_memory, 0);

        var count_data: ?*anyopaque = null;
        try vk.mapMemory(ctx.device, self.indirect_count_buffer_memory, 0, count_buffer_size, 0, &count_data);

        const count_ptr: *u32 = @ptrCast(@alignCast(count_data));
        count_ptr.* = 1;

        vk.unmapMemory(ctx.device, self.indirect_count_buffer_memory);

        std.log.info("Indirect draw buffers created (count buffer for GPU-driven rendering)", .{});
    }

    fn createComputePipeline(self: *RenderState, shader_compiler: *ShaderCompiler, ctx: *const VulkanContext) !void {
        const tz = tracy.zone(@src(), "createComputePipeline");
        defer tz.end();

        const bindings = [_]vk.VkDescriptorSetLayoutBinding{
            .{
                .binding = 0,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_COMPUTE_BIT,
                .pImmutableSamplers = null,
            },
            .{
                .binding = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_COMPUTE_BIT,
                .pImmutableSamplers = null,
            },
        };

        const layout_info = vk.VkDescriptorSetLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .bindingCount = bindings.len,
            .pBindings = &bindings,
        };

        self.descriptor_set_layout = try vk.createDescriptorSetLayout(ctx.device, &layout_info, null);

        const pool_size = vk.VkDescriptorPoolSize{
            .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 2,
        };

        const pool_info = vk.VkDescriptorPoolCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .maxSets = 1,
            .poolSizeCount = 1,
            .pPoolSizes = &pool_size,
        };

        self.descriptor_pool = try vk.createDescriptorPool(ctx.device, &pool_info, null);

        const desc_alloc_info = vk.VkDescriptorSetAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = self.descriptor_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &self.descriptor_set_layout,
        };

        var descriptor_sets: [1]vk.VkDescriptorSet = undefined;
        try vk.allocateDescriptorSets(ctx.device, &desc_alloc_info, &descriptor_sets);
        self.descriptor_set = descriptor_sets[0];

        const draw_buffer_info = vk.VkDescriptorBufferInfo{
            .buffer = self.indirect_buffer,
            .offset = 0,
            .range = @sizeOf(vk.VkDrawIndexedIndirectCommand),
        };

        const count_buffer_info = vk.VkDescriptorBufferInfo{
            .buffer = self.indirect_count_buffer,
            .offset = 0,
            .range = @sizeOf(u32),
        };

        const descriptor_writes = [_]vk.VkWriteDescriptorSet{
            .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = self.descriptor_set,
                .dstBinding = 0,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .pImageInfo = null,
                .pBufferInfo = &draw_buffer_info,
                .pTexelBufferView = null,
            },
            .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = self.descriptor_set,
                .dstBinding = 1,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .pImageInfo = null,
                .pBufferInfo = &count_buffer_info,
                .pTexelBufferView = null,
            },
        };

        vk.updateDescriptorSets(ctx.device, descriptor_writes.len, &descriptor_writes, 0, null);

        const comp_spirv = try shader_compiler.compile("cull.comp", .compute);
        defer shader_compiler.allocator.free(comp_spirv);

        const comp_module_info = vk.VkShaderModuleCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = comp_spirv.len,
            .pCode = @ptrCast(@alignCast(comp_spirv.ptr)),
        };

        const comp_module = try vk.createShaderModule(ctx.device, &comp_module_info, null);
        defer vk.destroyShaderModule(ctx.device, comp_module, null);

        const push_constant_range = vk.VkPushConstantRange{
            .stageFlags = vk.VK_SHADER_STAGE_COMPUTE_BIT,
            .offset = 0,
            .size = @sizeOf(u32) * 2, // objectCount + totalIndexCount
        };

        const compute_layout_info = vk.VkPipelineLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 1,
            .pSetLayouts = &self.descriptor_set_layout,
            .pushConstantRangeCount = 1,
            .pPushConstantRanges = &push_constant_range,
        };

        self.compute_pipeline_layout = try vk.createPipelineLayout(ctx.device, &compute_layout_info, null);

        const compute_stage_info = vk.VkPipelineShaderStageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = vk.VK_SHADER_STAGE_COMPUTE_BIT,
            .module = comp_module,
            .pName = "main",
            .pSpecializationInfo = null,
        };

        const compute_pipeline_info = vk.VkComputePipelineCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = compute_stage_info,
            .layout = self.compute_pipeline_layout,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };

        const pipeline_infos = &[_]vk.VkComputePipelineCreateInfo{compute_pipeline_info};
        var pipelines: [1]vk.VkPipeline = undefined;
        try vk.createComputePipelines(ctx.device, null, 1, pipeline_infos, null, &pipelines);
        self.compute_pipeline = pipelines[0];

        std.log.info("Compute pipeline created", .{});
    }

    fn createDebugLineResources(self: *RenderState, ctx: *const VulkanContext) !void {
        const tz = tracy.zone(@src(), "createDebugLineResources");
        defer tz.end();

        // Vertex SSBO (host-visible for CPU writes)
        const vertex_buffer_size: vk.VkDeviceSize = DEBUG_LINE_MAX_VERTICES * @sizeOf(LineVertex);
        try vk_utils.createBuffer(
            ctx,
            vertex_buffer_size,
            vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &self.debug_line_vertex_buffer,
            &self.debug_line_vertex_buffer_memory,
        );

        // Indirect draw buffer (device-local, written by compute)
        try vk_utils.createBuffer(
            ctx,
            @sizeOf(vk.VkDrawIndirectCommand),
            vk.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT | vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            &self.debug_line_indirect_buffer,
            &self.debug_line_indirect_buffer_memory,
        );

        // Count buffer (host-visible, always 1)
        try vk_utils.createBuffer(
            ctx,
            @sizeOf(u32),
            vk.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &self.debug_line_count_buffer,
            &self.debug_line_count_buffer_memory,
        );
        {
            var data: ?*anyopaque = null;
            try vk.mapMemory(ctx.device, self.debug_line_count_buffer_memory, 0, @sizeOf(u32), 0, &data);
            const count_ptr: *u32 = @ptrCast(@alignCast(data));
            count_ptr.* = 1;
            vk.unmapMemory(ctx.device, self.debug_line_count_buffer_memory);
        }

        // Graphics descriptor set (binding 0 = vertex SSBO)
        {
            const binding = vk.VkDescriptorSetLayoutBinding{
                .binding = 0,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
                .pImmutableSamplers = null,
            };

            const layout_info = vk.VkDescriptorSetLayoutCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .bindingCount = 1,
                .pBindings = &binding,
            };

            self.debug_line_descriptor_set_layout = try vk.createDescriptorSetLayout(ctx.device, &layout_info, null);

            const pool_size = vk.VkDescriptorPoolSize{
                .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1,
            };

            const pool_info = vk.VkDescriptorPoolCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .maxSets = 1,
                .poolSizeCount = 1,
                .pPoolSizes = &pool_size,
            };

            self.debug_line_descriptor_pool = try vk.createDescriptorPool(ctx.device, &pool_info, null);

            const alloc_info = vk.VkDescriptorSetAllocateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
                .pNext = null,
                .descriptorPool = self.debug_line_descriptor_pool,
                .descriptorSetCount = 1,
                .pSetLayouts = &self.debug_line_descriptor_set_layout,
            };

            var sets: [1]vk.VkDescriptorSet = undefined;
            try vk.allocateDescriptorSets(ctx.device, &alloc_info, &sets);
            self.debug_line_descriptor_set = sets[0];

            const buffer_info = vk.VkDescriptorBufferInfo{
                .buffer = self.debug_line_vertex_buffer,
                .offset = 0,
                .range = vertex_buffer_size,
            };

            const write = vk.VkWriteDescriptorSet{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = self.debug_line_descriptor_set,
                .dstBinding = 0,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .pImageInfo = null,
                .pBufferInfo = &buffer_info,
                .pTexelBufferView = null,
            };

            vk.updateDescriptorSets(ctx.device, 1, &[_]vk.VkWriteDescriptorSet{write}, 0, null);
        }

        // Compute descriptor set (binding 0 = indirect draw command SSBO)
        {
            const binding = vk.VkDescriptorSetLayoutBinding{
                .binding = 0,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_COMPUTE_BIT,
                .pImmutableSamplers = null,
            };

            const layout_info = vk.VkDescriptorSetLayoutCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .bindingCount = 1,
                .pBindings = &binding,
            };

            self.debug_line_compute_descriptor_set_layout = try vk.createDescriptorSetLayout(ctx.device, &layout_info, null);

            const pool_size = vk.VkDescriptorPoolSize{
                .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1,
            };

            const pool_info = vk.VkDescriptorPoolCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .maxSets = 1,
                .poolSizeCount = 1,
                .pPoolSizes = &pool_size,
            };

            self.debug_line_compute_descriptor_pool = try vk.createDescriptorPool(ctx.device, &pool_info, null);

            const alloc_info = vk.VkDescriptorSetAllocateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
                .pNext = null,
                .descriptorPool = self.debug_line_compute_descriptor_pool,
                .descriptorSetCount = 1,
                .pSetLayouts = &self.debug_line_compute_descriptor_set_layout,
            };

            var sets: [1]vk.VkDescriptorSet = undefined;
            try vk.allocateDescriptorSets(ctx.device, &alloc_info, &sets);
            self.debug_line_compute_descriptor_set = sets[0];

            const buffer_info = vk.VkDescriptorBufferInfo{
                .buffer = self.debug_line_indirect_buffer,
                .offset = 0,
                .range = @sizeOf(vk.VkDrawIndirectCommand),
            };

            const write = vk.VkWriteDescriptorSet{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = self.debug_line_compute_descriptor_set,
                .dstBinding = 0,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .pImageInfo = null,
                .pBufferInfo = &buffer_info,
                .pTexelBufferView = null,
            };

            vk.updateDescriptorSets(ctx.device, 1, &[_]vk.VkWriteDescriptorSet{write}, 0, null);
        }

        // Fill vertex buffer with chunk outlines
        self.generateChunkOutlines(ctx.device);

        std.log.info("Debug line resources created ({} vertices)", .{self.debug_line_vertex_count});
    }

    fn generateChunkOutlines(self: *RenderState, device: vk.VkDevice) void {
        const tz = tracy.zone(@src(), "generateChunkOutlines");
        defer tz.end();

        const half_world_x: f32 = @as(f32, WORLD_SIZE_X) / 2.0;
        const half_world_y: f32 = @as(f32, WORLD_SIZE_Y) / 2.0;
        const half_world_z: f32 = @as(f32, WORLD_SIZE_Z) / 2.0;

        var data: ?*anyopaque = null;
        vk.mapMemory(device, self.debug_line_vertex_buffer_memory, 0, DEBUG_LINE_MAX_VERTICES * @sizeOf(LineVertex), 0, &data) catch return;
        const vertices: [*]LineVertex = @ptrCast(@alignCast(data));

        var count: u32 = 0;

        for (0..WORLD_CHUNKS_Y) |cy| {
            for (0..WORLD_CHUNKS_Z) |cz| {
                for (0..WORLD_CHUNKS_X) |cx| {
                    const min_x: f32 = @as(f32, @floatFromInt(cx * CHUNK_SIZE)) - half_world_x;
                    const min_y: f32 = @as(f32, @floatFromInt(cy * CHUNK_SIZE)) - half_world_y;
                    const min_z: f32 = @as(f32, @floatFromInt(cz * CHUNK_SIZE)) - half_world_z;
                    const max_x: f32 = min_x + CHUNK_SIZE;
                    const max_y: f32 = min_y + CHUNK_SIZE;
                    const max_z: f32 = min_z + CHUNK_SIZE;

                    // 8 corners of the chunk box
                    const corners = [8][3]f32{
                        .{ min_x, min_y, min_z },
                        .{ max_x, min_y, min_z },
                        .{ max_x, min_y, max_z },
                        .{ min_x, min_y, max_z },
                        .{ min_x, max_y, min_z },
                        .{ max_x, max_y, min_z },
                        .{ max_x, max_y, max_z },
                        .{ min_x, max_y, max_z },
                    };

                    // 12 edges as pairs of corner indices
                    const edges = [12][2]u8{
                        .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 0 }, // bottom
                        .{ 4, 5 }, .{ 5, 6 }, .{ 6, 7 }, .{ 7, 4 }, // top
                        .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 }, // vertical
                    };

                    for (edges) |edge| {
                        const c0 = corners[edge[0]];
                        const c1 = corners[edge[1]];
                        vertices[count] = .{ .px = c0[0], .py = c0[1], .pz = c0[2], .r = 0.0, .g = 1.0, .b = 0.0, .a = 1.0 };
                        count += 1;
                        vertices[count] = .{ .px = c1[0], .py = c1[1], .pz = c1[2], .r = 0.0, .g = 1.0, .b = 0.0, .a = 1.0 };
                        count += 1;
                    }
                }
            }
        }

        vk.unmapMemory(device, self.debug_line_vertex_buffer_memory);
        self.debug_line_vertex_count = count;
    }

    fn createDebugLinePipeline(self: *RenderState, shader_compiler: *ShaderCompiler, device: vk.VkDevice, swapchain_format: vk.VkFormat) !void {
        const tz = tracy.zone(@src(), "createDebugLinePipeline");
        defer tz.end();

        const vert_spirv = try shader_compiler.compile("debug_line.vert", .vertex);
        defer shader_compiler.allocator.free(vert_spirv);

        const frag_spirv = try shader_compiler.compile("debug_line.frag", .fragment);
        defer shader_compiler.allocator.free(frag_spirv);

        const vert_module_info = vk.VkShaderModuleCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = vert_spirv.len,
            .pCode = @ptrCast(@alignCast(vert_spirv.ptr)),
        };

        const frag_module_info = vk.VkShaderModuleCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = frag_spirv.len,
            .pCode = @ptrCast(@alignCast(frag_spirv.ptr)),
        };

        const vert_module = try vk.createShaderModule(device, &vert_module_info, null);
        defer vk.destroyShaderModule(device, vert_module, null);

        const frag_module = try vk.createShaderModule(device, &frag_module_info, null);
        defer vk.destroyShaderModule(device, frag_module, null);

        const shader_stages = [_]vk.VkPipelineShaderStageCreateInfo{
            .{
                .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stage = vk.VK_SHADER_STAGE_VERTEX_BIT,
                .module = vert_module,
                .pName = "main",
                .pSpecializationInfo = null,
            },
            .{
                .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
                .module = frag_module,
                .pName = "main",
                .pSpecializationInfo = null,
            },
        };

        const vertex_input_info = vk.VkPipelineVertexInputStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .vertexBindingDescriptionCount = 0,
            .pVertexBindingDescriptions = null,
            .vertexAttributeDescriptionCount = 0,
            .pVertexAttributeDescriptions = null,
        };

        const input_assembly = vk.VkPipelineInputAssemblyStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .topology = vk.VK_PRIMITIVE_TOPOLOGY_LINE_LIST,
            .primitiveRestartEnable = vk.VK_FALSE,
        };

        const viewport_state = vk.VkPipelineViewportStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .viewportCount = 1,
            .pViewports = null,
            .scissorCount = 1,
            .pScissors = null,
        };

        const rasterizer = vk.VkPipelineRasterizationStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthClampEnable = vk.VK_FALSE,
            .rasterizerDiscardEnable = vk.VK_FALSE,
            .polygonMode = vk.VK_POLYGON_MODE_FILL,
            .cullMode = vk.VK_CULL_MODE_NONE,
            .frontFace = vk.VK_FRONT_FACE_COUNTER_CLOCKWISE,
            .depthBiasEnable = vk.VK_FALSE,
            .depthBiasConstantFactor = 0.0,
            .depthBiasClamp = 0.0,
            .depthBiasSlopeFactor = 0.0,
            .lineWidth = 1.0,
        };

        const multisampling = vk.VkPipelineMultisampleStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .rasterizationSamples = vk.VK_SAMPLE_COUNT_1_BIT,
            .sampleShadingEnable = vk.VK_FALSE,
            .minSampleShading = 1.0,
            .pSampleMask = null,
            .alphaToCoverageEnable = vk.VK_FALSE,
            .alphaToOneEnable = vk.VK_FALSE,
        };

        const depth_stencil = vk.VkPipelineDepthStencilStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthTestEnable = vk.VK_TRUE,
            .depthWriteEnable = vk.VK_FALSE,
            .depthCompareOp = vk.VK_COMPARE_OP_LESS_OR_EQUAL,
            .depthBoundsTestEnable = vk.VK_FALSE,
            .stencilTestEnable = vk.VK_FALSE,
            .front = std.mem.zeroes(vk.VkStencilOpState),
            .back = std.mem.zeroes(vk.VkStencilOpState),
            .minDepthBounds = 0.0,
            .maxDepthBounds = 1.0,
        };

        const color_blend_attachment = vk.VkPipelineColorBlendAttachmentState{
            .blendEnable = vk.VK_TRUE,
            .srcColorBlendFactor = vk.VK_BLEND_FACTOR_SRC_ALPHA,
            .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .colorBlendOp = vk.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ZERO,
            .alphaBlendOp = vk.VK_BLEND_OP_ADD,
            .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT | vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT,
        };

        const color_blending = vk.VkPipelineColorBlendStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .logicOpEnable = vk.VK_FALSE,
            .logicOp = 0,
            .attachmentCount = 1,
            .pAttachments = &color_blend_attachment,
            .blendConstants = .{ 0.0, 0.0, 0.0, 0.0 },
        };

        const push_constant_range = vk.VkPushConstantRange{
            .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
            .offset = 0,
            .size = 64, // sizeof(mat4)
        };

        const pipeline_layout_info = vk.VkPipelineLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 1,
            .pSetLayouts = &self.debug_line_descriptor_set_layout,
            .pushConstantRangeCount = 1,
            .pPushConstantRanges = &push_constant_range,
        };

        self.debug_line_pipeline_layout = try vk.createPipelineLayout(device, &pipeline_layout_info, null);

        const color_attachment_format = [_]vk.VkFormat{swapchain_format};
        const rendering_create_info = vk.VkPipelineRenderingCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
            .pNext = null,
            .viewMask = 0,
            .colorAttachmentCount = 1,
            .pColorAttachmentFormats = &color_attachment_format,
            .depthAttachmentFormat = vk.VK_FORMAT_D32_SFLOAT,
            .stencilAttachmentFormat = vk.VK_FORMAT_UNDEFINED,
        };

        const dynamic_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
        const dynamic_state_info = c.VkPipelineDynamicStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .dynamicStateCount = dynamic_states.len,
            .pDynamicStates = &dynamic_states,
        };

        const pipeline_info = vk.VkGraphicsPipelineCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = &rendering_create_info,
            .flags = 0,
            .stageCount = 2,
            .pStages = &shader_stages,
            .pVertexInputState = &vertex_input_info,
            .pInputAssemblyState = &input_assembly,
            .pTessellationState = null,
            .pViewportState = &viewport_state,
            .pRasterizationState = &rasterizer,
            .pMultisampleState = &multisampling,
            .pDepthStencilState = &depth_stencil,
            .pColorBlendState = &color_blending,
            .pDynamicState = &dynamic_state_info,
            .layout = self.debug_line_pipeline_layout,
            .renderPass = null,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };

        var pipelines: [1]vk.VkPipeline = undefined;
        try vk.createGraphicsPipelines(device, null, 1, &[_]vk.VkGraphicsPipelineCreateInfo{pipeline_info}, null, &pipelines);
        self.debug_line_pipeline = pipelines[0];

        std.log.info("Debug line graphics pipeline created", .{});
    }

    fn createDebugLineComputePipeline(self: *RenderState, shader_compiler: *ShaderCompiler, ctx: *const VulkanContext) !void {
        const tz = tracy.zone(@src(), "createDebugLineComputePipeline");
        defer tz.end();

        const comp_spirv = try shader_compiler.compile("debug_line_indirect.comp", .compute);
        defer shader_compiler.allocator.free(comp_spirv);

        const comp_module_info = vk.VkShaderModuleCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = comp_spirv.len,
            .pCode = @ptrCast(@alignCast(comp_spirv.ptr)),
        };

        const comp_module = try vk.createShaderModule(ctx.device, &comp_module_info, null);
        defer vk.destroyShaderModule(ctx.device, comp_module, null);

        const push_constant_range = vk.VkPushConstantRange{
            .stageFlags = vk.VK_SHADER_STAGE_COMPUTE_BIT,
            .offset = 0,
            .size = @sizeOf(u32),
        };

        const compute_layout_info = vk.VkPipelineLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 1,
            .pSetLayouts = &self.debug_line_compute_descriptor_set_layout,
            .pushConstantRangeCount = 1,
            .pPushConstantRanges = &push_constant_range,
        };

        self.debug_line_compute_pipeline_layout = try vk.createPipelineLayout(ctx.device, &compute_layout_info, null);

        const compute_stage_info = vk.VkPipelineShaderStageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = vk.VK_SHADER_STAGE_COMPUTE_BIT,
            .module = comp_module,
            .pName = "main",
            .pSpecializationInfo = null,
        };

        const compute_pipeline_info = vk.VkComputePipelineCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = compute_stage_info,
            .layout = self.debug_line_compute_pipeline_layout,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };

        var pipelines: [1]vk.VkPipeline = undefined;
        try vk.createComputePipelines(ctx.device, null, 1, &[_]vk.VkComputePipelineCreateInfo{compute_pipeline_info}, null, &pipelines);
        self.debug_line_compute_pipeline = pipelines[0];

        std.log.info("Debug line compute pipeline created", .{});
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
