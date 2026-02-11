/// TextureManager - Loads block textures into a Vulkan texture array
/// Uses sampler2DArray for bindless-style texture access
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const volk = @import("volk");
const vk = volk.c;
const stb_image = @import("stb_image");
const shared = @import("Shared");
const Logger = shared.Logger;

pub const TextureManager = struct {
    const Self = @This();
    const logger = Logger.scoped(Self);

    // All block textures are 16x16
    pub const TEXTURE_SIZE: u32 = 16;
    pub const MAX_TEXTURES: u32 = 256; // Max textures in array

    /// Missing texture index - always 0, pink/black checkerboard
    pub const MISSING_TEXTURE_INDEX: u32 = 0;

    // Minecraft missing texture colors (RGBA format)
    const MISSING_COLOR_PINK: u32 = 0xFFF800F8; // Magenta/pink
    const MISSING_COLOR_BLACK: u32 = 0xFF000000; // Black

    allocator: std.mem.Allocator,
    io: Io,
    assets_path: []const u8,

    // Texture name -> array layer index
    texture_indices: std.StringHashMap(u32),
    texture_count: u32,

    texture_array: vk.VkImage,
    texture_array_memory: vk.VkDeviceMemory,
    texture_array_view: vk.VkImageView,
    texture_sampler: vk.VkSampler,

    device: vk.VkDevice,
    physical_device: vk.VkPhysicalDevice,
    command_pool: vk.VkCommandPool,
    graphics_queue: vk.VkQueue,

    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        assets_path: []const u8,
        device: vk.VkDevice,
        physical_device: vk.VkPhysicalDevice,
        command_pool: vk.VkCommandPool,
        graphics_queue: vk.VkQueue,
    ) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .assets_path = assets_path,
            .texture_indices = std.StringHashMap(u32).init(allocator),
            .texture_count = 0,
            .texture_array = null,
            .texture_array_memory = null,
            .texture_array_view = null,
            .texture_sampler = null,
            .device = device,
            .physical_device = physical_device,
            .command_pool = command_pool,
            .graphics_queue = graphics_queue,
        };
    }

    pub fn deinit(self: *Self) void {
        const vkDestroyImage = vk.vkDestroyImage orelse return;
        const vkFreeMemory = vk.vkFreeMemory orelse return;
        const vkDestroyImageView = vk.vkDestroyImageView orelse return;
        const vkDestroySampler = vk.vkDestroySampler orelse return;

        if (self.texture_sampler) |sampler| {
            vkDestroySampler(self.device, sampler, null);
        }
        if (self.texture_array_view) |view| {
            vkDestroyImageView(self.device, view, null);
        }
        if (self.texture_array) |image| {
            vkDestroyImage(self.device, image, null);
        }
        if (self.texture_array_memory) |memory| {
            vkFreeMemory(self.device, memory, null);
        }

        var it = self.texture_indices.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.texture_indices.deinit();
    }

    /// Load all block textures from assets directory
    /// Layer 0 is always the missing texture (pink/black checkerboard)
    /// Uses a single batched command buffer for all GPU operations (zero queue stalls).
    pub fn loadBlockTextures(self: *Self) !void {
        const vkCreateBuffer = vk.vkCreateBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkGetBufferMemoryRequirements = vk.vkGetBufferMemoryRequirements orelse return error.VulkanFunctionNotLoaded;
        const vkAllocateMemory = vk.vkAllocateMemory orelse return error.VulkanFunctionNotLoaded;
        const vkBindBufferMemory = vk.vkBindBufferMemory orelse return error.VulkanFunctionNotLoaded;
        const vkMapMemory = vk.vkMapMemory orelse return error.VulkanFunctionNotLoaded;
        const vkUnmapMemory = vk.vkUnmapMemory orelse return error.VulkanFunctionNotLoaded;
        const vkDestroyBuffer = vk.vkDestroyBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkFreeMemory = vk.vkFreeMemory orelse return error.VulkanFunctionNotLoaded;
        const vkAllocateCommandBuffers = vk.vkAllocateCommandBuffers orelse return error.VulkanFunctionNotLoaded;
        const vkBeginCommandBuffer = vk.vkBeginCommandBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkEndCommandBuffer = vk.vkEndCommandBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkCmdPipelineBarrier = vk.vkCmdPipelineBarrier orelse return error.VulkanFunctionNotLoaded;
        const vkCmdCopyBufferToImage = vk.vkCmdCopyBufferToImage orelse return error.VulkanFunctionNotLoaded;
        const vkQueueSubmit = vk.vkQueueSubmit orelse return error.VulkanFunctionNotLoaded;
        const vkCreateFence = vk.vkCreateFence orelse return error.VulkanFunctionNotLoaded;
        const vkWaitForFences = vk.vkWaitForFences orelse return error.VulkanFunctionNotLoaded;
        const vkDestroyFence = vk.vkDestroyFence orelse return error.VulkanFunctionNotLoaded;
        const vkFreeCommandBuffers = vk.vkFreeCommandBuffers orelse return error.VulkanFunctionNotLoaded;

        const texture_dir = try std.fmt.allocPrint(
            self.allocator,
            "{s}/farhorizons/textures/block",
            .{self.assets_path},
        );
        defer self.allocator.free(texture_dir);

        var dir = Dir.cwd().openDir(self.io, texture_dir, .{ .iterate = true }) catch |err| {
            logger.err("Failed to open texture directory: {s} - {}", .{ texture_dir, err });
            return error.TextureDirectoryNotFound;
        };
        defer dir.close(self.io);

        // First pass: count textures
        var count: u32 = 0;
        var iter = dir.iterate();
        while (try iter.next(self.io)) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".png")) {
                count += 1;
            }
        }

        if (count == 0) {
            logger.err("No textures found in {s}", .{texture_dir});
            return error.NoTexturesFound;
        }

        const total_layers = count + 1; // +1 for missing texture at index 0
        logger.info("Found {d} block textures (+ 1 missing texture)", .{count});

        // Create the texture array image
        try self.createTextureArray(total_layers);

        // --- Batched upload: single staging buffer, single command buffer ---

        const layer_size: vk.VkDeviceSize = TEXTURE_SIZE * TEXTURE_SIZE * 4;
        const staging_size: vk.VkDeviceSize = layer_size * total_layers;

        // Create single staging buffer for ALL textures
        var staging_buffer: vk.VkBuffer = null;
        var staging_buffer_memory: vk.VkDeviceMemory = null;

        const staging_buffer_info = vk.VkBufferCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = staging_size,
            .usage = vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };

        if (vkCreateBuffer(self.device, &staging_buffer_info, null, &staging_buffer) != vk.VK_SUCCESS) {
            return error.BufferCreationFailed;
        }
        defer vkDestroyBuffer(self.device, staging_buffer, null);

        var mem_requirements: vk.VkMemoryRequirements = undefined;
        vkGetBufferMemoryRequirements(self.device, staging_buffer, &mem_requirements);

        const staging_alloc_info = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = mem_requirements.size,
            .memoryTypeIndex = try self.findMemoryType(
                mem_requirements.memoryTypeBits,
                vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            ),
        };

        if (vkAllocateMemory(self.device, &staging_alloc_info, null, &staging_buffer_memory) != vk.VK_SUCCESS) {
            return error.MemoryAllocationFailed;
        }
        defer vkFreeMemory(self.device, staging_buffer_memory, null);

        if (vkBindBufferMemory(self.device, staging_buffer, staging_buffer_memory, 0) != vk.VK_SUCCESS) {
            return error.BufferMemoryBindFailed;
        }

        // Map entire staging buffer
        var mapped_ptr: ?*anyopaque = null;
        if (vkMapMemory(self.device, staging_buffer_memory, 0, staging_size, 0, &mapped_ptr) != vk.VK_SUCCESS) {
            return error.MemoryMapFailed;
        }
        const staging_bytes: [*]u8 = @ptrCast(mapped_ptr);

        // Write missing texture (layer 0) into staging buffer
        {
            const pixels: [*]u32 = @ptrCast(@alignCast(staging_bytes));
            const half_size = TEXTURE_SIZE / 2;
            for (0..TEXTURE_SIZE) |y| {
                for (0..TEXTURE_SIZE) |x| {
                    const in_top_half = y < half_size;
                    const in_left_half = x < half_size;
                    const is_pink = (in_top_half and in_left_half) or (!in_top_half and !in_left_half);
                    const color: u32 = if (is_pink)
                        0xFF | (0x00 << 8) | (0xF8 << 16) | (0xF8 << 24)
                    else
                        0x00 | (0x00 << 8) | (0x00 << 16) | (0xFF << 24);
                    pixels[y * TEXTURE_SIZE + x] = color;
                }
            }
        }
        logger.info("Loaded missing texture (pink/black checkerboard) to layer 0", .{});

        // Load all textures into staging buffer
        dir = Dir.cwd().openDir(self.io, texture_dir, .{ .iterate = true }) catch {
            return error.TextureDirectoryNotFound;
        };
        iter = dir.iterate();

        var layer_index: u32 = 1;
        while (try iter.next(self.io)) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".png")) {
                var path_buf: [512:0]u8 = undefined;
                const path_slice = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ texture_dir, entry.name }) catch {
                    logger.err("Path too long: {s}/{s}", .{ texture_dir, entry.name });
                    return error.PathTooLong;
                };
                path_buf[path_slice.len] = 0;

                stb_image.setFlipVerticallyOnLoad(false);
                const image = stb_image.load(&path_buf, 4) catch {
                    logger.err("Failed to load texture: {s}", .{&path_buf});
                    return error.TextureLoadFailed;
                };
                defer image.free();

                if (image.width != TEXTURE_SIZE or image.height != TEXTURE_SIZE) {
                    logger.err("Texture {s} is {}x{}, expected {}x{}", .{
                        &path_buf, image.width, image.height, TEXTURE_SIZE, TEXTURE_SIZE,
                    });
                    return error.InvalidTextureSize;
                }

                // Copy into staging buffer at correct offset
                const offset: usize = @intCast(layer_size * layer_index);
                @memcpy(staging_bytes[offset..][0..@intCast(layer_size)], image.data[0..@intCast(layer_size)]);

                const name_len = entry.name.len - 4;
                const texture_name = try self.allocator.dupe(u8, entry.name[0..name_len]);
                try self.texture_indices.put(texture_name, layer_index);

                logger.info("Loaded texture '{s}' to layer {d}", .{ texture_name, layer_index });
                layer_index += 1;
            }
        }

        vkUnmapMemory(self.device, staging_buffer_memory);

        self.texture_count = layer_index;

        // --- Record single command buffer for all transitions + copies ---

        const cmd_alloc_info = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };

        var command_buffer: vk.VkCommandBuffer = undefined;
        if (vkAllocateCommandBuffers(self.device, &cmd_alloc_info, &command_buffer) != vk.VK_SUCCESS) {
            return error.CommandBufferAllocationFailed;
        }

        const begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };

        if (vkBeginCommandBuffer(command_buffer, &begin_info) != vk.VK_SUCCESS) {
            return error.CommandBufferBeginFailed;
        }

        // Transition ALL layers: UNDEFINED → TRANSFER_DST (single barrier)
        const to_transfer_barrier = vk.VkImageMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = 0,
            .dstAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = self.texture_array,
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = self.texture_count,
            },
        };

        vkCmdPipelineBarrier(
            command_buffer,
            vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            0, 0, null, 0, null,
            1, &to_transfer_barrier,
        );

        // Copy ALL layers from staging buffer to image
        var copy_regions: [MAX_TEXTURES]vk.VkBufferImageCopy = undefined;
        for (0..self.texture_count) |i| {
            copy_regions[i] = .{
                .bufferOffset = layer_size * @as(vk.VkDeviceSize, @intCast(i)),
                .bufferRowLength = 0,
                .bufferImageHeight = 0,
                .imageSubresource = .{
                    .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                    .mipLevel = 0,
                    .baseArrayLayer = @intCast(i),
                    .layerCount = 1,
                },
                .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
                .imageExtent = .{
                    .width = TEXTURE_SIZE,
                    .height = TEXTURE_SIZE,
                    .depth = 1,
                },
            };
        }

        vkCmdCopyBufferToImage(
            command_buffer,
            staging_buffer,
            self.texture_array,
            vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            self.texture_count,
            &copy_regions,
        );

        // Transition ALL layers: TRANSFER_DST → SHADER_READ_ONLY (single barrier)
        const to_shader_barrier = vk.VkImageMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = self.texture_array,
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = self.texture_count,
            },
        };

        vkCmdPipelineBarrier(
            command_buffer,
            vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            0, 0, null, 0, null,
            1, &to_shader_barrier,
        );

        if (vkEndCommandBuffer(command_buffer) != vk.VK_SUCCESS) {
            return error.CommandBufferEndFailed;
        }

        // Submit once with a fence (no queue stall)
        var fence: vk.VkFence = null;
        const fence_info = vk.VkFenceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
        };
        if (vkCreateFence(self.device, &fence_info, null, &fence) != vk.VK_SUCCESS) {
            return error.FenceCreationFailed;
        }
        defer vkDestroyFence(self.device, fence, null);

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

        if (vkQueueSubmit(self.graphics_queue, 1, &submit_info, fence) != vk.VK_SUCCESS) {
            return error.QueueSubmitFailed;
        }

        // Single fence wait for the entire batch
        _ = vkWaitForFences(self.device, 1, &fence, vk.VK_TRUE, std.math.maxInt(u64));
        vkFreeCommandBuffers(self.device, self.command_pool, 1, &command_buffer);

        try self.createTextureArrayView();
        try self.createTextureSampler();

        logger.info("TextureManager initialized with {d} textures (single batched upload)", .{self.texture_count});
    }

    /// Get texture array layer index by name (e.g., "stone", "oak_planks")
    /// Returns MISSING_TEXTURE_INDEX (0) if texture is not found
    pub fn getTextureIndex(self: *const Self, name: []const u8) u32 {
        // Handle full path like "block/stone" or "farhorizons:block/stone"
        var texture_name = name;

        // Strip namespace prefix
        if (std.mem.indexOf(u8, texture_name, ":")) |idx| {
            texture_name = texture_name[idx + 1 ..];
        }

        // Strip "block/" prefix
        if (std.mem.startsWith(u8, texture_name, "block/")) {
            texture_name = texture_name[6..];
        }

        // Return the texture index, or missing texture (0) if not found
        return self.texture_indices.get(texture_name) orelse MISSING_TEXTURE_INDEX;
    }

    fn createTextureArray(self: *Self, layer_count: u32) !void {
        const vkCreateImage = vk.vkCreateImage orelse return error.VulkanFunctionNotLoaded;
        const vkGetImageMemoryRequirements = vk.vkGetImageMemoryRequirements orelse return error.VulkanFunctionNotLoaded;
        const vkAllocateMemory = vk.vkAllocateMemory orelse return error.VulkanFunctionNotLoaded;
        const vkBindImageMemory = vk.vkBindImageMemory orelse return error.VulkanFunctionNotLoaded;

        const image_create_info = vk.VkImageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = vk.VK_IMAGE_TYPE_2D,
            .format = vk.VK_FORMAT_R8G8B8A8_SRGB,
            .extent = .{
                .width = TEXTURE_SIZE,
                .height = TEXTURE_SIZE,
                .depth = 1,
            },
            .mipLevels = 1,
            .arrayLayers = layer_count, // This makes it a texture array!
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
            .usage = vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT | vk.VK_IMAGE_USAGE_SAMPLED_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        };

        if (vkCreateImage(self.device, &image_create_info, null, &self.texture_array) != vk.VK_SUCCESS) {
            return error.ImageCreationFailed;
        }

        var mem_requirements: vk.VkMemoryRequirements = undefined;
        vkGetImageMemoryRequirements(self.device, self.texture_array, &mem_requirements);

        const alloc_info = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = mem_requirements.size,
            .memoryTypeIndex = try self.findMemoryType(
                mem_requirements.memoryTypeBits,
                vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            ),
        };

        if (vkAllocateMemory(self.device, &alloc_info, null, &self.texture_array_memory) != vk.VK_SUCCESS) {
            return error.MemoryAllocationFailed;
        }

        if (vkBindImageMemory(self.device, self.texture_array, self.texture_array_memory, 0) != vk.VK_SUCCESS) {
            return error.ImageMemoryBindFailed;
        }

        logger.info("Created texture array with {d} layers", .{layer_count});
    }


    fn createTextureArrayView(self: *Self) !void {
        const vkCreateImageView = vk.vkCreateImageView orelse return error.VulkanFunctionNotLoaded;

        const view_info = vk.VkImageViewCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = self.texture_array,
            .viewType = vk.VK_IMAGE_VIEW_TYPE_2D_ARRAY, // Array view!
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
                .layerCount = self.texture_count,
            },
        };

        if (vkCreateImageView(self.device, &view_info, null, &self.texture_array_view) != vk.VK_SUCCESS) {
            return error.ImageViewCreationFailed;
        }

        logger.info("Texture array view created", .{});
    }

    fn createTextureSampler(self: *Self) !void {
        const vkCreateSampler = vk.vkCreateSampler orelse return error.VulkanFunctionNotLoaded;

        const sampler_info = vk.VkSamplerCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .magFilter = vk.VK_FILTER_NEAREST, // Pixelated look
            .minFilter = vk.VK_FILTER_NEAREST,
            .mipmapMode = vk.VK_SAMPLER_MIPMAP_MODE_NEAREST,
            .addressModeU = vk.VK_SAMPLER_ADDRESS_MODE_REPEAT,
            .addressModeV = vk.VK_SAMPLER_ADDRESS_MODE_REPEAT,
            .addressModeW = vk.VK_SAMPLER_ADDRESS_MODE_REPEAT,
            .mipLodBias = 0.0,
            .anisotropyEnable = vk.VK_FALSE,
            .maxAnisotropy = 1.0,
            .compareEnable = vk.VK_FALSE,
            .compareOp = vk.VK_COMPARE_OP_ALWAYS,
            .minLod = 0.0,
            .maxLod = 0.0,
            .borderColor = vk.VK_BORDER_COLOR_INT_OPAQUE_BLACK,
            .unnormalizedCoordinates = vk.VK_FALSE,
        };

        if (vkCreateSampler(self.device, &sampler_info, null, &self.texture_sampler) != vk.VK_SUCCESS) {
            return error.SamplerCreationFailed;
        }

        logger.info("Texture sampler created", .{});
    }

    fn findMemoryType(self: *Self, type_filter: u32, properties: vk.VkMemoryPropertyFlags) !u32 {
        const vkGetPhysicalDeviceMemoryProperties = vk.vkGetPhysicalDeviceMemoryProperties orelse return error.VulkanFunctionNotLoaded;

        var mem_properties: vk.VkPhysicalDeviceMemoryProperties = undefined;
        vkGetPhysicalDeviceMemoryProperties(self.physical_device, &mem_properties);

        for (0..mem_properties.memoryTypeCount) |i| {
            const type_bit = @as(u32, 1) << @intCast(i);
            if ((type_filter & type_bit) != 0 and
                (mem_properties.memoryTypes[i].propertyFlags & properties) == properties)
            {
                return @intCast(i);
            }
        }

        return error.NoSuitableMemoryType;
    }

    // Accessors for RenderSystem
    pub fn getImageView(self: *const Self) vk.VkImageView {
        return self.texture_array_view;
    }

    pub fn getSampler(self: *const Self) vk.VkSampler {
        return self.texture_sampler;
    }
};
