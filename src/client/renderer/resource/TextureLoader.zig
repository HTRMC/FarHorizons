// TextureLoader - Generic texture loading utility
//
// Consolidates texture loading from RenderSystem and EntityRenderer into a unified module.

const std = @import("std");
const volk = @import("volk");
const vk = volk.c;
const shared = @import("Shared");
const Logger = shared.Logger;
const stb_image = @import("stb_image");
const GpuDevice = @import("../GpuDevice.zig").GpuDevice;

const logger = Logger.scoped(@This());

pub const TextureLoader = struct {
    const Self = @This();

    /// Loaded texture result containing all Vulkan resources
    pub const LoadedTexture = struct {
        image: vk.VkImage,
        memory: vk.VkDeviceMemory,
        view: vk.VkImageView,
        sampler: vk.VkSampler,
        width: u32,
        height: u32,
    };

    /// Sampler configuration options
    pub const SamplerConfig = struct {
        filter: Filter = .nearest,
        address_mode: AddressMode = .clamp_to_edge,
        format: Format = .rgba8_unorm,

        pub const Filter = enum {
            nearest,
            linear,
        };

        pub const AddressMode = enum {
            repeat,
            clamp_to_edge,
        };

        pub const Format = enum {
            rgba8_unorm,
            rgba8_srgb,
        };

        fn getVkFilter(self: SamplerConfig) vk.VkFilter {
            return switch (self.filter) {
                .nearest => vk.VK_FILTER_NEAREST,
                .linear => vk.VK_FILTER_LINEAR,
            };
        }

        fn getVkAddressMode(self: SamplerConfig) vk.VkSamplerAddressMode {
            return switch (self.address_mode) {
                .repeat => vk.VK_SAMPLER_ADDRESS_MODE_REPEAT,
                .clamp_to_edge => vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            };
        }

        fn getVkFormat(self: SamplerConfig) vk.VkFormat {
            return switch (self.format) {
                .rgba8_unorm => vk.VK_FORMAT_R8G8B8A8_UNORM,
                .rgba8_srgb => vk.VK_FORMAT_R8G8B8A8_SRGB,
            };
        }

        fn getVkMipmapMode(self: SamplerConfig) vk.VkSamplerMipmapMode {
            return switch (self.filter) {
                .nearest => vk.VK_SAMPLER_MIPMAP_MODE_NEAREST,
                .linear => vk.VK_SAMPLER_MIPMAP_MODE_LINEAR,
            };
        }
    };

    /// Load a texture from a file path
    pub fn load(
        gpu: *GpuDevice,
        path: [:0]const u8,
        config: SamplerConfig,
    ) !LoadedTexture {
        const vkCreateImage = vk.vkCreateImage orelse return error.VulkanFunctionNotLoaded;
        const vkGetImageMemoryRequirements = vk.vkGetImageMemoryRequirements orelse return error.VulkanFunctionNotLoaded;
        const vkAllocateMemory = vk.vkAllocateMemory orelse return error.VulkanFunctionNotLoaded;
        const vkBindImageMemory = vk.vkBindImageMemory orelse return error.VulkanFunctionNotLoaded;
        const vkCreateImageView = vk.vkCreateImageView orelse return error.VulkanFunctionNotLoaded;
        const vkCreateSampler = vk.vkCreateSampler orelse return error.VulkanFunctionNotLoaded;

        const device = gpu.getDevice();

        // Load image using stb_image
        stb_image.setFlipVerticallyOnLoad(false);
        const image = stb_image.load(path.ptr, 4) catch {
            logger.err("Failed to load texture: {s}", .{path});
            if (stb_image.failureReason()) |reason| {
                logger.err("STB error: {s}", .{reason});
            }
            return error.TextureLoadFailed;
        };
        defer image.free();

        const width: u32 = @intCast(image.width);
        const height: u32 = @intCast(image.height);
        logger.info("Loaded texture: {s} ({d}x{d})", .{ path, width, height });

        // Create staging buffer and copy pixel data
        const image_size: u64 = @as(u64, width) * @as(u64, height) * 4;
        const staging = try gpu.createMappedBufferRaw(image_size, vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
        defer gpu.destroyMappedBufferRaw(staging);

        const mapped_bytes = @as([*]u8, @ptrCast(staging.mapped.?))[0..image_size];
        @memcpy(mapped_bytes, image.data[0..image_size]);

        // Create VkImage
        const image_info = vk.VkImageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = vk.VK_IMAGE_TYPE_2D,
            .format = config.getVkFormat(),
            .extent = .{ .width = width, .height = height, .depth = 1 },
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

        var tex_image: vk.VkImage = undefined;
        if (vkCreateImage(device, &image_info, null, &tex_image) != vk.VK_SUCCESS) {
            return error.ImageCreationFailed;
        }
        errdefer if (vk.vkDestroyImage) |destroyImg| destroyImg(device, tex_image, null);

        var img_mem_req: vk.VkMemoryRequirements = undefined;
        vkGetImageMemoryRequirements(device, tex_image, &img_mem_req);

        const img_alloc_info = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = img_mem_req.size,
            .memoryTypeIndex = try findMemoryType(gpu, img_mem_req.memoryTypeBits, vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
        };

        var tex_memory: vk.VkDeviceMemory = undefined;
        if (vkAllocateMemory(device, &img_alloc_info, null, &tex_memory) != vk.VK_SUCCESS) {
            return error.MemoryAllocationFailed;
        }
        errdefer if (vk.vkFreeMemory) |free| free(device, tex_memory, null);

        if (vkBindImageMemory(device, tex_image, tex_memory, 0) != vk.VK_SUCCESS) {
            return error.ImageBindFailed;
        }

        // Upload: transition → copy → transition in a single command buffer with fence sync
        try uploadImageBatched(gpu, staging.handle, tex_image, width, height);

        // Create image view
        const view_info = vk.VkImageViewCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = tex_image,
            .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
            .format = config.getVkFormat(),
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

        var tex_view: vk.VkImageView = undefined;
        if (vkCreateImageView(device, &view_info, null, &tex_view) != vk.VK_SUCCESS) {
            return error.ImageViewCreationFailed;
        }
        errdefer if (vk.vkDestroyImageView) |destroyView| destroyView(device, tex_view, null);

        // Create sampler
        const sampler_info = vk.VkSamplerCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .magFilter = config.getVkFilter(),
            .minFilter = config.getVkFilter(),
            .mipmapMode = config.getVkMipmapMode(),
            .addressModeU = config.getVkAddressMode(),
            .addressModeV = config.getVkAddressMode(),
            .addressModeW = config.getVkAddressMode(),
            .mipLodBias = 0.0,
            .anisotropyEnable = vk.VK_FALSE,
            .maxAnisotropy = 1.0,
            .compareEnable = vk.VK_FALSE,
            .compareOp = vk.VK_COMPARE_OP_ALWAYS,
            .minLod = 0.0,
            .maxLod = 0.0,
            .borderColor = vk.VK_BORDER_COLOR_INT_TRANSPARENT_BLACK,
            .unnormalizedCoordinates = vk.VK_FALSE,
        };

        var tex_sampler: vk.VkSampler = undefined;
        if (vkCreateSampler(device, &sampler_info, null, &tex_sampler) != vk.VK_SUCCESS) {
            return error.SamplerCreationFailed;
        }

        return LoadedTexture{
            .image = tex_image,
            .memory = tex_memory,
            .view = tex_view,
            .sampler = tex_sampler,
            .width = width,
            .height = height,
        };
    }

    /// Destroy a loaded texture and free all Vulkan resources
    pub fn destroy(texture: *LoadedTexture, device: vk.VkDevice) void {
        if (vk.vkDestroySampler) |destroySampler| {
            destroySampler(device, texture.sampler, null);
        }
        if (vk.vkDestroyImageView) |destroyView| {
            destroyView(device, texture.view, null);
        }
        if (vk.vkDestroyImage) |destroyImage| {
            destroyImage(device, texture.image, null);
        }
        if (vk.vkFreeMemory) |freeMemory| {
            freeMemory(device, texture.memory, null);
        }

        texture.* = .{
            .image = null,
            .memory = null,
            .view = null,
            .sampler = null,
            .width = 0,
            .height = 0,
        };
    }

    // ============================================================
    // Internal Helper Functions
    // ============================================================

    fn findMemoryType(gpu: *GpuDevice, type_filter: u32, properties: vk.VkMemoryPropertyFlags) !u32 {
        const vkGetPhysicalDeviceMemoryProperties = vk.vkGetPhysicalDeviceMemoryProperties orelse return error.VulkanFunctionNotLoaded;

        var mem_properties: vk.VkPhysicalDeviceMemoryProperties = undefined;
        vkGetPhysicalDeviceMemoryProperties(gpu.physical_device, &mem_properties);

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

    /// Batched upload: transition → copy → transition in a single command buffer with fence sync.
    /// Replaces the old 3-submit pattern that called vkQueueWaitIdle after each step.
    fn uploadImageBatched(
        gpu: *GpuDevice,
        staging_buffer: vk.VkBuffer,
        image: vk.VkImage,
        width: u32,
        height: u32,
    ) !void {
        const vkAllocateCommandBuffers = vk.vkAllocateCommandBuffers orelse return error.VulkanFunctionNotLoaded;
        const vkBeginCommandBuffer = vk.vkBeginCommandBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkCmdPipelineBarrier = vk.vkCmdPipelineBarrier orelse return error.VulkanFunctionNotLoaded;
        const vkCmdCopyBufferToImage = vk.vkCmdCopyBufferToImage orelse return error.VulkanFunctionNotLoaded;
        const vkEndCommandBuffer = vk.vkEndCommandBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkQueueSubmit = vk.vkQueueSubmit orelse return error.VulkanFunctionNotLoaded;
        const vkCreateFence = vk.vkCreateFence orelse return error.VulkanFunctionNotLoaded;
        const vkWaitForFences = vk.vkWaitForFences orelse return error.VulkanFunctionNotLoaded;
        const vkDestroyFence = vk.vkDestroyFence orelse return error.VulkanFunctionNotLoaded;
        const vkFreeCommandBuffers = vk.vkFreeCommandBuffers orelse return error.VulkanFunctionNotLoaded;

        const device = gpu.getDevice();
        const command_pool = gpu.getCommandPool();
        const graphics_queue = gpu.getGraphicsQueue();

        var command_buffer: vk.VkCommandBuffer = undefined;
        const alloc_info = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        if (vkAllocateCommandBuffers(device, &alloc_info, &command_buffer) != vk.VK_SUCCESS) {
            return error.CommandBufferAllocationFailed;
        }
        defer vkFreeCommandBuffers(device, command_pool, 1, &command_buffer);

        const begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };
        if (vkBeginCommandBuffer(command_buffer, &begin_info) != vk.VK_SUCCESS) {
            return error.CommandBufferBeginFailed;
        }

        const subresource_range = vk.VkImageSubresourceRange{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        };

        // 1) UNDEFINED → TRANSFER_DST
        const to_transfer = vk.VkImageMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = 0,
            .dstAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresourceRange = subresource_range,
        };
        vkCmdPipelineBarrier(command_buffer, vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, vk.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &to_transfer);

        // 2) Copy staging buffer → image
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
            .imageExtent = .{ .width = width, .height = height, .depth = 1 },
        };
        vkCmdCopyBufferToImage(command_buffer, staging_buffer, image, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

        // 3) TRANSFER_DST → SHADER_READ_ONLY
        const to_shader = vk.VkImageMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresourceRange = subresource_range,
        };
        vkCmdPipelineBarrier(command_buffer, vk.VK_PIPELINE_STAGE_TRANSFER_BIT, vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &to_shader);

        if (vkEndCommandBuffer(command_buffer) != vk.VK_SUCCESS) {
            return error.CommandBufferEndFailed;
        }

        // Submit with fence (no queue stall)
        var fence: vk.VkFence = null;
        const fence_info = vk.VkFenceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
        };
        if (vkCreateFence(device, &fence_info, null, &fence) != vk.VK_SUCCESS) {
            return error.FenceCreationFailed;
        }
        defer vkDestroyFence(device, fence, null);

        const submit_info = vk.VkSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = null,
            .pWaitDstStageMask = null,
            .commandBufferCount = 1,
            .pCommandBuffers = &command_buffer,
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = null,
        };
        if (vkQueueSubmit(graphics_queue, 1, &submit_info, fence) != vk.VK_SUCCESS) {
            return error.QueueSubmitFailed;
        }
        _ = vkWaitForFences(device, 1, &fence, vk.VK_TRUE, std.math.maxInt(u64));
    }
};
