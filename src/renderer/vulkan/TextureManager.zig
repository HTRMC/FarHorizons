const std = @import("std");
const vk = @import("../../platform/volk.zig");
const c = @import("../../platform/c.zig").c;
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const vk_utils = @import("vk_utils.zig");
const app_config = @import("../../app_config.zig");
const tracy = @import("../../platform/tracy.zig");

const BLOCK_TEXTURE_COUNT = 4;
const block_texture_names = [BLOCK_TEXTURE_COUNT][]const u8{ "glass.png", "grass_block.png", "dirt.png", "stone.png" };

pub const TextureManager = struct {
    texture_image: vk.VkImage,
    texture_image_memory: vk.VkDeviceMemory,
    texture_image_view: vk.VkImageView,
    texture_sampler: vk.VkSampler,
    bindless_descriptor_set_layout: vk.VkDescriptorSetLayout,
    bindless_descriptor_pool: vk.VkDescriptorPool,
    bindless_descriptor_set: vk.VkDescriptorSet,

    pub fn init(allocator: std.mem.Allocator, ctx: *const VulkanContext) !TextureManager {
        const tz = tracy.zone(@src(), "TextureManager.init");
        defer tz.end();

        var self = TextureManager{
            .texture_image = null,
            .texture_image_memory = null,
            .texture_image_view = null,
            .texture_sampler = null,
            .bindless_descriptor_set_layout = null,
            .bindless_descriptor_pool = null,
            .bindless_descriptor_set = null,
        };

        try self.createTextureImage(allocator, ctx);
        try self.createBindlessDescriptorSet(ctx);

        return self;
    }

    pub fn deinit(self: *TextureManager, device: vk.VkDevice) void {
        vk.destroyDescriptorPool(device, self.bindless_descriptor_pool, null);
        vk.destroyDescriptorSetLayout(device, self.bindless_descriptor_set_layout, null);
        vk.destroySampler(device, self.texture_sampler, null);
        vk.destroyImageView(device, self.texture_image_view, null);
        vk.destroyImage(device, self.texture_image, null);
        vk.freeMemory(device, self.texture_image_memory, null);
    }

    pub fn updateChunkPositions(self: *TextureManager, ctx: *const VulkanContext, buffer: vk.VkBuffer, size: vk.VkDeviceSize) void {
        const buffer_info = vk.VkDescriptorBufferInfo{
            .buffer = buffer,
            .offset = 0,
            .range = size,
        };

        const descriptor_write = vk.VkWriteDescriptorSet{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = self.bindless_descriptor_set,
            .dstBinding = 2,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = &buffer_info,
            .pTexelBufferView = null,
        };

        vk.updateDescriptorSets(ctx.device, 1, &[_]vk.VkWriteDescriptorSet{descriptor_write}, 0, null);
    }

    pub fn updateVertexDescriptor(self: *TextureManager, ctx: *const VulkanContext, vertex_buffer: vk.VkBuffer, vb_size: vk.VkDeviceSize) void {
        const vertex_buffer_info = vk.VkDescriptorBufferInfo{
            .buffer = vertex_buffer,
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
    }

    fn createTextureImage(self: *TextureManager, allocator: std.mem.Allocator, ctx: *const VulkanContext) !void {
        const tz = tracy.zone(@src(), "createTextureImage");
        defer tz.end();

        const base_path = try app_config.getAppDataPath(allocator);
        defer allocator.free(base_path);

        const sep = std.fs.path.sep_str;

        const tex_w = 16;
        const tex_h = 16;
        const layer_size: vk.VkDeviceSize = tex_w * tex_h * 4;
        const total_size: vk.VkDeviceSize = layer_size * BLOCK_TEXTURE_COUNT;

        var staging_buffer: vk.VkBuffer = undefined;
        var staging_buffer_memory: vk.VkDeviceMemory = undefined;
        try vk_utils.createBuffer(
            ctx,
            total_size,
            vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &staging_buffer,
            &staging_buffer_memory,
        );

        var data: ?*anyopaque = null;
        try vk.mapMemory(ctx.device, staging_buffer_memory, 0, total_size, 0, &data);
        const dst: [*]u8 = @ptrCast(data.?);

        for (0..BLOCK_TEXTURE_COUNT) |i| {
            const texture_path = try std.fmt.allocPrintSentinel(allocator, "{s}" ++ sep ++ "assets" ++ sep ++ "farhorizons" ++ sep ++ "textures" ++ sep ++ "block" ++ sep ++ "{s}", .{ base_path, block_texture_names[i] }, 0);
            defer allocator.free(texture_path);

            var tw: c_int = 0;
            var th: c_int = 0;
            var tc: c_int = 0;
            const pixels = c.stbi_load(texture_path.ptr, &tw, &th, &tc, 4) orelse {
                std.log.err("Failed to load texture image from {s}", .{texture_path});
                return error.TextureLoadFailed;
            };
            defer c.stbi_image_free(pixels);

            const offset = i * @as(usize, @intCast(layer_size));
            const src: [*]const u8 = @ptrCast(pixels);
            @memcpy(dst[offset..][0..@intCast(layer_size)], src[0..@intCast(layer_size)]);
            std.log.info("Texture loaded: {s} ({}x{})", .{ block_texture_names[i], tw, th });
        }

        vk.unmapMemory(ctx.device, staging_buffer_memory);

        const image_info = vk.VkImageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = vk.VK_IMAGE_TYPE_2D,
            .format = vk.VK_FORMAT_R8G8B8A8_UNORM,
            .extent = .{ .width = tex_w, .height = tex_h, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = BLOCK_TEXTURE_COUNT,
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
                .layerCount = BLOCK_TEXTURE_COUNT,
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

        var regions: [BLOCK_TEXTURE_COUNT]vk.VkBufferImageCopy = undefined;
        for (0..BLOCK_TEXTURE_COUNT) |i| {
            regions[i] = .{
                .bufferOffset = @intCast(i * @as(usize, @intCast(layer_size))),
                .bufferRowLength = 0,
                .bufferImageHeight = 0,
                .imageSubresource = .{
                    .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                    .mipLevel = 0,
                    .baseArrayLayer = @intCast(i),
                    .layerCount = 1,
                },
                .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
                .imageExtent = .{ .width = tex_w, .height = tex_h, .depth = 1 },
            };
        }

        vk.cmdCopyBufferToImage(
            cmd,
            staging_buffer,
            self.texture_image,
            vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            BLOCK_TEXTURE_COUNT,
            &regions,
        );

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
                .layerCount = BLOCK_TEXTURE_COUNT,
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

        vk.destroyBuffer(ctx.device, staging_buffer, null);
        vk.freeMemory(ctx.device, staging_buffer_memory, null);

        const view_info = vk.VkImageViewCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = self.texture_image,
            .viewType = vk.VK_IMAGE_VIEW_TYPE_2D_ARRAY,
            .format = vk.VK_FORMAT_R8G8B8A8_UNORM,
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
                .layerCount = BLOCK_TEXTURE_COUNT,
            },
        };

        self.texture_image_view = try vk.createImageView(ctx.device, &view_info, null);

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
    }

    fn createBindlessDescriptorSet(self: *TextureManager, ctx: *const VulkanContext) !void {
        const tz = tracy.zone(@src(), "createBindlessDescriptorSet");
        defer tz.end();

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
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
                .pImmutableSamplers = null,
            },
            .{
                .binding = 2,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
                .pImmutableSamplers = null,
            },
        };

        const binding_flags = [_]c.VkDescriptorBindingFlags{
            vk.VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT,
            vk.VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT,
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

        const pool_sizes = [_]vk.VkDescriptorPoolSize{
            .{
                .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 2,
            },
            .{
                .type = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .descriptorCount = 1,
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

        const alloc_info = vk.VkDescriptorSetAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = self.bindless_descriptor_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &self.bindless_descriptor_set_layout,
        };

        var descriptor_sets: [1]vk.VkDescriptorSet = undefined;
        try vk.allocateDescriptorSets(ctx.device, &alloc_info, &descriptor_sets);
        self.bindless_descriptor_set = descriptor_sets[0];

        const image_info = vk.VkDescriptorImageInfo{
            .sampler = self.texture_sampler,
            .imageView = self.texture_image_view,
            .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };

        const descriptor_write = vk.VkWriteDescriptorSet{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = self.bindless_descriptor_set,
            .dstBinding = 1,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &image_info,
            .pBufferInfo = null,
            .pTexelBufferView = null,
        };

        vk.updateDescriptorSets(ctx.device, 1, &[_]vk.VkWriteDescriptorSet{descriptor_write}, 0, null);
        std.log.info("Descriptor set created (texture array with {} layers)", .{BLOCK_TEXTURE_COUNT});
    }
};
