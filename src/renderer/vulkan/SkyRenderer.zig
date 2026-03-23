const std = @import("std");
const vk = @import("../../platform/volk.zig");
const ShaderCompiler = @import("ShaderCompiler.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const vk_utils = @import("vk_utils.zig");
const stbi = @import("../../platform/stb_image.zig");
const app_config = @import("../../app_config.zig");
const tracy = @import("../../platform/tracy.zig");
const zlm = @import("zlm");
const Io = std.Io;
const Dir = Io.Dir;

pub const SkyRenderer = struct {
    pipeline: vk.VkPipeline,
    pipeline_layout: vk.VkPipelineLayout,
    descriptor_set_layout: vk.VkDescriptorSetLayout,
    descriptor_pool: vk.VkDescriptorPool,
    descriptor_set: vk.VkDescriptorSet,
    image: vk.VkImage,
    image_memory: vk.VkDeviceMemory,
    image_view: vk.VkImageView,
    sampler: vk.VkSampler,

    pub fn init(allocator: std.mem.Allocator, shader_compiler: *ShaderCompiler, ctx: *const VulkanContext, swapchain_format: vk.VkFormat) !SkyRenderer {
        var self = SkyRenderer{
            .pipeline = null,
            .pipeline_layout = null,
            .descriptor_set_layout = null,
            .descriptor_pool = null,
            .descriptor_set = null,
            .image = null,
            .image_memory = null,
            .image_view = null,
            .sampler = null,
        };
        try self.loadTextures(allocator, ctx);
        try self.createDescriptors(ctx);
        try self.createPipeline(shader_compiler, ctx, swapchain_format);
        return self;
    }

    pub fn deinit(self: *SkyRenderer, device: vk.VkDevice) void {
        vk.destroyPipeline(device, self.pipeline, null);
        vk.destroyPipelineLayout(device, self.pipeline_layout, null);
        vk.destroyDescriptorPool(device, self.descriptor_pool, null);
        vk.destroyDescriptorSetLayout(device, self.descriptor_set_layout, null);
        vk.destroySampler(device, self.sampler, null);
        vk.destroyImageView(device, self.image_view, null);
        vk.destroyImage(device, self.image, null);
        vk.freeMemory(device, self.image_memory, null);
    }

    pub fn record(self: *const SkyRenderer, command_buffer: vk.VkCommandBuffer, view_proj: *const [16]f32, sun_dir: [3]f32, moon_dir: [3]f32) void {
        const tz = tracy.zone(@src(), "SkyRenderer.record");
        defer tz.end();

        vk.cmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);
        vk.cmdBindDescriptorSets(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline_layout, 0, 1, &[_]vk.VkDescriptorSet{self.descriptor_set}, 0, null);

        // Push viewProj matrix (offset 0, 64 bytes)
        vk.cmdPushConstants(command_buffer, self.pipeline_layout, vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(zlm.Mat4), view_proj);

        // Push sun direction + size (offset 64, 16 bytes)
        const body_size: f32 = 0.12;
        const sun_data = [4]f32{ sun_dir[0], sun_dir[1], sun_dir[2], body_size };
        vk.cmdPushConstants(command_buffer, self.pipeline_layout, vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT, 64, @sizeOf([4]f32), @ptrCast(&sun_data));

        // Push moon direction + size (offset 80, 16 bytes)
        const moon_data = [4]f32{ moon_dir[0], moon_dir[1], moon_dir[2], body_size };
        vk.cmdPushConstants(command_buffer, self.pipeline_layout, vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT, 80, @sizeOf([4]f32), @ptrCast(&moon_data));

        // Draw 12 vertices: 2 quads (sun + moon) × 6 vertices each
        vk.cmdDraw(command_buffer, 12, 1, 0, 0);
    }

    // ============================================================
    // Texture loading
    // ============================================================

    fn loadTextures(self: *SkyRenderer, allocator: std.mem.Allocator, ctx: *const VulkanContext) !void {
        const sep = std.fs.path.sep_str;
        const assets_path = try app_config.getAssetsPath(allocator);
        defer allocator.free(assets_path);

        const sun_path = try std.fmt.allocPrintSentinel(allocator, "{s}" ++ sep ++ "textures" ++ sep ++ "environment" ++ sep ++ "sun.png", .{assets_path}, 0);
        defer allocator.free(sun_path);

        const moon_path = try std.fmt.allocPrintSentinel(allocator, "{s}" ++ sep ++ "textures" ++ sep ++ "environment" ++ sep ++ "moon.png", .{assets_path}, 0);
        defer allocator.free(moon_path);

        // Load sun texture
        var sun_w: c_int = 0;
        var sun_h: c_int = 0;
        var sun_c: c_int = 0;
        const sun_pixels: [*]u8 = stbi.load(sun_path.ptr, &sun_w, &sun_h, &sun_c, 4) orelse return error.TextureLoadFailed;
        defer stbi.free(sun_pixels);

        // Load moon texture
        var moon_w: c_int = 0;
        var moon_h: c_int = 0;
        var moon_c: c_int = 0;
        const moon_pixels: [*]u8 = stbi.load(moon_path.ptr, &moon_w, &moon_h, &moon_c, 4) orelse return error.TextureLoadFailed;
        defer stbi.free(moon_pixels);

        // Both textures must be the same size for the array
        if (sun_w != moon_w or sun_h != moon_h) return error.TextureSizeMismatch;

        const tw: u32 = @intCast(sun_w);
        const th: u32 = @intCast(sun_h);
        const layer_bytes: vk.VkDeviceSize = @as(u64, tw) * th * 4;
        const total_bytes: vk.VkDeviceSize = layer_bytes * 2;

        std.log.info("Sky textures loaded: sun.png ({}x{}), moon.png ({}x{})", .{ tw, th, @as(u32, @intCast(moon_w)), @as(u32, @intCast(moon_h)) });

        // Create staging buffer
        var staging_buffer: vk.VkBuffer = undefined;
        var staging_memory: vk.VkDeviceMemory = undefined;
        try vk_utils.createBuffer(ctx, total_bytes, vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT, vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, &staging_buffer, &staging_memory);
        defer vk.destroyBuffer(ctx.device, staging_buffer, null);
        defer vk.freeMemory(ctx.device, staging_memory, null);

        {
            var data: ?*anyopaque = null;
            try vk.mapMemory(ctx.device, staging_memory, 0, total_bytes, 0, &data);
            const dst: [*]u8 = @ptrCast(data.?);
            @memcpy(dst[0..@intCast(layer_bytes)], sun_pixels[0..@intCast(layer_bytes)]);
            @memcpy(dst[@intCast(layer_bytes)..@intCast(total_bytes)], moon_pixels[0..@intCast(layer_bytes)]);
            vk.unmapMemory(ctx.device, staging_memory);
        }

        // Create 2-layer array image
        self.image = try vk.createImage(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .pNext = null, .flags = 0,
            .imageType = vk.VK_IMAGE_TYPE_2D,
            .format = vk.VK_FORMAT_R8G8B8A8_UNORM,
            .extent = .{ .width = tw, .height = th, .depth = 1 },
            .mipLevels = 1, .arrayLayers = 2,
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
            .usage = vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT | vk.VK_IMAGE_USAGE_SAMPLED_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0, .pQueueFamilyIndices = null,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        }, null);

        var mem_req: vk.VkMemoryRequirements = undefined;
        vk.getImageMemoryRequirements(ctx.device, self.image, &mem_req);
        const mem_type = try vk_utils.findMemoryType(ctx.physical_device, mem_req.memoryTypeBits, vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        self.image_memory = try vk.allocateMemory(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .pNext = null,
            .allocationSize = mem_req.size, .memoryTypeIndex = mem_type,
        }, null);
        try vk.bindImageMemory(ctx.device, self.image, self.image_memory, 0);

        // Upload via one-shot command buffer
        var cmd_bufs: [1]vk.VkCommandBuffer = undefined;
        try vk.allocateCommandBuffers(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .pNext = null,
            .commandPool = ctx.command_pool, .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1,
        }, &cmd_bufs);
        const cmd = cmd_bufs[0];

        try vk.beginCommandBuffer(cmd, &.{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .pNext = null,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, .pInheritanceInfo = null,
        });

        const subresource_range = vk.VkImageSubresourceRange{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0, .levelCount = 1,
            .baseArrayLayer = 0, .layerCount = 2,
        };

        // UNDEFINED → TRANSFER_DST
        vk.cmdPipelineBarrier(cmd, vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, vk.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &[_]vk.VkImageMemoryBarrier{.{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .pNext = null,
            .srcAccessMask = 0, .dstAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = self.image, .subresourceRange = subresource_range,
        }});

        // Copy both layers from staging buffer
        const copies = [_]vk.VkBufferImageCopy{
            .{
                .bufferOffset = 0, .bufferRowLength = 0, .bufferImageHeight = 0,
                .imageSubresource = .{ .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
                .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
                .imageExtent = .{ .width = tw, .height = th, .depth = 1 },
            },
            .{
                .bufferOffset = layer_bytes, .bufferRowLength = 0, .bufferImageHeight = 0,
                .imageSubresource = .{ .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 1, .layerCount = 1 },
                .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
                .imageExtent = .{ .width = tw, .height = th, .depth = 1 },
            },
        };
        vk.cmdCopyBufferToImage(cmd, staging_buffer, self.image, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 2, &copies);

        // TRANSFER_DST → SHADER_READ_ONLY
        vk.cmdPipelineBarrier(cmd, vk.VK_PIPELINE_STAGE_TRANSFER_BIT, vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &[_]vk.VkImageMemoryBarrier{.{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .pNext = null,
            .srcAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, .newLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = self.image, .subresourceRange = subresource_range,
        }});

        try vk.endCommandBuffer(cmd);
        try vk.queueSubmit(ctx.graphics_queue, 1, &[_]vk.VkSubmitInfo{.{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO, .pNext = null,
            .waitSemaphoreCount = 0, .pWaitSemaphores = null, .pWaitDstStageMask = null,
            .commandBufferCount = 1, .pCommandBuffers = &cmd,
            .signalSemaphoreCount = 0, .pSignalSemaphores = null,
        }}, null);
        try vk.queueWaitIdle(ctx.graphics_queue);
        vk.freeCommandBuffers(ctx.device, ctx.command_pool, 1, &cmd_bufs);

        // Create image view (2D array)
        self.image_view = try vk.createImageView(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .pNext = null, .flags = 0,
            .image = self.image, .viewType = vk.VK_IMAGE_VIEW_TYPE_2D_ARRAY,
            .format = vk.VK_FORMAT_R8G8B8A8_UNORM,
            .components = .{ .r = vk.VK_COMPONENT_SWIZZLE_IDENTITY, .g = vk.VK_COMPONENT_SWIZZLE_IDENTITY, .b = vk.VK_COMPONENT_SWIZZLE_IDENTITY, .a = vk.VK_COMPONENT_SWIZZLE_IDENTITY },
            .subresourceRange = subresource_range,
        }, null);

        // Create sampler (nearest filtering for pixel art style)
        self.sampler = try vk.createSampler(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO, .pNext = null, .flags = 0,
            .magFilter = vk.VK_FILTER_NEAREST, .minFilter = vk.VK_FILTER_NEAREST,
            .mipmapMode = vk.VK_SAMPLER_MIPMAP_MODE_NEAREST,
            .addressModeU = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeV = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeW = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .mipLodBias = 0, .anisotropyEnable = vk.VK_FALSE, .maxAnisotropy = 1,
            .compareEnable = vk.VK_FALSE, .compareOp = 0,
            .minLod = 0, .maxLod = 0,
            .borderColor = vk.VK_BORDER_COLOR_INT_OPAQUE_BLACK,
            .unnormalizedCoordinates = vk.VK_FALSE,
        }, null);
    }

    // ============================================================
    // Descriptors
    // ============================================================

    fn createDescriptors(self: *SkyRenderer, ctx: *const VulkanContext) !void {
        const binding = vk.VkDescriptorSetLayoutBinding{
            .binding = 0,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        };

        self.descriptor_set_layout = try vk.createDescriptorSetLayout(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pNext = null, .flags = 0,
            .bindingCount = 1, .pBindings = &binding,
        }, null);

        const pool_size = vk.VkDescriptorPoolSize{
            .type = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
        };

        self.descriptor_pool = try vk.createDescriptorPool(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .pNext = null, .flags = 0,
            .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &pool_size,
        }, null);

        var sets: [1]vk.VkDescriptorSet = undefined;
        try vk.allocateDescriptorSets(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .pNext = null,
            .descriptorPool = self.descriptor_pool,
            .descriptorSetCount = 1, .pSetLayouts = &self.descriptor_set_layout,
        }, &sets);
        self.descriptor_set = sets[0];

        const image_info = vk.VkDescriptorImageInfo{
            .sampler = self.sampler,
            .imageView = self.image_view,
            .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };

        vk.updateDescriptorSets(ctx.device, 1, &[_]vk.VkWriteDescriptorSet{.{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .pNext = null,
            .dstSet = self.descriptor_set, .dstBinding = 0, .dstArrayElement = 0,
            .descriptorCount = 1, .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &image_info, .pBufferInfo = null, .pTexelBufferView = null,
        }}, 0, null);
    }

    // ============================================================
    // Pipeline
    // ============================================================

    fn createPipeline(self: *SkyRenderer, shader_compiler: *ShaderCompiler, ctx: *const VulkanContext, swapchain_format: vk.VkFormat) !void {
        const device = ctx.device;
        const tz = tracy.zone(@src(), "SkyRenderer.createPipeline");
        defer tz.end();

        const vert_spirv = try shader_compiler.compile("sky.vert", .vertex);
        defer shader_compiler.allocator.free(vert_spirv);

        const frag_spirv = try shader_compiler.compile("sky.frag", .fragment);
        defer shader_compiler.allocator.free(frag_spirv);

        const vert_module = try vk.createShaderModule(device, &vk.VkShaderModuleCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .pNext = null, .flags = 0,
            .codeSize = vert_spirv.len, .pCode = @ptrCast(@alignCast(vert_spirv.ptr)),
        }, null);
        defer vk.destroyShaderModule(device, vert_module, null);

        const frag_module = try vk.createShaderModule(device, &vk.VkShaderModuleCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .pNext = null, .flags = 0,
            .codeSize = frag_spirv.len, .pCode = @ptrCast(@alignCast(frag_spirv.ptr)),
        }, null);
        defer vk.destroyShaderModule(device, frag_module, null);

        const shader_stages = [_]vk.VkPipelineShaderStageCreateInfo{
            .{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .pNext = null, .flags = 0, .stage = vk.VK_SHADER_STAGE_VERTEX_BIT, .module = vert_module, .pName = "main", .pSpecializationInfo = null },
            .{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .pNext = null, .flags = 0, .stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT, .module = frag_module, .pName = "main", .pSpecializationInfo = null },
        };

        const vertex_input = vk.VkPipelineVertexInputStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO, .pNext = null, .flags = 0,
            .vertexBindingDescriptionCount = 0, .pVertexBindingDescriptions = null,
            .vertexAttributeDescriptionCount = 0, .pVertexAttributeDescriptions = null,
        };
        const input_assembly = vk.VkPipelineInputAssemblyStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, .pNext = null, .flags = 0,
            .topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, .primitiveRestartEnable = vk.VK_FALSE,
        };
        const viewport_state = vk.VkPipelineViewportStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .pNext = null, .flags = 0,
            .viewportCount = 1, .pViewports = null, .scissorCount = 1, .pScissors = null,
        };
        const rasterizer = vk.VkPipelineRasterizationStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO, .pNext = null, .flags = 0,
            .depthClampEnable = vk.VK_FALSE, .rasterizerDiscardEnable = vk.VK_FALSE,
            .polygonMode = vk.VK_POLYGON_MODE_FILL,
            .cullMode = vk.VK_CULL_MODE_NONE,
            .frontFace = vk.VK_FRONT_FACE_COUNTER_CLOCKWISE,
            .depthBiasEnable = vk.VK_FALSE, .depthBiasConstantFactor = 0, .depthBiasClamp = 0, .depthBiasSlopeFactor = 0,
            .lineWidth = 1,
        };
        const multisampling = vk.VkPipelineMultisampleStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, .pNext = null, .flags = 0,
            .rasterizationSamples = vk.VK_SAMPLE_COUNT_1_BIT, .sampleShadingEnable = vk.VK_FALSE,
            .minSampleShading = 1, .pSampleMask = null, .alphaToCoverageEnable = vk.VK_FALSE, .alphaToOneEnable = vk.VK_FALSE,
        };

        // Depth test LESS_OR_EQUAL, no depth write: only renders on sky (depth=1.0)
        const depth_stencil = vk.VkPipelineDepthStencilStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO, .pNext = null, .flags = 0,
            .depthTestEnable = vk.VK_TRUE,
            .depthWriteEnable = vk.VK_FALSE,
            .depthCompareOp = vk.VK_COMPARE_OP_LESS_OR_EQUAL,
            .depthBoundsTestEnable = vk.VK_FALSE, .stencilTestEnable = vk.VK_FALSE,
            .front = std.mem.zeroes(vk.VkStencilOpState), .back = std.mem.zeroes(vk.VkStencilOpState),
            .minDepthBounds = 0, .maxDepthBounds = 1,
        };

        // Additive blending: sun/moon light adds to the sky color
        const blend_att = vk.VkPipelineColorBlendAttachmentState{
            .blendEnable = vk.VK_TRUE,
            .srcColorBlendFactor = vk.VK_BLEND_FACTOR_SRC_ALPHA,
            .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .colorBlendOp = vk.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ZERO,
            .alphaBlendOp = vk.VK_BLEND_OP_ADD,
            .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT | vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT,
        };
        const color_blending = vk.VkPipelineColorBlendStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .pNext = null, .flags = 0,
            .logicOpEnable = vk.VK_FALSE, .logicOp = 0,
            .attachmentCount = 1, .pAttachments = &blend_att,
            .blendConstants = .{ 0, 0, 0, 0 },
        };

        const push_range = vk.VkPushConstantRange{
            .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .offset = 0,
            .size = 96, // mat4 (64) + vec4 sun (16) + vec4 moon (16)
        };

        self.pipeline_layout = try vk.createPipelineLayout(device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .pNext = null, .flags = 0,
            .setLayoutCount = 1, .pSetLayouts = &self.descriptor_set_layout,
            .pushConstantRangeCount = 1, .pPushConstantRanges = &push_range,
        }, null);

        const color_fmt = [_]vk.VkFormat{swapchain_format};
        const rendering_info = vk.VkPipelineRenderingCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO, .pNext = null,
            .viewMask = 0,
            .colorAttachmentCount = 1, .pColorAttachmentFormats = &color_fmt,
            .depthAttachmentFormat = vk.VK_FORMAT_D32_SFLOAT,
            .stencilAttachmentFormat = vk.VK_FORMAT_UNDEFINED,
        };

        const dyn_states = [_]vk.VkDynamicState{ vk.VK_DYNAMIC_STATE_VIEWPORT, vk.VK_DYNAMIC_STATE_SCISSOR };
        const dyn_info = vk.VkPipelineDynamicStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO, .pNext = null, .flags = 0,
            .dynamicStateCount = 2, .pDynamicStates = &dyn_states,
        };

        const pipeline_info = vk.VkGraphicsPipelineCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .pNext = &rendering_info, .flags = 0,
            .stageCount = 2, .pStages = &shader_stages,
            .pVertexInputState = &vertex_input, .pInputAssemblyState = &input_assembly,
            .pTessellationState = null, .pViewportState = &viewport_state,
            .pRasterizationState = &rasterizer, .pMultisampleState = &multisampling,
            .pDepthStencilState = &depth_stencil, .pColorBlendState = &color_blending,
            .pDynamicState = @ptrCast(&dyn_info),
            .layout = self.pipeline_layout, .renderPass = null, .subpass = 0,
            .basePipelineHandle = null, .basePipelineIndex = -1,
        };

        var pipelines: [1]vk.VkPipeline = undefined;
        try vk.createGraphicsPipelines(device, null, 1, &[1]vk.VkGraphicsPipelineCreateInfo{pipeline_info}, null, &pipelines);
        self.pipeline = pipelines[0];

        std.log.info("Sky pipeline created", .{});
    }
};
