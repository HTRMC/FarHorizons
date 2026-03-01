const std = @import("std");
const vk = @import("../../platform/volk.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const vk_utils = @import("vk_utils.zig");
const types = @import("types.zig");
const ChunkData = types.ChunkData;
const TlsfAllocator = @import("../../allocators/TlsfAllocator.zig").TlsfAllocator;
const WorldState = @import("../../world/WorldState.zig");
const render_state_mod = @import("RenderState.zig");
const MAX_FRAMES_IN_FLIGHT = render_state_mod.MAX_FRAMES_IN_FLIGHT;
const tracy = @import("../../platform/tracy.zig");

const RING_BUFFER_SIZE: vk.VkDeviceSize = 8 * 1024 * 1024; // 8MB per slot
const MAX_PENDING = 64;

pub const StagingAlloc = struct {
    buffer: vk.VkBuffer,
    offset: vk.VkDeviceSize,
    mapped_ptr: [*]u8,
};

pub const PendingChunk = struct {
    slot: u16,
    chunk_data: ChunkData,
    face_alloc: ?TlsfAllocator.Allocation,
    light_alloc: ?TlsfAllocator.Allocation,
};

const DeferredFree = struct {
    handle: TlsfAllocator.Handle,
};

const RingBuffer = struct {
    buffer: vk.VkBuffer,
    memory: vk.VkDeviceMemory,
    mapped_ptr: [*]u8,
    head: vk.VkDeviceSize,
};

pub const TransferPipeline = struct {
    device: vk.VkDevice,
    transfer_queue: vk.VkQueue,
    separate_transfer_family: bool,
    graphics_queue_family: u32,
    transfer_queue_family: u32,

    ring_buffers: [MAX_FRAMES_IN_FLIGHT]RingBuffer,
    command_pools: [MAX_FRAMES_IN_FLIGHT]vk.VkCommandPool,
    command_buffers: [MAX_FRAMES_IN_FLIGHT]vk.VkCommandBuffer,

    timeline_semaphore: vk.VkSemaphore,
    timeline_value: u64,
    frame_timeline_values: [MAX_FRAMES_IN_FLIGHT]u64,

    pending_chunks: [MAX_PENDING]PendingChunk,
    pending_count: u32,

    completed_chunks: [MAX_FRAMES_IN_FLIGHT][MAX_PENDING]PendingChunk,
    completed_counts: [MAX_FRAMES_IN_FLIGHT]u32,

    deferred_face_frees: [MAX_FRAMES_IN_FLIGHT][MAX_PENDING]DeferredFree,
    deferred_face_free_counts: [MAX_FRAMES_IN_FLIGHT]u32,
    deferred_light_frees: [MAX_FRAMES_IN_FLIGHT][MAX_PENDING]DeferredFree,
    deferred_light_free_counts: [MAX_FRAMES_IN_FLIGHT]u32,

    has_commands: [MAX_FRAMES_IN_FLIGHT]bool,

    pub fn init(ctx: *const VulkanContext) !TransferPipeline {
        const tz = tracy.zone(@src(), "TransferPipeline.init");
        defer tz.end();

        var self: TransferPipeline = undefined;
        self.device = ctx.device;
        self.transfer_queue = ctx.transfer_queue;
        self.separate_transfer_family = ctx.separate_transfer_family;
        self.graphics_queue_family = ctx.queue_family_index;
        self.transfer_queue_family = ctx.transfer_queue_family;
        self.timeline_value = 0;
        self.pending_count = 0;
        self.completed_counts = .{0} ** MAX_FRAMES_IN_FLIGHT;
        self.deferred_face_free_counts = .{0} ** MAX_FRAMES_IN_FLIGHT;
        self.deferred_light_free_counts = .{0} ** MAX_FRAMES_IN_FLIGHT;
        self.has_commands = .{false} ** MAX_FRAMES_IN_FLIGHT;

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            self.frame_timeline_values[i] = 0;
        }

        // Create ring buffers
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            var buffer: vk.VkBuffer = undefined;
            var memory: vk.VkDeviceMemory = undefined;
            try vk_utils.createBuffer(
                ctx,
                RING_BUFFER_SIZE,
                vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                &buffer,
                &memory,
            );
            errdefer {
                vk.destroyBuffer(ctx.device, buffer, null);
                vk.freeMemory(ctx.device, memory, null);
            }

            var data: ?*anyopaque = null;
            try vk.mapMemory(ctx.device, memory, 0, RING_BUFFER_SIZE, 0, &data);

            self.ring_buffers[i] = .{
                .buffer = buffer,
                .memory = memory,
                .mapped_ptr = @ptrCast(data.?),
                .head = 0,
            };
        }

        // Create timeline semaphore
        var type_info = vk.VkSemaphoreTypeCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO,
            .pNext = null,
            .semaphoreType = vk.VK_SEMAPHORE_TYPE_TIMELINE,
            .initialValue = 0,
        };
        const sem_info = vk.VkSemaphoreCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = &type_info,
            .flags = 0,
        };
        self.timeline_semaphore = try vk.createSemaphore(ctx.device, &sem_info, null);

        // Create per-frame command pools and allocate command buffers
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            const pool_info = vk.VkCommandPoolCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
                .pNext = null,
                .flags = vk.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT,
                .queueFamilyIndex = ctx.transfer_queue_family,
            };
            self.command_pools[i] = try vk.createCommandPool(ctx.device, &pool_info, null);

            const cb_alloc_info = vk.VkCommandBufferAllocateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                .pNext = null,
                .commandPool = self.command_pools[i],
                .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
                .commandBufferCount = 1,
            };
            var cmd_buf: [1]vk.VkCommandBuffer = undefined;
            try vk.allocateCommandBuffers(ctx.device, &cb_alloc_info, &cmd_buf);
            self.command_buffers[i] = cmd_buf[0];
        }

        std.log.info("TransferPipeline: initialized ({} MB ring x{}, timeline semaphore)", .{
            RING_BUFFER_SIZE / (1024 * 1024),
            MAX_FRAMES_IN_FLIGHT,
        });

        return self;
    }

    pub fn beginTransfer(self: *TransferPipeline, frame_index: u32) !void {
        const tz = tracy.zone(@src(), "TransferPipeline.beginTransfer");
        defer tz.end();

        // Wait for this slot's previous transfer to complete
        const prev_value = self.frame_timeline_values[frame_index];
        if (prev_value > 0) {
            var current_value: u64 = 0;
            try vk.getSemaphoreCounterValue(self.device, self.timeline_semaphore, &current_value);
            if (current_value < prev_value) {
                const sems = [_]vk.VkSemaphore{self.timeline_semaphore};
                const vals = [_]u64{prev_value};
                const wait_info = vk.VkSemaphoreWaitInfo{
                    .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO,
                    .pNext = null,
                    .flags = 0,
                    .semaphoreCount = 1,
                    .pSemaphores = &sems,
                    .pValues = &vals,
                };
                try vk.waitSemaphores(self.device, &wait_info, std.math.maxInt(u64));
            }
        }

        // Reset ring buffer
        self.ring_buffers[frame_index].head = 0;
        self.pending_count = 0;
        self.has_commands[frame_index] = false;

        // Reset this frame's command pool and begin command buffer
        try vk.resetCommandPool(self.device, self.command_pools[frame_index], 0);
        const begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };
        try vk.beginCommandBuffer(self.command_buffers[frame_index], &begin_info);
    }

    pub fn commitTransfers(self: *TransferPipeline, frame_index: u32, world_renderer: anytype) void {
        const tz = tracy.zone(@src(), "TransferPipeline.commitTransfers");
        defer tz.end();

        // Apply deferred ChunkData writes from completed transfers
        const count = self.completed_counts[frame_index];
        for (0..count) |i| {
            const pc = &self.completed_chunks[frame_index][i];
            const slot = pc.slot;
            world_renderer.chunk_data[slot] = pc.chunk_data;
            world_renderer.chunk_face_alloc[slot] = pc.face_alloc;
            world_renderer.chunk_light_alloc[slot] = pc.light_alloc;
            world_renderer.writeChunkData(slot);
        }
        self.completed_counts[frame_index] = 0;

        // Process deferred TLSF frees
        const face_free_count = self.deferred_face_free_counts[frame_index];
        for (0..face_free_count) |i| {
            const handle = self.deferred_face_frees[frame_index][i].handle;
            if (handle != TlsfAllocator.null_handle) {
                world_renderer.face_tlsf.free(handle);
            }
        }
        self.deferred_face_free_counts[frame_index] = 0;

        const light_free_count = self.deferred_light_free_counts[frame_index];
        for (0..light_free_count) |i| {
            const handle = self.deferred_light_frees[frame_index][i].handle;
            if (handle != TlsfAllocator.null_handle) {
                world_renderer.light_tlsf.free(handle);
            }
        }
        self.deferred_light_free_counts[frame_index] = 0;
    }

    pub fn allocStaging(self: *TransferPipeline, frame_index: u32, size: vk.VkDeviceSize, alignment: vk.VkDeviceSize) !StagingAlloc {
        const ring = &self.ring_buffers[frame_index];
        const align_val = if (alignment > 0) alignment else 1;
        const aligned_head = (ring.head + align_val - 1) & ~(align_val - 1);
        if (aligned_head + size > RING_BUFFER_SIZE) {
            return error.StagingBufferFull;
        }
        const offset = aligned_head;
        ring.head = aligned_head + size;
        return .{
            .buffer = ring.buffer,
            .offset = offset,
            .mapped_ptr = ring.mapped_ptr + @as(usize, @intCast(offset)),
        };
    }

    pub fn recordCopy(self: *TransferPipeline, frame_index: u32, staging: StagingAlloc, dst_buffer: vk.VkBuffer, dst_offset: vk.VkDeviceSize, size: vk.VkDeviceSize) void {
        const regions = [_]vk.VkBufferCopy{.{
            .srcOffset = staging.offset,
            .dstOffset = dst_offset,
            .size = size,
        }};
        vk.cmdCopyBuffer(self.command_buffers[frame_index], staging.buffer, dst_buffer, 1, &regions);
        self.has_commands[frame_index] = true;
    }

    pub fn addPendingChunk(self: *TransferPipeline, chunk: PendingChunk) !void {
        if (self.pending_count >= MAX_PENDING) return error.StagingBufferFull;
        self.pending_chunks[self.pending_count] = chunk;
        self.pending_count += 1;
    }

    pub fn deferFaceFree(self: *TransferPipeline, frame_index: u32, handle: TlsfAllocator.Handle) void {
        const count = self.deferred_face_free_counts[frame_index];
        if (count < MAX_PENDING) {
            self.deferred_face_frees[frame_index][count] = .{ .handle = handle };
            self.deferred_face_free_counts[frame_index] = count + 1;
        } else {
            std.log.warn("TransferPipeline: deferred face free overflow, TLSF handle leaked", .{});
        }
    }

    pub fn deferLightFree(self: *TransferPipeline, frame_index: u32, handle: TlsfAllocator.Handle) void {
        const count = self.deferred_light_free_counts[frame_index];
        if (count < MAX_PENDING) {
            self.deferred_light_frees[frame_index][count] = .{ .handle = handle };
            self.deferred_light_free_counts[frame_index] = count + 1;
        } else {
            std.log.warn("TransferPipeline: deferred light free overflow, TLSF handle leaked", .{});
        }
    }

    pub fn submitTransfer(self: *TransferPipeline, frame_index: u32) !void {
        const tz = tracy.zone(@src(), "TransferPipeline.submitTransfer");
        defer tz.end();

        try vk.endCommandBuffer(self.command_buffers[frame_index]);

        if (!self.has_commands[frame_index]) {
            // Move pending to completed without incrementing timeline
            const count = self.pending_count;
            for (0..count) |i| {
                self.completed_chunks[frame_index][self.completed_counts[frame_index]] = self.pending_chunks[i];
                self.completed_counts[frame_index] += 1;
            }
            self.pending_count = 0;
            return;
        }

        self.timeline_value += 1;
        self.frame_timeline_values[frame_index] = self.timeline_value;

        const timeline_info = vk.VkTimelineSemaphoreSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreValueCount = 0,
            .pWaitSemaphoreValues = null,
            .signalSemaphoreValueCount = 1,
            .pSignalSemaphoreValues = &[_]u64{self.timeline_value},
        };

        const signal_semaphores = [_]vk.VkSemaphore{self.timeline_semaphore};
        const submit_info = vk.VkSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = &timeline_info,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = null,
            .pWaitDstStageMask = null,
            .commandBufferCount = 1,
            .pCommandBuffers = &self.command_buffers[frame_index],
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &signal_semaphores,
        };
        try vk.queueSubmit(self.transfer_queue, 1, &[_]vk.VkSubmitInfo{submit_info}, null);

        // Move pending to completed
        const count = self.pending_count;
        for (0..count) |i| {
            self.completed_chunks[frame_index][self.completed_counts[frame_index]] = self.pending_chunks[i];
            self.completed_counts[frame_index] += 1;
        }
        self.pending_count = 0;
    }

    pub fn getGraphicsWaitValue(self: *const TransferPipeline) u64 {
        return self.timeline_value;
    }

    pub fn deinit(self: *TransferPipeline) void {
        const tz = tracy.zone(@src(), "TransferPipeline.deinit");
        defer tz.end();

        // Wait for all pending transfers
        if (self.timeline_value > 0) {
            const sems = [_]vk.VkSemaphore{self.timeline_semaphore};
            const vals = [_]u64{self.timeline_value};
            const wait_info = vk.VkSemaphoreWaitInfo{
                .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO,
                .pNext = null,
                .flags = 0,
                .semaphoreCount = 1,
                .pSemaphores = &sems,
                .pValues = &vals,
            };
            vk.waitSemaphores(self.device, &wait_info, std.math.maxInt(u64)) catch {};
        }

        vk.destroySemaphore(self.device, self.timeline_semaphore, null);

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            vk.destroyCommandPool(self.device, self.command_pools[i], null);
            vk.destroyBuffer(self.device, self.ring_buffers[i].buffer, null);
            vk.unmapMemory(self.device, self.ring_buffers[i].memory);
            vk.freeMemory(self.device, self.ring_buffers[i].memory, null);
        }

        std.log.info("TransferPipeline destroyed", .{});
    }
};
