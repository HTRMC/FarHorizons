const std = @import("std");
const Renderer = @import("../Renderer.zig").Renderer;
const vk = @import("../../platform/volk.zig");
const Window = @import("../../platform/Window.zig").Window;
const glfw = @import("../../platform/glfw.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const SurfaceState = @import("SurfaceState.zig").SurfaceState;
const RenderState = @import("RenderState.zig").RenderState;
const MeshWorker = @import("../../world/MeshWorker.zig").MeshWorker;
const GameState = @import("../../GameState.zig");
const zlm = @import("zlm");
const tracy = @import("../../platform/tracy.zig");

const enable_validation_layers = @import("builtin").mode == .Debug;
const validation_layers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};
const MAX_FRAMES_IN_FLIGHT = 2;

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
    device: vk.VkDevice,
    graphics_queue: vk.VkQueue,
    queue_family_index: u32,
    surface: vk.VkSurfaceKHR,
    ctx: VulkanContext,
    surface_state: SurfaceState,
    render_state: RenderState,
    command_pool: vk.VkCommandPool,
    mesh_worker: MeshWorker,
    game_state: *GameState,
    framebuffer_resized: bool,

    pub fn init(allocator: std.mem.Allocator, window: *const Window, game_state: *GameState) !*VulkanRenderer {
        const init_zone = tracy.zone(@src(), "VulkanRenderer.init");
        defer init_zone.end();

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

        const ctx = VulkanContext{
            .device = device,
            .physical_device = device_info.physical_device,
            .graphics_queue = graphics_queue,
            .queue_family_index = device_info.queue_family_index,
            .command_pool = undefined,
        };

        self.* = .{
            .allocator = allocator,
            .window = window,
            .instance = instance,
            .debug_messenger = debug_messenger,
            .validation_enabled = validation_enabled,
            .device = device,
            .graphics_queue = graphics_queue,
            .queue_family_index = device_info.queue_family_index,
            .surface = surface,
            .ctx = ctx,
            .surface_state = undefined,
            .render_state = undefined,
            .command_pool = null,
            .mesh_worker = MeshWorker.init(allocator),
            .game_state = game_state,
            .framebuffer_resized = false,
        };

        try self.createCommandPool();
        self.surface_state = try SurfaceState.create(allocator, &self.ctx, self.surface, self.window);
        self.game_state.camera.updateAspect(self.surface_state.swapchain_extent.width, self.surface_state.swapchain_extent.height);
        self.render_state = try RenderState.create(allocator, &self.ctx, self.surface_state.swapchain_format);

        self.mesh_worker.start();

        std.log.info("VulkanRenderer initialized", .{});
        return self;
    }

    pub fn deinit(self: *VulkanRenderer) void {
        const tz = tracy.zone(@src(), "VulkanRenderer.deinit");
        defer tz.end();

        vk.deviceWaitIdle(self.device) catch |err| {
            std.log.err("vkDeviceWaitIdle failed: {}", .{err});
        };

        self.mesh_worker.deinit();
        self.render_state.deinit(self.device);
        vk.destroyCommandPool(self.device, self.command_pool, null);
        self.surface_state.deinit(self.allocator, self.device);

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
        const tz = tracy.zone(@src(), "beginFrame");
        defer tz.end();

        const fence = &[_]vk.VkFence{self.render_state.in_flight_fences[self.render_state.current_frame]};
        try vk.waitForFences(self.device, 1, fence, vk.VK_TRUE, std.math.maxInt(u64));

        self.pollMeshWorker();
    }

    fn pollMeshWorker(self: *VulkanRenderer) void {
        const result = self.mesh_worker.poll() orelse return;
        defer self.allocator.free(result.vertices);
        defer self.allocator.free(result.indices);

        self.render_state.uploadChunkMesh(
            &self.ctx,
            result.vertices,
            result.indices,
            result.vertex_count,
            result.index_count,
        ) catch |err| {
            std.log.err("Failed to upload chunk mesh: {}", .{err});
        };
    }

    pub fn endFrame(self: *VulkanRenderer) !void {
        const tz = tracy.zone(@src(), "endFrame");
        defer tz.end();

        self.render_state.current_frame = (self.render_state.current_frame + 1) % MAX_FRAMES_IN_FLIGHT;
    }

    pub fn render(self: *VulkanRenderer) !void {
        const tz = tracy.zone(@src(), "render");
        defer tz.end();

        // Handle minimized window (0x0 framebuffer)
        const fb_size = self.window.getFramebufferSize();
        if (fb_size.width == 0 or fb_size.height == 0) {
            glfw.waitEvents();
            return;
        }

        var image_index: u32 = undefined;
        const acquire_result = vk.acquireNextImageKHRResult(
            self.device,
            self.surface_state.swapchain,
            std.math.maxInt(u64),
            self.render_state.image_available_semaphores[self.render_state.current_frame],
            null,
            &image_index,
        ) catch |err| {
            if (err == error.OutOfDateKHR) {
                try self.recreateSwapchain();
                return;
            }
            return err;
        };

        if (self.surface_state.images_in_flight.items[image_index]) |image_fence| {
            const fence = &[_]vk.VkFence{image_fence};
            try vk.waitForFences(self.device, 1, fence, vk.VK_TRUE, std.math.maxInt(u64));
        }

        self.surface_state.images_in_flight.items[image_index] = self.render_state.in_flight_fences[self.render_state.current_frame];

        const fence = &[_]vk.VkFence{self.render_state.in_flight_fences[self.render_state.current_frame]};
        try vk.resetFences(self.device, 1, fence);

        try self.recordCommandBuffer(self.render_state.command_buffers[self.render_state.current_frame], image_index);

        const wait_semaphores = [_]vk.VkSemaphore{self.render_state.image_available_semaphores[self.render_state.current_frame]};
        const wait_stages = [_]c_uint{vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
        const signal_semaphores = [_]vk.VkSemaphore{self.surface_state.render_finished_semaphores.items[image_index]};

        const submit_info = vk.VkSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &wait_semaphores,
            .pWaitDstStageMask = &wait_stages,
            .commandBufferCount = 1,
            .pCommandBuffers = &self.render_state.command_buffers[self.render_state.current_frame],
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &signal_semaphores,
        };

        const submit_infos = &[_]vk.VkSubmitInfo{submit_info};
        try vk.queueSubmit(self.graphics_queue, 1, submit_infos, self.render_state.in_flight_fences[self.render_state.current_frame]);

        const swapchains = [_]vk.VkSwapchainKHR{self.surface_state.swapchain};
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
        const tz = tracy.zone(@src(), "recreateSwapchain");
        defer tz.end();

        // Wait for all in-flight frames to complete
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            const fence = &[_]vk.VkFence{self.render_state.in_flight_fences[i]};
            try vk.waitForFences(self.device, 1, fence, vk.VK_TRUE, std.math.maxInt(u64));
        }

        // Destroy depth buffer
        vk.destroyImageView(self.device, self.surface_state.depth_image_view, null);
        vk.destroyImage(self.device, self.surface_state.depth_image, null);
        vk.freeMemory(self.device, self.surface_state.depth_image_memory, null);

        // Cleanup old swapchain (image views + swapchain handle)
        self.surface_state.cleanupSwapchain(self.device);

        // Recreate swapchain, image views (semaphores are reused/grown inside)
        try self.surface_state.createSwapchain(self.allocator, &self.ctx, self.surface, self.window);

        // Recreate depth buffer at new size
        try self.surface_state.createDepthBuffer(&self.ctx);

        // Update camera aspect ratio
        self.game_state.camera.updateAspect(self.surface_state.swapchain_extent.width, self.surface_state.swapchain_extent.height);

        std.log.info("Swapchain recreated: {}x{}", .{ self.surface_state.swapchain_extent.width, self.surface_state.swapchain_extent.height });
    }

    fn recordCommandBuffer(self: *VulkanRenderer, command_buffer: vk.VkCommandBuffer, image_index: u32) !void {
        const tz = tracy.zone(@src(), "recordCommandBuffer");
        defer tz.end();

        const begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = 0,
            .pInheritanceInfo = null,
        };

        try vk.beginCommandBuffer(command_buffer, &begin_info);

        // Compute culling pass (only if chunk mesh is available)
        const has_chunks = self.render_state.chunk_index_count > 0;
        if (has_chunks) {
            var data: ?*anyopaque = null;
            try vk.mapMemory(self.device, self.render_state.indirect_count_buffer_memory, 0, @sizeOf(u32), 0, &data);
            const count_ptr: *u32 = @ptrCast(@alignCast(data));
            count_ptr.* = 0;
            vk.unmapMemory(self.device, self.render_state.indirect_count_buffer_memory);

            vk.cmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.render_state.compute_pipeline);
            vk.cmdBindDescriptorSets(
                command_buffer,
                vk.VK_PIPELINE_BIND_POINT_COMPUTE,
                self.render_state.compute_pipeline_layout,
                0,
                1,
                &[_]vk.VkDescriptorSet{self.render_state.descriptor_set},
                0,
                null,
            );

            const ComputePushConstants = extern struct {
                object_count: u32,
                total_index_count: u32,
            };
            const compute_pc = ComputePushConstants{
                .object_count = 1,
                .total_index_count = self.render_state.chunk_index_count,
            };
            vk.cmdPushConstants(
                command_buffer,
                self.render_state.compute_pipeline_layout,
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
                .buffer = self.render_state.indirect_buffer,
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
        }

        // Debug line compute dispatch
        vk.cmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.render_state.debug_line_compute_pipeline);
        vk.cmdBindDescriptorSets(
            command_buffer,
            vk.VK_PIPELINE_BIND_POINT_COMPUTE,
            self.render_state.debug_line_compute_pipeline_layout,
            0,
            1,
            &[_]vk.VkDescriptorSet{self.render_state.debug_line_compute_descriptor_set},
            0,
            null,
        );
        vk.cmdPushConstants(
            command_buffer,
            self.render_state.debug_line_compute_pipeline_layout,
            vk.VK_SHADER_STAGE_COMPUTE_BIT,
            0,
            @sizeOf(u32),
            &self.render_state.debug_line_vertex_count,
        );
        vk.cmdDispatch(command_buffer, 1, 1, 1);

        // Barrier: compute write -> indirect read for debug lines
        const debug_line_indirect_barrier = vk.VkBufferMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = vk.VK_ACCESS_SHADER_WRITE_BIT,
            .dstAccessMask = vk.VK_ACCESS_INDIRECT_COMMAND_READ_BIT,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .buffer = self.render_state.debug_line_indirect_buffer,
            .offset = 0,
            .size = @sizeOf(vk.VkDrawIndirectCommand),
        };

        vk.cmdPipelineBarrier(
            command_buffer,
            vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            vk.VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT,
            0,
            0,
            null,
            1,
            &[_]vk.VkBufferMemoryBarrier{debug_line_indirect_barrier},
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
            .image = self.surface_state.depth_image,
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
            .image = self.surface_state.swapchain_images.items[image_index],
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
            .imageView = self.surface_state.swapchain_image_views.items[image_index],
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
            .imageView = self.surface_state.depth_image_view,
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
                .extent = self.surface_state.swapchain_extent,
            },
            .layerCount = 1,
            .viewMask = 0,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_attachment,
            .pDepthAttachment = &depth_attachment,
            .pStencilAttachment = null,
        };

        vk.cmdBeginRendering(command_buffer, &rendering_info);

        // Set viewport and scissor
        const viewport = vk.VkViewport{
            .x = 0.0,
            .y = 0.0,
            .width = @floatFromInt(self.surface_state.swapchain_extent.width),
            .height = @floatFromInt(self.surface_state.swapchain_extent.height),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };
        vk.cmdSetViewport(command_buffer, 0, 1, &[_]vk.VkViewport{viewport});

        const scissor = vk.VkRect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.surface_state.swapchain_extent,
        };
        vk.cmdSetScissor(command_buffer, 0, 1, &[_]vk.VkRect2D{scissor});

        const mvp = self.game_state.camera.getViewProjectionMatrix();

        // Draw chunks (only if mesh data is available)
        if (has_chunks) {
            vk.cmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.render_state.graphics_pipeline);

            // Bind bindless descriptor set (vertex SSBO + textures)
            vk.cmdBindDescriptorSets(
                command_buffer,
                vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
                self.render_state.pipeline_layout,
                0,
                1,
                &[_]vk.VkDescriptorSet{self.render_state.bindless_descriptor_set},
                0,
                null,
            );

            // Bind index buffer (u32 indices for chunk)
            vk.cmdBindIndexBuffer(command_buffer, self.render_state.index_buffer, 0, vk.VK_INDEX_TYPE_UINT32);

            // Push MVP matrix
            vk.cmdPushConstants(
                command_buffer,
                self.render_state.pipeline_layout,
                vk.VK_SHADER_STAGE_VERTEX_BIT,
                0,
                @sizeOf(zlm.Mat4),
                &mvp.m,
            );

            // Draw indexed indirect with count
            vk.cmdDrawIndexedIndirectCount(
                command_buffer,
                self.render_state.indirect_buffer,
                0,
                self.render_state.indirect_count_buffer,
                0,
                1,
                @sizeOf(vk.VkDrawIndexedIndirectCommand),
            );
        }

        // Debug line draw
        vk.cmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.render_state.debug_line_pipeline);
        vk.cmdBindDescriptorSets(
            command_buffer,
            vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.render_state.debug_line_pipeline_layout,
            0,
            1,
            &[_]vk.VkDescriptorSet{self.render_state.debug_line_descriptor_set},
            0,
            null,
        );
        vk.cmdPushConstants(
            command_buffer,
            self.render_state.debug_line_pipeline_layout,
            vk.VK_SHADER_STAGE_VERTEX_BIT,
            0,
            @sizeOf(zlm.Mat4),
            &mvp.m,
        );
        vk.cmdDrawIndirectCount(
            command_buffer,
            self.render_state.debug_line_indirect_buffer,
            0,
            self.render_state.debug_line_count_buffer,
            0,
            1,
            @sizeOf(vk.VkDrawIndirectCommand),
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
            .image = self.surface_state.swapchain_images.items[image_index],
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
        const tz = tracy.zone(@src(), "createCommandPool");
        defer tz.end();

        const pool_info = vk.VkCommandPoolCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = self.queue_family_index,
        };

        self.command_pool = try vk.createCommandPool(self.device, &pool_info, null);
        self.ctx.command_pool = self.command_pool;
        std.log.info("Command pool created", .{});
    }

    const InstanceResult = struct {
        instance: vk.VkInstance,
        validation_enabled: bool,
    };

    fn createInstance(allocator: std.mem.Allocator) !InstanceResult {
        const tz = tracy.zone(@src(), "createInstance");
        defer tz.end();

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
        const tz = tracy.zone(@src(), "selectPhysicalDevice");
        defer tz.end();

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
        const tz = tracy.zone(@src(), "findQueueFamily");
        defer tz.end();

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
        const tz = tracy.zone(@src(), "createDevice");
        defer tz.end();

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

    fn createDebugMessenger(instance: vk.VkInstance) !vk.VkDebugUtilsMessengerEXT {
        const tz = tracy.zone(@src(), "createDebugMessenger");
        defer tz.end();

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

    fn initVTable(allocator: std.mem.Allocator, window: *const Window, user_data: ?*anyopaque) anyerror!*anyopaque {
        const game_state: *GameState = @ptrCast(@alignCast(user_data.?));
        const self = try init(allocator, window, game_state);
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
        self.game_state.camera.rotate(delta_azimuth, delta_elevation);
    }

    fn zoomCameraVTable(impl: *anyopaque, delta_distance: f32) void {
        const self: *VulkanRenderer = @ptrCast(@alignCast(impl));
        self.game_state.camera.zoom(delta_distance);
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
