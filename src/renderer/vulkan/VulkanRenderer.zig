const std = @import("std");
const Renderer = @import("../Renderer.zig").Renderer;
const vk = @import("../../platform/volk.zig");
const Window = @import("../../platform/Window.zig").Window;
const glfw = @import("../../platform/glfw.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const SurfaceState = @import("SurfaceState.zig").SurfaceState;
const render_state_mod = @import("RenderState.zig");
const RenderState = render_state_mod.RenderState;
const MAX_FRAMES_IN_FLIGHT = render_state_mod.MAX_FRAMES_IN_FLIGHT;
const MeshWorker = @import("../../world/MeshWorker.zig").MeshWorker;
const GameState = @import("../../GameState.zig");
const app_config = @import("../../app_config.zig");
const zlm = @import("zlm");
const tracy = @import("../../platform/tracy.zig");
const Io = std.Io;
const Dir = Io.Dir;

const sep = std.fs.path.sep_str;

const enable_validation_layers = @import("builtin").mode == .Debug;
const validation_layers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};

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
    surface: vk.VkSurfaceKHR,
    ctx: VulkanContext,
    surface_state: SurfaceState,
    render_state: RenderState,
    pipeline_cache_path: []const u8,
    mesh_worker: MeshWorker,
    game_state: *GameState,
    framebuffer_resized: bool,

    pub fn init(allocator: std.mem.Allocator, window: *const Window, game_state: *GameState) !*VulkanRenderer {
        const init_zone = tracy.zone(@src(), "VulkanRenderer.init");
        defer init_zone.end();

        const self = try allocator.create(VulkanRenderer);
        errdefer allocator.destroy(self);

        try vk.initialize();

        // Build pipeline cache path
        const app_data_path = try app_config.getAppDataPath(allocator);
        defer allocator.free(app_data_path);
        const pipeline_cache_path = try std.fmt.allocPrint(allocator, "{s}" ++ sep ++ ".pipeline_cache", .{app_data_path});
        errdefer allocator.free(pipeline_cache_path);

        // Read pipeline cache file (synchronous, small file)
        const io = Io.Threaded.global_single_threaded.io();
        const cache_data = Dir.readFileAlloc(.cwd(), io, pipeline_cache_path, allocator, .unlimited) catch null;
        defer if (cache_data) |d| allocator.free(d);

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

        // Create pipeline cache
        const pipeline_cache = try createPipelineCache(device, cache_data);

        const ctx = VulkanContext{
            .device = device,
            .physical_device = device_info.physical_device,
            .graphics_queue = graphics_queue,
            .queue_family_index = device_info.queue_family_index,
            .command_pool = undefined,
            .pipeline_cache = pipeline_cache,
        };

        self.* = .{
            .allocator = allocator,
            .window = window,
            .instance = instance,
            .debug_messenger = debug_messenger,
            .validation_enabled = validation_enabled,
            .surface = surface,
            .ctx = ctx,
            .pipeline_cache_path = pipeline_cache_path,
            .surface_state = undefined,
            .render_state = undefined,
            .mesh_worker = MeshWorker.init(allocator, game_state.world),
            .game_state = game_state,
            .framebuffer_resized = false,
        };

        try self.createCommandPool();
        self.surface_state = try SurfaceState.create(allocator, &self.ctx, self.surface, self.window);
        self.game_state.camera.updateAspect(self.surface_state.swapchain_extent.width, self.surface_state.swapchain_extent.height);
        self.render_state = try RenderState.create(allocator, &self.ctx, self.surface_state.swapchain_format);

        self.mesh_worker.startAll();

        std.log.info("VulkanRenderer initialized", .{});
        return self;
    }

    pub fn deinit(self: *VulkanRenderer) void {
        const tz = tracy.zone(@src(), "VulkanRenderer.deinit");
        defer tz.end();

        vk.deviceWaitIdle(self.ctx.device) catch |err| {
            std.log.err("vkDeviceWaitIdle failed: {}", .{err});
        };

        self.mesh_worker.deinit();
        self.render_state.deinit(self.ctx.device);
        vk.destroyCommandPool(self.ctx.device, self.ctx.command_pool, null);
        self.surface_state.deinit(self.allocator, self.ctx.device);

        self.savePipelineCache();
        vk.destroyPipelineCache(self.ctx.device, self.ctx.pipeline_cache, null);
        self.allocator.free(self.pipeline_cache_path);

        vk.destroySurfaceKHR(self.instance, self.surface, null);
        vk.destroyDevice(self.ctx.device, null);

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

        // Wait for ALL in-flight fences so shared buffers (debug vertices, draw commands)
        // are not read by the GPU while we update them on the CPU.
        try vk.waitForFences(self.ctx.device, MAX_FRAMES_IN_FLIGHT, &self.render_state.in_flight_fences, vk.VK_TRUE, std.math.maxInt(u64));

        if (!self.game_state.debug_camera_active) {
            self.pollMeshWorker();
            self.render_state.world_renderer.buildIndirectCommands(&self.ctx, self.game_state.camera.position);
            self.render_state.debug_renderer.updateVertices(self.ctx.device, self.game_state);

            if (self.game_state.dirty_chunks.count > 0 and self.mesh_worker.state.load(.acquire) == .idle) {
                self.mesh_worker.startDirty(self.game_state.dirty_chunks.chunks[0..self.game_state.dirty_chunks.count]);
                self.game_state.dirty_chunks.clear();
            }
        }
    }

    fn pollMeshWorker(self: *VulkanRenderer) void {
        const poll_result = self.mesh_worker.poll() orelse return;

        for (0..poll_result.count) |i| {
            if (poll_result.results[i]) |chunk_result| {
                self.render_state.world_renderer.uploadChunkData(
                    &self.ctx,
                    chunk_result.coord,
                    chunk_result.faces,
                    chunk_result.face_counts,
                    chunk_result.total_face_count,
                    chunk_result.lights,
                    chunk_result.light_count,
                ) catch |err| {
                    std.log.err("Failed to upload chunk ({},{},{}): {}", .{
                        chunk_result.coord.cx, chunk_result.coord.cy, chunk_result.coord.cz, err,
                    });
                };
                self.mesh_worker.freeResult(i);
            }
        }
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
            self.ctx.device,
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
            try vk.waitForFences(self.ctx.device, 1, fence, vk.VK_TRUE, std.math.maxInt(u64));
        }

        self.surface_state.images_in_flight.items[image_index] = self.render_state.in_flight_fences[self.render_state.current_frame];

        const fence = &[_]vk.VkFence{self.render_state.in_flight_fences[self.render_state.current_frame]};
        try vk.resetFences(self.ctx.device, 1, fence);

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
        try vk.queueSubmit(self.ctx.graphics_queue, 1, submit_infos, self.render_state.in_flight_fences[self.render_state.current_frame]);

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

        const present_result = vk.queuePresentKHRResult(self.ctx.graphics_queue, &present_info) catch |err| {
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
            try vk.waitForFences(self.ctx.device, 1, fence, vk.VK_TRUE, std.math.maxInt(u64));
        }

        // Destroy depth buffer
        vk.destroyImageView(self.ctx.device, self.surface_state.depth_image_view, null);
        vk.destroyImage(self.ctx.device, self.surface_state.depth_image, null);
        vk.freeMemory(self.ctx.device, self.surface_state.depth_image_memory, null);

        // Cleanup old swapchain (image views + swapchain handle)
        self.surface_state.cleanupSwapchain(self.ctx.device);

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

        // Debug line compute dispatch (before render pass)
        self.render_state.debug_renderer.recordCompute(command_buffer);

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

        // Draw world chunks
        self.render_state.world_renderer.record(command_buffer, &mvp.m);

        // Draw debug lines with view-space shrink
        // Compute P * VIEW_SCALE * V so lines are pulled toward camera in view-space.
        const VIEW_SHRINK = 1.0 - (1.0 / 256.0);
        const view_scale = zlm.Mat4{
            .m = .{
                VIEW_SHRINK, 0, 0, 0,
                0, VIEW_SHRINK, 0, 0,
                0, 0, VIEW_SHRINK, 0,
                0, 0, 0, 1,
            },
        };
        const view = self.game_state.camera.getViewMatrix();
        const proj = self.game_state.camera.getProjectionMatrix();
        const debug_mvp = zlm.Mat4.mul(proj, zlm.Mat4.mul(view_scale, view));
        self.render_state.debug_renderer.recordDraw(command_buffer, &debug_mvp.m);

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

    fn createPipelineCache(device: vk.VkDevice, cache_data: ?[]const u8) !vk.VkPipelineCache {
        const create_info = vk.c.VkPipelineCacheCreateInfo{
            .sType = vk.c.VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .initialDataSize = if (cache_data) |d| d.len else 0,
            .pInitialData = if (cache_data) |d| d.ptr else null,
        };

        const cache = try vk.createPipelineCache(device, &create_info, null);

        if (cache_data) |d| {
            std.log.info("Pipeline cache: loaded {} bytes from disk", .{d.len});
        } else {
            std.log.info("Pipeline cache: created empty", .{});
        }

        return cache;
    }

    fn savePipelineCache(self: *VulkanRenderer) void {
        // Query cache data size
        var data_size: usize = 0;
        vk.getPipelineCacheData(self.ctx.device, self.ctx.pipeline_cache, &data_size, null) catch {
            std.log.warn("Pipeline cache: failed to query size", .{});
            return;
        };

        if (data_size == 0) return;

        // Allocate and retrieve cache data
        const data = self.allocator.alloc(u8, data_size) catch {
            std.log.warn("Pipeline cache: failed to allocate {} bytes", .{data_size});
            return;
        };
        defer self.allocator.free(data);

        vk.getPipelineCacheData(self.ctx.device, self.ctx.pipeline_cache, &data_size, data.ptr) catch {
            std.log.warn("Pipeline cache: failed to retrieve data", .{});
            return;
        };

        // Write to disk
        const io = Io.Threaded.global_single_threaded.io();
        Dir.writeFile(.cwd(), io, .{ .sub_path = self.pipeline_cache_path, .data = data[0..data_size] }) catch {
            std.log.warn("Pipeline cache: failed to write to disk", .{});
            return;
        };

        std.log.info("Pipeline cache: saved {} bytes to disk", .{data_size});
    }

    fn createCommandPool(self: *VulkanRenderer) !void {
        const tz = tracy.zone(@src(), "createCommandPool");
        defer tz.end();

        const pool_info = vk.VkCommandPoolCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = self.ctx.queue_family_index,
        };

        self.ctx.command_pool = try vk.createCommandPool(self.ctx.device, &pool_info, null);
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

        var vulkan11_features: vk.c.VkPhysicalDeviceVulkan11Features = std.mem.zeroes(vk.c.VkPhysicalDeviceVulkan11Features);
        vulkan11_features.sType = vk.c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES;
        vulkan11_features.shaderDrawParameters = vk.VK_TRUE;

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

        // Chain: DeviceCreateInfo -> Vulkan13Features -> Vulkan12Features -> Vulkan11Features
        vulkan12_features.pNext = &vulkan11_features;
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
        .get_framebuffer_resized_ptr = getFramebufferResizedPtrVTable,
    };
};
