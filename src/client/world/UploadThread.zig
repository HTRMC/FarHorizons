/// UploadThread - Dedicated thread for GPU mesh uploads
/// Follows AAA pattern: render thread does no allocations, no uploads, no waits
/// Time-budgeted processing (default 0.5ms per batch)
/// Owns command buffer and submits GPU copy commands with fence tracking
const std = @import("std");
const Io = std.Io;
const shared = @import("Shared");
const renderer = @import("Renderer");
const volk = @import("volk");
const vk = volk.c;

const Logger = shared.Logger;
const profiler = shared.profiler;
const ChunkPos = shared.ChunkPos;
const Chunk = shared.Chunk;

const Vertex = renderer.Vertex;
const ChunkBufferManager = renderer.buffer.ChunkBufferManager;
const ChunkBufferAllocation = renderer.buffer.ChunkBufferAllocation;
const StagingRing = renderer.buffer.StagingRing;
const PendingCopy = renderer.buffer.PendingCopy;

const render_chunk = @import("RenderChunk.zig");
const RenderChunk = render_chunk.RenderChunk;
const ChunkMesh = render_chunk.ChunkMesh;
const CompletedMesh = render_chunk.CompletedMesh;
const RENDER_LAYER_COUNT = render_chunk.RENDER_LAYER_COUNT;

const thread_pool = @import("ThreadPool.zig");
const ThreadSafeQueue = thread_pool.ThreadSafeQueue;

const SPSCQueue = @import("SPSCQueue.zig").SPSCQueue;

/// Number of fences in the pool (rotating through batches)
/// Larger pool allows upload thread to stay ahead of main thread consumption
const FENCE_POOL_SIZE: usize = 8;

/// Prepared batch ready for main thread to submit
/// Upload thread prepares, main thread submits (thread-safe queue access)
pub const PreparedBatch = struct {
    command_buffer: vk.VkCommandBuffer,
    fence: vk.VkFence,
    result_count: u32,
};

/// Result from upload thread to main thread
pub const UploadResult = struct {
    pos: ChunkPos,
    /// Pre-built ChunkMesh with buffer allocations set
    mesh: ChunkMesh,
    /// Generated chunk data (for new chunks, null for remesh)
    generated_chunk: ?Chunk,
    /// GPU slot (allocated by main thread)
    gpu_slot: u32,
    /// Whether this result is valid (false if processing failed/empty)
    valid: bool,
    /// Fence that signals when GPU copy is complete
    /// Main thread must check this before using the mesh
    upload_fence: vk.VkFence,
};

/// Upload thread statistics
/// NOTE: These fields are modified by the upload thread and read by the main thread
/// without synchronization. This is an intentional data race - torn reads may occur
/// but won't cause crashes, and precise stats are not required for monitoring purposes.
pub const UploadStats = struct {
    /// Total uploads processed
    total_uploads: u64 = 0,
    /// Total batches submitted
    batches_submitted: u64 = 0,
    /// Times budget was exhausted
    budget_exhausted_count: u64 = 0,
    /// Times max count was reached
    max_count_reached: u64 = 0,
    /// Upload errors
    upload_errors: u64 = 0,
    /// Skipped stale meshes
    stale_skipped: u64 = 0,
    /// Empty meshes (no geometry)
    empty_meshes: u64 = 0,
    /// Allocation failures
    alloc_failures: u64 = 0,
    /// GPU submit errors
    submit_errors: u64 = 0,
};

/// Configuration for upload thread
pub const UploadConfig = struct {
    /// Target time budget per batch (nanoseconds)
    time_budget_ns: u64 = 500_000, // 0.5ms default
    /// Maximum uploads per batch (fallback limit)
    max_uploads_per_batch: u32 = 64,
    /// Output queue capacity
    output_queue_capacity: usize = 128,
    /// Sleep time when idle (nanoseconds)
    idle_sleep_ns: u64 = 100_000, // 100us
};

/// Dedicated upload thread for GPU mesh staging
/// Owns staging ring buffer and command buffer - submits to graphics queue with fence tracking
/// AAA pattern: main thread never touches buffer manager directly
pub const UploadThread = struct {
    const Self = @This();
    const logger = Logger.scoped(Self);

    allocator: std.mem.Allocator,
    config: UploadConfig,
    io: Io,

    // Thread control
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool),

    // Input queue (from meshing workers, owned by ChunkManager)
    input_queue: *ThreadSafeQueue(CompletedMesh),

    // Output queue (to main thread)
    output_queue: SPSCQueue(UploadResult),

    // Free queue (from main thread - old allocations to be freed by upload thread)
    // AAA pattern: only upload thread touches buffer_manager
    free_queue: ThreadSafeQueue(ChunkBufferAllocation),

    // Buffer manager reference (owned by ChunkManager, only accessed by upload thread)
    buffer_manager: *ChunkBufferManager,

    // Staging ring buffer (OWNED by upload thread - not shared)
    staging_ring: StagingRing,

    // Vulkan resources for GPU command submission
    device: vk.VkDevice,
    physical_device: vk.VkPhysicalDevice,
    command_pool: vk.VkCommandPool,

    // Command buffer pool (one per fence slot for pipelining)
    command_buffers: [FENCE_POOL_SIZE]vk.VkCommandBuffer,

    // Fence pool for tracking GPU completion per batch
    fence_pool: [FENCE_POOL_SIZE]vk.VkFence,
    current_fence_index: usize = 0,

    // Prepared batches queue (upload thread prepares, main thread submits)
    // This avoids queue access from multiple threads
    prepared_batches: SPSCQueue(PreparedBatch),

    // Results pending fence assignment (will get current batch's fence)
    pending_results: std.ArrayListUnmanaged(UploadResult),

    // Player position for staleness checks (atomics for thread-safe access)
    player_chunk_x: std.atomic.Value(i32),
    player_chunk_z: std.atomic.Value(i32),
    player_chunk_y: std.atomic.Value(i32),

    // View distance for staleness checks
    view_distance: u32,
    vertical_view_distance: u32,
    unload_distance: u32,

    // Statistics
    stats: UploadStats = .{},

    /// Initialize the upload thread (does not start it)
    /// Note: No queue parameter - main thread does all queue submissions
    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        device: vk.VkDevice,
        physical_device: vk.VkPhysicalDevice,
        queue_family: u32,
        buffer_manager: *ChunkBufferManager,
        input_queue: *ThreadSafeQueue(CompletedMesh),
        view_distance: u32,
        vertical_view_distance: u32,
        unload_distance: u32,
        config: UploadConfig,
    ) !Self {
        var output_queue = try SPSCQueue(UploadResult).init(allocator, config.output_queue_capacity);
        errdefer output_queue.deinit();

        // Create free queue (main thread pushes old allocations, upload thread frees them)
        var free_queue = ThreadSafeQueue(ChunkBufferAllocation).init(allocator);
        errdefer free_queue.deinit();

        // Create prepared batches queue (upload thread writes, main thread reads for submission)
        var prepared_batches = try SPSCQueue(PreparedBatch).init(allocator, FENCE_POOL_SIZE);
        errdefer prepared_batches.deinit();

        // Create staging ring buffer (OWNED by upload thread)
        var staging_ring = try StagingRing.init(allocator, device, physical_device, StagingRing.DEFAULT_SIZE);
        errdefer staging_ring.deinit();

        // Create command pool for transfer commands
        const vkCreateCommandPool = vk.vkCreateCommandPool orelse return error.VulkanFunctionNotLoaded;
        const vkDestroyCommandPool = vk.vkDestroyCommandPool orelse return error.VulkanFunctionNotLoaded;
        const pool_info = vk.VkCommandPoolCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = queue_family,
        };
        var command_pool: vk.VkCommandPool = null;
        if (vkCreateCommandPool(device, &pool_info, null, &command_pool) != vk.VK_SUCCESS) {
            return error.CommandPoolCreationFailed;
        }
        errdefer vkDestroyCommandPool(device, command_pool, null);

        // Allocate command buffer pool (one per fence slot for pipelining)
        const vkAllocateCommandBuffers = vk.vkAllocateCommandBuffers orelse return error.VulkanFunctionNotLoaded;
        const alloc_info = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = FENCE_POOL_SIZE,
        };
        var command_buffers: [FENCE_POOL_SIZE]vk.VkCommandBuffer = undefined;
        if (vkAllocateCommandBuffers(device, &alloc_info, &command_buffers) != vk.VK_SUCCESS) {
            return error.CommandBufferAllocationFailed;
        }

        // Create fence pool
        const vkCreateFence = vk.vkCreateFence orelse return error.VulkanFunctionNotLoaded;
        const vkDestroyFence = vk.vkDestroyFence orelse return error.VulkanFunctionNotLoaded;
        var fence_pool: [FENCE_POOL_SIZE]vk.VkFence = undefined;
        var fences_created: usize = 0;
        errdefer {
            for (0..fences_created) |i| {
                vkDestroyFence(device, fence_pool[i], null);
            }
        }

        for (0..FENCE_POOL_SIZE) |i| {
            const fence_info = vk.VkFenceCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
                .pNext = null,
                .flags = vk.VK_FENCE_CREATE_SIGNALED_BIT, // Start signaled
            };
            if (vkCreateFence(device, &fence_info, null, &fence_pool[i]) != vk.VK_SUCCESS) {
                return error.FenceCreationFailed;
            }
            fences_created += 1;
        }

        logger.info("UploadThread initialized: budget={}us, max_per_batch={}, fence_pool={}", .{
            config.time_budget_ns / 1000,
            config.max_uploads_per_batch,
            FENCE_POOL_SIZE,
        });

        logger.info("UploadThread owns staging ring: {} MB", .{StagingRing.DEFAULT_SIZE / (1024 * 1024)});

        return Self{
            .allocator = allocator,
            .config = config,
            .io = io,
            .running = std.atomic.Value(bool).init(false),
            .input_queue = input_queue,
            .output_queue = output_queue,
            .free_queue = free_queue,
            .buffer_manager = buffer_manager,
            .staging_ring = staging_ring,
            .device = device,
            .physical_device = physical_device,
            .command_pool = command_pool,
            .command_buffers = command_buffers,
            .fence_pool = fence_pool,
            .prepared_batches = prepared_batches,
            .pending_results = .{},
            .player_chunk_x = std.atomic.Value(i32).init(0),
            .player_chunk_z = std.atomic.Value(i32).init(0),
            .player_chunk_y = std.atomic.Value(i32).init(0),
            .view_distance = view_distance,
            .vertical_view_distance = vertical_view_distance,
            .unload_distance = unload_distance,
        };
    }

    pub fn deinit(self: *Self) void {
        self.shutdown();

        // Destroy Vulkan resources
        const vkDestroyFence = vk.vkDestroyFence orelse return;
        const vkDestroyCommandPool = vk.vkDestroyCommandPool orelse return;
        const vkDeviceWaitIdle = vk.vkDeviceWaitIdle orelse return;

        // Wait for GPU to be idle before destroying
        _ = vkDeviceWaitIdle(self.device);

        // Process any remaining frees
        while (self.free_queue.tryPop()) |alloc| {
            self.buffer_manager.free(alloc);
        }

        for (self.fence_pool) |fence| {
            vkDestroyFence(self.device, fence, null);
        }
        vkDestroyCommandPool(self.device, self.command_pool, null);

        // Clean up owned staging ring
        self.staging_ring.deinit();

        // Drain output queue and clean up any remaining upload results
        // These contain ChunkMesh objects with allocated vertex/index data
        while (self.output_queue.tryPop()) |result| {
            if (result.valid) {
                var mesh = result.mesh;
                // Free GPU allocations first
                for (0..RENDER_LAYER_COUNT) |i| {
                    if (mesh.layers[i].buffer_allocation.valid) {
                        self.buffer_manager.free(mesh.layers[i].buffer_allocation);
                    }
                }
                mesh.deinit();
            }
        }

        self.pending_results.deinit(self.allocator);
        self.output_queue.deinit();
        self.free_queue.deinit();
        self.prepared_batches.deinit();

        logger.info("UploadThread destroyed", .{});
    }

    /// Start the upload thread
    pub fn start(self: *Self) !void {
        if (self.running.load(.acquire)) {
            return; // Already running
        }

        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, threadLoop, .{self});

        logger.info("UploadThread started", .{});
    }

    /// Shutdown the upload thread (blocking)
    pub fn shutdown(self: *Self) void {
        if (!self.running.load(.acquire)) {
            return; // Not running
        }

        logger.info("UploadThread shutting down...", .{});

        self.running.store(false, .release);

        // Wake up the thread if it's waiting
        self.input_queue.broadcast();

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        logger.info("UploadThread shutdown complete: {} uploads, {} batches", .{
            self.stats.total_uploads,
            self.stats.batches_submitted,
        });
    }

    /// Update player position for staleness checks (called from main thread)
    pub fn updatePlayerPos(self: *Self, chunk_x: i32, chunk_z: i32, section_y: i32) void {
        self.player_chunk_x.store(chunk_x, .release);
        self.player_chunk_z.store(chunk_z, .release);
        self.player_chunk_y.store(section_y, .release);
    }

    /// Get current queue depth (for backpressure)
    pub fn getOutputQueueDepth(self: *const Self) usize {
        return self.output_queue.len();
    }

    /// Check if output queue is full (for backpressure)
    pub fn isOutputQueueFull(self: *const Self) bool {
        return self.output_queue.isFull();
    }

    /// Get statistics (non-synchronized snapshot, may have torn reads)
    pub fn getStats(self: *const Self) UploadStats {
        return self.stats;
    }

    /// Queue an allocation to be freed by the upload thread (called from main thread)
    /// AAA pattern: main thread never touches buffer_manager directly
    pub fn queueFree(self: *Self, allocation: ChunkBufferAllocation) void {
        if (!allocation.valid) return;
        self.free_queue.push(allocation) catch {
            // OOM - this shouldn't happen with proper sizing
            logger.warn("Failed to queue free, dropping allocation", .{});
        };
    }

    /// Submit all prepared batches to the GPU queue (called from main thread only)
    /// Returns the number of batches submitted
    /// AAA pattern: only main thread touches the queue
    pub fn submitPreparedBatches(self: *Self, queue: vk.VkQueue) u32 {
        const vkQueueSubmit = vk.vkQueueSubmit orelse return 0;
        const vkResetFences = vk.vkResetFences orelse return 0;

        var submitted: u32 = 0;

        while (self.prepared_batches.tryPop()) |batch| {
            // Reset the fence before submission
            const fences = [_]vk.VkFence{batch.fence};
            _ = vkResetFences(self.device, 1, &fences);

            // Submit to queue
            const cmd_buffers = [_]vk.VkCommandBuffer{batch.command_buffer};
            const submit_info = vk.VkSubmitInfo{
                .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
                .pNext = null,
                .waitSemaphoreCount = 0,
                .pWaitSemaphores = null,
                .pWaitDstStageMask = null,
                .commandBufferCount = 1,
                .pCommandBuffers = &cmd_buffers,
                .signalSemaphoreCount = 0,
                .pSignalSemaphores = null,
            };

            if (vkQueueSubmit(queue, 1, &submit_info, batch.fence) != vk.VK_SUCCESS) {
                logger.err("Failed to submit prepared batch", .{});
                self.stats.submit_errors += 1;
            } else {
                submitted += 1;
            }
        }

        return submitted;
    }

    /// Check if there are prepared batches waiting for submission
    pub fn hasPreparedBatches(self: *const Self) bool {
        return !self.prepared_batches.isEmpty();
    }

    /// Sleep for idle_sleep_ns duration using Zig 0.16 API
    fn sleepIdle(self: *Self) void {
        Io.Clock.Duration.sleep(.{
            .clock = .awake,
            .raw = .fromNanoseconds(self.config.idle_sleep_ns),
        }, self.io) catch {};
    }

    /// Main upload thread loop
    fn threadLoop(self: *Self) void {
        profiler.setThreadName("UploadThread");
        logger.debug("Upload thread started", .{});

        while (self.running.load(.acquire)) {
            const zone = profiler.traceNamed("UploadBatch");
            defer zone.end();

            // Process pending frees from main thread (AAA pattern: only upload thread touches buffer_manager)
            self.processFreeQueue();

            // Advance frame and process deferred frees (AAA: upload thread owns buffer_manager)
            self.buffer_manager.advanceFrameAndProcessFrees();

            var timer = std.time.Timer.start() catch {
                self.sleepIdle();
                continue;
            };

            var uploads_this_batch: u32 = 0;

            // Process uploads until time budget exhausted or max count reached
            while (true) {
                // Check time budget
                const elapsed_ns = timer.read();
                if (elapsed_ns >= self.config.time_budget_ns) {
                    if (uploads_this_batch > 0) {
                        self.stats.budget_exhausted_count += 1;
                    }
                    break;
                }

                // Check max count
                if (uploads_this_batch >= self.config.max_uploads_per_batch) {
                    self.stats.max_count_reached += 1;
                    break;
                }

                // Check output queue capacity (accounting for pending results not yet pushed)
                const available = self.output_queue.getCapacity() -| self.output_queue.len();
                if (available <= self.pending_results.items.len) {
                    // Backpressure: not enough room for pending + new results
                    break;
                }

                // Try to get work (non-blocking)
                const mesh_opt = self.input_queue.tryPop();
                if (mesh_opt == null) {
                    // No work available
                    if (uploads_this_batch == 0) {
                        // No work at all, sleep briefly
                        self.sleepIdle();
                    }
                    break;
                }

                var mesh = mesh_opt.?;

                // Process the mesh (stages data, builds ChunkMesh)
                const result = self.processUpload(&mesh);
                mesh.deinit(); // Free input mesh data

                // Always add result (valid or not) so main thread can update tracking
                self.pending_results.append(self.allocator, result) catch {
                    // Only cleanup mesh if it was valid
                    if (result.valid) {
                        var r = result;
                        // Free GPU allocations first
                        for (0..RENDER_LAYER_COUNT) |i| {
                            if (r.mesh.layers[i].buffer_allocation.valid) {
                                self.buffer_manager.free(r.mesh.layers[i].buffer_allocation);
                            }
                        }
                        r.mesh.deinit();
                    }
                    self.stats.upload_errors += 1;
                    continue;
                };
                if (result.valid) {
                    uploads_this_batch += 1;
                }
            }

            // Submit batch if we have pending results (includes results from previous cycles)
            if (self.pending_results.items.len > 0) {
                if (self.submitBatch()) {
                    // Batch was prepared successfully
                    self.stats.total_uploads += uploads_this_batch;
                    self.stats.batches_submitted += 1;
                    profiler.plotInt("UploadBatchSize", @intCast(uploads_this_batch));
                }
                // If submitBatch returned false, pending_results are kept for next cycle
            }
        }

        logger.debug("Upload thread exiting", .{});
    }

    /// Prepare the current batch of uploads (records commands, does NOT submit)
    /// Main thread will call getPreparedBatch() to get and submit
    /// Returns true if batch was prepared, false if we need to wait (fence not ready)
    fn submitBatch(self: *Self) bool {
        const zone = profiler.traceNamed("PrepareBatch");
        defer zone.end();

        // Check if prepared_batches queue has space (avoid recording commands we can't push)
        if (self.prepared_batches.isFull()) {
            // Queue full - main thread hasn't consumed batches yet, hold results for next cycle
            return false;
        }

        // Get resources for this batch slot
        const batch_fence = self.fence_pool[self.current_fence_index];
        const command_buffer = self.command_buffers[self.current_fence_index];

        // Non-blocking fence check - if not signaled, command buffer still in use
        const vkGetFenceStatus = vk.vkGetFenceStatus orelse return false;
        const vkResetCommandBuffer = vk.vkResetCommandBuffer orelse return false;
        const vkBeginCommandBuffer = vk.vkBeginCommandBuffer orelse return false;
        const vkEndCommandBuffer = vk.vkEndCommandBuffer orelse return false;
        const vkCmdCopyBuffer = vk.vkCmdCopyBuffer orelse return false;

        // Check if fence is signaled (non-blocking)
        if (vkGetFenceStatus(self.device, batch_fence) != vk.VK_SUCCESS) {
            // Fence not signaled - command buffer still in GPU use, wait for next cycle
            return false;
        }

        // Reset and begin command buffer
        _ = vkResetCommandBuffer(command_buffer, 0);

        const begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };
        if (vkBeginCommandBuffer(command_buffer, &begin_info) != vk.VK_SUCCESS) {
            self.stats.submit_errors += 1;
            self.clearPendingResults();
            return false;
        }

        // Record copy commands from our owned staging ring
        const pending_copies = self.staging_ring.getPendingCopies();
        for (pending_copies) |copy| {
            const region = vk.VkBufferCopy{
                .srcOffset = copy.src_offset,
                .dstOffset = copy.dst_offset,
                .size = copy.size,
            };
            vkCmdCopyBuffer(command_buffer, copy.src_buffer, copy.dst_buffer, 1, &region);
        }
        self.staging_ring.clearPendingCopies();

        // End command buffer
        if (vkEndCommandBuffer(command_buffer) != vk.VK_SUCCESS) {
            self.stats.submit_errors += 1;
            self.clearPendingResults();
            return false;
        }

        // Push prepared batch to queue for main thread to submit
        // (No vkQueueSubmit here - main thread does all queue work)
        // We already checked isFull() at the start, so this should succeed
        const result_count: u32 = @intCast(self.pending_results.items.len);
        if (!self.prepared_batches.tryPush(PreparedBatch{
            .command_buffer = command_buffer,
            .fence = batch_fence,
            .result_count = result_count,
        })) {
            // Should not happen since we checked isFull() at start
            logger.err("Prepared batches queue unexpectedly full", .{});
            self.stats.submit_errors += 1;
            self.clearPendingResults();
            return false;
        }

        // Push results to output queue with this batch's fence
        for (self.pending_results.items) |*result| {
            result.upload_fence = batch_fence;
            if (!self.output_queue.tryPush(result.*)) {
                // Queue full, cleanup this result
                // Free GPU allocations first to prevent memory leak
                for (0..RENDER_LAYER_COUNT) |i| {
                    if (result.mesh.layers[i].buffer_allocation.valid) {
                        self.buffer_manager.free(result.mesh.layers[i].buffer_allocation);
                    }
                }
                result.mesh.deinit();
                self.stats.upload_errors += 1;
            }
        }
        self.pending_results.clearRetainingCapacity();

        // Advance to next fence
        self.current_fence_index = (self.current_fence_index + 1) % FENCE_POOL_SIZE;

        return true;
    }

    /// Clear pending results on error (cleanup allocations)
    fn clearPendingResults(self: *Self) void {
        for (self.pending_results.items) |*result| {
            if (result.valid) {
                // Free GPU allocations first (before deinit invalidates the mesh)
                for (0..RENDER_LAYER_COUNT) |i| {
                    if (result.mesh.layers[i].buffer_allocation.valid) {
                        self.buffer_manager.free(result.mesh.layers[i].buffer_allocation);
                    }
                }
                result.mesh.deinit();
            }
        }
        self.pending_results.clearRetainingCapacity();
    }

    /// Process pending frees from main thread
    /// AAA pattern: only upload thread touches buffer_manager
    fn processFreeQueue(self: *Self) void {
        var freed: u32 = 0;
        while (self.free_queue.tryPop()) |allocation| {
            self.buffer_manager.free(allocation);
            freed += 1;
        }
        if (freed > 0) {
            profiler.plotInt("FreesProcessed", @intCast(freed));
        }
    }

    /// Process a single mesh upload
    /// Always returns an UploadResult - valid=false for skip/failure so main thread can update tracking
    fn processUpload(self: *Self, mesh: *CompletedMesh) UploadResult {
        const zone = profiler.traceNamed("ProcessUpload");
        defer zone.end();

        // Helper for creating invalid results (preserves position for tracking cleanup)
        const invalid_result = UploadResult{
            .pos = mesh.pos,
            .mesh = undefined,
            .generated_chunk = mesh.generated_chunk,
            .gpu_slot = 0,
            .valid = false,
            .upload_fence = null,
        };

        // Check staleness (chunk moved out of view while queued)
        if (self.isStale(mesh.pos)) {
            self.stats.stale_skipped += 1;
            return invalid_result;
        }

        // Check for empty mesh
        const total_vertices = mesh.getTotalVertexCount();
        const total_indices = mesh.getTotalIndexCount();
        if (total_vertices == 0 or total_indices == 0) {
            self.stats.empty_meshes += 1;
            // Return a valid but empty result (no fence needed)
            return UploadResult{
                .pos = mesh.pos,
                .mesh = undefined, // Will not be used
                .generated_chunk = mesh.generated_chunk,
                .gpu_slot = 0,
                .valid = false, // Mark as invalid so main thread knows to skip
                .upload_fence = null,
            };
        }

        // Validate mesh integrity
        for (0..RENDER_LAYER_COUNT) |i| {
            const layer = &mesh.layers[i];
            if (layer.vertices.len == 0) continue;

            var max_index: u32 = 0;
            for (layer.indices) |idx| {
                if (idx > max_index) max_index = idx;
            }
            if (max_index >= layer.vertices.len) {
                logger.err("Chunk ({},{},{}) layer {} has invalid index {} >= vertex count {}", .{
                    mesh.pos.x,
                    mesh.pos.z,
                    mesh.pos.section_y,
                    i,
                    max_index,
                    layer.vertices.len,
                });
                self.stats.upload_errors += 1;
                return invalid_result;
            }
        }

        // Allocate GPU buffer space for each layer
        var layer_allocations: [RENDER_LAYER_COUNT]?ChunkBufferAllocation = .{ null, null, null };
        var allocation_failed = false;

        for (0..RENDER_LAYER_COUNT) |i| {
            const layer = &mesh.layers[i];
            if (layer.vertices.len == 0) continue;

            layer_allocations[i] = self.buffer_manager.allocate(
                @intCast(layer.vertices.len),
                @intCast(layer.indices.len),
            );
            if (layer_allocations[i] == null) {
                logger.warn("Failed to allocate buffer space for chunk layer {}", .{i});
                allocation_failed = true;
                break;
            }
        }

        if (allocation_failed) {
            // Free any allocations we made
            for (layer_allocations) |alloc_opt| {
                if (alloc_opt) |alloc| {
                    self.buffer_manager.free(alloc);
                }
            }
            self.stats.alloc_failures += 1;
            return invalid_result;
        }

        // Stage data to our owned staging ring (not buffer_manager's)
        // Track pending count so we can cancel if staging fails partway
        const pending_before = self.staging_ring.getPendingCount();
        var staging_failed = false;
        for (0..RENDER_LAYER_COUNT) |i| {
            const layer = &mesh.layers[i];
            const alloc_opt = layer_allocations[i];
            if (alloc_opt == null) continue;
            const allocation = alloc_opt.?;

            // Get destination buffers from buffer_manager
            const vertex_buffer = self.buffer_manager.getVertexBuffer(allocation.vertex_slice.arena_index) orelse {
                logger.warn("Failed to get vertex buffer for layer {}", .{i});
                staging_failed = true;
                break;
            };
            const index_buffer = self.buffer_manager.getIndexBuffer(allocation.index_slice.arena_index) orelse {
                logger.warn("Failed to get index buffer for layer {}", .{i});
                staging_failed = true;
                break;
            };

            // Stage to our owned staging ring
            const vertex_bytes = std.mem.sliceAsBytes(layer.vertices);
            _ = self.staging_ring.stage(vertex_bytes, vertex_buffer, allocation.vertex_slice.offset) catch |err| {
                logger.warn("Failed to stage vertex data for layer {}: {}", .{ i, err });
                staging_failed = true;
                break;
            };

            const index_bytes = std.mem.sliceAsBytes(layer.indices);
            _ = self.staging_ring.stage(index_bytes, index_buffer, allocation.index_slice.offset) catch |err| {
                logger.warn("Failed to stage index data for layer {}: {}", .{ i, err });
                staging_failed = true;
                break;
            };
        }

        if (staging_failed) {
            // Cancel any copy commands we added before freeing the allocations
            // Otherwise GPU would copy to freed/reallocated buffer regions
            self.staging_ring.cancelPendingCopiesAfter(pending_before);
            for (layer_allocations) |alloc_opt| {
                if (alloc_opt) |alloc| {
                    self.buffer_manager.free(alloc);
                }
            }
            self.stats.upload_errors += 1;
            return invalid_result;
        }

        // Build ChunkMesh with allocations
        var layer_vertices: [RENDER_LAYER_COUNT][]const Vertex = undefined;
        var layer_indices: [RENDER_LAYER_COUNT][]const u32 = undefined;
        for (0..RENDER_LAYER_COUNT) |i| {
            layer_vertices[i] = mesh.layers[i].vertices;
            layer_indices[i] = mesh.layers[i].indices;
        }

        var chunk_mesh = ChunkMesh.init(
            self.allocator,
            layer_vertices,
            layer_indices,
        ) catch {
            logger.warn("Failed to create chunk mesh", .{});
            // Cancel copy commands before freeing allocations
            self.staging_ring.cancelPendingCopiesAfter(pending_before);
            for (layer_allocations) |alloc_opt| {
                if (alloc_opt) |alloc| {
                    self.buffer_manager.free(alloc);
                }
            }
            self.stats.upload_errors += 1;
            return invalid_result;
        };

        // Set allocations on the mesh
        for (0..RENDER_LAYER_COUNT) |i| {
            if (layer_allocations[i]) |alloc| {
                chunk_mesh.setLayerBufferAllocation(i, alloc);
            }
        }

        return UploadResult{
            .pos = mesh.pos,
            .mesh = chunk_mesh,
            .generated_chunk = mesh.generated_chunk,
            .gpu_slot = 0, // Will be allocated by main thread
            .valid = true,
            .upload_fence = null, // Will be set when batch is submitted
        };
    }

    /// Check if a chunk position is stale (out of view range)
    fn isStale(self: *Self, pos: ChunkPos) bool {
        const player_x = self.player_chunk_x.load(.acquire);
        const player_z = self.player_chunk_z.load(.acquire);
        const player_y = self.player_chunk_y.load(.acquire);

        const dx: u32 = @intCast(@abs(pos.x - player_x));
        const dz: u32 = @intCast(@abs(pos.z - player_z));
        const dy: u32 = @intCast(@abs(pos.section_y - player_y));

        const horizontal_dist = @max(dx, dz);
        return horizontal_dist > self.unload_distance or
            dy > self.vertical_view_distance + 2;
    }
};
