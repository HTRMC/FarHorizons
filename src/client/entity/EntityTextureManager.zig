const std = @import("std");
const volk = @import("volk");
const vk = volk.c;
const shared = @import("Shared");
const stb_image = @import("stb_image");

const Logger = shared.Logger;

/// Maximum number of entity textures in the bindless array
pub const MAX_ENTITY_TEXTURES: u32 = 256;

/// Manages bindless entity textures using descriptor indexing
/// All entity textures are loaded into a single descriptor set with an array of samplers
/// Shaders index into this array using a texture_index vertex attribute
pub const EntityTextureManager = struct {
    const Self = @This();
    const logger = Logger.init("EntityTextureManager");

    allocator: std.mem.Allocator,
    device: vk.VkDevice,
    physical_device: vk.VkPhysicalDevice,
    command_pool: vk.VkCommandPool,
    graphics_queue: vk.VkQueue,

    // Bindless descriptor resources
    descriptor_set_layout: vk.VkDescriptorSetLayout = null,
    descriptor_pool: vk.VkDescriptorPool = null,
    descriptor_set: vk.VkDescriptorSet = null,

    // Texture storage
    textures: std.ArrayList(TextureEntry),
    name_to_index: std.StringHashMap(u32),

    // Default sampler for all entity textures (nearest neighbor)
    sampler: vk.VkSampler = null,

    pub const TextureEntry = struct {
        image: vk.VkImage,
        memory: vk.VkDeviceMemory,
        view: vk.VkImageView,
        width: u32,
        height: u32,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        device: vk.VkDevice,
        physical_device: vk.VkPhysicalDevice,
        command_pool: vk.VkCommandPool,
        graphics_queue: vk.VkQueue,
    ) !Self {
        var self = Self{
            .allocator = allocator,
            .device = device,
            .physical_device = physical_device,
            .command_pool = command_pool,
            .graphics_queue = graphics_queue,
            .textures = .empty,
            .name_to_index = std.StringHashMap(u32).init(allocator),
        };

        try self.createSampler();
        try self.createDescriptorSetLayout();
        try self.createDescriptorPool();
        try self.allocateDescriptorSet();

        logger.info("EntityTextureManager initialized with bindless support (max {} textures)", .{MAX_ENTITY_TEXTURES});
        return self;
    }

    pub fn deinit(self: *Self) void {
        const vkDestroySampler = vk.vkDestroySampler orelse return;
        const vkDestroyImageView = vk.vkDestroyImageView orelse return;
        const vkDestroyImage = vk.vkDestroyImage orelse return;
        const vkFreeMemory = vk.vkFreeMemory orelse return;
        const vkDestroyDescriptorPool = vk.vkDestroyDescriptorPool orelse return;
        const vkDestroyDescriptorSetLayout = vk.vkDestroyDescriptorSetLayout orelse return;

        // Destroy all textures
        for (self.textures.items) |tex| {
            vkDestroyImageView(self.device, tex.view, null);
            vkDestroyImage(self.device, tex.image, null);
            vkFreeMemory(self.device, tex.memory, null);
        }
        self.textures.deinit(self.allocator);

        // Free name keys
        var iter = self.name_to_index.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.name_to_index.deinit();

        if (self.sampler != null) {
            vkDestroySampler(self.device, self.sampler, null);
        }
        if (self.descriptor_pool != null) {
            vkDestroyDescriptorPool(self.device, self.descriptor_pool, null);
        }
        if (self.descriptor_set_layout != null) {
            vkDestroyDescriptorSetLayout(self.device, self.descriptor_set_layout, null);
        }
    }

    /// Load a texture and return its index in the bindless array
    pub fn loadTexture(self: *Self, name: []const u8, path: []const u8) !u32 {
        // Check if already loaded
        if (self.name_to_index.get(name)) |existing_index| {
            return existing_index;
        }

        if (self.textures.items.len >= MAX_ENTITY_TEXTURES) {
            logger.err("Maximum entity textures ({}) exceeded", .{MAX_ENTITY_TEXTURES});
            return error.MaxTexturesExceeded;
        }

        logger.info("Loading entity texture: {s} from {s}", .{ name, path });

        // Load image data
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);

        const image = stb_image.load(path_z.ptr, 4) catch {
            logger.err("Failed to load texture: {s}", .{path});
            if (stb_image.failureReason()) |reason| {
                logger.err("STB error: {s}", .{reason});
            }
            return error.TextureLoadFailed;
        };
        defer image.free();

        const width: u32 = @intCast(image.width);
        const height: u32 = @intCast(image.height);
        logger.info("Loaded texture: {d}x{d}", .{ width, height });

        // Create Vulkan image
        const tex_entry = try self.createTextureImage(image.data, width, height);

        // Store texture entry
        const index: u32 = @intCast(self.textures.items.len);
        try self.textures.append(self.allocator, tex_entry);

        // Store name mapping
        const name_copy = try self.allocator.dupe(u8, name);
        try self.name_to_index.put(name_copy, index);

        // Update descriptor set
        try self.updateDescriptor(index, tex_entry.view);

        logger.info("Texture '{s}' loaded at index {}", .{ name, index });
        return index;
    }

    /// Get texture index by name (returns null if not found)
    pub fn getTextureIndex(self: *const Self, name: []const u8) ?u32 {
        return self.name_to_index.get(name);
    }

    /// Get the descriptor set layout for pipeline creation
    pub fn getDescriptorSetLayout(self: *const Self) vk.VkDescriptorSetLayout {
        return self.descriptor_set_layout;
    }

    /// Get the descriptor set for binding
    pub fn getDescriptorSet(self: *const Self) vk.VkDescriptorSet {
        return self.descriptor_set;
    }

    fn createSampler(self: *Self) !void {
        const vkCreateSampler = vk.vkCreateSampler orelse return error.VulkanFunctionNotLoaded;

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
            .mipmapMode = vk.VK_SAMPLER_MIPMAP_MODE_NEAREST,
            .mipLodBias = 0.0,
            .minLod = 0.0,
            .maxLod = 0.0,
        };

        if (vkCreateSampler(self.device, &sampler_info, null, &self.sampler) != vk.VK_SUCCESS) {
            return error.SamplerCreationFailed;
        }
    }

    fn createDescriptorSetLayout(self: *Self) !void {
        const vkCreateDescriptorSetLayout = vk.vkCreateDescriptorSetLayout orelse return error.VulkanFunctionNotLoaded;

        // Binding 0: Uniform buffer (for MVP matrices)
        // Binding 1: Bindless texture array (sampled images)
        // Binding 2: Sampler (single sampler for all textures)

        const bindings = [_]vk.VkDescriptorSetLayoutBinding{
            // Binding 0: UBO
            .{
                .binding = 0,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
                .pImmutableSamplers = null,
            },
            // Binding 1: Bindless texture array
            .{
                .binding = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
                .descriptorCount = MAX_ENTITY_TEXTURES,
                .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
                .pImmutableSamplers = null,
            },
            // Binding 2: Sampler
            .{
                .binding = 2,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_SAMPLER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
                .pImmutableSamplers = null,
            },
        };

        // Enable bindless features for binding 1
        const binding_flags = [_]vk.VkDescriptorBindingFlags{
            0, // Binding 0: UBO - no special flags
            vk.VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT |
                vk.VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT |
                vk.VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT, // Binding 1: Bindless textures
            0, // Binding 2: Sampler - no special flags
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

        if (vkCreateDescriptorSetLayout(self.device, &layout_info, null, &self.descriptor_set_layout) != vk.VK_SUCCESS) {
            return error.DescriptorSetLayoutCreationFailed;
        }

        logger.info("Bindless descriptor set layout created", .{});
    }

    fn createDescriptorPool(self: *Self) !void {
        const vkCreateDescriptorPool = vk.vkCreateDescriptorPool orelse return error.VulkanFunctionNotLoaded;

        const pool_sizes = [_]vk.VkDescriptorPoolSize{
            .{
                .type = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .descriptorCount = 1,
            },
            .{
                .type = vk.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
                .descriptorCount = MAX_ENTITY_TEXTURES,
            },
            .{
                .type = vk.VK_DESCRIPTOR_TYPE_SAMPLER,
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

        if (vkCreateDescriptorPool(self.device, &pool_info, null, &self.descriptor_pool) != vk.VK_SUCCESS) {
            return error.DescriptorPoolCreationFailed;
        }

        logger.info("Bindless descriptor pool created", .{});
    }

    fn allocateDescriptorSet(self: *Self) !void {
        const vkAllocateDescriptorSets = vk.vkAllocateDescriptorSets orelse return error.VulkanFunctionNotLoaded;
        const vkUpdateDescriptorSets = vk.vkUpdateDescriptorSets orelse return error.VulkanFunctionNotLoaded;

        // Variable descriptor count for binding 1
        const variable_count: u32 = MAX_ENTITY_TEXTURES;
        const variable_count_info = vk.VkDescriptorSetVariableDescriptorCountAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO,
            .pNext = null,
            .descriptorSetCount = 1,
            .pDescriptorCounts = &variable_count,
        };

        const layouts = [_]vk.VkDescriptorSetLayout{self.descriptor_set_layout};
        const alloc_info = vk.VkDescriptorSetAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = &variable_count_info,
            .descriptorPool = self.descriptor_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &layouts,
        };

        if (vkAllocateDescriptorSets(self.device, &alloc_info, &self.descriptor_set) != vk.VK_SUCCESS) {
            return error.DescriptorSetAllocationFailed;
        }

        // Write the sampler to binding 2
        const sampler_info = vk.VkDescriptorImageInfo{
            .sampler = self.sampler,
            .imageView = null,
            .imageLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        };

        const sampler_write = vk.VkWriteDescriptorSet{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = self.descriptor_set,
            .dstBinding = 2,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_SAMPLER,
            .pImageInfo = &sampler_info,
            .pBufferInfo = null,
            .pTexelBufferView = null,
        };

        vkUpdateDescriptorSets(self.device, 1, &sampler_write, 0, null);

        logger.info("Bindless descriptor set allocated", .{});
    }

    /// Update the UBO binding (call this to set the uniform buffer)
    pub fn updateUniformBuffer(self: *Self, buffer: vk.VkBuffer, size: u64) void {
        const vkUpdateDescriptorSets = vk.vkUpdateDescriptorSets orelse return;

        const buffer_info = vk.VkDescriptorBufferInfo{
            .buffer = buffer,
            .offset = 0,
            .range = size,
        };

        const write = vk.VkWriteDescriptorSet{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = self.descriptor_set,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = &buffer_info,
            .pTexelBufferView = null,
        };

        vkUpdateDescriptorSets(self.device, 1, &write, 0, null);
    }

    fn updateDescriptor(self: *Self, index: u32, image_view: vk.VkImageView) !void {
        const vkUpdateDescriptorSets = vk.vkUpdateDescriptorSets orelse return error.VulkanFunctionNotLoaded;

        const image_info = vk.VkDescriptorImageInfo{
            .sampler = null,
            .imageView = image_view,
            .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };

        const write = vk.VkWriteDescriptorSet{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = self.descriptor_set,
            .dstBinding = 1,
            .dstArrayElement = index,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
            .pImageInfo = &image_info,
            .pBufferInfo = null,
            .pTexelBufferView = null,
        };

        vkUpdateDescriptorSets(self.device, 1, &write, 0, null);
    }

    fn createTextureImage(self: *Self, pixels: [*]const u8, width: u32, height: u32) !TextureEntry {
        const vkCreateImage = vk.vkCreateImage orelse return error.VulkanFunctionNotLoaded;
        const vkGetImageMemoryRequirements = vk.vkGetImageMemoryRequirements orelse return error.VulkanFunctionNotLoaded;
        const vkAllocateMemory = vk.vkAllocateMemory orelse return error.VulkanFunctionNotLoaded;
        const vkBindImageMemory = vk.vkBindImageMemory orelse return error.VulkanFunctionNotLoaded;
        const vkCreateImageView = vk.vkCreateImageView orelse return error.VulkanFunctionNotLoaded;
        const vkCreateBuffer = vk.vkCreateBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkGetBufferMemoryRequirements = vk.vkGetBufferMemoryRequirements orelse return error.VulkanFunctionNotLoaded;
        const vkBindBufferMemory = vk.vkBindBufferMemory orelse return error.VulkanFunctionNotLoaded;
        const vkMapMemory = vk.vkMapMemory orelse return error.VulkanFunctionNotLoaded;
        const vkUnmapMemory = vk.vkUnmapMemory orelse return error.VulkanFunctionNotLoaded;
        const vkDestroyBuffer = vk.vkDestroyBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkFreeMemory = vk.vkFreeMemory orelse return error.VulkanFunctionNotLoaded;

        const image_size: u64 = @as(u64, width) * @as(u64, height) * 4;

        // Create staging buffer
        var staging_buffer: vk.VkBuffer = undefined;
        var staging_memory: vk.VkDeviceMemory = undefined;

        const staging_buffer_info = vk.VkBufferCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = image_size,
            .usage = vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };

        if (vkCreateBuffer(self.device, &staging_buffer_info, null, &staging_buffer) != vk.VK_SUCCESS) {
            return error.BufferCreationFailed;
        }

        var staging_mem_req: vk.VkMemoryRequirements = undefined;
        vkGetBufferMemoryRequirements(self.device, staging_buffer, &staging_mem_req);

        const staging_alloc_info = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = staging_mem_req.size,
            .memoryTypeIndex = try self.findMemoryType(
                staging_mem_req.memoryTypeBits,
                vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            ),
        };

        if (vkAllocateMemory(self.device, &staging_alloc_info, null, &staging_memory) != vk.VK_SUCCESS) {
            vkDestroyBuffer(self.device, staging_buffer, null);
            return error.MemoryAllocationFailed;
        }

        if (vkBindBufferMemory(self.device, staging_buffer, staging_memory, 0) != vk.VK_SUCCESS) {
            vkFreeMemory(self.device, staging_memory, null);
            vkDestroyBuffer(self.device, staging_buffer, null);
            return error.BufferBindFailed;
        }

        // Copy pixel data to staging buffer
        var mapped: ?*anyopaque = undefined;
        if (vkMapMemory(self.device, staging_memory, 0, image_size, 0, &mapped) != vk.VK_SUCCESS) {
            vkFreeMemory(self.device, staging_memory, null);
            vkDestroyBuffer(self.device, staging_buffer, null);
            return error.MemoryMapFailed;
        }
        @memcpy(@as([*]u8, @ptrCast(mapped))[0..image_size], pixels[0..image_size]);
        vkUnmapMemory(self.device, staging_memory);

        // Create image
        var tex_image: vk.VkImage = undefined;
        var tex_memory: vk.VkDeviceMemory = undefined;

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

        if (vkCreateImage(self.device, &image_info, null, &tex_image) != vk.VK_SUCCESS) {
            vkFreeMemory(self.device, staging_memory, null);
            vkDestroyBuffer(self.device, staging_buffer, null);
            return error.ImageCreationFailed;
        }

        var img_mem_req: vk.VkMemoryRequirements = undefined;
        vkGetImageMemoryRequirements(self.device, tex_image, &img_mem_req);

        const img_alloc_info = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = img_mem_req.size,
            .memoryTypeIndex = try self.findMemoryType(img_mem_req.memoryTypeBits, vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
        };

        if (vkAllocateMemory(self.device, &img_alloc_info, null, &tex_memory) != vk.VK_SUCCESS) {
            vkDestroyBuffer(self.device, staging_buffer, null);
            vkFreeMemory(self.device, staging_memory, null);
            return error.MemoryAllocationFailed;
        }

        if (vkBindImageMemory(self.device, tex_image, tex_memory, 0) != vk.VK_SUCCESS) {
            vkFreeMemory(self.device, tex_memory, null);
            vkDestroyBuffer(self.device, staging_buffer, null);
            vkFreeMemory(self.device, staging_memory, null);
            return error.ImageBindFailed;
        }

        // Transition and copy
        try self.transitionImageLayout(tex_image, vk.VK_IMAGE_LAYOUT_UNDEFINED, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
        try self.copyBufferToImage(staging_buffer, tex_image, width, height);
        try self.transitionImageLayout(tex_image, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);

        // Clean up staging buffer
        vkDestroyBuffer(self.device, staging_buffer, null);
        vkFreeMemory(self.device, staging_memory, null);

        // Create image view
        var tex_view: vk.VkImageView = undefined;
        const view_info = vk.VkImageViewCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = tex_image,
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

        if (vkCreateImageView(self.device, &view_info, null, &tex_view) != vk.VK_SUCCESS) {
            vkFreeMemory(self.device, tex_memory, null);
            return error.ImageViewCreationFailed;
        }

        return TextureEntry{
            .image = tex_image,
            .memory = tex_memory,
            .view = tex_view,
            .width = width,
            .height = height,
        };
    }

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

    fn transitionImageLayout(self: *Self, image: vk.VkImage, old_layout: vk.VkImageLayout, new_layout: vk.VkImageLayout) !void {
        const vkAllocateCommandBuffers = vk.vkAllocateCommandBuffers orelse return error.VulkanFunctionNotLoaded;
        const vkBeginCommandBuffer = vk.vkBeginCommandBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkCmdPipelineBarrier = vk.vkCmdPipelineBarrier orelse return error.VulkanFunctionNotLoaded;
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

        var command_buffer: vk.VkCommandBuffer = undefined;
        if (vkAllocateCommandBuffers(self.device, &alloc_info, &command_buffer) != vk.VK_SUCCESS) {
            return error.CommandBufferAllocationFailed;
        }
        defer vkFreeCommandBuffers(self.device, self.command_pool, 1, &command_buffer);

        const begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };

        if (vkBeginCommandBuffer(command_buffer, &begin_info) != vk.VK_SUCCESS) {
            return error.CommandBufferBeginFailed;
        }

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

        if (vkQueueSubmit(self.graphics_queue, 1, &submit_info, null) != vk.VK_SUCCESS) {
            return error.QueueSubmitFailed;
        }

        _ = vkQueueWaitIdle(self.graphics_queue);
    }

    fn copyBufferToImage(self: *Self, buffer: vk.VkBuffer, image: vk.VkImage, width: u32, height: u32) !void {
        const vkAllocateCommandBuffers = vk.vkAllocateCommandBuffers orelse return error.VulkanFunctionNotLoaded;
        const vkBeginCommandBuffer = vk.vkBeginCommandBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkCmdCopyBufferToImage = vk.vkCmdCopyBufferToImage orelse return error.VulkanFunctionNotLoaded;
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

        var command_buffer: vk.VkCommandBuffer = undefined;
        if (vkAllocateCommandBuffers(self.device, &alloc_info, &command_buffer) != vk.VK_SUCCESS) {
            return error.CommandBufferAllocationFailed;
        }
        defer vkFreeCommandBuffers(self.device, self.command_pool, 1, &command_buffer);

        const begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };

        if (vkBeginCommandBuffer(command_buffer, &begin_info) != vk.VK_SUCCESS) {
            return error.CommandBufferBeginFailed;
        }

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

        vkCmdCopyBufferToImage(command_buffer, buffer, image, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

        if (vkEndCommandBuffer(command_buffer) != vk.VK_SUCCESS) {
            return error.CommandBufferEndFailed;
        }

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

        if (vkQueueSubmit(self.graphics_queue, 1, &submit_info, null) != vk.VK_SUCCESS) {
            return error.QueueSubmitFailed;
        }

        _ = vkQueueWaitIdle(self.graphics_queue);
    }
};
