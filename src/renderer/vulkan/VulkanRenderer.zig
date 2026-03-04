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
const vk_utils = @import("vk_utils.zig");
const TransferPipeline = @import("TransferPipeline.zig").TransferPipeline;
const GpuAllocator = @import("../../allocators/GpuAllocator.zig").GpuAllocator;
const MeshWorker = @import("../../world/MeshWorker.zig").MeshWorker;
const TlsfAllocator = @import("../../allocators/TlsfAllocator.zig").TlsfAllocator;
const GameState = @import("../../GameState.zig");
const UiManager = @import("../../ui/UiManager.zig").UiManager;
const app_config = @import("../../app_config.zig");
const zlm = @import("zlm");
const tracy = @import("../../platform/tracy.zig");
const Io = std.Io;
const Dir = Io.Dir;

const sep = std.fs.path.sep_str;

const enable_validation_layers = @import("builtin").mode == .Debug;
const validation_layers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};

const vk_log = std.log.scoped(.Vulkan);

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
        vk_log.err("{s}", .{message});
    } else if (message_severity >= vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) {
        vk_log.warn("{s}", .{message});
    } else if (message_severity >= vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT) {
        vk_log.info("{s}", .{message});
    } else {
        vk_log.debug("{s}", .{message});
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
    gpu_allocator: *GpuAllocator,
    surface_state: SurfaceState,
    render_state: RenderState,
    pipeline_cache_path: []const u8,
    initial_cache_hash: u64,
    transfer_pipeline: TransferPipeline,
    mesh_worker: ?*MeshWorker,
    game_state: ?*GameState,
    ui_manager: ?*UiManager,
    framebuffer_resized: bool,

    // Deferred TLSF frees (per frame slot)
    deferred_face_frees: [MAX_FRAMES_IN_FLIGHT][2048]TlsfAllocator.Handle,
    deferred_face_free_counts: [MAX_FRAMES_IN_FLIGHT]u32,
    deferred_light_frees: [MAX_FRAMES_IN_FLIGHT][2048]TlsfAllocator.Handle,
    deferred_light_free_counts: [MAX_FRAMES_IN_FLIGHT]u32,
    max_graphics_wait_timeline: u64,

    pub fn init(allocator: std.mem.Allocator, window: *const Window, game_state: ?*GameState) !*VulkanRenderer {
        const init_zone = tracy.zone(@src(), "VulkanRenderer.init");
        defer init_zone.end();

        const self = try allocator.create(VulkanRenderer);
        errdefer allocator.destroy(self);

        try vk.initialize();

        const app_data_path = try app_config.getAppDataPath(allocator);
        defer allocator.free(app_data_path);
        const pipeline_cache_path = try std.fmt.allocPrint(allocator, "{s}" ++ sep ++ ".pipeline_cache", .{app_data_path});
        errdefer allocator.free(pipeline_cache_path);

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
        const device = try createDevice(device_info);
        errdefer vk.destroyDevice(device, null);

        vk.loadDevice(device);

        var graphics_queue: vk.VkQueue = undefined;
        vk.getDeviceQueue(device, device_info.queue_family_index, 0, &graphics_queue);

        var transfer_queue: vk.VkQueue = undefined;
        vk.getDeviceQueue(device, device_info.transfer_queue_family, device_info.transfer_queue_index, &transfer_queue);

        const pipeline_cache = try createPipelineCache(device, cache_data);

        const ctx = VulkanContext{
            .device = device,
            .physical_device = device_info.physical_device,
            .graphics_queue = graphics_queue,
            .queue_family_index = device_info.queue_family_index,
            .command_pool = undefined,
            .pipeline_cache = pipeline_cache,
            .transfer_queue = transfer_queue,
            .transfer_queue_family = device_info.transfer_queue_family,
            .separate_transfer_family = device_info.separate_transfer_family,
        };

        self.* = .{
            .allocator = allocator,
            .window = window,
            .instance = instance,
            .debug_messenger = debug_messenger,
            .validation_enabled = validation_enabled,
            .surface = surface,
            .ctx = ctx,
            .gpu_allocator = undefined,
            .pipeline_cache_path = pipeline_cache_path,
            .initial_cache_hash = hashCacheData(pipeline_cache_path, cache_data),
            .surface_state = undefined,
            .render_state = undefined,
            .transfer_pipeline = undefined,
            .mesh_worker = null,
            .game_state = game_state,
            .ui_manager = null,
            .framebuffer_resized = false,
            .deferred_face_frees = undefined,
            .deferred_face_free_counts = .{0} ** MAX_FRAMES_IN_FLIGHT,
            .deferred_light_frees = undefined,
            .deferred_light_free_counts = .{0} ** MAX_FRAMES_IN_FLIGHT,
            .max_graphics_wait_timeline = 0,
        };

        try self.createCommandPool();
        self.gpu_allocator = try GpuAllocator.init(allocator, &self.ctx);
        self.transfer_pipeline = try TransferPipeline.init(&self.ctx);
        self.surface_state = try SurfaceState.create(allocator, &self.ctx, self.surface, self.window);
        try self.render_state.initInPlace(allocator, &self.ctx, self.surface_state.swapchain_format, self.gpu_allocator);
        const actual_w = self.surface_state.swapchain_extent.width;
        const actual_h = self.surface_state.swapchain_extent.height;
        const ui_scale = @max(1.0, @as(f32, @floatFromInt(actual_h)) / 720.0);
        const virtual_w: u32 = @intFromFloat(@as(f32, @floatFromInt(actual_w)) / ui_scale);
        const virtual_h: u32 = @intFromFloat(@as(f32, @floatFromInt(actual_h)) / ui_scale);
        self.render_state.text_renderer.updateScreenSize(virtual_w, virtual_h, ui_scale);
        self.render_state.ui_renderer.updateScreenSize(virtual_w, virtual_h, ui_scale);

        self.render_state.ui_renderer.loadHudAtlas(allocator, &self.ctx) catch |err| {
            std.log.warn("Failed to load HUD atlas: {}, HUD sprites disabled", .{err});
        };

        if (game_state) |gs| {
            gs.camera.updateAspect(self.surface_state.swapchain_extent.width, self.surface_state.swapchain_extent.height);
            self.startWorkerPipeline(gs);
        }

        std.log.info("VulkanRenderer initialized", .{});
        return self;
    }

    pub fn deinit(self: *VulkanRenderer) void {
        const tz = tracy.zone(@src(), "VulkanRenderer.deinit");
        defer tz.end();

        vk.deviceWaitIdle(self.ctx.device) catch |err| {
            std.log.err("vkDeviceWaitIdle failed: {}", .{err});
        };

        self.stopWorkerPipeline();
        self.transfer_pipeline.deinit();

        self.render_state.deinit(self.ctx.device);
        self.gpu_allocator.deinit();
        vk.destroyCommandPool(self.ctx.device, self.ctx.command_pool, null);
        self.surface_state.deinit(self.allocator, self.ctx.device);

        self.savePipelineCache();
        vk.destroyPipelineCache(self.ctx.device, self.ctx.pipeline_cache, null);
        self.allocator.free(self.pipeline_cache_path);

        vk.destroyDevice(self.ctx.device, null);
        vk.destroySurfaceKHR(self.instance, self.surface, null);

        if (self.debug_messenger) |messenger| {
            vk.destroyDebugUtilsMessengerEXT(self.instance, messenger, null);
        }

        vk.destroyInstance(self.instance, null);
        std.log.info("VulkanRenderer destroyed", .{});
        self.allocator.destroy(self);
    }

    pub fn setGameState(self: *VulkanRenderer, gs: ?*GameState) void {
        self.stopWorkerPipeline();
        self.game_state = gs;

        if (gs) |game_state| {
            game_state.camera.updateAspect(self.surface_state.swapchain_extent.width, self.surface_state.swapchain_extent.height);
            self.startWorkerPipeline(game_state);
        }
    }

    fn startWorkerPipeline(self: *VulkanRenderer, gs: *GameState) void {
        const wr = &self.render_state.world_renderer;

        // 1. Create + init MeshWorker
        const mw = self.allocator.create(MeshWorker) catch |err| {
            std.log.err("Failed to allocate MeshWorker: {}", .{err});
            return;
        };

        mw.initInPlace(self.allocator, &gs.chunk_map);

        self.mesh_worker = mw;

        // 3. Init + start ChunkStreamer
        gs.streamer.initInPlace(self.allocator, gs.storage, &gs.chunk_pool, gs.world_seed);

        // Sync player position before starting threads so initial heap ordering is correct
        gs.streamer.syncPlayerChunk(gs.player_chunk);
        mw.syncChunkMap(&gs.chunk_map, gs.player_chunk);

        gs.streamer.start();

        // 4. Setup + start TransferPipeline thread
        self.transfer_pipeline.setupThread(
            mw,
            &wr.face_tlsf,
            &wr.light_tlsf,
            wr.face_alloc.buffer,
            wr.light_alloc.buffer,
        );

        // 5. Set pipeline references for stats reporting
        gs.mesh_worker = mw;
        gs.transfer_pipeline = &self.transfer_pipeline;

        // 6. Start threads (mesh first so transfer can consume)
        mw.start();
        self.transfer_pipeline.start();

        // 6. Request initial load batch if async loading
        if (!gs.initial_load_ready) {
            const WorldState = @import("../../world/WorldState.zig");
            const rd: i32 = 3; // spawn radius for initial load
            const rd_sq = rd * rd;
            const pc = gs.player_chunk;
            var batch: [512]WorldState.ChunkKey = undefined;
            var batch_len: u32 = 0;

            var dy: i32 = -rd;
            while (dy <= rd) : (dy += 1) {
                var dz: i32 = -rd;
                while (dz <= rd) : (dz += 1) {
                    var dx: i32 = -rd;
                    while (dx <= rd) : (dx += 1) {
                        if (dx * dx + dy * dy + dz * dz > rd_sq) continue;
                        const key = WorldState.ChunkKey{
                            .cx = pc.cx + dx,
                            .cy = pc.cy + dy,
                            .cz = pc.cz + dz,
                        };
                        if (batch_len < batch.len) {
                            batch[batch_len] = key;
                            batch_len += 1;
                        }
                    }
                }
            }

            if (batch_len > 0) {
                gs.streamer.requestLoadBatch(batch[0..batch_len]);
            }
        }
    }

    fn stopWorkerPipeline(self: *VulkanRenderer) void {
        // Stop streamer first (produces chunks for main thread)
        if (self.game_state) |gs| {
            gs.streamer.stop();
            gs.mesh_worker = null;
            gs.transfer_pipeline = null;
        }

        // Stop threads in dependency order: transfer (consumes mesh) → mesh (produces)
        self.transfer_pipeline.stop();
        if (self.mesh_worker) |mw| {
            mw.stop();
        }

        // Wait for all in-flight GPU transfers before freeing TLSF handles
        self.transfer_pipeline.waitAllPending();

        // Drain committed queue — free TLSF handles for chunks that were never applied
        self.drainAndFreeCommitted();

        // Flush deferred frees for all frame slots
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            self.processDeferredFrees(@intCast(i));
        }

        // Release all GPU mesh slots so old world geometry doesn't persist
        self.render_state.world_renderer.clearAllSlots();

        // Clear references and destroy
        self.transfer_pipeline.mesh_worker = null;
        if (self.mesh_worker) |mw| {
            self.allocator.destroy(mw);
            self.mesh_worker = null;
        }
    }

    pub fn beginFrame(self: *VulkanRenderer) !void {
        const tz = tracy.zone(@src(), "beginFrame");
        defer tz.end();

        const cf = self.render_state.current_frame;

        // 1. Wait this frame's fence only
        const fence = [_]vk.VkFence{self.render_state.in_flight_fences[cf]};
        try vk.waitForFences(self.ctx.device, 1, &fence, vk.VK_TRUE, std.math.maxInt(u64));

        if (self.game_state) |gs| {
            if (!gs.debug_camera_active) {
                // Always: deferred TLSF frees (usually empty between ticks)
                self.processDeferredFrees(cf);

                // Player fast path: feed player-caused dirty chunks EVERY frame
                // (bypass tick gate for instant responsiveness)
                if (self.mesh_worker) |mw| {
                    if (gs.player_dirty_chunks.count > 0) {
                        mw.enqueueBatch(gs.player_dirty_chunks.keys[0..gs.player_dirty_chunks.count]);
                        gs.player_dirty_chunks.clear();
                    }
                }

                // Tick-gated: only when 30 Hz tick fired since last frame
                if (gs.world_tick_pending) {
                    gs.world_tick_pending = false;

                    self.drainCommittedChunks(cf);

                    gs.applyUnloadsToGpu(
                        &self.render_state.world_renderer,
                        &self.deferred_face_frees[cf],
                        &self.deferred_face_free_counts[cf],
                        &self.deferred_light_frees[cf],
                        &self.deferred_light_free_counts[cf],
                    );

                    if (self.mesh_worker) |mw| {
                        mw.syncChunkMap(&gs.chunk_map, gs.player_chunk);
                        if (gs.dirty_chunks.count > 0) {
                            mw.enqueueBatch(gs.dirty_chunks.keys[0..gs.dirty_chunks.count]);
                            gs.dirty_chunks.clear();
                        }
                    }
                }

                // Always: rebuild draw commands for this frame
                self.render_state.world_renderer.buildIndirectCommands(&self.ctx, gs.camera.position);
                self.render_state.debug_renderer.updateVertices(self.ctx.device, gs);
            }
        }

        self.render_state.ui_renderer.beginFrame(self.ctx.device);

        self.render_state.text_renderer.beginFrame(self.ctx.device);

        if (self.game_state) |gs| {
            const DebugOverlay = @import("../../DebugOverlay.zig");
            DebugOverlay.draw(&self.render_state.text_renderer, gs, &self.render_state.world_renderer, self.gpu_allocator);
        }

        if (self.ui_manager) |um| {
            um.layout(&self.render_state.text_renderer);
            um.draw(&self.render_state.ui_renderer, &self.render_state.text_renderer);
        }
    }

    fn drainCommittedChunks(self: *VulkanRenderer, cf: u32) void {
        const CommittedChunk = @import("TransferPipeline.zig").CommittedChunk;
        var buf: [1024]CommittedChunk = undefined;
        const count = self.transfer_pipeline.drainCommitted(&buf);

        const wr = &self.render_state.world_renderer;

        for (buf[0..count]) |entry| {
            // Resolve ChunkKey → GPU slot (allocate if new)
            const slot: u16 = wr.getOrAllocateSlot(entry.key) orelse {
                // No slot available — free TLSF allocs to prevent leak
                const io_val = Io.Threaded.global_single_threaded.io();
                self.transfer_pipeline.tlsf_mutex.lockUncancelable(io_val);
                if (entry.face_alloc) |fa| {
                    if (fa.handle != TlsfAllocator.null_handle) wr.face_tlsf.free(fa.handle);
                }
                if (entry.light_alloc) |la| {
                    if (la.handle != TlsfAllocator.null_handle) wr.light_tlsf.free(la.handle);
                }
                self.transfer_pipeline.tlsf_mutex.unlock(io_val);
                self.max_graphics_wait_timeline = @max(self.max_graphics_wait_timeline, entry.timeline_value);
                // Re-dirty so the chunk gets retried when slots free up
                if (self.game_state) |gs| gs.dirty_chunks.add(entry.key);
                continue;
            };

            if (entry.light_only) {
                // Light-only: only update light_start, keep existing face data
                // Safety check: face_counts total must match existing geometry
                var new_total: u32 = 0;
                for (entry.chunk_data.face_counts) |fc| new_total += fc;
                var existing_total: u32 = 0;
                for (wr.chunk_data[slot].face_counts) |fc| existing_total += fc;

                if (new_total != existing_total) {
                    // Geometry changed since light gen — discard stale light-only update
                    if (entry.light_alloc) |la| {
                        if (la.handle != TlsfAllocator.null_handle) {
                            const idx = self.deferred_light_free_counts[cf];
                            if (idx < 2048) {
                                self.deferred_light_frees[cf][idx] = la.handle;
                                self.deferred_light_free_counts[cf] = idx + 1;
                            }
                        }
                    }
                    self.max_graphics_wait_timeline = @max(self.max_graphics_wait_timeline, entry.timeline_value);
                    continue;
                }

                // Defer-free old light alloc only (NOT face_alloc)
                if (wr.chunk_light_alloc[slot]) |la| {
                    if (la.handle != TlsfAllocator.null_handle) {
                        const idx = self.deferred_light_free_counts[cf];
                        if (idx < 2048) {
                            self.deferred_light_frees[cf][idx] = la.handle;
                            self.deferred_light_free_counts[cf] = idx + 1;
                        }
                    }
                }

                // Update light_start only, keep face_start/face_counts/face_alloc unchanged
                if (entry.light_alloc) |la| {
                    wr.chunk_data[slot].light_start = la.offset;
                }
                wr.chunk_light_alloc[slot] = entry.light_alloc;
                wr.writeChunkData(slot);
            } else {
                // Full remesh: replace everything
                // Defer OLD alloc handles for this frame slot
                if (wr.chunk_face_alloc[slot]) |fa| {
                    if (fa.handle != TlsfAllocator.null_handle) {
                        const idx = self.deferred_face_free_counts[cf];
                        if (idx < 2048) {
                            self.deferred_face_frees[cf][idx] = fa.handle;
                            self.deferred_face_free_counts[cf] = idx + 1;
                        }
                    }
                }
                if (wr.chunk_light_alloc[slot]) |la| {
                    if (la.handle != TlsfAllocator.null_handle) {
                        const idx = self.deferred_light_free_counts[cf];
                        if (idx < 2048) {
                            self.deferred_light_frees[cf][idx] = la.handle;
                            self.deferred_light_free_counts[cf] = idx + 1;
                        }
                    }
                }

                // Apply NEW data
                wr.chunk_data[slot] = entry.chunk_data;
                wr.chunk_face_alloc[slot] = entry.face_alloc;
                wr.chunk_light_alloc[slot] = entry.light_alloc;
                wr.writeChunkData(slot);
            }

            // Track max timeline for graphics wait
            self.max_graphics_wait_timeline = @max(self.max_graphics_wait_timeline, entry.timeline_value);
        }
    }

    fn drainAndFreeCommitted(self: *VulkanRenderer) void {
        const CommittedChunk = @import("TransferPipeline.zig").CommittedChunk;
        var buf: [1024]CommittedChunk = undefined;
        const count = self.transfer_pipeline.drainCommitted(&buf);
        if (count == 0) return;

        const wr = &self.render_state.world_renderer;
        const io_val = Io.Threaded.global_single_threaded.io();
        self.transfer_pipeline.tlsf_mutex.lockUncancelable(io_val);
        for (buf[0..count]) |entry| {
            if (entry.face_alloc) |fa| {
                if (fa.handle != TlsfAllocator.null_handle) {
                    wr.face_tlsf.free(fa.handle);
                }
            }
            if (entry.light_alloc) |la| {
                if (la.handle != TlsfAllocator.null_handle) {
                    wr.light_tlsf.free(la.handle);
                }
            }
        }
        self.transfer_pipeline.tlsf_mutex.unlock(io_val);
    }

    fn processDeferredFrees(self: *VulkanRenderer, cf: u32) void {
        const io_val = Io.Threaded.global_single_threaded.io();
        const wr = &self.render_state.world_renderer;

        self.transfer_pipeline.tlsf_mutex.lockUncancelable(io_val);

        const face_count = self.deferred_face_free_counts[cf];
        for (self.deferred_face_frees[cf][0..face_count]) |handle| {
            if (handle != TlsfAllocator.null_handle) {
                wr.face_tlsf.free(handle);
            }
        }
        self.deferred_face_free_counts[cf] = 0;

        const light_count = self.deferred_light_free_counts[cf];
        for (self.deferred_light_frees[cf][0..light_count]) |handle| {
            if (handle != TlsfAllocator.null_handle) {
                wr.light_tlsf.free(handle);
            }
        }
        self.deferred_light_free_counts[cf] = 0;

        self.transfer_pipeline.tlsf_mutex.unlock(io_val);
    }

    pub fn endFrame(self: *VulkanRenderer) !void {
        const tz = tracy.zone(@src(), "endFrame");
        defer tz.end();

        self.render_state.ui_renderer.endFrame(self.ctx.device);
        self.render_state.text_renderer.endFrame(self.ctx.device);
        self.render_state.current_frame = (self.render_state.current_frame + 1) % MAX_FRAMES_IN_FLIGHT;
    }

    pub fn render(self: *VulkanRenderer) !void {
        const tz = tracy.zone(@src(), "render");
        defer tz.end();

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

        const wait_semaphores = [_]vk.VkSemaphore{
            self.render_state.image_available_semaphores[self.render_state.current_frame],
            self.transfer_pipeline.timeline_semaphore,
        };
        const wait_stages = [_]c_uint{
            vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            vk.VK_PIPELINE_STAGE_VERTEX_INPUT_BIT,
        };
        const signal_semaphores = [_]vk.VkSemaphore{self.surface_state.render_finished_semaphores.items[image_index]};

        // Timeline semaphore submit info: 0 for binary semaphores (ignored by driver)
        const wait_values = [_]u64{ 0, self.max_graphics_wait_timeline };
        const signal_values = [_]u64{0};
        const timeline_info = vk.VkTimelineSemaphoreSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreValueCount = 2,
            .pWaitSemaphoreValues = &wait_values,
            .signalSemaphoreValueCount = 1,
            .pSignalSemaphoreValues = &signal_values,
        };

        const submit_info = vk.VkSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = &timeline_info,
            .waitSemaphoreCount = 2,
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

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            const fence = &[_]vk.VkFence{self.render_state.in_flight_fences[i]};
            try vk.waitForFences(self.ctx.device, 1, fence, vk.VK_TRUE, std.math.maxInt(u64));
        }

        // Also wait for pending transfers
        if (self.transfer_pipeline.timeline_value > 0) {
            const sems = [_]vk.VkSemaphore{self.transfer_pipeline.timeline_semaphore};
            const vals = [_]u64{self.transfer_pipeline.timeline_value};
            const wait_info = vk.VkSemaphoreWaitInfo{
                .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO,
                .pNext = null,
                .flags = 0,
                .semaphoreCount = 1,
                .pSemaphores = &sems,
                .pValues = &vals,
            };
            try vk.waitSemaphores(self.ctx.device, &wait_info, std.math.maxInt(u64));
        }

        vk.destroyImageView(self.ctx.device, self.surface_state.depth_image_view, null);
        vk.destroyImage(self.ctx.device, self.surface_state.depth_image, null);
        vk.freeMemory(self.ctx.device, self.surface_state.depth_image_memory, null);

        self.surface_state.cleanupSwapchain(self.ctx.device);

        try self.surface_state.createSwapchain(self.allocator, &self.ctx, self.surface, self.window);

        try self.surface_state.createDepthBuffer(&self.ctx);

        if (self.game_state) |gs| {
            gs.camera.updateAspect(self.surface_state.swapchain_extent.width, self.surface_state.swapchain_extent.height);
        }

        const actual_w = self.surface_state.swapchain_extent.width;
        const actual_h = self.surface_state.swapchain_extent.height;
        const ui_scale = @max(1.0, @as(f32, @floatFromInt(actual_h)) / 720.0);
        const virtual_w: u32 = @intFromFloat(@as(f32, @floatFromInt(actual_w)) / ui_scale);
        const virtual_h: u32 = @intFromFloat(@as(f32, @floatFromInt(actual_h)) / ui_scale);
        self.render_state.text_renderer.updateScreenSize(virtual_w, virtual_h, ui_scale);
        self.render_state.ui_renderer.updateScreenSize(virtual_w, virtual_h, ui_scale);

        if (self.ui_manager) |um| {
            um.updateScreenSize(virtual_w, virtual_h);
            um.ui_scale = ui_scale;
        }

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

        const has_game = self.game_state != null;
        const overdraw = if (self.game_state) |gs| gs.overdraw_mode else false;

        if (has_game and !overdraw) self.render_state.debug_renderer.recordCompute(command_buffer);

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

        const clear_color: [4]f32 = if (!has_game)
            .{ 0.05, 0.05, 0.1, 1.0 }
        else if (overdraw)
            .{ 0.0, 0.0, 0.0, 1.0 }
        else
            .{ 0.224, 0.643, 0.918, 1.0 };

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
            .clearValue = .{ .color = .{ .float32 = clear_color } },
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

        if (self.game_state) |gs| {
            const mvp = gs.camera.getViewProjectionMatrix();

            self.render_state.world_renderer.record(command_buffer, &mvp.m, overdraw);

            if (!overdraw) {
                const VIEW_SHRINK = 1.0 - (1.0 / 256.0);
                const view_scale = zlm.Mat4{
                    .m = .{
                        VIEW_SHRINK, 0, 0, 0,
                        0, VIEW_SHRINK, 0, 0,
                        0, 0, VIEW_SHRINK, 0,
                        0, 0, 0, 1,
                    },
                };
                const view = gs.camera.getViewMatrix();
                const proj = gs.camera.getProjectionMatrix();
                const debug_mvp = zlm.Mat4.mul(proj, zlm.Mat4.mul(view_scale, view));
                self.render_state.debug_renderer.recordDraw(command_buffer, &debug_mvp.m);
            }
        }

        self.render_state.ui_renderer.recordDraw(command_buffer);

        self.render_state.text_renderer.recordDraw(command_buffer);

        vk.cmdEndRendering(command_buffer);

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

    fn hashCacheData(path: []const u8, data: ?[]const u8) u64 {
        var h = std.hash.XxHash3.init(0);
        h.update(path);
        if (data) |d| h.update(d);
        return h.final();
    }

    fn savePipelineCache(self: *VulkanRenderer) void {
        var data_size: usize = 0;
        vk.getPipelineCacheData(self.ctx.device, self.ctx.pipeline_cache, &data_size, null) catch {
            std.log.warn("Pipeline cache: failed to query size", .{});
            return;
        };

        if (data_size == 0) return;

        const data = self.allocator.alloc(u8, data_size) catch {
            std.log.warn("Pipeline cache: failed to allocate {} bytes", .{data_size});
            return;
        };
        defer self.allocator.free(data);

        vk.getPipelineCacheData(self.ctx.device, self.ctx.pipeline_cache, &data_size, data.ptr) catch {
            std.log.warn("Pipeline cache: failed to retrieve data", .{});
            return;
        };

        const current_hash = hashCacheData(self.pipeline_cache_path, data[0..data_size]);
        if (current_hash == self.initial_cache_hash) {
            std.log.info("Pipeline cache: unchanged, skipping save", .{});
            return;
        }

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

        if (enable_validation_layers) {
            if (vk.createInstance(&create_info, null)) |instance| {
                return .{ .instance = instance, .validation_enabled = true };
            } else |err| {
                if (err == error.LayerNotPresent) {
                    std.log.warn("Validation layers requested but not available, continuing without them", .{});
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
        transfer_queue_family: u32,
        transfer_queue_index: u32,
        separate_transfer_family: bool,
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

            if (try findQueueFamilies(allocator, device, surface)) |info| {
                return info;
            }
        }

        return error.NoSuitableDevice;
    }

    fn findQueueFamilies(allocator: std.mem.Allocator, device: vk.VkPhysicalDevice, surface: vk.VkSurfaceKHR) !?DeviceInfo {
        const tz = tracy.zone(@src(), "findQueueFamilies");
        defer tz.end();

        var queue_family_count: u32 = 0;
        try vk.getPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, null);

        var queue_families = try allocator.alloc(vk.VkQueueFamilyProperties, queue_family_count);
        defer allocator.free(queue_families);

        try vk.getPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, queue_families.ptr);

        // Find graphics+present family
        var graphics_family: ?u32 = null;
        for (queue_families[0..queue_family_count], 0..) |family, i| {
            const idx: u32 = @intCast(i);
            const supports_graphics = (family.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT) != 0;

            var present_support: vk.VkBool32 = vk.VK_FALSE;
            try vk.getPhysicalDeviceSurfaceSupportKHR(device, idx, surface, &present_support);

            if (supports_graphics and present_support == vk.VK_TRUE) {
                graphics_family = idx;
                break;
            }
        }

        const gf = graphics_family orelse return null;

        // Search for dedicated transfer family (TRANSFER but NOT GRAPHICS — DMA engine)
        for (queue_families[0..queue_family_count], 0..) |family, i| {
            const idx: u32 = @intCast(i);
            const has_transfer = (family.queueFlags & vk.VK_QUEUE_TRANSFER_BIT) != 0;
            const has_graphics = (family.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT) != 0;
            if (has_transfer and !has_graphics) {
                std.log.info("Using dedicated transfer queue family {}", .{idx});
                return .{
                    .physical_device = device,
                    .queue_family_index = gf,
                    .transfer_queue_family = idx,
                    .transfer_queue_index = 0,
                    .separate_transfer_family = true,
                };
            }
        }

        // Fallback: same family, second queue if available
        if (queue_families[gf].queueCount >= 2) {
            std.log.info("Using second queue in graphics family {} for transfers", .{gf});
            return .{
                .physical_device = device,
                .queue_family_index = gf,
                .transfer_queue_family = gf,
                .transfer_queue_index = 1,
                .separate_transfer_family = false,
            };
        }

        // Last resort: same queue
        std.log.info("Using same queue for graphics and transfers (family {})", .{gf});
        return .{
            .physical_device = device,
            .queue_family_index = gf,
            .transfer_queue_family = gf,
            .transfer_queue_index = 0,
            .separate_transfer_family = false,
        };
    }

    fn createDevice(device_info: DeviceInfo) !vk.VkDevice {
        const tz = tracy.zone(@src(), "createDevice");
        defer tz.end();

        // Build queue create infos
        var queue_create_infos: [2]vk.VkDeviceQueueCreateInfo = undefined;
        var queue_create_info_count: u32 = 1;

        if (device_info.separate_transfer_family) {
            // Two separate families: graphics and transfer
            const gfx_priority = [_]f32{1.0};
            queue_create_infos[0] = .{
                .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .queueFamilyIndex = device_info.queue_family_index,
                .queueCount = 1,
                .pQueuePriorities = &gfx_priority,
            };
            const xfer_priority = [_]f32{0.5};
            queue_create_infos[1] = .{
                .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .queueFamilyIndex = device_info.transfer_queue_family,
                .queueCount = 1,
                .pQueuePriorities = &xfer_priority,
            };
            queue_create_info_count = 2;
        } else if (device_info.transfer_queue_index == 1) {
            // Same family, two queues
            const priorities = [_]f32{ 1.0, 0.5 };
            queue_create_infos[0] = .{
                .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .queueFamilyIndex = device_info.queue_family_index,
                .queueCount = 2,
                .pQueuePriorities = &priorities,
            };
        } else {
            // Same family, same queue
            const priority = [_]f32{1.0};
            queue_create_infos[0] = .{
                .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .queueFamilyIndex = device_info.queue_family_index,
                .queueCount = 1,
                .pQueuePriorities = &priority,
            };
        }

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
        vulkan12_features.timelineSemaphore = vk.VK_TRUE;

        var vulkan13_features: vk.VkPhysicalDeviceVulkan13Features = std.mem.zeroes(vk.VkPhysicalDeviceVulkan13Features);
        vulkan13_features.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES;
        vulkan13_features.dynamicRendering = vk.VK_TRUE;
        vulkan13_features.synchronization2 = vk.VK_TRUE;

        vulkan12_features.pNext = &vulkan11_features;
        vulkan13_features.pNext = &vulkan12_features;

        const create_info = vk.VkDeviceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = &vulkan13_features,
            .flags = 0,
            .queueCreateInfoCount = queue_create_info_count,
            .pQueueCreateInfos = &queue_create_infos,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = device_extensions.len,
            .ppEnabledExtensionNames = &device_extensions,
            .pEnabledFeatures = null,
        };

        return try vk.createDevice(device_info.physical_device, &create_info, null);
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
        _ = user_data;
        const self = try init(allocator, window, null);
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

    fn setGameStateVTable(ptr: *anyopaque, game_state_ptr: ?*anyopaque) void {
        const self: *VulkanRenderer = @ptrCast(@alignCast(ptr));
        const gs: ?*GameState = if (game_state_ptr) |p| @ptrCast(@alignCast(p)) else null;
        self.setGameState(gs);
    }

    fn setUiManagerVTable(ptr: *anyopaque, ui_manager_ptr: ?*anyopaque) void {
        const self: *VulkanRenderer = @ptrCast(@alignCast(ptr));
        self.ui_manager = if (ui_manager_ptr) |p| @ptrCast(@alignCast(p)) else null;
        if (self.ui_manager) |um| {
            const actual_w = self.surface_state.swapchain_extent.width;
            const actual_h = self.surface_state.swapchain_extent.height;
            const ui_scale = @max(1.0, @as(f32, @floatFromInt(actual_h)) / 720.0);
            const virtual_w: u32 = @intFromFloat(@as(f32, @floatFromInt(actual_w)) / ui_scale);
            const virtual_h: u32 = @intFromFloat(@as(f32, @floatFromInt(actual_h)) / ui_scale);
            um.updateScreenSize(virtual_w, virtual_h);
            um.ui_scale = ui_scale;
        }
    }

    pub const vtable: Renderer.VTable = .{
        .init = initVTable,
        .deinit = deinitVTable,
        .begin_frame = beginFrameVTable,
        .end_frame = endFrameVTable,
        .render = renderVTable,
        .get_framebuffer_resized_ptr = getFramebufferResizedPtrVTable,
        .set_game_state = setGameStateVTable,
        .set_ui_manager = setUiManagerVTable,
    };
};
