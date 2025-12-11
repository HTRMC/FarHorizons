// Render system - Vulkan state management

const std = @import("std");
const volk = @import("volk");
const vk = volk.c;
const shared = @import("Shared");
const Logger = shared.Logger;
const platform = @import("Platform");
const ShaderManager = @import("ShaderManager.zig").ShaderManager;

const MAX_FRAMES_IN_FLIGHT = 2;

// Uniform buffer object matching shader uniform
pub const UniformBufferObject = extern struct {
    model: [16]f32,
    view: [16]f32,
    proj: [16]f32,
};

// Vertex structure matching shader input
pub const Vertex = extern struct {
    pos: [3]f32,
    color: [3]f32,
    uv: [2]f32,
    tex_index: u32, // Texture array layer index

    pub fn getBindingDescription() vk.VkVertexInputBindingDescription {
        return .{
            .binding = 0,
            .stride = @sizeOf(Vertex),
            .inputRate = vk.VK_VERTEX_INPUT_RATE_VERTEX,
        };
    }

    pub fn getAttributeDescriptions() [4]vk.VkVertexInputAttributeDescription {
        return .{
            .{
                .binding = 0,
                .location = 0,
                .format = vk.VK_FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(Vertex, "pos"),
            },
            .{
                .binding = 0,
                .location = 1,
                .format = vk.VK_FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(Vertex, "color"),
            },
            .{
                .binding = 0,
                .location = 2,
                .format = vk.VK_FORMAT_R32G32_SFLOAT,
                .offset = @offsetOf(Vertex, "uv"),
            },
            .{
                .binding = 0,
                .location = 3,
                .format = vk.VK_FORMAT_R32_UINT,
                .offset = @offsetOf(Vertex, "tex_index"),
            },
        };
    }
};

// Note: Geometry is now generated dynamically from block models via uploadMesh()

pub const RenderSystem = struct {
    const Self = @This();
    const logger = Logger.init("RenderSystem");

    // Core Vulkan objects
    instance: vk.VkInstance = null,
    surface: vk.VkSurfaceKHR = null,
    physical_device: vk.VkPhysicalDevice = null,
    device: vk.VkDevice = null,

    // Queues
    graphics_queue: vk.VkQueue = null,
    present_queue: vk.VkQueue = null,
    graphics_family: u32 = 0,
    present_family: u32 = 0,

    // Swapchain
    swapchain: vk.VkSwapchainKHR = null,
    swapchain_images: []vk.VkImage = &.{},
    swapchain_image_views: []vk.VkImageView = &.{},
    swapchain_format: vk.VkFormat = vk.VK_FORMAT_UNDEFINED,
    swapchain_extent: vk.VkExtent2D = .{ .width = 0, .height = 0 },

    // Depth buffer
    depth_image: vk.VkImage = null,
    depth_image_memory: vk.VkDeviceMemory = null,
    depth_image_view: vk.VkImageView = null,
    depth_format: vk.VkFormat = vk.VK_FORMAT_UNDEFINED,

    // Render pass & framebuffers
    render_pass: vk.VkRenderPass = null,
    framebuffers: []vk.VkFramebuffer = &.{},

    // Pipeline
    pipeline_layout: vk.VkPipelineLayout = null,
    graphics_pipeline: vk.VkPipeline = null,

    // Vertex/Index buffers
    vertex_buffer: vk.VkBuffer = null,
    vertex_buffer_memory: vk.VkDeviceMemory = null,
    index_buffer: vk.VkBuffer = null,
    index_buffer_memory: vk.VkDeviceMemory = null,
    index_count: u32 = 0,

    // Uniform buffers (one per frame in flight)
    uniform_buffers: [MAX_FRAMES_IN_FLIGHT]vk.VkBuffer = .{null} ** MAX_FRAMES_IN_FLIGHT,
    uniform_buffers_memory: [MAX_FRAMES_IN_FLIGHT]vk.VkDeviceMemory = .{null} ** MAX_FRAMES_IN_FLIGHT,
    uniform_buffers_mapped: [MAX_FRAMES_IN_FLIGHT]?*anyopaque = .{null} ** MAX_FRAMES_IN_FLIGHT,

    // Texture resources (set externally by TextureManager)
    texture_image_view: vk.VkImageView = null,
    texture_sampler: vk.VkSampler = null,

    // Descriptors
    descriptor_set_layout: vk.VkDescriptorSetLayout = null,
    descriptor_pool: vk.VkDescriptorPool = null,
    descriptor_sets: [MAX_FRAMES_IN_FLIGHT]vk.VkDescriptorSet = .{null} ** MAX_FRAMES_IN_FLIGHT,

    // Command buffers
    command_pool: vk.VkCommandPool = null,
    command_buffers: []vk.VkCommandBuffer = &.{},

    // Synchronization
    image_available_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.VkSemaphore = .{null} ** MAX_FRAMES_IN_FLIGHT,
    render_finished_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.VkSemaphore = .{null} ** MAX_FRAMES_IN_FLIGHT,
    in_flight_fences: [MAX_FRAMES_IN_FLIGHT]vk.VkFence = .{null} ** MAX_FRAMES_IN_FLIGHT,
    current_frame: u32 = 0,

    // Allocator for dynamic arrays
    allocator: std.mem.Allocator = undefined,

    // Window reference for swapchain recreation
    window: ?*platform.Window = null,

    // Shader management (supports runtime shader packs)
    shader_manager: ?ShaderManager = null,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn initBackend(self: *Self, window: *platform.Window) !void {
        self.window = window;

        // Initialize shader manager (enable runtime compilation for shader pack support)
        // Set to false if you want to disable runtime shader compilation
        const enable_runtime_shaders = true;
        self.shader_manager = ShaderManager.init(self.allocator, enable_runtime_shaders) catch |err| blk: {
            logger.warn("Failed to initialize shader manager with runtime compilation: {}", .{err});
            // Fall back to embedded shaders only
            break :blk ShaderManager.init(self.allocator, false) catch null;
        };

        if (!platform.isVulkanSupported()) {
            logger.err("Vulkan is not supported on this system", .{});
            return error.VulkanNotSupported;
        }

        volk.init() catch {
            logger.err("Failed to initialize Vulkan loader", .{});
            return error.VulkanLoaderFailed;
        };

        const vk_version = volk.getInstanceVersion();
        logger.info("Vulkan version: {}.{}.{}", .{
            (vk_version >> 22) & 0x7F,
            (vk_version >> 12) & 0x3FF,
            vk_version & 0xFFF,
        });

        try self.createInstance();
        try self.createSurface();
        try self.pickPhysicalDevice();
        try self.createLogicalDevice();
        try self.createSwapchain();
        try self.createImageViews();
        try self.createDepthResources();
        try self.createRenderPass();
        try self.createDescriptorSetLayout();
        try self.createGraphicsPipeline();
        try self.createFramebuffers();
        try self.createCommandPool();
        // Note: Vertex/Index buffers are created by uploadMesh() with actual geometry
        try self.createUniformBuffers();
        // Note: Texture resources and descriptor sets are created after TextureManager is initialized
        // See initializeTextures() which must be called after setting texture resources
        try self.createCommandBuffers();
        try self.createSyncObjects();

        logger.info("Vulkan renderer initialized", .{});
    }

    pub fn shutdown(self: *Self) void {
        // Wait for device to finish
        if (self.device) |device| {
            if (vk.vkDeviceWaitIdle) |wait| {
                _ = wait(device);
            }
        }

        // Shutdown shader manager
        if (self.shader_manager) |*sm| {
            sm.deinit();
            self.shader_manager = null;
        }

        self.destroySyncObjects();
        self.destroyCommandPool();
        self.destroyDescriptorPool();
        // Note: texture_image_view and texture_sampler are owned by TextureManager
        self.destroyUniformBuffers();
        self.destroyBuffers();
        self.destroyFramebuffers();
        self.destroyPipeline();
        self.destroyDescriptorSetLayout();
        self.destroyRenderPass();
        self.destroyDepthResources();
        self.destroyImageViews();
        self.destroySwapchain();
        self.destroyDevice();
        self.destroySurface();
        self.destroyInstance();

        logger.info("Render system shut down", .{});
    }

    /// Load a shader pack from a directory path
    /// This will compile the shaders and recreate the graphics pipeline
    pub fn loadShaderPack(self: *Self, pack_path: []const u8) !void {
        if (self.shader_manager) |*sm| {
            try sm.loadShaderPack(pack_path);
            try self.recreateGraphicsPipeline();
            logger.info("Loaded shader pack: {s}", .{pack_path});
        } else {
            logger.err("Shader manager not initialized", .{});
            return error.ShaderManagerNotInitialized;
        }
    }

    /// Unload current shader pack and return to default shaders
    pub fn unloadShaderPack(self: *Self) !void {
        if (self.shader_manager) |*sm| {
            sm.unloadShaderPack();
            try self.recreateGraphicsPipeline();
            logger.info("Unloaded shader pack, using default shaders", .{});
        }
    }

    /// Recreate the graphics pipeline (used after shader changes)
    fn recreateGraphicsPipeline(self: *Self) !void {
        const vkDeviceWaitIdle = vk.vkDeviceWaitIdle orelse return error.VulkanFunctionNotLoaded;
        const vkDestroyPipeline = vk.vkDestroyPipeline orelse return error.VulkanFunctionNotLoaded;
        const vkDestroyPipelineLayout = vk.vkDestroyPipelineLayout orelse return error.VulkanFunctionNotLoaded;

        // Wait for GPU to finish
        _ = vkDeviceWaitIdle(self.device);

        // Destroy old pipeline
        if (self.graphics_pipeline) |pipeline| {
            vkDestroyPipeline(self.device, pipeline, null);
            self.graphics_pipeline = null;
        }
        if (self.pipeline_layout) |layout| {
            vkDestroyPipelineLayout(self.device, layout, null);
            self.pipeline_layout = null;
        }

        // Create new pipeline with new shaders
        try self.createGraphicsPipeline();
    }

    /// Check if runtime shader compilation is available
    pub fn isRuntimeShaderCompilationEnabled(self: *const Self) bool {
        if (self.shader_manager) |sm| {
            return sm.isRuntimeCompilationEnabled();
        }
        return false;
    }

    /// Set texture resources from TextureManager and create descriptor sets
    pub fn setTextureResources(self: *Self, image_view: vk.VkImageView, sampler: vk.VkSampler) !void {
        self.texture_image_view = image_view;
        self.texture_sampler = sampler;

        // Now we can create descriptor pool and sets
        try self.createDescriptorPool();
        try self.createDescriptorSets();

        logger.info("Texture resources set and descriptors created", .{});
    }

    /// Get Vulkan device (for TextureManager)
    pub fn getDevice(self: *const Self) vk.VkDevice {
        return self.device;
    }

    /// Get Vulkan physical device (for TextureManager)
    pub fn getPhysicalDevice(self: *const Self) vk.VkPhysicalDevice {
        return self.physical_device;
    }

    /// Get command pool (for TextureManager)
    pub fn getCommandPool(self: *const Self) vk.VkCommandPool {
        return self.command_pool;
    }

    /// Get graphics queue (for TextureManager)
    pub fn getGraphicsQueue(self: *const Self) vk.VkQueue {
        return self.graphics_queue;
    }

    pub fn drawFrame(self: *Self) !void {
        const vkWaitForFences = vk.vkWaitForFences orelse return error.VulkanFunctionNotLoaded;
        const vkResetFences = vk.vkResetFences orelse return error.VulkanFunctionNotLoaded;
        const vkAcquireNextImageKHR = vk.vkAcquireNextImageKHR orelse return error.VulkanFunctionNotLoaded;
        const vkQueueSubmit = vk.vkQueueSubmit orelse return error.VulkanFunctionNotLoaded;
        const vkQueuePresentKHR = vk.vkQueuePresentKHR orelse return error.VulkanFunctionNotLoaded;

        const fence = self.in_flight_fences[self.current_frame];
        _ = vkWaitForFences(self.device, 1, &fence, vk.VK_TRUE, std.math.maxInt(u64));

        var image_index: u32 = 0;
        const acquire_result = vkAcquireNextImageKHR(
            self.device,
            self.swapchain,
            std.math.maxInt(u64),
            self.image_available_semaphores[self.current_frame],
            null,
            &image_index,
        );

        if (acquire_result == vk.VK_ERROR_OUT_OF_DATE_KHR) {
            try self.recreateSwapchain();
            return;
        } else if (acquire_result != vk.VK_SUCCESS and acquire_result != vk.VK_SUBOPTIMAL_KHR) {
            return error.SwapchainAcquireFailed;
        }

        _ = vkResetFences(self.device, 1, &fence);

        try self.recordCommandBuffer(self.command_buffers[self.current_frame], image_index);

        const wait_semaphores = [_]vk.VkSemaphore{self.image_available_semaphores[self.current_frame]};
        const wait_stages = [_]vk.VkPipelineStageFlags{vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
        const signal_semaphores = [_]vk.VkSemaphore{self.render_finished_semaphores[self.current_frame]};
        const cmd_buffers = [_]vk.VkCommandBuffer{self.command_buffers[self.current_frame]};

        const submit_info = vk.VkSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &wait_semaphores,
            .pWaitDstStageMask = &wait_stages,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd_buffers,
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &signal_semaphores,
        };

        if (vkQueueSubmit(self.graphics_queue, 1, &submit_info, fence) != vk.VK_SUCCESS) {
            return error.QueueSubmitFailed;
        }

        const swapchains = [_]vk.VkSwapchainKHR{self.swapchain};
        const present_info = vk.VkPresentInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &signal_semaphores,
            .swapchainCount = 1,
            .pSwapchains = &swapchains,
            .pImageIndices = &image_index,
            .pResults = null,
        };

        const present_result = vkQueuePresentKHR(self.present_queue, &present_info);

        if (present_result == vk.VK_ERROR_OUT_OF_DATE_KHR or present_result == vk.VK_SUBOPTIMAL_KHR or self.window.?.wasResized()) {
            try self.recreateSwapchain();
        } else if (present_result != vk.VK_SUCCESS) {
            return error.PresentFailed;
        }

        self.current_frame = (self.current_frame + 1) % MAX_FRAMES_IN_FLIGHT;
    }

    /// Update the uniform buffer with MVP matrices for the current frame
    pub fn updateMVP(self: *Self, model: [16]f32, view: [16]f32, proj: [16]f32) void {
        const ubo = UniformBufferObject{
            .model = model,
            .view = view,
            .proj = proj,
        };

        if (self.uniform_buffers_mapped[self.current_frame]) |mapped| {
            const dest: *UniformBufferObject = @ptrCast(@alignCast(mapped));
            dest.* = ubo;
        }
    }

    /// Get the current swapchain aspect ratio
    pub fn getAspectRatio(self: *const Self) f32 {
        if (self.swapchain_extent.height == 0) return 1.0;
        return @as(f32, @floatFromInt(self.swapchain_extent.width)) / @as(f32, @floatFromInt(self.swapchain_extent.height));
    }

    /// Upload new mesh data (vertices and indices)
    pub fn uploadMesh(self: *Self, vertices: []const Vertex, indices: []const u16) !void {
        const vkDeviceWaitIdle = vk.vkDeviceWaitIdle orelse return error.VulkanFunctionNotLoaded;
        const vkDestroyBuffer = vk.vkDestroyBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkFreeMemory = vk.vkFreeMemory orelse return error.VulkanFunctionNotLoaded;
        const vkCreateBuffer = vk.vkCreateBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkGetBufferMemoryRequirements = vk.vkGetBufferMemoryRequirements orelse return error.VulkanFunctionNotLoaded;
        const vkAllocateMemory = vk.vkAllocateMemory orelse return error.VulkanFunctionNotLoaded;
        const vkBindBufferMemory = vk.vkBindBufferMemory orelse return error.VulkanFunctionNotLoaded;
        const vkMapMemory = vk.vkMapMemory orelse return error.VulkanFunctionNotLoaded;
        const vkUnmapMemory = vk.vkUnmapMemory orelse return error.VulkanFunctionNotLoaded;

        // Wait for device to be idle before modifying buffers
        _ = vkDeviceWaitIdle(self.device);

        // Destroy old buffers
        if (self.vertex_buffer != null) {
            vkDestroyBuffer(self.device, self.vertex_buffer, null);
            self.vertex_buffer = null;
        }
        if (self.vertex_buffer_memory != null) {
            vkFreeMemory(self.device, self.vertex_buffer_memory, null);
            self.vertex_buffer_memory = null;
        }
        if (self.index_buffer != null) {
            vkDestroyBuffer(self.device, self.index_buffer, null);
            self.index_buffer = null;
        }
        if (self.index_buffer_memory != null) {
            vkFreeMemory(self.device, self.index_buffer_memory, null);
            self.index_buffer_memory = null;
        }

        // Create vertex buffer
        const vertex_buffer_size: vk.VkDeviceSize = @sizeOf(Vertex) * vertices.len;
        {
            const buffer_info = vk.VkBufferCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .size = vertex_buffer_size,
                .usage = vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
                .queueFamilyIndexCount = 0,
                .pQueueFamilyIndices = null,
            };

            if (vkCreateBuffer(self.device, &buffer_info, null, &self.vertex_buffer) != vk.VK_SUCCESS) {
                return error.BufferCreationFailed;
            }

            var mem_requirements: vk.VkMemoryRequirements = undefined;
            vkGetBufferMemoryRequirements(self.device, self.vertex_buffer, &mem_requirements);

            const mem_type = try self.findMemoryType(
                mem_requirements.memoryTypeBits,
                vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            );

            const alloc_info = vk.VkMemoryAllocateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                .pNext = null,
                .allocationSize = mem_requirements.size,
                .memoryTypeIndex = mem_type,
            };

            if (vkAllocateMemory(self.device, &alloc_info, null, &self.vertex_buffer_memory) != vk.VK_SUCCESS) {
                return error.MemoryAllocationFailed;
            }

            if (vkBindBufferMemory(self.device, self.vertex_buffer, self.vertex_buffer_memory, 0) != vk.VK_SUCCESS) {
                return error.BufferMemoryBindFailed;
            }

            var data: ?*anyopaque = null;
            if (vkMapMemory(self.device, self.vertex_buffer_memory, 0, vertex_buffer_size, 0, &data) != vk.VK_SUCCESS) {
                return error.MemoryMapFailed;
            }

            const dest: [*]Vertex = @ptrCast(@alignCast(data));
            @memcpy(dest[0..vertices.len], vertices);

            vkUnmapMemory(self.device, self.vertex_buffer_memory);
        }

        // Create index buffer
        const index_buffer_size: vk.VkDeviceSize = @sizeOf(u16) * indices.len;
        {
            const buffer_info = vk.VkBufferCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .size = index_buffer_size,
                .usage = vk.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
                .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
                .queueFamilyIndexCount = 0,
                .pQueueFamilyIndices = null,
            };

            if (vkCreateBuffer(self.device, &buffer_info, null, &self.index_buffer) != vk.VK_SUCCESS) {
                return error.BufferCreationFailed;
            }

            var mem_requirements: vk.VkMemoryRequirements = undefined;
            vkGetBufferMemoryRequirements(self.device, self.index_buffer, &mem_requirements);

            const mem_type = try self.findMemoryType(
                mem_requirements.memoryTypeBits,
                vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            );

            const alloc_info = vk.VkMemoryAllocateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                .pNext = null,
                .allocationSize = mem_requirements.size,
                .memoryTypeIndex = mem_type,
            };

            if (vkAllocateMemory(self.device, &alloc_info, null, &self.index_buffer_memory) != vk.VK_SUCCESS) {
                return error.MemoryAllocationFailed;
            }

            if (vkBindBufferMemory(self.device, self.index_buffer, self.index_buffer_memory, 0) != vk.VK_SUCCESS) {
                return error.BufferMemoryBindFailed;
            }

            var data: ?*anyopaque = null;
            if (vkMapMemory(self.device, self.index_buffer_memory, 0, index_buffer_size, 0, &data) != vk.VK_SUCCESS) {
                return error.MemoryMapFailed;
            }

            const dest: [*]u16 = @ptrCast(@alignCast(data));
            @memcpy(dest[0..indices.len], indices);

            vkUnmapMemory(self.device, self.index_buffer_memory);
        }

        self.index_count = @intCast(indices.len);
        logger.info("Mesh uploaded: {d} vertices, {d} indices", .{ vertices.len, indices.len });
    }

    fn recreateSwapchain(self: *Self) !void {
        const vkDeviceWaitIdle = vk.vkDeviceWaitIdle orelse return error.VulkanFunctionNotLoaded;

        // Wait for window to have non-zero size (handles minimization)
        self.window.?.waitIfMinimized();

        _ = vkDeviceWaitIdle(self.device);

        // Cleanup old swapchain resources
        self.destroyFramebuffers();
        self.destroyDepthResources();
        self.destroyImageViews();
        self.destroySwapchain();

        // Recreate
        try self.createSwapchain();
        try self.createImageViews();
        try self.createDepthResources();
        try self.createFramebuffers();

        logger.info("Swapchain recreated: {}x{}", .{ self.swapchain_extent.width, self.swapchain_extent.height });
    }

    fn recordCommandBuffer(self: *Self, command_buffer: vk.VkCommandBuffer, image_index: u32) !void {
        const vkResetCommandBuffer = vk.vkResetCommandBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkBeginCommandBuffer = vk.vkBeginCommandBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkCmdBeginRenderPass = vk.vkCmdBeginRenderPass orelse return error.VulkanFunctionNotLoaded;
        const vkCmdBindPipeline = vk.vkCmdBindPipeline orelse return error.VulkanFunctionNotLoaded;
        const vkCmdBindDescriptorSets = vk.vkCmdBindDescriptorSets orelse return error.VulkanFunctionNotLoaded;
        const vkCmdBindVertexBuffers = vk.vkCmdBindVertexBuffers orelse return error.VulkanFunctionNotLoaded;
        const vkCmdBindIndexBuffer = vk.vkCmdBindIndexBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkCmdSetViewport = vk.vkCmdSetViewport orelse return error.VulkanFunctionNotLoaded;
        const vkCmdSetScissor = vk.vkCmdSetScissor orelse return error.VulkanFunctionNotLoaded;
        const vkCmdDrawIndexed = vk.vkCmdDrawIndexed orelse return error.VulkanFunctionNotLoaded;
        const vkCmdEndRenderPass = vk.vkCmdEndRenderPass orelse return error.VulkanFunctionNotLoaded;
        const vkEndCommandBuffer = vk.vkEndCommandBuffer orelse return error.VulkanFunctionNotLoaded;

        _ = vkResetCommandBuffer(command_buffer, 0);

        const begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = 0,
            .pInheritanceInfo = null,
        };

        if (vkBeginCommandBuffer(command_buffer, &begin_info) != vk.VK_SUCCESS) {
            return error.CommandBufferBeginFailed;
        }

        const clear_values = [_]vk.VkClearValue{
            .{ .color = .{ .float32 = .{ 0.0, 0.0, 0.0, 1.0 } } },
            .{ .depthStencil = .{ .depth = 1.0, .stencil = 0 } },
        };

        const render_pass_info = vk.VkRenderPassBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .pNext = null,
            .renderPass = self.render_pass,
            .framebuffer = self.framebuffers[image_index],
            .renderArea = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = self.swapchain_extent,
            },
            .clearValueCount = clear_values.len,
            .pClearValues = &clear_values,
        };

        vkCmdBeginRenderPass(command_buffer, &render_pass_info, vk.VK_SUBPASS_CONTENTS_INLINE);
        vkCmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.graphics_pipeline);

        // Bind descriptor set for current frame
        const descriptor_sets = [_]vk.VkDescriptorSet{self.descriptor_sets[self.current_frame]};
        vkCmdBindDescriptorSets(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline_layout, 0, 1, &descriptor_sets, 0, null);

        // Bind vertex buffer
        const vertex_buffers = [_]vk.VkBuffer{self.vertex_buffer};
        const offsets = [_]vk.VkDeviceSize{0};
        vkCmdBindVertexBuffers(command_buffer, 0, 1, &vertex_buffers, &offsets);

        // Bind index buffer
        vkCmdBindIndexBuffer(command_buffer, self.index_buffer, 0, vk.VK_INDEX_TYPE_UINT16);

        const viewport = vk.VkViewport{
            .x = 0.0,
            .y = 0.0,
            .width = @floatFromInt(self.swapchain_extent.width),
            .height = @floatFromInt(self.swapchain_extent.height),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };
        vkCmdSetViewport(command_buffer, 0, 1, &viewport);

        const scissor = vk.VkRect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swapchain_extent,
        };
        vkCmdSetScissor(command_buffer, 0, 1, &scissor);

        // Draw indexed
        vkCmdDrawIndexed(command_buffer, self.index_count, 1, 0, 0, 0);
        vkCmdEndRenderPass(command_buffer);

        if (vkEndCommandBuffer(command_buffer) != vk.VK_SUCCESS) {
            return error.CommandBufferEndFailed;
        }
    }

    fn createInstance(self: *Self) !void {
        const ext_info = platform.getRequiredVulkanExtensions() orelse {
            logger.err("Failed to get required Vulkan extensions", .{});
            return error.VulkanExtensionsFailed;
        };

        logger.info("Required extensions: {}", .{ext_info.count});

        const app_info = vk.VkApplicationInfo{
            .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pNext = null,
            .pApplicationName = "FarHorizons",
            .applicationVersion = vk.VK_MAKE_VERSION(0, 0, 1),
            .pEngineName = "FarHorizons Engine",
            .engineVersion = vk.VK_MAKE_VERSION(0, 0, 1),
            .apiVersion = vk.VK_API_VERSION_1_0,
        };

        const create_info = vk.VkInstanceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .pApplicationInfo = &app_info,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = ext_info.count,
            .ppEnabledExtensionNames = ext_info.extensions,
        };

        const vkCreateInstance = vk.vkCreateInstance orelse return error.VulkanFunctionNotLoaded;
        if (vkCreateInstance(&create_info, null, &self.instance) != vk.VK_SUCCESS) {
            return error.VulkanInstanceFailed;
        }

        volk.loadInstance(self.instance);
        logger.info("Vulkan instance created", .{});
    }

    fn createSurface(self: *Self) !void {
        const surface = try self.window.?.createSurface(@ptrCast(self.instance));
        self.surface = @ptrCast(surface);
    }

    fn pickPhysicalDevice(self: *Self) !void {
        const vkEnumeratePhysicalDevices = vk.vkEnumeratePhysicalDevices orelse return error.VulkanFunctionNotLoaded;

        var device_count: u32 = 0;
        _ = vkEnumeratePhysicalDevices(self.instance, &device_count, null);

        if (device_count == 0) {
            logger.err("No Vulkan-capable GPUs found", .{});
            return error.NoVulkanDevices;
        }

        const devices = try self.allocator.alloc(vk.VkPhysicalDevice, device_count);
        defer self.allocator.free(devices);
        _ = vkEnumeratePhysicalDevices(self.instance, &device_count, devices.ptr);

        for (devices) |device| {
            if (try self.isDeviceSuitable(device)) {
                self.physical_device = device;
                break;
            }
        }

        if (self.physical_device == null) {
            logger.err("No suitable GPU found", .{});
            return error.NoSuitableDevice;
        }

        // Log device name
        const vkGetPhysicalDeviceProperties = vk.vkGetPhysicalDeviceProperties orelse return error.VulkanFunctionNotLoaded;
        var props: vk.VkPhysicalDeviceProperties = undefined;
        vkGetPhysicalDeviceProperties(self.physical_device, &props);
        const name_slice = std.mem.sliceTo(&props.deviceName, 0);
        logger.info("Selected GPU: {s}", .{name_slice});
    }

    fn isDeviceSuitable(self: *Self, device: vk.VkPhysicalDevice) !bool {
        const families = try self.findQueueFamilies(device);
        if (families.graphics == null or families.present == null) return false;

        self.graphics_family = families.graphics.?;
        self.present_family = families.present.?;

        // Check swapchain support
        const vkEnumerateDeviceExtensionProperties = vk.vkEnumerateDeviceExtensionProperties orelse return error.VulkanFunctionNotLoaded;
        var ext_count: u32 = 0;
        _ = vkEnumerateDeviceExtensionProperties(device, null, &ext_count, null);

        const extensions = try self.allocator.alloc(vk.VkExtensionProperties, ext_count);
        defer self.allocator.free(extensions);
        _ = vkEnumerateDeviceExtensionProperties(device, null, &ext_count, extensions.ptr);

        var has_swapchain = false;
        for (extensions) |ext| {
            const name = std.mem.sliceTo(&ext.extensionName, 0);
            if (std.mem.eql(u8, name, "VK_KHR_swapchain")) {
                has_swapchain = true;
                break;
            }
        }

        return has_swapchain;
    }

    fn findQueueFamilies(self: *Self, device: vk.VkPhysicalDevice) !struct { graphics: ?u32, present: ?u32 } {
        const vkGetPhysicalDeviceQueueFamilyProperties = vk.vkGetPhysicalDeviceQueueFamilyProperties orelse return error.VulkanFunctionNotLoaded;
        const vkGetPhysicalDeviceSurfaceSupportKHR = vk.vkGetPhysicalDeviceSurfaceSupportKHR orelse return error.VulkanFunctionNotLoaded;

        var queue_family_count: u32 = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, null);

        const queue_families = try self.allocator.alloc(vk.VkQueueFamilyProperties, queue_family_count);
        defer self.allocator.free(queue_families);
        vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, queue_families.ptr);

        var graphics: ?u32 = null;
        var present: ?u32 = null;

        for (queue_families, 0..) |family, i| {
            const idx: u32 = @intCast(i);

            if ((family.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT) != 0) {
                graphics = idx;
            }

            var present_support: vk.VkBool32 = vk.VK_FALSE;
            _ = vkGetPhysicalDeviceSurfaceSupportKHR(device, idx, self.surface, &present_support);
            if (present_support == vk.VK_TRUE) {
                present = idx;
            }

            if (graphics != null and present != null) break;
        }

        return .{ .graphics = graphics, .present = present };
    }

    fn createLogicalDevice(self: *Self) !void {
        const vkCreateDevice = vk.vkCreateDevice orelse return error.VulkanFunctionNotLoaded;
        const vkGetDeviceQueue = vk.vkGetDeviceQueue orelse return error.VulkanFunctionNotLoaded;

        const queue_priority: f32 = 1.0;
        var queue_create_infos: [2]vk.VkDeviceQueueCreateInfo = undefined;
        var queue_count: u32 = 1;

        queue_create_infos[0] = .{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = self.graphics_family,
            .queueCount = 1,
            .pQueuePriorities = &queue_priority,
        };

        if (self.graphics_family != self.present_family) {
            queue_create_infos[1] = .{
                .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .queueFamilyIndex = self.present_family,
                .queueCount = 1,
                .pQueuePriorities = &queue_priority,
            };
            queue_count = 2;
        }

        const device_extensions = [_][*:0]const u8{"VK_KHR_swapchain"};

        const device_features: vk.VkPhysicalDeviceFeatures = std.mem.zeroes(vk.VkPhysicalDeviceFeatures);

        const create_info = vk.VkDeviceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueCreateInfoCount = queue_count,
            .pQueueCreateInfos = &queue_create_infos,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = device_extensions.len,
            .ppEnabledExtensionNames = &device_extensions,
            .pEnabledFeatures = &device_features,
        };

        if (vkCreateDevice(self.physical_device, &create_info, null, &self.device) != vk.VK_SUCCESS) {
            return error.DeviceCreationFailed;
        }

        volk.loadDevice(self.device);

        vkGetDeviceQueue(self.device, self.graphics_family, 0, &self.graphics_queue);
        vkGetDeviceQueue(self.device, self.present_family, 0, &self.present_queue);

        logger.info("Logical device created", .{});
    }

    fn createSwapchain(self: *Self) !void {
        const vkGetPhysicalDeviceSurfaceCapabilitiesKHR = vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR orelse return error.VulkanFunctionNotLoaded;
        const vkGetPhysicalDeviceSurfaceFormatsKHR = vk.vkGetPhysicalDeviceSurfaceFormatsKHR orelse return error.VulkanFunctionNotLoaded;
        const vkGetPhysicalDeviceSurfacePresentModesKHR = vk.vkGetPhysicalDeviceSurfacePresentModesKHR orelse return error.VulkanFunctionNotLoaded;
        const vkCreateSwapchainKHR = vk.vkCreateSwapchainKHR orelse return error.VulkanFunctionNotLoaded;
        const vkGetSwapchainImagesKHR = vk.vkGetSwapchainImagesKHR orelse return error.VulkanFunctionNotLoaded;

        const window = self.window.?;

        var capabilities: vk.VkSurfaceCapabilitiesKHR = undefined;
        _ = vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, self.surface, &capabilities);

        // Choose format
        var format_count: u32 = 0;
        _ = vkGetPhysicalDeviceSurfaceFormatsKHR(self.physical_device, self.surface, &format_count, null);
        const formats = try self.allocator.alloc(vk.VkSurfaceFormatKHR, format_count);
        defer self.allocator.free(formats);
        _ = vkGetPhysicalDeviceSurfaceFormatsKHR(self.physical_device, self.surface, &format_count, formats.ptr);

        var chosen_format = formats[0];
        for (formats) |format| {
            if (format.format == vk.VK_FORMAT_B8G8R8A8_SRGB and format.colorSpace == vk.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
                chosen_format = format;
                break;
            }
        }

        // Choose present mode (prefer mailbox, fallback to FIFO)
        var mode_count: u32 = 0;
        _ = vkGetPhysicalDeviceSurfacePresentModesKHR(self.physical_device, self.surface, &mode_count, null);
        const modes = try self.allocator.alloc(vk.VkPresentModeKHR, mode_count);
        defer self.allocator.free(modes);
        _ = vkGetPhysicalDeviceSurfacePresentModesKHR(self.physical_device, self.surface, &mode_count, modes.ptr);

        var chosen_mode: vk.VkPresentModeKHR = vk.VK_PRESENT_MODE_FIFO_KHR;
        for (modes) |mode| {
            if (mode == vk.VK_PRESENT_MODE_MAILBOX_KHR) {
                chosen_mode = mode;
                break;
            }
        }

        // Choose extent
        var extent: vk.VkExtent2D = undefined;
        if (capabilities.currentExtent.width != 0xFFFFFFFF) {
            extent = capabilities.currentExtent;
        } else {
            extent = .{
                .width = std.math.clamp(window.getFramebufferWidth(), capabilities.minImageExtent.width, capabilities.maxImageExtent.width),
                .height = std.math.clamp(window.getFramebufferHeight(), capabilities.minImageExtent.height, capabilities.maxImageExtent.height),
            };
        }

        var image_count = capabilities.minImageCount + 1;
        if (capabilities.maxImageCount > 0 and image_count > capabilities.maxImageCount) {
            image_count = capabilities.maxImageCount;
        }

        var create_info = vk.VkSwapchainCreateInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .pNext = null,
            .flags = 0,
            .surface = self.surface,
            .minImageCount = image_count,
            .imageFormat = chosen_format.format,
            .imageColorSpace = chosen_format.colorSpace,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            .imageUsage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .imageSharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .preTransform = capabilities.currentTransform,
            .compositeAlpha = vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = chosen_mode,
            .clipped = vk.VK_TRUE,
            .oldSwapchain = null,
        };

        const queue_family_indices = [_]u32{ self.graphics_family, self.present_family };
        if (self.graphics_family != self.present_family) {
            create_info.imageSharingMode = vk.VK_SHARING_MODE_CONCURRENT;
            create_info.queueFamilyIndexCount = 2;
            create_info.pQueueFamilyIndices = &queue_family_indices;
        }

        if (vkCreateSwapchainKHR(self.device, &create_info, null, &self.swapchain) != vk.VK_SUCCESS) {
            return error.SwapchainCreationFailed;
        }

        self.swapchain_format = chosen_format.format;
        self.swapchain_extent = extent;

        // Get swapchain images
        var actual_image_count: u32 = 0;
        _ = vkGetSwapchainImagesKHR(self.device, self.swapchain, &actual_image_count, null);
        self.swapchain_images = try self.allocator.alloc(vk.VkImage, actual_image_count);
        _ = vkGetSwapchainImagesKHR(self.device, self.swapchain, &actual_image_count, self.swapchain_images.ptr);

        logger.info("Swapchain created: {}x{}, {} images", .{ extent.width, extent.height, actual_image_count });
    }

    fn createImageViews(self: *Self) !void {
        const vkCreateImageView = vk.vkCreateImageView orelse return error.VulkanFunctionNotLoaded;

        self.swapchain_image_views = try self.allocator.alloc(vk.VkImageView, self.swapchain_images.len);

        for (self.swapchain_images, 0..) |image, i| {
            const create_info = vk.VkImageViewCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .image = image,
                .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
                .format = self.swapchain_format,
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

            if (vkCreateImageView(self.device, &create_info, null, &self.swapchain_image_views[i]) != vk.VK_SUCCESS) {
                return error.ImageViewCreationFailed;
            }
        }

        logger.info("Image views created", .{});
    }

    fn createDepthResources(self: *Self) !void {
        const vkCreateImage = vk.vkCreateImage orelse return error.VulkanFunctionNotLoaded;
        const vkGetImageMemoryRequirements = vk.vkGetImageMemoryRequirements orelse return error.VulkanFunctionNotLoaded;
        const vkAllocateMemory = vk.vkAllocateMemory orelse return error.VulkanFunctionNotLoaded;
        const vkBindImageMemory = vk.vkBindImageMemory orelse return error.VulkanFunctionNotLoaded;
        const vkCreateImageView = vk.vkCreateImageView orelse return error.VulkanFunctionNotLoaded;

        self.depth_format = try self.findDepthFormat();

        const image_info = vk.VkImageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = vk.VK_IMAGE_TYPE_2D,
            .format = self.depth_format,
            .extent = .{
                .width = self.swapchain_extent.width,
                .height = self.swapchain_extent.height,
                .depth = 1,
            },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
            .usage = vk.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        };

        if (vkCreateImage(self.device, &image_info, null, &self.depth_image) != vk.VK_SUCCESS) {
            return error.DepthImageCreationFailed;
        }

        var mem_requirements: vk.VkMemoryRequirements = undefined;
        vkGetImageMemoryRequirements(self.device, self.depth_image, &mem_requirements);

        const mem_type = try self.findMemoryType(
            mem_requirements.memoryTypeBits,
            vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        );

        const alloc_info = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = mem_requirements.size,
            .memoryTypeIndex = mem_type,
        };

        if (vkAllocateMemory(self.device, &alloc_info, null, &self.depth_image_memory) != vk.VK_SUCCESS) {
            return error.DepthMemoryAllocationFailed;
        }

        if (vkBindImageMemory(self.device, self.depth_image, self.depth_image_memory, 0) != vk.VK_SUCCESS) {
            return error.DepthImageMemoryBindFailed;
        }

        const view_info = vk.VkImageViewCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = self.depth_image,
            .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
            .format = self.depth_format,
            .components = .{
                .r = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_DEPTH_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        if (vkCreateImageView(self.device, &view_info, null, &self.depth_image_view) != vk.VK_SUCCESS) {
            return error.DepthImageViewCreationFailed;
        }

        logger.info("Depth resources created", .{});
    }

    fn findDepthFormat(self: *Self) !vk.VkFormat {
        const vkGetPhysicalDeviceFormatProperties = vk.vkGetPhysicalDeviceFormatProperties orelse return error.VulkanFunctionNotLoaded;

        const candidates = [_]vk.VkFormat{
            vk.VK_FORMAT_D32_SFLOAT,
            vk.VK_FORMAT_D32_SFLOAT_S8_UINT,
            vk.VK_FORMAT_D24_UNORM_S8_UINT,
        };

        for (candidates) |format| {
            var props: vk.VkFormatProperties = undefined;
            vkGetPhysicalDeviceFormatProperties(self.physical_device, format, &props);

            if ((props.optimalTilingFeatures & vk.VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT) != 0) {
                return format;
            }
        }

        return error.NoSupportedDepthFormat;
    }

    fn createRenderPass(self: *Self) !void {
        const vkCreateRenderPass = vk.vkCreateRenderPass orelse return error.VulkanFunctionNotLoaded;

        const color_attachment = vk.VkAttachmentDescription{
            .flags = 0,
            .format = self.swapchain_format,
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        };

        const depth_attachment = vk.VkAttachmentDescription{
            .flags = 0,
            .format = self.depth_format,
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .stencilLoadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = vk.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        };

        const attachments = [_]vk.VkAttachmentDescription{ color_attachment, depth_attachment };

        const color_attachment_ref = vk.VkAttachmentReference{
            .attachment = 0,
            .layout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };

        const depth_attachment_ref = vk.VkAttachmentReference{
            .attachment = 1,
            .layout = vk.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        };

        const subpass = vk.VkSubpassDescription{
            .flags = 0,
            .pipelineBindPoint = vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            .inputAttachmentCount = 0,
            .pInputAttachments = null,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_attachment_ref,
            .pResolveAttachments = null,
            .pDepthStencilAttachment = &depth_attachment_ref,
            .preserveAttachmentCount = 0,
            .pPreserveAttachments = null,
        };

        const dependency = vk.VkSubpassDependency{
            .srcSubpass = vk.VK_SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | vk.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
            .dstStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | vk.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
            .srcAccessMask = 0,
            .dstAccessMask = vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | vk.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
            .dependencyFlags = 0,
        };

        const render_pass_info = vk.VkRenderPassCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .attachmentCount = attachments.len,
            .pAttachments = &attachments,
            .subpassCount = 1,
            .pSubpasses = &subpass,
            .dependencyCount = 1,
            .pDependencies = &dependency,
        };

        if (vkCreateRenderPass(self.device, &render_pass_info, null, &self.render_pass) != vk.VK_SUCCESS) {
            return error.RenderPassCreationFailed;
        }

        logger.info("Render pass created", .{});
    }

    fn createDescriptorSetLayout(self: *Self) !void {
        const vkCreateDescriptorSetLayout = vk.vkCreateDescriptorSetLayout orelse return error.VulkanFunctionNotLoaded;

        const bindings = [_]vk.VkDescriptorSetLayoutBinding{
            // Binding 0: Uniform buffer (MVP matrices)
            .{
                .binding = 0,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
                .pImmutableSamplers = null,
            },
            // Binding 1: Combined image sampler (texture)
            .{
                .binding = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
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

        if (vkCreateDescriptorSetLayout(self.device, &layout_info, null, &self.descriptor_set_layout) != vk.VK_SUCCESS) {
            return error.DescriptorSetLayoutCreationFailed;
        }

        logger.info("Descriptor set layout created", .{});
    }

    fn createGraphicsPipeline(self: *Self) !void {
        const vkCreateShaderModule = vk.vkCreateShaderModule orelse return error.VulkanFunctionNotLoaded;
        const vkDestroyShaderModule = vk.vkDestroyShaderModule orelse return error.VulkanFunctionNotLoaded;
        const vkCreatePipelineLayout = vk.vkCreatePipelineLayout orelse return error.VulkanFunctionNotLoaded;
        const vkCreateGraphicsPipelines = vk.vkCreateGraphicsPipelines orelse return error.VulkanFunctionNotLoaded;

        // Get SPIR-V shaders from ShaderManager (runtime-compiled with #fh_import support)
        const vert_shader_code = if (self.shader_manager) |*sm|
            sm.getDefaultVertexShader() orelse return error.ShaderNotAvailable
        else
            return error.ShaderManagerNotInitialized;

        const frag_shader_code = if (self.shader_manager) |*sm|
            sm.getDefaultFragmentShader() orelse return error.ShaderNotAvailable
        else
            return error.ShaderManagerNotInitialized;

        const vert_module = try self.createShaderModule(vkCreateShaderModule, vert_shader_code);
        defer vkDestroyShaderModule(self.device, vert_module, null);

        const frag_module = try self.createShaderModule(vkCreateShaderModule, frag_shader_code);
        defer vkDestroyShaderModule(self.device, frag_module, null);

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

        const dynamic_states = [_]vk.VkDynamicState{ vk.VK_DYNAMIC_STATE_VIEWPORT, vk.VK_DYNAMIC_STATE_SCISSOR };
        const dynamic_state = vk.VkPipelineDynamicStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .dynamicStateCount = dynamic_states.len,
            .pDynamicStates = &dynamic_states,
        };

        const binding_description = Vertex.getBindingDescription();
        const attribute_descriptions = Vertex.getAttributeDescriptions();

        const vertex_input_info = vk.VkPipelineVertexInputStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .vertexBindingDescriptionCount = 1,
            .pVertexBindingDescriptions = &binding_description,
            .vertexAttributeDescriptionCount = attribute_descriptions.len,
            .pVertexAttributeDescriptions = &attribute_descriptions,
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
            .blendEnable = vk.VK_FALSE,
            .srcColorBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ZERO,
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
            .logicOp = vk.VK_LOGIC_OP_COPY,
            .attachmentCount = 1,
            .pAttachments = &color_blend_attachment,
            .blendConstants = .{ 0.0, 0.0, 0.0, 0.0 },
        };

        const descriptor_set_layouts = [_]vk.VkDescriptorSetLayout{self.descriptor_set_layout};
        const pipeline_layout_info = vk.VkPipelineLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 1,
            .pSetLayouts = &descriptor_set_layouts,
            .pushConstantRangeCount = 0,
            .pPushConstantRanges = null,
        };

        if (vkCreatePipelineLayout(self.device, &pipeline_layout_info, null, &self.pipeline_layout) != vk.VK_SUCCESS) {
            return error.PipelineLayoutCreationFailed;
        }

        const pipeline_info = vk.VkGraphicsPipelineCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stageCount = shader_stages.len,
            .pStages = &shader_stages,
            .pVertexInputState = &vertex_input_info,
            .pInputAssemblyState = &input_assembly,
            .pTessellationState = null,
            .pViewportState = &viewport_state,
            .pRasterizationState = &rasterizer,
            .pMultisampleState = &multisampling,
            .pDepthStencilState = &depth_stencil,
            .pColorBlendState = &color_blending,
            .pDynamicState = &dynamic_state,
            .layout = self.pipeline_layout,
            .renderPass = self.render_pass,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };

        if (vkCreateGraphicsPipelines(self.device, null, 1, &pipeline_info, null, &self.graphics_pipeline) != vk.VK_SUCCESS) {
            return error.PipelineCreationFailed;
        }

        logger.info("Graphics pipeline created", .{});
    }

    fn createShaderModule(self: *Self, vkCreateShaderModule: anytype, code: []const u8) !vk.VkShaderModule {
        const create_info = vk.VkShaderModuleCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = code.len,
            .pCode = @ptrCast(@alignCast(code.ptr)),
        };

        var shader_module: vk.VkShaderModule = null;
        if (vkCreateShaderModule(self.device, &create_info, null, &shader_module) != vk.VK_SUCCESS) {
            return error.ShaderModuleCreationFailed;
        }
        return shader_module;
    }

    fn createFramebuffers(self: *Self) !void {
        const vkCreateFramebuffer = vk.vkCreateFramebuffer orelse return error.VulkanFunctionNotLoaded;

        self.framebuffers = try self.allocator.alloc(vk.VkFramebuffer, self.swapchain_image_views.len);

        for (self.swapchain_image_views, 0..) |image_view, i| {
            const attachments = [_]vk.VkImageView{ image_view, self.depth_image_view };

            const framebuffer_info = vk.VkFramebufferCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .renderPass = self.render_pass,
                .attachmentCount = attachments.len,
                .pAttachments = &attachments,
                .width = self.swapchain_extent.width,
                .height = self.swapchain_extent.height,
                .layers = 1,
            };

            if (vkCreateFramebuffer(self.device, &framebuffer_info, null, &self.framebuffers[i]) != vk.VK_SUCCESS) {
                return error.FramebufferCreationFailed;
            }
        }

        logger.info("Framebuffers created", .{});
    }

    fn createCommandPool(self: *Self) !void {
        const vkCreateCommandPool = vk.vkCreateCommandPool orelse return error.VulkanFunctionNotLoaded;

        const pool_info = vk.VkCommandPoolCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = self.graphics_family,
        };

        if (vkCreateCommandPool(self.device, &pool_info, null, &self.command_pool) != vk.VK_SUCCESS) {
            return error.CommandPoolCreationFailed;
        }

        logger.info("Command pool created", .{});
    }

    // Note: Vertex/Index buffers are created dynamically by uploadMesh()

    fn createUniformBuffers(self: *Self) !void {
        const vkCreateBuffer = vk.vkCreateBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkGetBufferMemoryRequirements = vk.vkGetBufferMemoryRequirements orelse return error.VulkanFunctionNotLoaded;
        const vkAllocateMemory = vk.vkAllocateMemory orelse return error.VulkanFunctionNotLoaded;
        const vkBindBufferMemory = vk.vkBindBufferMemory orelse return error.VulkanFunctionNotLoaded;
        const vkMapMemory = vk.vkMapMemory orelse return error.VulkanFunctionNotLoaded;

        const buffer_size: vk.VkDeviceSize = @sizeOf(UniformBufferObject);

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            const buffer_info = vk.VkBufferCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .size = buffer_size,
                .usage = vk.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
                .queueFamilyIndexCount = 0,
                .pQueueFamilyIndices = null,
            };

            if (vkCreateBuffer(self.device, &buffer_info, null, &self.uniform_buffers[i]) != vk.VK_SUCCESS) {
                return error.BufferCreationFailed;
            }

            var mem_requirements: vk.VkMemoryRequirements = undefined;
            vkGetBufferMemoryRequirements(self.device, self.uniform_buffers[i], &mem_requirements);

            const mem_type = try self.findMemoryType(
                mem_requirements.memoryTypeBits,
                vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            );

            const alloc_info = vk.VkMemoryAllocateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                .pNext = null,
                .allocationSize = mem_requirements.size,
                .memoryTypeIndex = mem_type,
            };

            if (vkAllocateMemory(self.device, &alloc_info, null, &self.uniform_buffers_memory[i]) != vk.VK_SUCCESS) {
                return error.MemoryAllocationFailed;
            }

            if (vkBindBufferMemory(self.device, self.uniform_buffers[i], self.uniform_buffers_memory[i], 0) != vk.VK_SUCCESS) {
                return error.BufferMemoryBindFailed;
            }

            // Map memory persistently (we'll update it every frame)
            if (vkMapMemory(self.device, self.uniform_buffers_memory[i], 0, buffer_size, 0, &self.uniform_buffers_mapped[i]) != vk.VK_SUCCESS) {
                return error.MemoryMapFailed;
            }
        }

        logger.info("Uniform buffers created", .{});
    }

    // Note: Texture creation/destruction is now handled by TextureManager

    fn createDescriptorPool(self: *Self) !void {
        const vkCreateDescriptorPool = vk.vkCreateDescriptorPool orelse return error.VulkanFunctionNotLoaded;

        const pool_sizes = [_]vk.VkDescriptorPoolSize{
            .{
                .type = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .descriptorCount = MAX_FRAMES_IN_FLIGHT,
            },
            .{
                .type = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .descriptorCount = MAX_FRAMES_IN_FLIGHT,
            },
        };

        const pool_info = vk.VkDescriptorPoolCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .maxSets = MAX_FRAMES_IN_FLIGHT,
            .poolSizeCount = pool_sizes.len,
            .pPoolSizes = &pool_sizes,
        };

        if (vkCreateDescriptorPool(self.device, &pool_info, null, &self.descriptor_pool) != vk.VK_SUCCESS) {
            return error.DescriptorPoolCreationFailed;
        }

        logger.info("Descriptor pool created", .{});
    }

    fn createDescriptorSets(self: *Self) !void {
        const vkAllocateDescriptorSets = vk.vkAllocateDescriptorSets orelse return error.VulkanFunctionNotLoaded;
        const vkUpdateDescriptorSets = vk.vkUpdateDescriptorSets orelse return error.VulkanFunctionNotLoaded;

        const layouts = [_]vk.VkDescriptorSetLayout{self.descriptor_set_layout} ** MAX_FRAMES_IN_FLIGHT;

        const alloc_info = vk.VkDescriptorSetAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = self.descriptor_pool,
            .descriptorSetCount = MAX_FRAMES_IN_FLIGHT,
            .pSetLayouts = &layouts,
        };

        if (vkAllocateDescriptorSets(self.device, &alloc_info, &self.descriptor_sets) != vk.VK_SUCCESS) {
            return error.DescriptorSetAllocationFailed;
        }

        // Configure each descriptor set to point to its uniform buffer and texture
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            const buffer_info = vk.VkDescriptorBufferInfo{
                .buffer = self.uniform_buffers[i],
                .offset = 0,
                .range = @sizeOf(UniformBufferObject),
            };

            const image_info = vk.VkDescriptorImageInfo{
                .sampler = self.texture_sampler,
                .imageView = self.texture_image_view,
                .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            };

            const descriptor_writes = [_]vk.VkWriteDescriptorSet{
                .{
                    .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                    .pNext = null,
                    .dstSet = self.descriptor_sets[i],
                    .dstBinding = 0,
                    .dstArrayElement = 0,
                    .descriptorCount = 1,
                    .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                    .pImageInfo = null,
                    .pBufferInfo = &buffer_info,
                    .pTexelBufferView = null,
                },
                .{
                    .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                    .pNext = null,
                    .dstSet = self.descriptor_sets[i],
                    .dstBinding = 1,
                    .dstArrayElement = 0,
                    .descriptorCount = 1,
                    .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                    .pImageInfo = &image_info,
                    .pBufferInfo = null,
                    .pTexelBufferView = null,
                },
            };

            vkUpdateDescriptorSets(self.device, descriptor_writes.len, &descriptor_writes, 0, null);
        }

        logger.info("Descriptor sets created", .{});
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

    fn createCommandBuffers(self: *Self) !void {
        const vkAllocateCommandBuffers = vk.vkAllocateCommandBuffers orelse return error.VulkanFunctionNotLoaded;

        self.command_buffers = try self.allocator.alloc(vk.VkCommandBuffer, MAX_FRAMES_IN_FLIGHT);

        const alloc_info = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = MAX_FRAMES_IN_FLIGHT,
        };

        if (vkAllocateCommandBuffers(self.device, &alloc_info, self.command_buffers.ptr) != vk.VK_SUCCESS) {
            return error.CommandBufferAllocationFailed;
        }

        logger.info("Command buffers allocated", .{});
    }

    fn createSyncObjects(self: *Self) !void {
        const vkCreateSemaphore = vk.vkCreateSemaphore orelse return error.VulkanFunctionNotLoaded;
        const vkCreateFence = vk.vkCreateFence orelse return error.VulkanFunctionNotLoaded;

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
            if (vkCreateSemaphore(self.device, &semaphore_info, null, &self.image_available_semaphores[i]) != vk.VK_SUCCESS or
                vkCreateSemaphore(self.device, &semaphore_info, null, &self.render_finished_semaphores[i]) != vk.VK_SUCCESS or
                vkCreateFence(self.device, &fence_info, null, &self.in_flight_fences[i]) != vk.VK_SUCCESS)
            {
                return error.SyncObjectCreationFailed;
            }
        }

        logger.info("Sync objects created", .{});
    }

    fn destroySyncObjects(self: *Self) void {
        const vkDestroySemaphore = vk.vkDestroySemaphore orelse return;
        const vkDestroyFence = vk.vkDestroyFence orelse return;

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            if (self.image_available_semaphores[i]) |s| vkDestroySemaphore(self.device, s, null);
            if (self.render_finished_semaphores[i]) |s| vkDestroySemaphore(self.device, s, null);
            if (self.in_flight_fences[i]) |f| vkDestroyFence(self.device, f, null);
        }
    }

    fn destroyCommandPool(self: *Self) void {
        if (self.command_buffers.len > 0) {
            self.allocator.free(self.command_buffers);
            self.command_buffers = &.{};
        }
        if (self.command_pool) |pool| {
            if (vk.vkDestroyCommandPool) |destroy| destroy(self.device, pool, null);
            self.command_pool = null;
        }
    }

    fn destroyDescriptorPool(self: *Self) void {
        if (self.descriptor_pool) |pool| {
            if (vk.vkDestroyDescriptorPool) |destroy| destroy(self.device, pool, null);
            self.descriptor_pool = null;
        }
    }

    fn destroyUniformBuffers(self: *Self) void {
        const vkDestroyBuffer = vk.vkDestroyBuffer orelse return;
        const vkFreeMemory = vk.vkFreeMemory orelse return;

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            if (self.uniform_buffers[i]) |buf| {
                vkDestroyBuffer(self.device, buf, null);
                self.uniform_buffers[i] = null;
            }
            if (self.uniform_buffers_memory[i]) |mem| {
                vkFreeMemory(self.device, mem, null);
                self.uniform_buffers_memory[i] = null;
            }
            self.uniform_buffers_mapped[i] = null;
        }
    }

    fn destroyBuffers(self: *Self) void {
        const vkDestroyBuffer = vk.vkDestroyBuffer orelse return;
        const vkFreeMemory = vk.vkFreeMemory orelse return;

        if (self.index_buffer) |buf| {
            vkDestroyBuffer(self.device, buf, null);
            self.index_buffer = null;
        }
        if (self.index_buffer_memory) |mem| {
            vkFreeMemory(self.device, mem, null);
            self.index_buffer_memory = null;
        }
        if (self.vertex_buffer) |buf| {
            vkDestroyBuffer(self.device, buf, null);
            self.vertex_buffer = null;
        }
        if (self.vertex_buffer_memory) |mem| {
            vkFreeMemory(self.device, mem, null);
            self.vertex_buffer_memory = null;
        }
    }

    fn destroyFramebuffers(self: *Self) void {
        const vkDestroyFramebuffer = vk.vkDestroyFramebuffer orelse return;
        for (self.framebuffers) |fb| {
            if (fb) |f| vkDestroyFramebuffer(self.device, f, null);
        }
        if (self.framebuffers.len > 0) {
            self.allocator.free(self.framebuffers);
            self.framebuffers = &.{};
        }
    }

    fn destroyPipeline(self: *Self) void {
        if (self.graphics_pipeline) |p| {
            if (vk.vkDestroyPipeline) |destroy| destroy(self.device, p, null);
            self.graphics_pipeline = null;
        }
        if (self.pipeline_layout) |l| {
            if (vk.vkDestroyPipelineLayout) |destroy| destroy(self.device, l, null);
            self.pipeline_layout = null;
        }
    }

    fn destroyDescriptorSetLayout(self: *Self) void {
        if (self.descriptor_set_layout) |layout| {
            if (vk.vkDestroyDescriptorSetLayout) |destroy| destroy(self.device, layout, null);
            self.descriptor_set_layout = null;
        }
    }

    fn destroyRenderPass(self: *Self) void {
        if (self.render_pass) |rp| {
            if (vk.vkDestroyRenderPass) |destroy| destroy(self.device, rp, null);
            self.render_pass = null;
        }
    }

    fn destroyDepthResources(self: *Self) void {
        const vkDestroyImageView = vk.vkDestroyImageView orelse return;
        const vkDestroyImage = vk.vkDestroyImage orelse return;
        const vkFreeMemory = vk.vkFreeMemory orelse return;

        if (self.depth_image_view) |view| {
            vkDestroyImageView(self.device, view, null);
            self.depth_image_view = null;
        }
        if (self.depth_image) |image| {
            vkDestroyImage(self.device, image, null);
            self.depth_image = null;
        }
        if (self.depth_image_memory) |mem| {
            vkFreeMemory(self.device, mem, null);
            self.depth_image_memory = null;
        }
    }

    fn destroyImageViews(self: *Self) void {
        const vkDestroyImageView = vk.vkDestroyImageView orelse return;
        for (self.swapchain_image_views) |iv| {
            if (iv) |v| vkDestroyImageView(self.device, v, null);
        }
        if (self.swapchain_image_views.len > 0) {
            self.allocator.free(self.swapchain_image_views);
            self.swapchain_image_views = &.{};
        }
    }

    fn destroySwapchain(self: *Self) void {
        if (self.swapchain_images.len > 0) {
            self.allocator.free(self.swapchain_images);
            self.swapchain_images = &.{};
        }
        if (self.swapchain) |sc| {
            if (vk.vkDestroySwapchainKHR) |destroy| destroy(self.device, sc, null);
            self.swapchain = null;
        }
    }

    fn destroyDevice(self: *Self) void {
        if (self.device) |d| {
            if (vk.vkDestroyDevice) |destroy| destroy(d, null);
            self.device = null;
        }
    }

    fn destroySurface(self: *Self) void {
        if (self.surface) |s| {
            if (vk.vkDestroySurfaceKHR) |destroy| destroy(self.instance, s, null);
            self.surface = null;
        }
    }

    fn destroyInstance(self: *Self) void {
        if (self.instance) |i| {
            if (vk.vkDestroyInstance) |destroy| destroy(i, null);
            self.instance = null;
        }
    }

    pub fn getInstance(self: *const Self) vk.VkInstance {
        return self.instance;
    }
};
