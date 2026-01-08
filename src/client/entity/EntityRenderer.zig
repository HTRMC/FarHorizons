const std = @import("std");
const shared = @import("Shared");
const renderer = @import("Renderer");
const volk = @import("volk");
const vk = volk.c;

const Entity = @import("Entity.zig").Entity;
const EntityType = @import("Entity.zig").EntityType;
const EntityManager = @import("Entity.zig").EntityManager;
const CowModel = @import("models/CowModel.zig").CowModel;
const BabyCowModel = @import("models/BabyCowModel.zig").BabyCowModel;
const Vertex = renderer.Vertex;
const GpuDevice = renderer.GpuDevice;
const Logger = shared.Logger;
const Mat4 = shared.Mat4;
const stb_image = @import("stb_image");

pub const EntityRenderer = struct {
    const Self = @This();
    const logger = Logger.init("EntityRenderer");

    allocator: std.mem.Allocator,
    gpu_device: *GpuDevice,
    asset_directory: []const u8,

    // Cow models (adult and baby)
    cow_model: CowModel,
    baby_cow_model: BabyCowModel,

    // GPU buffers for entity rendering
    vertex_buffer: vk.VkBuffer = null,
    vertex_buffer_memory: vk.VkDeviceMemory = null,
    index_buffer: vk.VkBuffer = null,
    index_buffer_memory: vk.VkDeviceMemory = null,

    // Entity texture (cow texture)
    texture_image: vk.VkImage = null,
    texture_memory: vk.VkDeviceMemory = null,
    texture_view: vk.VkImageView = null,
    texture_sampler: vk.VkSampler = null,

    // Current buffer sizes
    vertex_count: u32 = 0,
    index_count: u32 = 0,

    // Cached mesh data
    cached_vertices: ?[]Vertex = null,
    cached_indices: ?[]u32 = null,

    pub fn init(allocator: std.mem.Allocator, gpu_device: *GpuDevice, asset_directory: []const u8) !Self {
        var self = Self{
            .allocator = allocator,
            .gpu_device = gpu_device,
            .asset_directory = asset_directory,
            .cow_model = CowModel.init(allocator),
            .baby_cow_model = BabyCowModel.init(allocator),
        };

        // Load cow texture
        try self.loadCowTexture();

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.destroyBuffers();
        self.destroyTexture();
        self.cow_model.deinit();
        self.baby_cow_model.deinit();

        if (self.cached_vertices) |verts| {
            self.allocator.free(verts);
        }

        if (self.cached_indices) |inds| {
            self.allocator.free(inds);
        }
    }

    fn destroyBuffers(self: *Self) void {
        if (self.vertex_buffer != null) {
            self.gpu_device.destroyBufferRaw(.{
                .handle = self.vertex_buffer,
                .memory = self.vertex_buffer_memory,
            });
            self.vertex_buffer = null;
            self.vertex_buffer_memory = null;
        }
        if (self.index_buffer != null) {
            self.gpu_device.destroyBufferRaw(.{
                .handle = self.index_buffer,
                .memory = self.index_buffer_memory,
            });
            self.index_buffer = null;
            self.index_buffer_memory = null;
        }
    }

    fn destroyTexture(self: *Self) void {
        const vkDestroySampler = vk.vkDestroySampler orelse return;
        const vkDestroyImageView = vk.vkDestroyImageView orelse return;
        const vkDestroyImage = vk.vkDestroyImage orelse return;
        const vkFreeMemory = vk.vkFreeMemory orelse return;

        if (self.texture_sampler != null) {
            vkDestroySampler(self.gpu_device.device, self.texture_sampler, null);
            self.texture_sampler = null;
        }
        if (self.texture_view != null) {
            vkDestroyImageView(self.gpu_device.device, self.texture_view, null);
            self.texture_view = null;
        }
        if (self.texture_image != null) {
            vkDestroyImage(self.gpu_device.device, self.texture_image, null);
            self.texture_image = null;
        }
        if (self.texture_memory != null) {
            vkFreeMemory(self.gpu_device.device, self.texture_memory, null);
            self.texture_memory = null;
        }
    }

    fn loadCowTexture(self: *Self) !void {
        const vkCreateImage = vk.vkCreateImage orelse return error.VulkanFunctionNotLoaded;
        const vkGetImageMemoryRequirements = vk.vkGetImageMemoryRequirements orelse return error.VulkanFunctionNotLoaded;
        const vkAllocateMemory = vk.vkAllocateMemory orelse return error.VulkanFunctionNotLoaded;
        const vkBindImageMemory = vk.vkBindImageMemory orelse return error.VulkanFunctionNotLoaded;
        const vkCreateImageView = vk.vkCreateImageView orelse return error.VulkanFunctionNotLoaded;
        const vkCreateSampler = vk.vkCreateSampler orelse return error.VulkanFunctionNotLoaded;

        // Build path to cow texture
        const texture_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/farhorizons/textures/entity/cow/cow.png",
            .{self.asset_directory},
        );
        defer self.allocator.free(texture_path);

        logger.info("Loading cow texture from: {s}", .{texture_path});

        // Load image
        const path_z = try self.allocator.dupeZ(u8, texture_path);
        defer self.allocator.free(path_z);

        const image = stb_image.load(path_z.ptr, 4) catch {
            logger.err("Failed to load cow texture: {s}", .{texture_path});
            if (stb_image.failureReason()) |reason| {
                logger.err("STB error: {s}", .{reason});
            }
            return error.TextureLoadFailed;
        };
        defer image.free();

        const width: u32 = @intCast(image.width);
        const height: u32 = @intCast(image.height);
        logger.info("Loaded cow texture: {d}x{d}", .{ width, height });

        // Create staging buffer and copy pixel data
        const image_size: u64 = @as(u64, width) * @as(u64, height) * 4;
        const staging = try self.gpu_device.createMappedBufferRaw(image_size, vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
        defer self.gpu_device.destroyMappedBufferRaw(staging);

        const mapped_bytes = @as([*]u8, @ptrCast(staging.mapped))[0..image_size];
        @memcpy(mapped_bytes, image.data[0..image_size]);

        // Create VkImage
        const image_info = vk.VkImageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = vk.VK_IMAGE_TYPE_2D,
            .format = vk.VK_FORMAT_R8G8B8A8_SRGB,
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

        const device = self.gpu_device.getDevice();
        if (vkCreateImage(device, &image_info, null, &self.texture_image) != vk.VK_SUCCESS) {
            return error.ImageCreationFailed;
        }

        var img_mem_req: vk.VkMemoryRequirements = undefined;
        vkGetImageMemoryRequirements(device, self.texture_image, &img_mem_req);

        const img_alloc_info = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = img_mem_req.size,
            .memoryTypeIndex = try self.findMemoryType(img_mem_req.memoryTypeBits, vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
        };

        if (vkAllocateMemory(device, &img_alloc_info, null, &self.texture_memory) != vk.VK_SUCCESS) {
            return error.MemoryAllocationFailed;
        }

        if (vkBindImageMemory(device, self.texture_image, self.texture_memory, 0) != vk.VK_SUCCESS) {
            return error.ImageBindFailed;
        }

        // Transition image and copy from staging buffer
        try self.transitionImageLayout(self.texture_image, vk.VK_IMAGE_LAYOUT_UNDEFINED, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
        try self.copyBufferToImage(staging.handle, self.texture_image, width, height);
        try self.transitionImageLayout(self.texture_image, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);

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

        if (vkCreateImageView(device, &view_info, null, &self.texture_view) != vk.VK_SUCCESS) {
            return error.ImageViewCreationFailed;
        }

        // Create sampler (nearest neighbor for pixel-perfect rendering)
        const sampler_info = vk.VkSamplerCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .magFilter = vk.VK_FILTER_NEAREST,
            .minFilter = vk.VK_FILTER_NEAREST,
            .addressModeU = vk.VK_SAMPLER_ADDRESS_MODE_REPEAT,
            .addressModeV = vk.VK_SAMPLER_ADDRESS_MODE_REPEAT,
            .addressModeW = vk.VK_SAMPLER_ADDRESS_MODE_REPEAT,
            .anisotropyEnable = vk.VK_FALSE,
            .maxAnisotropy = 1.0,
            .borderColor = vk.VK_BORDER_COLOR_INT_OPAQUE_BLACK,
            .unnormalizedCoordinates = vk.VK_FALSE,
            .compareEnable = vk.VK_FALSE,
            .compareOp = vk.VK_COMPARE_OP_ALWAYS,
            .mipmapMode = vk.VK_SAMPLER_MIPMAP_MODE_LINEAR,
            .mipLodBias = 0.0,
            .minLod = 0.0,
            .maxLod = 0.0,
        };

        if (vkCreateSampler(device, &sampler_info, null, &self.texture_sampler) != vk.VK_SUCCESS) {
            return error.SamplerCreationFailed;
        }

        logger.info("Cow texture loaded successfully", .{});
    }

    fn findMemoryType(self: *Self, type_filter: u32, properties: vk.VkMemoryPropertyFlags) !u32 {
        const vkGetPhysicalDeviceMemoryProperties = vk.vkGetPhysicalDeviceMemoryProperties orelse return error.VulkanFunctionNotLoaded;

        var mem_properties: vk.VkPhysicalDeviceMemoryProperties = undefined;
        vkGetPhysicalDeviceMemoryProperties(self.gpu_device.getPhysicalDevice(), &mem_properties);

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

    fn transitionImageLayout(
        self: *Self,
        image: vk.VkImage,
        old_layout: vk.VkImageLayout,
        new_layout: vk.VkImageLayout,
    ) !void {
        const vkAllocateCommandBuffers = vk.vkAllocateCommandBuffers orelse return error.VulkanFunctionNotLoaded;
        const vkBeginCommandBuffer = vk.vkBeginCommandBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkCmdPipelineBarrier = vk.vkCmdPipelineBarrier orelse return error.VulkanFunctionNotLoaded;
        const vkEndCommandBuffer = vk.vkEndCommandBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkQueueSubmit = vk.vkQueueSubmit orelse return error.VulkanFunctionNotLoaded;
        const vkQueueWaitIdle = vk.vkQueueWaitIdle orelse return error.VulkanFunctionNotLoaded;
        const vkFreeCommandBuffers = vk.vkFreeCommandBuffers orelse return error.VulkanFunctionNotLoaded;

        // Allocate command buffer
        const alloc_info = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.gpu_device.getCommandPool(),
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };

        var command_buffer: vk.VkCommandBuffer = undefined;
        if (vkAllocateCommandBuffers(self.gpu_device.getDevice(), &alloc_info, &command_buffer) != vk.VK_SUCCESS) {
            return error.CommandBufferAllocationFailed;
        }
        defer vkFreeCommandBuffers(self.gpu_device.getDevice(), self.gpu_device.getCommandPool(), 1, &command_buffer);

        // Begin command buffer
        const begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };

        if (vkBeginCommandBuffer(command_buffer, &begin_info) != vk.VK_SUCCESS) {
            return error.CommandBufferBeginFailed;
        }

        // Transition image layout
        var src_stage: vk.VkPipelineStageFlags = undefined;
        var dst_stage: vk.VkPipelineStageFlags = undefined;
        var src_access: vk.VkAccessFlags = 0;
        var dst_access: vk.VkAccessFlags = 0;

        if (old_layout == vk.VK_IMAGE_LAYOUT_UNDEFINED and new_layout == vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) {
            src_access = 0;
            dst_access = vk.VK_ACCESS_TRANSFER_WRITE_BIT;
            src_stage = vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
            dst_stage = vk.VK_PIPELINE_STAGE_TRANSFER_BIT;
        } else if (old_layout == vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL and new_layout == vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) {
            src_access = vk.VK_ACCESS_TRANSFER_WRITE_BIT;
            dst_access = vk.VK_ACCESS_SHADER_READ_BIT;
            src_stage = vk.VK_PIPELINE_STAGE_TRANSFER_BIT;
            dst_stage = vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
        } else {
            return error.UnsupportedLayoutTransition;
        }

        const barrier = vk.VkImageMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = src_access,
            .dstAccessMask = dst_access,
            .oldLayout = old_layout,
            .newLayout = new_layout,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        vkCmdPipelineBarrier(command_buffer, src_stage, dst_stage, 0, 0, null, 0, null, 1, &barrier);

        if (vkEndCommandBuffer(command_buffer) != vk.VK_SUCCESS) {
            return error.CommandBufferEndFailed;
        }

        // Submit command buffer
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

        if (vkQueueSubmit(self.gpu_device.getGraphicsQueue(), 1, &submit_info, null) != vk.VK_SUCCESS) {
            return error.QueueSubmitFailed;
        }

        _ = vkQueueWaitIdle(self.gpu_device.getGraphicsQueue());
    }

    fn copyBufferToImage(
        self: *Self,
        buffer: vk.VkBuffer,
        image: vk.VkImage,
        width: u32,
        height: u32,
    ) !void {
        const vkAllocateCommandBuffers = vk.vkAllocateCommandBuffers orelse return error.VulkanFunctionNotLoaded;
        const vkBeginCommandBuffer = vk.vkBeginCommandBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkCmdCopyBufferToImage = vk.vkCmdCopyBufferToImage orelse return error.VulkanFunctionNotLoaded;
        const vkEndCommandBuffer = vk.vkEndCommandBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkQueueSubmit = vk.vkQueueSubmit orelse return error.VulkanFunctionNotLoaded;
        const vkQueueWaitIdle = vk.vkQueueWaitIdle orelse return error.VulkanFunctionNotLoaded;
        const vkFreeCommandBuffers = vk.vkFreeCommandBuffers orelse return error.VulkanFunctionNotLoaded;

        // Allocate command buffer
        const alloc_info = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.gpu_device.getCommandPool(),
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };

        var command_buffer: vk.VkCommandBuffer = undefined;
        if (vkAllocateCommandBuffers(self.gpu_device.getDevice(), &alloc_info, &command_buffer) != vk.VK_SUCCESS) {
            return error.CommandBufferAllocationFailed;
        }
        defer vkFreeCommandBuffers(self.gpu_device.getDevice(), self.gpu_device.getCommandPool(), 1, &command_buffer);

        // Begin command buffer
        const begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };

        if (vkBeginCommandBuffer(command_buffer, &begin_info) != vk.VK_SUCCESS) {
            return error.CommandBufferBeginFailed;
        }

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
                .width = width,
                .height = height,
                .depth = 1,
            },
        };

        vkCmdCopyBufferToImage(command_buffer, buffer, image, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

        if (vkEndCommandBuffer(command_buffer) != vk.VK_SUCCESS) {
            return error.CommandBufferEndFailed;
        }

        // Submit command buffer
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

        if (vkQueueSubmit(self.gpu_device.getGraphicsQueue(), 1, &submit_info, null) != vk.VK_SUCCESS) {
            return error.QueueSubmitFailed;
        }

        _ = vkQueueWaitIdle(self.gpu_device.getGraphicsQueue());
    }

    /// Update entity meshes and upload to GPU
    pub fn update(self: *Self, entity_manager: *EntityManager, partial_tick: f32) !void {
        // Collect all entity vertices/indices
        var all_vertices: std.ArrayList(Vertex) = .empty;
        defer all_vertices.deinit(self.allocator);
        var all_indices: std.ArrayList(u32) = .empty;
        defer all_indices.deinit(self.allocator);

        var iter = entity_manager.iterator();
        while (iter.next()) |entity| {
            const base_vertex: u32 = @intCast(all_vertices.items.len);

            // Generated mesh based on entity type
            switch (entity.entity_type) {
                .cow => {
                    // Select model based on baby state (like MC's AdultAndBabyModelPair)
                    // Get model matrix for transforming vertices
                    const m = entity.getModelMatrix(partial_tick);

                    if (entity.is_baby) {
                        const mesh = try self.baby_cow_model.generateMesh(
                            entity.getWalkAnimation(partial_tick),
                            entity.getWalkSpeed(partial_tick),
                            entity.getHeadPitch(partial_tick),
                            entity.getHeadYaw(partial_tick),
                        );
                        defer self.allocator.free(mesh.vertices);
                        defer self.allocator.free(mesh.indices);

                        for (mesh.vertices) |vert| {
                            var transformed = vert;
                            const x = vert.pos[0];
                            const y = vert.pos[1];
                            const z = vert.pos[2];
                            transformed.pos = .{
                                m.data[0] * x + m.data[4] * y + m.data[8] * z + m.data[12],
                                m.data[1] * x + m.data[5] * y + m.data[9] * z + m.data[13],
                                m.data[2] * x + m.data[6] * y + m.data[10] * z + m.data[14],
                            };
                            try all_vertices.append(self.allocator, transformed);
                        }

                        for (mesh.indices) |idx| {
                            try all_indices.append(self.allocator, base_vertex + idx);
                        }
                    } else {
                        const mesh = try self.cow_model.generateMesh(
                            entity.getWalkAnimation(partial_tick),
                            entity.getWalkSpeed(partial_tick),
                            entity.getHeadPitch(partial_tick),
                            entity.getHeadYaw(partial_tick),
                        );
                        defer self.allocator.free(mesh.vertices);
                        defer self.allocator.free(mesh.indices);

                        for (mesh.vertices) |vert| {
                            var transformed = vert;
                            const x = vert.pos[0];
                            const y = vert.pos[1];
                            const z = vert.pos[2];
                            transformed.pos = .{
                                m.data[0] * x + m.data[4] * y + m.data[8] * z + m.data[12],
                                m.data[1] * x + m.data[5] * y + m.data[9] * z + m.data[13],
                                m.data[2] * x + m.data[6] * y + m.data[10] * z + m.data[14],
                            };
                            try all_vertices.append(self.allocator, transformed);
                        }

                        for (mesh.indices) |idx| {
                            try all_indices.append(self.allocator, base_vertex + idx);
                        }
                    }
                },
                else => {
                    // Other entity types not implemented yet
                },
            }
        }

        if (all_vertices.items.len == 0) {
            self.vertex_count = 0;
            self.index_count = 0;
            return;
        }

        // Recreate buffers if size changed
        self.destroyBuffers();

        // Create vertex buffer
        const vertex_result = try self.gpu_device.createBufferWithDataRaw(
            Vertex,
            all_vertices.items,
            vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        );
        self.vertex_buffer = vertex_result.handle;
        self.vertex_buffer_memory = vertex_result.memory;

        // Create index buffer
        const index_result = try self.gpu_device.createBufferWithDataRaw(
            u32,
            all_indices.items,
            vk.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
        );
        self.index_buffer = index_result.handle;
        self.index_buffer_memory = index_result.memory;

        self.vertex_count = @intCast(all_vertices.items.len);
        self.index_count = @intCast(all_indices.items.len);
    }

    /// Record draw commands into command buffer
    /// Call this after binding the entity pipeline
    pub fn recordDrawCommands(self: *const Self, command_buffer: vk.VkCommandBuffer) void {
        if (self.index_count == 0 or self.vertex_buffer == null) return;

        const vkCmdBindVertexBuffers = vk.vkCmdBindVertexBuffers orelse return;
        const vkCmdBindIndexBuffer = vk.vkCmdBindIndexBuffer orelse return;
        const vkCmdDrawIndexed = vk.vkCmdDrawIndexed orelse return;

        const vertex_buffers = [_]vk.VkBuffer{self.vertex_buffer};
        const offsets = [_]vk.VkDeviceSize{0};
        vkCmdBindVertexBuffers(command_buffer, 0, 1, &vertex_buffers, &offsets);
        vkCmdBindIndexBuffer(command_buffer, self.index_buffer, 0, vk.VK_INDEX_TYPE_UINT32);
        vkCmdDrawIndexed(command_buffer, self.index_count, 1, 0, 0, 0);
    }

    pub fn hasEntities(self: *const Self) bool {
        return self.index_count > 0;
    }

    /// Get vertex buffer for external rendering
    pub fn getVertexBuffer(self: *const Self) ?vk.VkBuffer {
        return self.vertex_buffer;
    }

    /// Get index buffer for external rendering
    pub fn getIndexBuffer(self: *const Self) ?vk.VkBuffer {
        return self.index_buffer;
    }

    /// Get index count for external rendering
    pub fn getIndexCount(self: *const Self) u32 {
        return self.index_count;
    }

    /// Get texture view for binding
    pub fn getTextureView(self: *const Self) vk.VkImageView {
        return self.texture_view;
    }

    /// Get texture sampler for binding
    pub fn getTextureSampler(self: *const Self) vk.VkSampler {
        return self.texture_sampler;
    }
};