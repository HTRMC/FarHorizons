const std = @import("std");
const Renderer = @import("../Renderer.zig").Renderer;
const vk = @import("../../platform/volk.zig");
const c = @import("../../platform/c.zig").c;
const Window = @import("../../platform/Window.zig").Window;
const glfw = @import("../../platform/glfw.zig");
const ShaderCompiler = @import("ShaderCompiler.zig");
const Camera = @import("../Camera.zig");
const zlm = @import("zlm");

const enable_validation_layers = @import("builtin").mode == .Debug;
const validation_layers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};
const MAX_FRAMES_IN_FLIGHT = 2;
const MAX_TEXTURES = 256;

const CHUNK_SIZE = 16;
const BLOCKS_PER_CHUNK = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE; // 4096
const VERTS_PER_BLOCK = 24;
const INDICES_PER_BLOCK = 36;
const CHUNK_VERTEX_COUNT = BLOCKS_PER_CHUNK * VERTS_PER_BLOCK; // 98304
const CHUNK_INDEX_COUNT = BLOCKS_PER_CHUNK * INDICES_PER_BLOCK; // 147456

const GpuVertex = extern struct {
    px: f32,
    py: f32,
    pz: f32,
    u: f32,
    v: f32,
    tex_index: u32,
};

// Per-face vertex template (unit cube centered at origin)
const face_vertices = [6][4]struct { px: f32, py: f32, pz: f32, u: f32, v: f32 }{
    // Front face (z = +0.5)
    .{
        .{ .px = -0.5, .py = -0.5, .pz = 0.5, .u = 0.0, .v = 1.0 },
        .{ .px = 0.5, .py = -0.5, .pz = 0.5, .u = 1.0, .v = 1.0 },
        .{ .px = 0.5, .py = 0.5, .pz = 0.5, .u = 1.0, .v = 0.0 },
        .{ .px = -0.5, .py = 0.5, .pz = 0.5, .u = 0.0, .v = 0.0 },
    },
    // Back face (z = -0.5)
    .{
        .{ .px = 0.5, .py = -0.5, .pz = -0.5, .u = 0.0, .v = 1.0 },
        .{ .px = -0.5, .py = -0.5, .pz = -0.5, .u = 1.0, .v = 1.0 },
        .{ .px = -0.5, .py = 0.5, .pz = -0.5, .u = 1.0, .v = 0.0 },
        .{ .px = 0.5, .py = 0.5, .pz = -0.5, .u = 0.0, .v = 0.0 },
    },
    // Left face (x = -0.5)
    .{
        .{ .px = -0.5, .py = -0.5, .pz = -0.5, .u = 0.0, .v = 1.0 },
        .{ .px = -0.5, .py = -0.5, .pz = 0.5, .u = 1.0, .v = 1.0 },
        .{ .px = -0.5, .py = 0.5, .pz = 0.5, .u = 1.0, .v = 0.0 },
        .{ .px = -0.5, .py = 0.5, .pz = -0.5, .u = 0.0, .v = 0.0 },
    },
    // Right face (x = +0.5)
    .{
        .{ .px = 0.5, .py = -0.5, .pz = 0.5, .u = 0.0, .v = 1.0 },
        .{ .px = 0.5, .py = -0.5, .pz = -0.5, .u = 1.0, .v = 1.0 },
        .{ .px = 0.5, .py = 0.5, .pz = -0.5, .u = 1.0, .v = 0.0 },
        .{ .px = 0.5, .py = 0.5, .pz = 0.5, .u = 0.0, .v = 0.0 },
    },
    // Top face (y = +0.5)
    .{
        .{ .px = -0.5, .py = 0.5, .pz = 0.5, .u = 0.0, .v = 1.0 },
        .{ .px = 0.5, .py = 0.5, .pz = 0.5, .u = 1.0, .v = 1.0 },
        .{ .px = 0.5, .py = 0.5, .pz = -0.5, .u = 1.0, .v = 0.0 },
        .{ .px = -0.5, .py = 0.5, .pz = -0.5, .u = 0.0, .v = 0.0 },
    },
    // Bottom face (y = -0.5)
    .{
        .{ .px = -0.5, .py = -0.5, .pz = -0.5, .u = 0.0, .v = 1.0 },
        .{ .px = 0.5, .py = -0.5, .pz = -0.5, .u = 1.0, .v = 1.0 },
        .{ .px = 0.5, .py = -0.5, .pz = 0.5, .u = 1.0, .v = 0.0 },
        .{ .px = -0.5, .py = -0.5, .pz = 0.5, .u = 0.0, .v = 0.0 },
    },
};

// Per-face index pattern (two triangles, 6 indices referencing 4 verts)
const face_index_pattern = [6]u32{ 0, 1, 2, 2, 3, 0 };

// Face neighbor offsets: for each face index, the (dx, dy, dz) to the adjacent block
// Matches face_vertices order: 0=+Z, 1=-Z, 2=-X, 3=+X, 4=+Y, 5=-Y
const face_neighbor_offsets = [6][3]i32{
    .{ 0, 0, 1 }, // front  (+Z)
    .{ 0, 0, -1 }, // back   (-Z)
    .{ -1, 0, 0 }, // left   (-X)
    .{ 1, 0, 0 }, // right  (+X)
    .{ 0, 1, 0 }, // top    (+Y)
    .{ 0, -1, 0 }, // bottom (-Y)
};

const BlockType = enum(u8) {
    air,
    glass,
};

const block_properties = struct {
    fn isOpaque(block: BlockType) bool {
        return switch (block) {
            .air => false,
            .glass => false,
        };
    }
    fn cullsSelf(block: BlockType) bool {
        return switch (block) {
            .air => false,
            .glass => true,
        };
    }
};

const chunk_blocks: [BLOCKS_PER_CHUNK]BlockType = .{.glass} ** BLOCKS_PER_CHUNK;

fn chunkIndex(x: usize, y: usize, z: usize) usize {
    return y * CHUNK_SIZE * CHUNK_SIZE + z * CHUNK_SIZE + x;
}

fn debugCallback(
    message_severity: vk.VkDebugUtilsMessageSeverityFlagBitsEXT,
    message_type: vk.VkDebugUtilsMessageTypeFlagsEXT,
    callback_data: ?*const vk.VkDebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque,
) callconv(.c) vk.VkBool32 {
    _ = message_type;
    _ = user_data;

    const data = callback_data orelse return vk.VK_FALSE;
    const message = std.mem.span(data.pMessage);

    if (message_severity >= vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) {
        std.log.err("[Vulkan] {s}", .{message});
    } else if (message_severity >= vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) {
        std.log.warn("[Vulkan] {s}", .{message});
    } else if (message_severity >= vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT) {
        std.log.info("[Vulkan] {s}", .{message});
    } else {
        std.log.debug("[Vulkan] {s}", .{message});
    }

    return vk.VK_FALSE;
}

pub const VulkanRenderer = struct {
    allocator: std.mem.Allocator,
    window: *const Window,
    instance: vk.VkInstance,
    debug_messenger: ?vk.VkDebugUtilsMessengerEXT,
    validation_enabled: bool,
    physical_device: vk.VkPhysicalDevice,
    device: vk.VkDevice,
    graphics_queue: vk.VkQueue,
    queue_family_index: u32,
    surface: vk.VkSurfaceKHR,
    swapchain: vk.VkSwapchainKHR,
    swapchain_images: std.ArrayList(vk.VkImage),
    swapchain_image_views: std.ArrayList(vk.VkImageView),
    swapchain_format: vk.VkFormat,
    swapchain_extent: vk.VkExtent2D,
    depth_image: vk.VkImage,
    depth_image_memory: vk.VkDeviceMemory,
    depth_image_view: vk.VkImageView,
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
    command_pool: vk.VkCommandPool,
    command_buffers: [MAX_FRAMES_IN_FLIGHT]vk.VkCommandBuffer,
    image_available_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.VkSemaphore,
    render_finished_semaphores: std.ArrayList(vk.VkSemaphore),
    in_flight_fences: [MAX_FRAMES_IN_FLIGHT]vk.VkFence,
    images_in_flight: std.ArrayList(?vk.VkFence),
    current_frame: u32,
    // Vertex/index buffers
    vertex_buffer: vk.VkBuffer,
    vertex_buffer_memory: vk.VkDeviceMemory,
    index_buffer: vk.VkBuffer,
    index_buffer_memory: vk.VkDeviceMemory,
    camera: ?Camera,
    chunk_index_count: u32,
    framebuffer_resized: bool,

    pub fn init(allocator: std.mem.Allocator, window: *const Window) !*VulkanRenderer {
        const self = try allocator.create(VulkanRenderer);
        errdefer allocator.destroy(self);

        try vk.initialize();

        const instance_result = try createInstance(allocator);
        const instance = instance_result.instance;
        const validation_enabled = instance_result.validation_enabled;
        errdefer vk.destroyInstance(instance, null);

        vk.loadInstance(instance);

        const debug_messenger = if (validation_enabled)
            try createDebugMessenger(instance)
        else
            null;
        errdefer if (validation_enabled) vk.destroyDebugUtilsMessengerEXT(instance, debug_messenger.?, null);

        const surface = try window.createSurface(instance, null);
        errdefer vk.destroySurfaceKHR(instance, surface, null);

        const device_info = try selectPhysicalDevice(allocator, instance, surface);
        const device = try createDevice(device_info.physical_device, device_info.queue_family_index);
        errdefer vk.destroyDevice(device, null);

        vk.loadDevice(device);

        var graphics_queue: vk.VkQueue = undefined;
        vk.getDeviceQueue(device, device_info.queue_family_index, 0, &graphics_queue);

        const swapchain_images: std.ArrayList(vk.VkImage) = .empty;
        const swapchain_image_views: std.ArrayList(vk.VkImageView) = .empty;
        const render_finished_semaphores: std.ArrayList(vk.VkSemaphore) = .empty;
        const images_in_flight: std.ArrayList(?vk.VkFence) = .empty;

        self.* = .{
            .allocator = allocator,
            .window = window,
            .instance = instance,
            .debug_messenger = debug_messenger,
            .validation_enabled = validation_enabled,
            .physical_device = device_info.physical_device,
            .device = device,
            .graphics_queue = graphics_queue,
            .queue_family_index = device_info.queue_family_index,
            .surface = surface,
            .swapchain = null,
            .swapchain_images = swapchain_images,
            .swapchain_image_views = swapchain_image_views,
            .swapchain_format = vk.VK_FORMAT_UNDEFINED,
            .swapchain_extent = .{ .width = 0, .height = 0 },
            .depth_image = null,
            .depth_image_memory = null,
            .depth_image_view = null,
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
            .command_pool = null,
            .command_buffers = [_]vk.VkCommandBuffer{null} ** MAX_FRAMES_IN_FLIGHT,
            .image_available_semaphores = [_]vk.VkSemaphore{null} ** MAX_FRAMES_IN_FLIGHT,
            .render_finished_semaphores = render_finished_semaphores,
            .in_flight_fences = [_]vk.VkFence{null} ** MAX_FRAMES_IN_FLIGHT,
            .images_in_flight = images_in_flight,
            .current_frame = 0,
            .vertex_buffer = null,
            .vertex_buffer_memory = null,
            .index_buffer = null,
            .index_buffer_memory = null,
            .camera = null,
            .chunk_index_count = 0,
            .framebuffer_resized = false,
        };

        try self.createSwapchain();
        var cam = Camera.init(self.swapchain_extent.width, self.swapchain_extent.height);
        cam.target = zlm.Vec3.init(8.0, 8.0, 8.0);
        cam.distance = 40.0;
        cam.elevation = 0.5;
        self.camera = cam;
        try self.createDepthBuffer();
        try self.createCommandPool();
        try self.createTextureImage();
        try self.createChunkBuffers();
        try self.createBindlessDescriptorSet();
        try self.createGraphicsPipeline();
        try self.createIndirectBuffer();
        try self.createComputePipeline();
        try self.createCommandBuffers();
        try self.createSyncObjects();

        std.log.info("VulkanRenderer initialized", .{});
        return self;
    }

    pub fn deinit(self: *VulkanRenderer) void {
        vk.deviceWaitIdle(self.device) catch |err| {
            std.log.err("vkDeviceWaitIdle failed: {}", .{err});
        };

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            vk.destroySemaphore(self.device, self.image_available_semaphores[i], null);
            vk.destroyFence(self.device, self.in_flight_fences[i], null);
        }

        for (self.render_finished_semaphores.items) |semaphore| {
            vk.destroySemaphore(self.device, semaphore, null);
        }
        self.render_finished_semaphores.deinit(self.allocator);

        vk.destroyCommandPool(self.device, self.command_pool, null);

        vk.destroyPipeline(self.device, self.compute_pipeline, null);
        vk.destroyPipelineLayout(self.device, self.compute_pipeline_layout, null);
        vk.destroyDescriptorPool(self.device, self.descriptor_pool, null);
        vk.destroyDescriptorSetLayout(self.device, self.descriptor_set_layout, null);

        vk.destroyBuffer(self.device, self.indirect_buffer, null);
        vk.freeMemory(self.device, self.indirect_buffer_memory, null);
        vk.destroyBuffer(self.device, self.indirect_count_buffer, null);
        vk.freeMemory(self.device, self.indirect_count_buffer_memory, null);

        // Destroy bindless descriptor resources
        vk.destroyDescriptorPool(self.device, self.bindless_descriptor_pool, null);
        vk.destroyDescriptorSetLayout(self.device, self.bindless_descriptor_set_layout, null);

        // Destroy texture resources
        vk.destroySampler(self.device, self.texture_sampler, null);
        vk.destroyImageView(self.device, self.texture_image_view, null);
        vk.destroyImage(self.device, self.texture_image, null);
        vk.freeMemory(self.device, self.texture_image_memory, null);

        vk.destroyBuffer(self.device, self.vertex_buffer, null);
        vk.freeMemory(self.device, self.vertex_buffer_memory, null);
        vk.destroyBuffer(self.device, self.index_buffer, null);
        vk.freeMemory(self.device, self.index_buffer_memory, null);

        vk.destroyPipeline(self.device, self.graphics_pipeline, null);
        vk.destroyPipelineLayout(self.device, self.pipeline_layout, null);

        self.cleanupSwapchain();
        self.swapchain_images.deinit(self.allocator);
        self.swapchain_image_views.deinit(self.allocator);
        self.images_in_flight.deinit(self.allocator);

        vk.destroyImageView(self.device, self.depth_image_view, null);
        vk.destroyImage(self.device, self.depth_image, null);
        vk.freeMemory(self.device, self.depth_image_memory, null);

        vk.destroySurfaceKHR(self.instance, self.surface, null);
        vk.destroyDevice(self.device, null);

        if (self.debug_messenger) |messenger| {
            vk.destroyDebugUtilsMessengerEXT(self.instance, messenger, null);
        }

        vk.destroyInstance(self.instance, null);
        std.log.info("VulkanRenderer destroyed", .{});
        self.allocator.destroy(self);
    }

    pub fn beginFrame(self: *VulkanRenderer) !void {
        const fence = &[_]vk.VkFence{self.in_flight_fences[self.current_frame]};
        try vk.waitForFences(self.device, 1, fence, vk.VK_TRUE, std.math.maxInt(u64));
    }

    pub fn endFrame(self: *VulkanRenderer) !void {
        self.current_frame = (self.current_frame + 1) % MAX_FRAMES_IN_FLIGHT;
    }

    pub fn render(self: *VulkanRenderer) !void {
        // Handle minimized window (0x0 framebuffer)
        const fb_size = self.window.getFramebufferSize();
        if (fb_size.width == 0 or fb_size.height == 0) {
            glfw.waitEvents();
            return;
        }

        var image_index: u32 = undefined;
        const acquire_result = vk.acquireNextImageKHRResult(
            self.device,
            self.swapchain,
            std.math.maxInt(u64),
            self.image_available_semaphores[self.current_frame],
            null,
            &image_index,
        ) catch |err| {
            if (err == error.OutOfDateKHR) {
                try self.recreateSwapchain();
                return;
            }
            return err;
        };

        if (self.images_in_flight.items[image_index]) |image_fence| {
            const fence = &[_]vk.VkFence{image_fence};
            try vk.waitForFences(self.device, 1, fence, vk.VK_TRUE, std.math.maxInt(u64));
        }

        self.images_in_flight.items[image_index] = self.in_flight_fences[self.current_frame];

        const fence = &[_]vk.VkFence{self.in_flight_fences[self.current_frame]};
        try vk.resetFences(self.device, 1, fence);

        try self.recordCommandBuffer(self.command_buffers[self.current_frame], image_index);

        const wait_semaphores = [_]vk.VkSemaphore{self.image_available_semaphores[self.current_frame]};
        const wait_stages = [_]c_uint{vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
        const signal_semaphores = [_]vk.VkSemaphore{self.render_finished_semaphores.items[image_index]};

        const submit_info = vk.VkSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &wait_semaphores,
            .pWaitDstStageMask = &wait_stages,
            .commandBufferCount = 1,
            .pCommandBuffers = &self.command_buffers[self.current_frame],
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &signal_semaphores,
        };

        const submit_infos = &[_]vk.VkSubmitInfo{submit_info};
        try vk.queueSubmit(self.graphics_queue, 1, submit_infos, self.in_flight_fences[self.current_frame]);

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

        const present_result = vk.queuePresentKHRResult(self.graphics_queue, &present_info) catch |err| {
            if (err == error.OutOfDateKHR) {
                try self.recreateSwapchain();
                return;
            }
            return err;
        };

        if (present_result == vk.VK_SUBOPTIMAL_KHR or acquire_result == vk.VK_SUBOPTIMAL_KHR or self.framebuffer_resized) {
            self.framebuffer_resized = false;
            try self.recreateSwapchain();
        }
    }

    fn recreateSwapchain(self: *VulkanRenderer) !void {
        // Wait for all in-flight frames to complete
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            const fence = &[_]vk.VkFence{self.in_flight_fences[i]};
            try vk.waitForFences(self.device, 1, fence, vk.VK_TRUE, std.math.maxInt(u64));
        }

        // Destroy depth buffer
        vk.destroyImageView(self.device, self.depth_image_view, null);
        vk.destroyImage(self.device, self.depth_image, null);
        vk.freeMemory(self.device, self.depth_image_memory, null);

        // Cleanup old swapchain (image views + swapchain handle)
        self.cleanupSwapchain();

        // Recreate swapchain, image views (semaphores are reused/grown inside)
        try self.createSwapchain();

        // Recreate depth buffer at new size
        try self.createDepthBuffer();

        // Update camera aspect ratio
        if (self.camera) |*cam| {
            cam.updateAspect(self.swapchain_extent.width, self.swapchain_extent.height);
        }

        std.log.info("Swapchain recreated: {}x{}", .{ self.swapchain_extent.width, self.swapchain_extent.height });
    }

    fn recordCommandBuffer(self: *VulkanRenderer, command_buffer: vk.VkCommandBuffer, image_index: u32) !void {
        const begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = 0,
            .pInheritanceInfo = null,
        };

        try vk.beginCommandBuffer(command_buffer, &begin_info);

        // Compute culling pass
        var data: ?*anyopaque = null;
        try vk.mapMemory(self.device, self.indirect_count_buffer_memory, 0, @sizeOf(u32), 0, &data);
        const count_ptr: *u32 = @ptrCast(@alignCast(data));
        count_ptr.* = 0;
        vk.unmapMemory(self.device, self.indirect_count_buffer_memory);

        vk.cmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.compute_pipeline);
        vk.cmdBindDescriptorSets(
            command_buffer,
            vk.VK_PIPELINE_BIND_POINT_COMPUTE,
            self.compute_pipeline_layout,
            0,
            1,
            &[_]vk.VkDescriptorSet{self.descriptor_set},
            0,
            null,
        );

        const ComputePushConstants = extern struct {
            object_count: u32,
            total_index_count: u32,
        };
        const compute_pc = ComputePushConstants{
            .object_count = 1,
            .total_index_count = self.chunk_index_count,
        };
        vk.cmdPushConstants(
            command_buffer,
            self.compute_pipeline_layout,
            vk.VK_SHADER_STAGE_COMPUTE_BIT,
            0,
            @sizeOf(ComputePushConstants),
            &compute_pc,
        );

        vk.cmdDispatch(command_buffer, 1, 1, 1);

        // Buffer memory barrier: compute shader write -> indirect command read
        const indirect_barrier = vk.VkBufferMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = vk.VK_ACCESS_SHADER_WRITE_BIT,
            .dstAccessMask = vk.VK_ACCESS_INDIRECT_COMMAND_READ_BIT,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .buffer = self.indirect_buffer,
            .offset = 0,
            .size = @sizeOf(vk.VkDrawIndexedIndirectCommand),
        };

        vk.cmdPipelineBarrier(
            command_buffer,
            vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            vk.VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT,
            0,
            0,
            null,
            1,
            &[_]vk.VkBufferMemoryBarrier{indirect_barrier},
            0,
            null,
        );

        // Barrier: depth image UNDEFINED -> DEPTH_ATTACHMENT_OPTIMAL
        const depth_barrier = vk.VkImageMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = 0,
            .dstAccessMask = vk.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = vk.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = self.depth_image,
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_DEPTH_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        vk.cmdPipelineBarrier(
            command_buffer,
            vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            vk.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &[_]vk.VkImageMemoryBarrier{depth_barrier},
        );

        // Barrier: swapchain image UNDEFINED -> COLOR_ATTACHMENT_OPTIMAL
        const color_barrier = vk.VkImageMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = 0,
            .dstAccessMask = vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = self.swapchain_images.items[image_index],
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        vk.cmdPipelineBarrier(
            command_buffer,
            vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &[_]vk.VkImageMemoryBarrier{color_barrier},
        );

        // Dynamic rendering
        const color_attachment = vk.VkRenderingAttachmentInfo{
            .sType = vk.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
            .pNext = null,
            .imageView = self.swapchain_image_views.items[image_index],
            .imageLayout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .resolveMode = 0,
            .resolveImageView = null,
            .resolveImageLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
            .clearValue = .{ .color = .{ .float32 = .{ 0.224, 0.643, 0.918, 1.0 } } },
        };

        const depth_attachment = vk.VkRenderingAttachmentInfo{
            .sType = vk.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
            .pNext = null,
            .imageView = self.depth_image_view,
            .imageLayout = vk.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL,
            .resolveMode = 0,
            .resolveImageView = null,
            .resolveImageLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .clearValue = .{ .depthStencil = .{ .depth = 1.0, .stencil = 0 } },
        };

        const rendering_info = vk.VkRenderingInfo{
            .sType = vk.VK_STRUCTURE_TYPE_RENDERING_INFO,
            .pNext = null,
            .flags = 0,
            .renderArea = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = self.swapchain_extent,
            },
            .layerCount = 1,
            .viewMask = 0,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_attachment,
            .pDepthAttachment = &depth_attachment,
            .pStencilAttachment = null,
        };

        vk.cmdBeginRendering(command_buffer, &rendering_info);

        vk.cmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.graphics_pipeline);

        // Set viewport and scissor
        const viewport = vk.VkViewport{
            .x = 0.0,
            .y = 0.0,
            .width = @floatFromInt(self.swapchain_extent.width),
            .height = @floatFromInt(self.swapchain_extent.height),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };
        vk.cmdSetViewport(command_buffer, 0, 1, &[_]vk.VkViewport{viewport});

        const scissor = vk.VkRect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swapchain_extent,
        };
        vk.cmdSetScissor(command_buffer, 0, 1, &[_]vk.VkRect2D{scissor});

        // Bind bindless descriptor set (vertex SSBO + textures)
        vk.cmdBindDescriptorSets(
            command_buffer,
            vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.pipeline_layout,
            0,
            1,
            &[_]vk.VkDescriptorSet{self.bindless_descriptor_set},
            0,
            null,
        );

        // Bind index buffer (u32 indices for chunk)
        vk.cmdBindIndexBuffer(command_buffer, self.index_buffer, 0, vk.VK_INDEX_TYPE_UINT32);

        // Push MVP matrix
        const mvp = self.camera.?.getViewProjectionMatrix();
        vk.cmdPushConstants(
            command_buffer,
            self.pipeline_layout,
            vk.VK_SHADER_STAGE_VERTEX_BIT,
            0,
            @sizeOf(zlm.Mat4),
            &mvp.m,
        );

        // Draw indexed indirect with count
        vk.cmdDrawIndexedIndirectCount(
            command_buffer,
            self.indirect_buffer,
            0,
            self.indirect_count_buffer,
            0,
            1,
            @sizeOf(vk.VkDrawIndexedIndirectCommand),
        );

        vk.cmdEndRendering(command_buffer);

        // Barrier: swapchain image COLOR_ATTACHMENT_OPTIMAL -> PRESENT_SRC_KHR
        const present_barrier = vk.VkImageMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dstAccessMask = 0,
            .oldLayout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .newLayout = vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = self.swapchain_images.items[image_index],
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        vk.cmdPipelineBarrier(
            command_buffer,
            vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &[_]vk.VkImageMemoryBarrier{present_barrier},
        );

        try vk.endCommandBuffer(command_buffer);
    }

    fn createCommandPool(self: *VulkanRenderer) !void {
        const pool_info = vk.VkCommandPoolCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = self.queue_family_index,
        };

        self.command_pool = try vk.createCommandPool(self.device, &pool_info, null);
        std.log.info("Command pool created", .{});
    }

    fn createCommandBuffers(self: *VulkanRenderer) !void {
        const alloc_info = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = MAX_FRAMES_IN_FLIGHT,
        };

        try vk.allocateCommandBuffers(self.device, &alloc_info, &self.command_buffers);
        std.log.info("Command buffers allocated ({} frames in flight)", .{MAX_FRAMES_IN_FLIGHT});
    }

    fn createSyncObjects(self: *VulkanRenderer) !void {
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
            self.image_available_semaphores[i] = try vk.createSemaphore(self.device, &semaphore_info, null);
            self.in_flight_fences[i] = try vk.createFence(self.device, &fence_info, null);
        }

        std.log.info("Synchronization objects created", .{});
    }

    const InstanceResult = struct {
        instance: vk.VkInstance,
        validation_enabled: bool,
    };

    fn createInstance(allocator: std.mem.Allocator) !InstanceResult {
        const app_info = vk.VkApplicationInfo{
            .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pNext = null,
            .pApplicationName = "FarHorizons",
            .applicationVersion = vk.VK_MAKE_VERSION(0, 0, 1),
            .pEngineName = "FarHorizons Engine",
            .engineVersion = vk.VK_MAKE_VERSION(0, 0, 1),
            .apiVersion = vk.VK_API_VERSION_1_3,
        };

        const window_extensions = Window.getRequiredExtensions();

        // Collect all required extensions
        var extensions: std.ArrayList([*:0]const u8) = .empty;
        defer extensions.deinit(allocator);

        try extensions.appendSlice(allocator, window_extensions.names[0..window_extensions.count]);

        if (enable_validation_layers) {
            try extensions.append(allocator, vk.VK_EXT_DEBUG_UTILS_EXTENSION_NAME);
        }

        const create_info = vk.VkInstanceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .pApplicationInfo = &app_info,
            .enabledLayerCount = if (enable_validation_layers) validation_layers.len else 0,
            .ppEnabledLayerNames = if (enable_validation_layers) &validation_layers else null,
            .enabledExtensionCount = std.math.cast(u32, extensions.items.len) orelse unreachable,
            .ppEnabledExtensionNames = extensions.items.ptr,
        };

        // Try to create instance with validation layers
        if (enable_validation_layers) {
            if (vk.createInstance(&create_info, null)) |instance| {
                return .{ .instance = instance, .validation_enabled = true };
            } else |err| {
                if (err == error.LayerNotPresent) {
                    std.log.warn("Validation layers requested but not available, continuing without them", .{});
                    // Retry without validation layers
                    const create_info_no_validation = vk.VkInstanceCreateInfo{
                        .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
                        .pNext = null,
                        .flags = 0,
                        .pApplicationInfo = &app_info,
                        .enabledLayerCount = 0,
                        .ppEnabledLayerNames = null,
                        .enabledExtensionCount = window_extensions.count,
                        .ppEnabledExtensionNames = window_extensions.names,
                    };
                    const instance = try vk.createInstance(&create_info_no_validation, null);
                    return .{ .instance = instance, .validation_enabled = false };
                }
                return err;
            }
        }

        const instance = try vk.createInstance(&create_info, null);
        return .{ .instance = instance, .validation_enabled = false };
    }

    const DeviceInfo = struct {
        physical_device: vk.VkPhysicalDevice,
        queue_family_index: u32,
    };

    fn selectPhysicalDevice(allocator: std.mem.Allocator, instance: vk.VkInstance, surface: vk.VkSurfaceKHR) !DeviceInfo {
        var device_count: u32 = 0;
        try vk.enumeratePhysicalDevices(instance, &device_count, null);

        if (device_count == 0) {
            return error.NoVulkanDevices;
        }

        var devices: [16]vk.VkPhysicalDevice = undefined;
        try vk.enumeratePhysicalDevices(instance, &device_count, &devices);

        for (devices[0..device_count]) |device| {
            var props: vk.VkPhysicalDeviceProperties = undefined;
            try vk.getPhysicalDeviceProperties(device, &props);
            std.log.info("Found GPU: {s}", .{props.deviceName});

            if (try findQueueFamily(allocator, device, surface)) |queue_family| {
                return .{
                    .physical_device = device,
                    .queue_family_index = queue_family,
                };
            }
        }

        return error.NoSuitableDevice;
    }

    fn findQueueFamily(allocator: std.mem.Allocator, device: vk.VkPhysicalDevice, surface: vk.VkSurfaceKHR) !?u32 {
        var queue_family_count: u32 = 0;
        try vk.getPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, null);

        var queue_families = try allocator.alloc(vk.VkQueueFamilyProperties, queue_family_count);
        defer allocator.free(queue_families);

        try vk.getPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, queue_families.ptr);

        for (queue_families, 0..) |family, i| {
            const supports_graphics = (family.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT) != 0;

            var present_support: vk.VkBool32 = vk.VK_FALSE;
            try vk.getPhysicalDeviceSurfaceSupportKHR(device, std.math.cast(u32, i) orelse unreachable, surface, &present_support);

            if (supports_graphics and present_support == vk.VK_TRUE) {
                return std.math.cast(u32, i) orelse unreachable;
            }
        }

        return null;
    }

    fn createDevice(physical_device: vk.VkPhysicalDevice, queue_family_index: u32) !vk.VkDevice {
        const queue_priority: f32 = 1.0;
        const queue_create_info = vk.VkDeviceQueueCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = queue_family_index,
            .queueCount = 1,
            .pQueuePriorities = &queue_priority,
        };

        const device_extensions = [_][*:0]const u8{vk.VK_KHR_SWAPCHAIN_EXTENSION_NAME};

        var vulkan12_features: vk.VkPhysicalDeviceVulkan12Features = std.mem.zeroes(vk.VkPhysicalDeviceVulkan12Features);
        vulkan12_features.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES;
        vulkan12_features.drawIndirectCount = vk.VK_TRUE;
        vulkan12_features.descriptorIndexing = vk.VK_TRUE;
        vulkan12_features.runtimeDescriptorArray = vk.VK_TRUE;
        vulkan12_features.descriptorBindingPartiallyBound = vk.VK_TRUE;
        vulkan12_features.descriptorBindingVariableDescriptorCount = vk.VK_TRUE;
        vulkan12_features.shaderSampledImageArrayNonUniformIndexing = vk.VK_TRUE;
        vulkan12_features.shaderStorageBufferArrayNonUniformIndexing = vk.VK_TRUE;
        vulkan12_features.descriptorBindingUpdateUnusedWhilePending = vk.VK_TRUE;
        vulkan12_features.descriptorBindingSampledImageUpdateAfterBind = vk.VK_TRUE;
        vulkan12_features.descriptorBindingStorageBufferUpdateAfterBind = vk.VK_TRUE;

        var vulkan13_features: vk.VkPhysicalDeviceVulkan13Features = std.mem.zeroes(vk.VkPhysicalDeviceVulkan13Features);
        vulkan13_features.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES;
        vulkan13_features.dynamicRendering = vk.VK_TRUE;
        vulkan13_features.synchronization2 = vk.VK_TRUE;

        // Chain: DeviceCreateInfo -> Vulkan13Features -> Vulkan12Features
        vulkan13_features.pNext = &vulkan12_features;

        const create_info = vk.VkDeviceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = &vulkan13_features,
            .flags = 0,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_create_info,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = device_extensions.len,
            .ppEnabledExtensionNames = &device_extensions,
            .pEnabledFeatures = null,
        };

        return try vk.createDevice(physical_device, &create_info, null);
    }

    fn createSwapchain(self: *VulkanRenderer) !void {
        var capabilities: vk.VkSurfaceCapabilitiesKHR = undefined;
        try vk.getPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, self.surface, &capabilities);

        var format_count: u32 = 0;
        try vk.getPhysicalDeviceSurfaceFormatsKHR(self.physical_device, self.surface, &format_count, null);
        var formats = try self.allocator.alloc(vk.VkSurfaceFormatKHR, format_count);
        defer self.allocator.free(formats);
        try vk.getPhysicalDeviceSurfaceFormatsKHR(self.physical_device, self.surface, &format_count, formats.ptr);

        const format = formats[0];
        self.swapchain_format = format.format;

        const fb_size = self.window.getFramebufferSize();
        self.swapchain_extent = .{
            .width = std.math.clamp(fb_size.width, capabilities.minImageExtent.width, capabilities.maxImageExtent.width),
            .height = std.math.clamp(fb_size.height, capabilities.minImageExtent.height, capabilities.maxImageExtent.height),
        };

        var image_count = capabilities.minImageCount + 1;
        if (capabilities.maxImageCount > 0 and image_count > capabilities.maxImageCount) {
            image_count = capabilities.maxImageCount;
        }

        const create_info = vk.VkSwapchainCreateInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .pNext = null,
            .flags = 0,
            .surface = self.surface,
            .minImageCount = image_count,
            .imageFormat = format.format,
            .imageColorSpace = format.colorSpace,
            .imageExtent = self.swapchain_extent,
            .imageArrayLayers = 1,
            .imageUsage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .imageSharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .preTransform = capabilities.currentTransform,
            .compositeAlpha = vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = vk.VK_PRESENT_MODE_FIFO_KHR,
            .clipped = vk.VK_TRUE,
            .oldSwapchain = null,
        };

        self.swapchain = try vk.createSwapchainKHR(self.device, &create_info, null);

        var swapchain_image_count: u32 = 0;
        try vk.getSwapchainImagesKHR(self.device, self.swapchain, &swapchain_image_count, null);
        try self.swapchain_images.resize(self.allocator, swapchain_image_count);
        try vk.getSwapchainImagesKHR(self.device, self.swapchain, &swapchain_image_count, self.swapchain_images.items.ptr);

        try self.swapchain_image_views.resize(self.allocator, swapchain_image_count);
        for (self.swapchain_images.items, 0..) |image, i| {
            const view_info = vk.VkImageViewCreateInfo{
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

            self.swapchain_image_views.items[i] = try vk.createImageView(self.device, &view_info, null);
        }

        try self.images_in_flight.resize(self.allocator, swapchain_image_count);
        for (0..swapchain_image_count) |i| {
            self.images_in_flight.items[i] = null;
        }

        const semaphore_info = vk.VkSemaphoreCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
        };

        const old_semaphore_count = self.render_finished_semaphores.items.len;
        try self.render_finished_semaphores.resize(self.allocator, swapchain_image_count);
        for (old_semaphore_count..swapchain_image_count) |i| {
            self.render_finished_semaphores.items[i] = try vk.createSemaphore(self.device, &semaphore_info, null);
        }

        std.log.info("Swapchain created: {}x{} ({} images)", .{ self.swapchain_extent.width, self.swapchain_extent.height, swapchain_image_count });
    }

    fn cleanupSwapchain(self: *VulkanRenderer) void {
        for (self.swapchain_image_views.items) |view| {
            vk.destroyImageView(self.device, view, null);
        }
        self.swapchain_image_views.clearRetainingCapacity();
        self.swapchain_images.clearRetainingCapacity();
        self.images_in_flight.clearRetainingCapacity();

        if (self.swapchain != null) {
            vk.destroySwapchainKHR(self.device, self.swapchain, null);
        }
    }

    fn createDepthBuffer(self: *VulkanRenderer) !void {
        const image_info = vk.VkImageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = vk.VK_IMAGE_TYPE_2D,
            .format = vk.VK_FORMAT_D32_SFLOAT,
            .extent = .{
                .width = self.swapchain_extent.width,
                .height = self.swapchain_extent.height,
                .depth = 1,
            },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
            .usage = vk.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | vk.VK_IMAGE_USAGE_SAMPLED_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        };

        self.depth_image = try vk.createImage(self.device, &image_info, null);

        var mem_requirements: vk.VkMemoryRequirements = undefined;
        vk.getImageMemoryRequirements(self.device, self.depth_image, &mem_requirements);

        const memory_type_index = try self.findMemoryType(
            mem_requirements.memoryTypeBits,
            vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        );

        const alloc_info = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = mem_requirements.size,
            .memoryTypeIndex = memory_type_index,
        };

        self.depth_image_memory = try vk.allocateMemory(self.device, &alloc_info, null);
        try vk.bindImageMemory(self.device, self.depth_image, self.depth_image_memory, 0);

        const view_info = vk.VkImageViewCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = self.depth_image,
            .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
            .format = vk.VK_FORMAT_D32_SFLOAT,
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

        self.depth_image_view = try vk.createImageView(self.device, &view_info, null);
    }

    fn createTextureImage(self: *VulkanRenderer) !void {
        var tex_width: c_int = 0;
        var tex_height: c_int = 0;
        var tex_channels: c_int = 0;
        const pixels = c.stbi_load("assets/farhorizons/textures/block/glass.png", &tex_width, &tex_height, &tex_channels, 4) orelse {
            std.log.err("Failed to load texture image", .{});
            return error.TextureLoadFailed;
        };
        defer c.stbi_image_free(pixels);

        const image_size: vk.VkDeviceSize = @intCast(@as(u64, @intCast(tex_width)) * @as(u64, @intCast(tex_height)) * 4);

        // Create staging buffer
        var staging_buffer: vk.VkBuffer = undefined;
        var staging_buffer_memory: vk.VkDeviceMemory = undefined;
        try self.createBuffer(
            image_size,
            vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &staging_buffer,
            &staging_buffer_memory,
        );

        var data: ?*anyopaque = null;
        try vk.mapMemory(self.device, staging_buffer_memory, 0, image_size, 0, &data);
        const dst: [*]u8 = @ptrCast(data.?);
        const src: [*]const u8 = @ptrCast(pixels);
        @memcpy(dst[0..@intCast(image_size)], src[0..@intCast(image_size)]);
        vk.unmapMemory(self.device, staging_buffer_memory);

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

        self.texture_image = try vk.createImage(self.device, &image_info, null);

        var mem_requirements: vk.VkMemoryRequirements = undefined;
        vk.getImageMemoryRequirements(self.device, self.texture_image, &mem_requirements);

        const memory_type_index = try self.findMemoryType(
            mem_requirements.memoryTypeBits,
            vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        );

        const alloc_info = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = mem_requirements.size,
            .memoryTypeIndex = memory_type_index,
        };

        self.texture_image_memory = try vk.allocateMemory(self.device, &alloc_info, null);
        try vk.bindImageMemory(self.device, self.texture_image, self.texture_image_memory, 0);

        // Transition + copy via one-time command buffer
        const cmd_alloc_info = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };

        var cmd_buffers: [1]vk.VkCommandBuffer = undefined;
        try vk.allocateCommandBuffers(self.device, &cmd_alloc_info, &cmd_buffers);
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

        try vk.queueSubmit(self.graphics_queue, 1, &submit_infos, null);
        try vk.queueWaitIdle(self.graphics_queue);
        vk.freeCommandBuffers(self.device, self.command_pool, 1, &cmd_buffers);

        // Clean up staging buffer
        vk.destroyBuffer(self.device, staging_buffer, null);
        vk.freeMemory(self.device, staging_buffer_memory, null);

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

        self.texture_image_view = try vk.createImageView(self.device, &view_info, null);

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

        self.texture_sampler = try vk.createSampler(self.device, &sampler_info, null);
        std.log.info("Texture image created ({}x{})", .{ tex_width, tex_height });
    }

    fn createBindlessDescriptorSet(self: *VulkanRenderer) !void {
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

        self.bindless_descriptor_set_layout = try vk.createDescriptorSetLayout(self.device, &layout_info, null);

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

        self.bindless_descriptor_pool = try vk.createDescriptorPool(self.device, &pool_info, null);

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
        try vk.allocateDescriptorSets(self.device, &alloc_info, &descriptor_sets);
        self.bindless_descriptor_set = descriptor_sets[0];

        // Write descriptors
        const vertex_buffer_info = vk.VkDescriptorBufferInfo{
            .buffer = self.vertex_buffer,
            .offset = 0,
            .range = CHUNK_VERTEX_COUNT * @sizeOf(GpuVertex),
        };

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
                .dstBinding = 0,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .pImageInfo = null,
                .pBufferInfo = &vertex_buffer_info,
                .pTexelBufferView = null,
            },
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

        vk.updateDescriptorSets(self.device, descriptor_writes.len, &descriptor_writes, 0, null);
        std.log.info("Bindless descriptor set created", .{});
    }

    fn createGraphicsPipeline(self: *VulkanRenderer) !void {
        const vert_src = @embedFile("../../shaders/test.vert");
        const frag_src = @embedFile("../../shaders/test.frag");

        const vert_spirv = try ShaderCompiler.compile(self.allocator, vert_src, "test.vert", .vertex);
        defer self.allocator.free(vert_spirv);

        const frag_spirv = try ShaderCompiler.compile(self.allocator, frag_src, "test.frag", .fragment);
        defer self.allocator.free(frag_spirv);

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

        const vert_module = try vk.createShaderModule(self.device, &vert_module_info, null);
        defer vk.destroyShaderModule(self.device, vert_module, null);

        const frag_module = try vk.createShaderModule(self.device, &frag_module_info, null);
        defer vk.destroyShaderModule(self.device, frag_module, null);

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

        // Empty vertex input — vertex pulling from SSBO
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

        self.pipeline_layout = try vk.createPipelineLayout(self.device, &pipeline_layout_info, null);

        // Dynamic rendering pipeline info
        const color_attachment_format = [_]vk.VkFormat{self.swapchain_format};
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
        try vk.createGraphicsPipelines(self.device, null, 1, pipeline_infos, null, &pipelines);
        self.graphics_pipeline = pipelines[0];

        std.log.info("Graphics pipeline created", .{});
    }

    fn createIndirectBuffer(self: *VulkanRenderer) !void {
        const buffer_size = @sizeOf(vk.VkDrawIndexedIndirectCommand);

        try self.createBuffer(
            buffer_size,
            vk.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT | vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &self.indirect_buffer,
            &self.indirect_buffer_memory,
        );

        var data: ?*anyopaque = null;
        try vk.mapMemory(self.device, self.indirect_buffer_memory, 0, buffer_size, 0, &data);
        const draw_ptr: *vk.VkDrawIndexedIndirectCommand = @ptrCast(@alignCast(data));
        draw_ptr.* = std.mem.zeroes(vk.VkDrawIndexedIndirectCommand);
        vk.unmapMemory(self.device, self.indirect_buffer_memory);

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

        self.indirect_count_buffer = try vk.createBuffer(self.device, &count_buffer_info, null);

        var count_mem_requirements: vk.VkMemoryRequirements = undefined;
        vk.getBufferMemoryRequirements(self.device, self.indirect_count_buffer, &count_mem_requirements);

        const count_memory_type_index = try self.findMemoryType(
            count_mem_requirements.memoryTypeBits,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );

        const count_alloc_info = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = count_mem_requirements.size,
            .memoryTypeIndex = count_memory_type_index,
        };

        self.indirect_count_buffer_memory = try vk.allocateMemory(self.device, &count_alloc_info, null);
        try vk.bindBufferMemory(self.device, self.indirect_count_buffer, self.indirect_count_buffer_memory, 0);

        var count_data: ?*anyopaque = null;
        try vk.mapMemory(self.device, self.indirect_count_buffer_memory, 0, count_buffer_size, 0, &count_data);

        const count_ptr: *u32 = @ptrCast(@alignCast(count_data));
        count_ptr.* = 1;

        vk.unmapMemory(self.device, self.indirect_count_buffer_memory);

        std.log.info("Indirect draw buffers created (count buffer for GPU-driven rendering)", .{});
    }

    fn createComputePipeline(self: *VulkanRenderer) !void {
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

        self.descriptor_set_layout = try vk.createDescriptorSetLayout(self.device, &layout_info, null);

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

        self.descriptor_pool = try vk.createDescriptorPool(self.device, &pool_info, null);

        const desc_alloc_info = vk.VkDescriptorSetAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = self.descriptor_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &self.descriptor_set_layout,
        };

        var descriptor_sets: [1]vk.VkDescriptorSet = undefined;
        try vk.allocateDescriptorSets(self.device, &desc_alloc_info, &descriptor_sets);
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

        vk.updateDescriptorSets(self.device, descriptor_writes.len, &descriptor_writes, 0, null);

        const comp_src = @embedFile("../../shaders/cull.comp");
        const comp_spirv = try ShaderCompiler.compile(self.allocator, comp_src, "cull.comp", .compute);
        defer self.allocator.free(comp_spirv);

        const comp_module_info = vk.VkShaderModuleCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = comp_spirv.len,
            .pCode = @ptrCast(@alignCast(comp_spirv.ptr)),
        };

        const comp_module = try vk.createShaderModule(self.device, &comp_module_info, null);
        defer vk.destroyShaderModule(self.device, comp_module, null);

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

        self.compute_pipeline_layout = try vk.createPipelineLayout(self.device, &compute_layout_info, null);

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
        try vk.createComputePipelines(self.device, null, 1, pipeline_infos, null, &pipelines);
        self.compute_pipeline = pipelines[0];

        std.log.info("Compute pipeline created", .{});
    }

    fn findMemoryType(self: *VulkanRenderer, type_filter: u32, properties: c_uint) !u32 {
        var mem_properties: vk.VkPhysicalDeviceMemoryProperties = undefined;
        vk.getPhysicalDeviceMemoryProperties(self.physical_device, &mem_properties);

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

    fn createBuffer(
        self: *VulkanRenderer,
        size: vk.VkDeviceSize,
        usage: c_uint,
        properties: c_uint,
        buffer: *vk.VkBuffer,
        buffer_memory: *vk.VkDeviceMemory,
    ) !void {
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

        buffer.* = try vk.createBuffer(self.device, &buffer_info, null);

        var mem_requirements: vk.VkMemoryRequirements = undefined;
        vk.getBufferMemoryRequirements(self.device, buffer.*, &mem_requirements);

        const memory_type_index = try self.findMemoryType(
            mem_requirements.memoryTypeBits,
            properties,
        );

        const alloc_info = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = mem_requirements.size,
            .memoryTypeIndex = memory_type_index,
        };

        buffer_memory.* = try vk.allocateMemory(self.device, &alloc_info, null);
        try vk.bindBufferMemory(self.device, buffer.*, buffer_memory.*, 0);
    }

    fn copyBuffer(
        self: *VulkanRenderer,
        src_buffer: vk.VkBuffer,
        dst_buffer: vk.VkBuffer,
        size: vk.VkDeviceSize,
    ) !void {
        const alloc_info = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };

        var command_buffers: [1]vk.VkCommandBuffer = undefined;
        try vk.allocateCommandBuffers(self.device, &alloc_info, &command_buffers);
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

        try vk.queueSubmit(self.graphics_queue, 1, &submit_infos, null);
        try vk.queueWaitIdle(self.graphics_queue);

        vk.freeCommandBuffers(self.device, self.command_pool, 1, &command_buffers);
    }

    fn generateChunkMesh(
        allocator: std.mem.Allocator,
        blocks: []const BlockType,
    ) !struct { vertices: []GpuVertex, indices: []u32, vertex_count: u32, index_count: u32 } {
        const vertices = try allocator.alloc(GpuVertex, CHUNK_VERTEX_COUNT);
        errdefer allocator.free(vertices);
        const indices = try allocator.alloc(u32, CHUNK_INDEX_COUNT);
        errdefer allocator.free(indices);

        var vert_count: u32 = 0;
        var idx_count: u32 = 0;

        for (0..CHUNK_SIZE) |by| {
            for (0..CHUNK_SIZE) |bz| {
                for (0..CHUNK_SIZE) |bx| {
                    const block = blocks[chunkIndex(bx, by, bz)];
                    if (block == .air) continue;

                    const bx_f: f32 = @floatFromInt(bx);
                    const by_f: f32 = @floatFromInt(by);
                    const bz_f: f32 = @floatFromInt(bz);

                    for (0..6) |face| {
                        const offset = face_neighbor_offsets[face];
                        const nx: i32 = @as(i32, @intCast(bx)) + offset[0];
                        const ny: i32 = @as(i32, @intCast(by)) + offset[1];
                        const nz: i32 = @as(i32, @intCast(bz)) + offset[2];

                        // Check if neighbor is within chunk bounds
                        if (nx >= 0 and nx < CHUNK_SIZE and ny >= 0 and ny < CHUNK_SIZE and nz >= 0 and nz < CHUNK_SIZE) {
                            const neighbor = blocks[chunkIndex(@intCast(nx), @intCast(ny), @intCast(nz))];
                            // Skip face if neighbor is opaque
                            if (block_properties.isOpaque(neighbor)) continue;
                            // Skip face if same type and block culls self
                            if (neighbor == block and block_properties.cullsSelf(block)) continue;
                        }
                        // Out-of-bounds neighbor = chunk boundary, always emit face

                        // Emit 4 vertices for this face
                        for (0..4) |v| {
                            const fv = face_vertices[face][v];
                            vertices[vert_count + @as(u32, @intCast(v))] = .{
                                .px = fv.px + bx_f,
                                .py = fv.py + by_f,
                                .pz = fv.pz + bz_f,
                                .u = fv.u,
                                .v = fv.v,
                                .tex_index = 0,
                            };
                        }

                        // Emit 6 indices for this face
                        for (0..6) |i| {
                            indices[idx_count + @as(u32, @intCast(i))] = vert_count + face_index_pattern[i];
                        }

                        vert_count += 4;
                        idx_count += 6;
                    }
                }
            }
        }

        std.log.info("Chunk mesh: {} indices ({} faces) out of max {}", .{ idx_count, idx_count / 6, CHUNK_INDEX_COUNT });
        return .{ .vertices = vertices, .indices = indices, .vertex_count = vert_count, .index_count = idx_count };
    }

    fn createChunkBuffers(self: *VulkanRenderer) !void {
        const mesh = try generateChunkMesh(self.allocator, &chunk_blocks);
        defer self.allocator.free(mesh.vertices);
        defer self.allocator.free(mesh.indices);

        self.chunk_index_count = mesh.index_count;

        // Create vertex buffer via staging (allocate max size, upload actual data)
        const vb_max_size: vk.VkDeviceSize = @intCast(CHUNK_VERTEX_COUNT * @sizeOf(GpuVertex));
        const vb_actual_size: vk.VkDeviceSize = @intCast(mesh.vertex_count * @sizeOf(GpuVertex));
        {
            var staging_buffer: vk.VkBuffer = undefined;
            var staging_memory: vk.VkDeviceMemory = undefined;
            try self.createBuffer(
                vb_actual_size,
                vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                &staging_buffer,
                &staging_memory,
            );

            var data: ?*anyopaque = null;
            try vk.mapMemory(self.device, staging_memory, 0, vb_actual_size, 0, &data);
            const dst: [*]GpuVertex = @ptrCast(@alignCast(data));
            @memcpy(dst[0..mesh.vertex_count], mesh.vertices[0..mesh.vertex_count]);
            vk.unmapMemory(self.device, staging_memory);

            try self.createBuffer(
                vb_max_size,
                vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT | vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
                vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
                &self.vertex_buffer,
                &self.vertex_buffer_memory,
            );

            try self.copyBuffer(staging_buffer, self.vertex_buffer, vb_actual_size);
            vk.destroyBuffer(self.device, staging_buffer, null);
            vk.freeMemory(self.device, staging_memory, null);
        }

        // Create index buffer via staging (allocate max size, upload actual data)
        const ib_max_size: vk.VkDeviceSize = @intCast(CHUNK_INDEX_COUNT * @sizeOf(u32));
        const ib_actual_size: vk.VkDeviceSize = @intCast(mesh.index_count * @sizeOf(u32));
        {
            var staging_buffer: vk.VkBuffer = undefined;
            var staging_memory: vk.VkDeviceMemory = undefined;
            try self.createBuffer(
                ib_actual_size,
                vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                &staging_buffer,
                &staging_memory,
            );

            var data: ?*anyopaque = null;
            try vk.mapMemory(self.device, staging_memory, 0, ib_actual_size, 0, &data);
            const dst: [*]u32 = @ptrCast(@alignCast(data));
            @memcpy(dst[0..mesh.index_count], mesh.indices[0..mesh.index_count]);
            vk.unmapMemory(self.device, staging_memory);

            try self.createBuffer(
                ib_max_size,
                vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT | vk.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
                vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
                &self.index_buffer,
                &self.index_buffer_memory,
            );

            try self.copyBuffer(staging_buffer, self.index_buffer, ib_actual_size);
            vk.destroyBuffer(self.device, staging_buffer, null);
            vk.freeMemory(self.device, staging_memory, null);
        }

        std.log.info("Chunk buffers created ({} vertices, {} indices)", .{ mesh.vertex_count, mesh.index_count });
    }

    fn createDebugMessenger(instance: vk.VkInstance) !vk.VkDebugUtilsMessengerEXT {
        const create_info = vk.VkDebugUtilsMessengerCreateInfoEXT{
            .sType = vk.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            .pNext = null,
            .flags = 0,
            .messageSeverity = vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT |
                vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT |
                vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
            .messageType = vk.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                vk.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                vk.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
            .pfnUserCallback = debugCallback,
            .pUserData = null,
        };

        return try vk.createDebugUtilsMessengerEXT(instance, &create_info, null);
    }

    fn initVTable(allocator: std.mem.Allocator, window: *const Window) anyerror!*anyopaque {
        const self = try init(allocator, window);
        return @ptrCast(self);
    }

    fn deinitVTable(ptr: *anyopaque) void {
        const self: *VulkanRenderer = @ptrCast(@alignCast(ptr));
        deinit(self);
    }

    fn beginFrameVTable(ptr: *anyopaque) anyerror!void {
        const self: *VulkanRenderer = @ptrCast(@alignCast(ptr));
        return beginFrame(self);
    }

    fn endFrameVTable(ptr: *anyopaque) anyerror!void {
        const self: *VulkanRenderer = @ptrCast(@alignCast(ptr));
        return endFrame(self);
    }

    fn renderVTable(ptr: *anyopaque) anyerror!void {
        const self: *VulkanRenderer = @ptrCast(@alignCast(ptr));
        return render(self);
    }

    fn rotateCameraVTable(impl: *anyopaque, delta_azimuth: f32, delta_elevation: f32) void {
        const self: *VulkanRenderer = @ptrCast(@alignCast(impl));
        self.camera.?.rotate(delta_azimuth, delta_elevation);
    }

    fn zoomCameraVTable(impl: *anyopaque, delta_distance: f32) void {
        const self: *VulkanRenderer = @ptrCast(@alignCast(impl));
        self.camera.?.zoom(delta_distance);
    }

    fn getFramebufferResizedPtrVTable(impl: *anyopaque) *bool {
        const self: *VulkanRenderer = @ptrCast(@alignCast(impl));
        return &self.framebuffer_resized;
    }

    pub const vtable: Renderer.VTable = .{
        .init = initVTable,
        .deinit = deinitVTable,
        .begin_frame = beginFrameVTable,
        .end_frame = endFrameVTable,
        .render = renderVTable,
        .rotate_camera = rotateCameraVTable,
        .zoom_camera = zoomCameraVTable,
        .get_framebuffer_resized_ptr = getFramebufferResizedPtrVTable,
    };
};
