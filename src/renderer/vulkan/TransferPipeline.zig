const std = @import("std");
const vk = @import("../../platform/volk.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const vk_utils = @import("vk_utils.zig");
const types = @import("types.zig");
const ChunkData = types.ChunkData;
const FaceData = types.FaceData;
const LightEntry = types.LightEntry;
const TlsfAllocator = @import("../../allocators/TlsfAllocator.zig").TlsfAllocator;
const WorldState = @import("../../world/WorldState.zig");
const render_state_mod = @import("RenderState.zig");
const MAX_FRAMES_IN_FLIGHT = render_state_mod.MAX_FRAMES_IN_FLIGHT;
const tracy = @import("../../platform/tracy.zig");
const MeshWorker = @import("../../world/MeshWorker.zig").MeshWorker;
const Io = std.Io;

const RING_BUFFER_SIZE: vk.VkDeviceSize = 8 * 1024 * 1024; // 8MB per slot
const MAX_COMMITTED = 128;

pub const CommittedChunk = struct {
    key: WorldState.ChunkKey,
    chunk_data: ChunkData,
    face_alloc: ?TlsfAllocator.Allocation,
    light_alloc: ?TlsfAllocator.Allocation,
    timeline_value: u64,
    light_only: bool,
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
    slot_timeline_values: [MAX_FRAMES_IN_FLIGHT]u64,

    // Thread control
    thread: ?std.Thread,
    shutdown: std.atomic.Value(bool),

    // References (set via setupThread)
    mesh_worker: ?*MeshWorker,
    face_tlsf: ?*TlsfAllocator,
    light_tlsf: ?*TlsfAllocator,
    face_buffer: vk.VkBuffer,
    light_buffer: vk.VkBuffer,
    tlsf_mutex: Io.Mutex,

    // Committed queue (main thread drains this)
    committed_queue: [MAX_COMMITTED]CommittedChunk,
    committed_len: u32,
    committed_mutex: Io.Mutex,

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
        self.slot_timeline_values = .{0} ** MAX_FRAMES_IN_FLIGHT;

        // Thread fields
        self.thread = null;
        self.shutdown = std.atomic.Value(bool).init(false);
        self.mesh_worker = null;
        self.face_tlsf = null;
        self.light_tlsf = null;
        self.face_buffer = null;
        self.light_buffer = null;
        self.tlsf_mutex = .init;
        self.committed_len = 0;
        self.committed_mutex = .init;

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

    pub fn setupThread(
        self: *TransferPipeline,
        mesh_worker: *MeshWorker,
        face_tlsf: *TlsfAllocator,
        light_tlsf: *TlsfAllocator,
        face_buf: vk.VkBuffer,
        light_buf: vk.VkBuffer,
    ) void {
        self.mesh_worker = mesh_worker;
        self.face_tlsf = face_tlsf;
        self.light_tlsf = light_tlsf;
        self.face_buffer = face_buf;
        self.light_buffer = light_buf;
    }

    pub fn start(self: *TransferPipeline) void {
        self.shutdown.store(false, .release);
        self.thread = std.Thread.spawn(.{}, workerFn, .{self}) catch |err| {
            std.log.err("Failed to spawn transfer pipeline thread: {}", .{err});
            return;
        };
    }

    pub fn stop(self: *TransferPipeline) void {
        self.shutdown.store(true, .release);
        // Unblock the worker if it's waiting on mesh_worker output
        if (self.mesh_worker) |mw| {
            const io = Io.Threaded.global_single_threaded.io();
            mw.output_cond.broadcast(io);
        }
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn drainCommitted(self: *TransferPipeline, out_buf: []CommittedChunk) u32 {
        const io = Io.Threaded.global_single_threaded.io();
        self.committed_mutex.lockUncancelable(io);
        defer self.committed_mutex.unlock(io);

        const count = @min(self.committed_len, @as(u32, @intCast(out_buf.len)));
        if (count > 0) {
            @memcpy(out_buf[0..count], self.committed_queue[0..count]);
            // Shift remaining
            if (count < self.committed_len) {
                const remaining = self.committed_len - count;
                std.mem.copyForwards(
                    CommittedChunk,
                    self.committed_queue[0..remaining],
                    self.committed_queue[count..self.committed_len],
                );
            }
            self.committed_len -= count;
        }
        return count;
    }

    pub fn getGraphicsWaitValue(self: *const TransferPipeline) u64 {
        return self.timeline_value;
    }

    pub fn waitAllPending(self: *TransferPipeline) void {
        self.waitTimeline(self.timeline_value);
    }

    fn waitTimeline(self: *TransferPipeline, value: u64) void {
        if (value == 0) return;
        var current_value: u64 = 0;
        vk.getSemaphoreCounterValue(self.device, self.timeline_semaphore, &current_value) catch return;
        if (current_value >= value) return;

        const sems = [_]vk.VkSemaphore{self.timeline_semaphore};
        const vals = [_]u64{value};
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

    fn allocStaging(self: *TransferPipeline, slot: u32, size: vk.VkDeviceSize, alignment: vk.VkDeviceSize) !struct { buffer: vk.VkBuffer, offset: vk.VkDeviceSize, mapped_ptr: [*]u8 } {
        const ring = &self.ring_buffers[slot];
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

    fn freeResult(mw: *MeshWorker, result: MeshWorker.ChunkResult) void {
        if (!result.light_only) mw.allocator.free(result.faces);
        mw.allocator.free(result.lights);
    }

    fn workerFn(self: *TransferPipeline) void {
        const io = Io.Threaded.global_single_threaded.io();
        const mw = self.mesh_worker orelse return;
        const f_tlsf = self.face_tlsf orelse return;
        const l_tlsf = self.light_tlsf orelse return;

        var current_slot: u32 = 0;

        while (!self.shutdown.load(.acquire)) {
            // 1. Wait for mesh results
            var local_results: [MeshWorker.MAX_OUTPUT]MeshWorker.ChunkResult = undefined;
            var local_count: u32 = 0;

            mw.output_mutex.lockUncancelable(io);
            while (mw.output_len == 0 and !self.shutdown.load(.acquire)) {
                mw.output_cond.waitUncancelable(io, &mw.output_mutex);
            }
            local_count = mw.output_len;
            if (local_count > 0) {
                @memcpy(local_results[0..local_count], mw.output_queue[0..local_count]);
                mw.output_len = 0;
            }
            mw.output_mutex.unlock(io);
            if (local_count > 0) {
                mw.output_drained_cond.signal(io);
            }

            if (self.shutdown.load(.acquire)) {
                for (local_results[0..local_count]) |r| freeResult(mw, r);
                break;
            }

            // 2. Wait for current ring buffer slot to be available
            self.waitTimeline(self.slot_timeline_values[current_slot]);

            // 3. Reset ring + begin command buffer
            self.ring_buffers[current_slot].head = 0;
            vk.resetCommandPool(self.device, self.command_pools[current_slot], 0) catch |err| {
                std.log.err("Failed to reset transfer command pool: {}", .{err});
                for (local_results[0..local_count]) |r| freeResult(mw, r);
                continue;
            };
            const begin_info = vk.VkCommandBufferBeginInfo{
                .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                .pNext = null,
                .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
                .pInheritanceInfo = null,
            };
            vk.beginCommandBuffer(self.command_buffers[current_slot], &begin_info) catch |err| {
                std.log.err("Failed to begin transfer command buffer: {}", .{err});
                for (local_results[0..local_count]) |r| freeResult(mw, r);
                continue;
            };
            var has_commands = false;

            // 4. For each mesh result: TLSF alloc, stage, record copy
            for (local_results[0..local_count]) |result| {
                const key = result.key;

                // --- Light-only path ---
                if (result.light_only) {
                    if (result.light_count == 0) {
                        // No visible faces — commit light-only with no alloc
                        self.pushCommitted(.{
                            .key = key,
                            .chunk_data = .{
                                .position = key.position(),
                                .light_start = 0,
                                .face_start = 0,
                                .face_counts = result.face_counts,
                                .voxel_size = 1,
                            },
                            .face_alloc = null,
                            .light_alloc = null,
                            .timeline_value = self.timeline_value,
                            .light_only = true,
                        });
                        mw.allocator.free(result.lights);
                        continue;
                    }

                    // Allocate light TLSF only
                    self.tlsf_mutex.lockUncancelable(io);
                    const light_alloc = l_tlsf.alloc(result.light_count);
                    self.tlsf_mutex.unlock(io);

                    if (light_alloc == null) {
                        std.log.err("TLSF light heap full for light-only (requested {})", .{result.light_count});
                        mw.allocator.free(result.lights);
                        continue;
                    }
                    const la = light_alloc.?;

                    // Stage light data
                    const lb_size: vk.VkDeviceSize = @intCast(@as(u64, result.light_count) * @sizeOf(LightEntry));
                    const light_staging = self.allocStaging(current_slot, lb_size, @sizeOf(LightEntry)) catch {
                        self.tlsf_mutex.lockUncancelable(io);
                        l_tlsf.free(la.handle);
                        self.tlsf_mutex.unlock(io);
                        mw.allocator.free(result.lights);
                        continue;
                    };

                    const light_dst: [*]LightEntry = @ptrCast(@alignCast(light_staging.mapped_ptr));
                    @memcpy(light_dst[0..result.light_count], result.lights[0..result.light_count]);

                    const light_dst_offset: vk.VkDeviceSize = @intCast(@as(u64, la.offset) * @sizeOf(LightEntry));
                    const light_regions = [_]vk.VkBufferCopy{.{
                        .srcOffset = light_staging.offset,
                        .dstOffset = light_dst_offset,
                        .size = lb_size,
                    }};
                    vk.cmdCopyBuffer(self.command_buffers[current_slot], light_staging.buffer, self.light_buffer, 1, &light_regions);
                    has_commands = true;

                    self.pushCommitted(.{
                        .key = key,
                        .chunk_data = .{
                            .position = key.position(),
                            .light_start = la.offset,
                            .face_start = 0,
                            .face_counts = result.face_counts,
                            .voxel_size = 1,
                        },
                        .face_alloc = null,
                        .light_alloc = light_alloc,
                        .timeline_value = self.timeline_value + 1,
                        .light_only = true,
                    });

                    mw.allocator.free(result.lights);
                    continue;
                }

                // --- Full remesh path ---
                if (result.total_face_count == 0) {
                    // Empty chunk — commit with no alloc
                    self.pushCommitted(.{
                        .key = key,
                        .chunk_data = .{
                            .position = key.position(),
                            .light_start = 0,
                            .face_start = 0,
                            .face_counts = .{ 0, 0, 0, 0, 0, 0 },
                            .voxel_size = 1,
                        },
                        .face_alloc = null,
                        .light_alloc = null,
                        .timeline_value = self.timeline_value,
                        .light_only = false,
                    });
                    mw.allocator.free(result.faces);
                    mw.allocator.free(result.lights);
                    continue;
                }

                // TLSF alloc
                self.tlsf_mutex.lockUncancelable(io);
                const face_alloc = f_tlsf.alloc(result.total_face_count);
                const light_alloc = if (result.light_count > 0) l_tlsf.alloc(result.light_count) else null;
                self.tlsf_mutex.unlock(io);

                if (face_alloc == null) {
                    std.log.err("TLSF face heap full (requested {})", .{result.total_face_count});
                    if (light_alloc) |la_alloc| {
                        self.tlsf_mutex.lockUncancelable(io);
                        l_tlsf.free(la_alloc.handle);
                        self.tlsf_mutex.unlock(io);
                    }
                    mw.allocator.free(result.faces);
                    mw.allocator.free(result.lights);
                    continue;
                }
                const fa = face_alloc.?;
                const la = light_alloc orelse TlsfAllocator.Allocation{ .offset = 0, .size = 0, .handle = TlsfAllocator.null_handle };

                // Stage face data
                const fb_size: vk.VkDeviceSize = @intCast(@as(u64, result.total_face_count) * @sizeOf(FaceData));
                const face_staging = self.allocStaging(current_slot, fb_size, @sizeOf(FaceData)) catch {
                    // Ring full — free TLSF and skip rest
                    self.tlsf_mutex.lockUncancelable(io);
                    f_tlsf.free(fa.handle);
                    if (light_alloc != null) l_tlsf.free(la.handle);
                    self.tlsf_mutex.unlock(io);
                    mw.allocator.free(result.faces);
                    mw.allocator.free(result.lights);
                    continue;
                };

                const face_dst: [*]FaceData = @ptrCast(@alignCast(face_staging.mapped_ptr));
                @memcpy(face_dst[0..result.total_face_count], result.faces[0..result.total_face_count]);

                const face_dst_offset: vk.VkDeviceSize = @intCast(@as(u64, fa.offset) * @sizeOf(FaceData));
                const face_regions = [_]vk.VkBufferCopy{.{
                    .srcOffset = face_staging.offset,
                    .dstOffset = face_dst_offset,
                    .size = fb_size,
                }};
                vk.cmdCopyBuffer(self.command_buffers[current_slot], face_staging.buffer, self.face_buffer, 1, &face_regions);
                has_commands = true;

                // Stage light data
                if (result.light_count > 0 and light_alloc != null) {
                    const lb_size: vk.VkDeviceSize = @intCast(@as(u64, result.light_count) * @sizeOf(LightEntry));
                    const light_staging = self.allocStaging(current_slot, lb_size, @sizeOf(LightEntry)) catch {
                        // Ring full for lights — free light TLSF, still commit faces
                        self.tlsf_mutex.lockUncancelable(io);
                        l_tlsf.free(la.handle);
                        self.tlsf_mutex.unlock(io);
                        mw.allocator.free(result.faces);
                        mw.allocator.free(result.lights);
                        self.pushCommitted(.{
                            .key = key,
                            .chunk_data = .{
                                .position = key.position(),
                                .light_start = 0,
                                .face_start = fa.offset,
                                .face_counts = result.face_counts,
                                .voxel_size = 1,
                            },
                            .face_alloc = fa,
                            .light_alloc = null,
                            .timeline_value = self.timeline_value + 1,
                            .light_only = false,
                        });
                        continue;
                    };

                    const light_dst: [*]LightEntry = @ptrCast(@alignCast(light_staging.mapped_ptr));
                    @memcpy(light_dst[0..result.light_count], result.lights[0..result.light_count]);

                    const light_dst_offset: vk.VkDeviceSize = @intCast(@as(u64, la.offset) * @sizeOf(LightEntry));
                    const light_regions = [_]vk.VkBufferCopy{.{
                        .srcOffset = light_staging.offset,
                        .dstOffset = light_dst_offset,
                        .size = lb_size,
                    }};
                    vk.cmdCopyBuffer(self.command_buffers[current_slot], light_staging.buffer, self.light_buffer, 1, &light_regions);
                }

                // Push to committed queue
                self.pushCommitted(.{
                    .key = key,
                    .chunk_data = .{
                        .position = key.position(),
                        .light_start = la.offset,
                        .face_start = fa.offset,
                        .face_counts = result.face_counts,
                        .voxel_size = 1,
                    },
                    .face_alloc = fa,
                    .light_alloc = if (result.light_count > 0) light_alloc else null,
                    .timeline_value = self.timeline_value + 1,
                    .light_only = false,
                });

                // Free mesh result heap memory
                mw.allocator.free(result.faces);
                mw.allocator.free(result.lights);
            }

            // 5. End + submit
            vk.endCommandBuffer(self.command_buffers[current_slot]) catch |err| {
                std.log.err("Failed to end transfer command buffer: {}", .{err});
            };

            if (has_commands) {
                self.timeline_value += 1;
                self.slot_timeline_values[current_slot] = self.timeline_value;

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
                    .pCommandBuffers = &self.command_buffers[current_slot],
                    .signalSemaphoreCount = 1,
                    .pSignalSemaphores = &signal_semaphores,
                };
                vk.queueSubmit(self.transfer_queue, 1, &[_]vk.VkSubmitInfo{submit_info}, null) catch |err| {
                    std.log.err("Failed to submit transfer: {}", .{err});
                };
            }

            current_slot = (current_slot + 1) % MAX_FRAMES_IN_FLIGHT;
        }
    }

    fn pushCommitted(self: *TransferPipeline, entry: CommittedChunk) void {
        const io = Io.Threaded.global_single_threaded.io();
        var dropped = false;
        self.committed_mutex.lockUncancelable(io);
        if (self.committed_len < MAX_COMMITTED) {
            self.committed_queue[self.committed_len] = entry;
            self.committed_len += 1;
        } else {
            dropped = true;
        }
        self.committed_mutex.unlock(io);

        if (dropped) {
            std.log.warn("TransferPipeline committed queue full, dropping chunk", .{});
            // Free TLSF handles to prevent leaking GPU buffer space
            self.tlsf_mutex.lockUncancelable(io);
            if (entry.face_alloc) |fa| {
                if (fa.handle != TlsfAllocator.null_handle) {
                    if (self.face_tlsf) |ft| ft.free(fa.handle);
                }
            }
            if (entry.light_alloc) |la| {
                if (la.handle != TlsfAllocator.null_handle) {
                    if (self.light_tlsf) |lt| lt.free(la.handle);
                }
            }
            self.tlsf_mutex.unlock(io);
        }
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
