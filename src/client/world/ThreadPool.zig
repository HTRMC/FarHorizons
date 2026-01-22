/// ThreadPool - Worker thread management for async chunk operations
const std = @import("std");
const shared = @import("Shared");
const Logger = shared.Logger;
const ChunkPos = shared.ChunkPos;

/// Task types that workers can process
pub const TaskType = enum {
    generate_and_mesh,
    shutdown,
};

/// Whether this is a new chunk generation or a remesh of existing chunk
pub const ChunkTaskKind = enum {
    generate,
    remesh,
};

/// A task for the worker threads
pub const Task = struct {
    task_type: TaskType,
    /// Opaque pointer to task-specific data
    data: ?*anyopaque = null,
    /// Chunk position for distance calculation (used at poll time)
    chunk_pos: ChunkPos = .{ .x = 0, .z = 0, .section_y = 0 },
    /// Whether this is a generate or remesh task
    chunk_task_kind: ChunkTaskKind = .generate,
    /// Priority (lower = higher priority, 0 = highest)
    /// Shutdown tasks always have priority 0
    /// NOTE: This is now only used for shutdown tasks
    priority: i32 = 0,
};

/// Thread-safe task queue (FIFO, used for completed results)
pub fn ThreadSafeQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        mutex: std.Thread.Mutex = .{},
        condition: std.Thread.Condition = .{},
        items: std.ArrayListUnmanaged(T) = .{},
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit(self.allocator);
        }

        /// Add an item to the queue
        pub fn push(self: *Self, item: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.items.append(self.allocator, item);
            self.condition.signal();
        }

        /// Remove and return an item, blocking if empty
        pub fn pop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.items.items.len == 0) {
                self.condition.wait(&self.mutex);
            }

            return self.items.pop();
        }

        /// Try to pop without blocking
        pub fn tryPop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            return if (self.items.items.len > 0) self.items.pop() else null;
        }

        /// Check if queue is empty (for status only, may change immediately)
        pub fn isEmpty(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.items.items.len == 0;
        }

        /// Get current length (for status only)
        pub fn len(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.items.items.len;
        }

        /// Wake all waiting threads
        pub fn broadcast(self: *Self) void {
            self.condition.broadcast();
        }
    };
}

/// Dynamic priority queue for tasks - Minecraft's CompileTaskDynamicQueue pattern
/// Key difference from heap: priority is calculated at POLL time, not insert time
/// This ensures chunks closest to player are always processed first, even as player moves
pub const DynamicPriorityQueue = struct {
    const Self = @This();

    /// Maximum remesh tasks to process per poll cycle
    /// Prevents remesh spam from starving new chunk generation
    const MAX_REMESH_PER_CYCLE: u32 = 2;

    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    /// Simple list of tasks - we iterate to find closest at poll time
    tasks: std.ArrayListUnmanaged(Task) = .{},
    allocator: std.mem.Allocator,

    /// Current camera/player chunk position (updated atomically by main thread)
    camera_x: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    camera_z: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    camera_y: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),

    /// Remesh tasks processed in current cycle
    remesh_count: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.tasks.deinit(self.allocator);
    }

    /// Update camera position (called from main thread when player moves)
    pub fn updateCameraPos(self: *Self, x: i32, z: i32, y: i32) void {
        self.camera_x.store(x, .release);
        self.camera_z.store(z, .release);
        self.camera_y.store(y, .release);
    }

    /// Calculate squared distance from camera to chunk position
    fn distanceSquared(self: *Self, pos: ChunkPos) i64 {
        const cam_x = self.camera_x.load(.acquire);
        const cam_z = self.camera_z.load(.acquire);
        const cam_y = self.camera_y.load(.acquire);

        const dx: i64 = @as(i64, pos.x) - @as(i64, cam_x);
        const dz: i64 = @as(i64, pos.z) - @as(i64, cam_z);
        const dy: i64 = @as(i64, pos.section_y) - @as(i64, cam_y);

        // Horizontal distance matters more than vertical
        return dx * dx + dz * dz + @divFloor(dy * dy, 2);
    }

    /// Add a task to the queue
    pub fn push(self: *Self, task: Task) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.tasks.append(self.allocator, task);
        self.condition.signal();
    }

    /// Remove and return the closest task to camera, blocking if empty
    /// This is the key Minecraft optimization - priority is calculated at poll time
    pub fn pop(self: *Self) ?Task {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.tasks.items.len == 0) {
            self.condition.wait(&self.mutex);
        }

        return self.pollClosest();
    }

    /// Try to pop without blocking
    pub fn tryPop(self: *Self) ?Task {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.tasks.items.len == 0) return null;
        return self.pollClosest();
    }

    /// Find and remove the closest task to camera (must hold mutex)
    fn pollClosest(self: *Self) ?Task {
        if (self.tasks.items.len == 0) return null;

        // Check for shutdown tasks first - they have absolute priority
        for (self.tasks.items, 0..) |task, i| {
            if (task.task_type == .shutdown) {
                return self.tasks.swapRemove(i);
            }
        }

        // Find closest chunk to camera
        var best_distance: i64 = std.math.maxInt(i64);
        var best_index: ?usize = null;
        var best_remesh_distance: i64 = std.math.maxInt(i64);
        var best_remesh_index: ?usize = null;

        for (self.tasks.items, 0..) |task, i| {
            const dist = self.distanceSquared(task.chunk_pos);

            if (task.chunk_task_kind == .remesh) {
                // Track best remesh separately for quota
                if (dist < best_remesh_distance) {
                    best_remesh_distance = dist;
                    best_remesh_index = i;
                }
            } else {
                // New chunk generation
                if (dist < best_distance) {
                    best_distance = dist;
                    best_index = i;
                }
            }
        }

        // Apply remesh quota: prefer generate tasks unless we have quota
        // and the remesh is closer
        if (self.remesh_count < MAX_REMESH_PER_CYCLE) {
            if (best_remesh_index) |ri| {
                // If remesh is closer or no generate tasks, use remesh
                if (best_index == null or best_remesh_distance < best_distance) {
                    self.remesh_count += 1;
                    return self.tasks.swapRemove(ri);
                }
            }
        }

        // Reset remesh counter periodically (every full cycle through generates)
        if (best_index == null and best_remesh_index != null) {
            // Only remesh tasks left, reset counter and process them
            self.remesh_count = 0;
            if (best_remesh_index) |ri| {
                self.remesh_count += 1;
                return self.tasks.swapRemove(ri);
            }
        }

        // Return closest generate task
        if (best_index) |bi| {
            // Reset remesh counter when we process a generate
            self.remesh_count = 0;
            return self.tasks.swapRemove(bi);
        }

        return null;
    }

    /// Check if queue is empty
    pub fn isEmpty(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.tasks.items.len == 0;
    }

    /// Get current length
    pub fn len(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.tasks.items.len;
    }

    /// Wake all waiting threads
    pub fn broadcast(self: *Self) void {
        self.condition.broadcast();
    }
};

/// Worker thread context
pub const WorkerContext = struct {
    id: usize,
    pool: *ThreadPool,
    /// Per-worker state (e.g., allocator, model shaper)
    user_data: ?*anyopaque = null,
};

/// Callback type for task processing
pub const TaskCallback = *const fn (ctx: *WorkerContext, task: Task) void;

/// Thread pool for async chunk operations
pub const ThreadPool = struct {
    const Self = @This();
    const logger = Logger.scoped(Self);

    allocator: std.mem.Allocator,
    workers: []std.Thread,
    contexts: []WorkerContext,
    task_queue: DynamicPriorityQueue,
    running: std.atomic.Value(bool),
    callback: TaskCallback,

    /// Number of active workers
    active_count: std.atomic.Value(usize),

    /// Initialize the thread pool with the specified number of workers
    pub fn init(
        allocator: std.mem.Allocator,
        num_workers: usize,
        callback: TaskCallback,
    ) !Self {
        const worker_count = if (num_workers == 0) blk: {
            // Default to number of CPU cores minus 1 (leave one for main thread)
            const cpu_count = std.Thread.getCpuCount() catch 4;
            break :blk @max(1, cpu_count - 1);
        } else num_workers;

        logger.info("Initializing thread pool with {} workers (dynamic distance-based scheduling)", .{worker_count});

        return Self{
            .allocator = allocator,
            .workers = try allocator.alloc(std.Thread, worker_count),
            .contexts = try allocator.alloc(WorkerContext, worker_count),
            .task_queue = DynamicPriorityQueue.init(allocator),
            .running = std.atomic.Value(bool).init(true),
            .callback = callback,
            .active_count = std.atomic.Value(usize).init(0),
        };
    }

    /// Start all worker threads
    /// Must be called after the ThreadPool is at its final memory location
    pub fn start(self: *Self) !void {
        // Initialize contexts now that self is at its final location
        for (self.contexts, 0..) |*ctx, i| {
            ctx.* = WorkerContext{
                .id = i,
                .pool = self,
            };
        }

        // Start worker threads
        for (self.workers, 0..) |*worker, i| {
            worker.* = try std.Thread.spawn(.{}, workerLoop, .{&self.contexts[i]});
        }
        logger.info("All workers started", .{});
    }

    /// Set per-worker user data
    pub fn setWorkerData(self: *Self, worker_id: usize, data: ?*anyopaque) void {
        if (worker_id < self.contexts.len) {
            self.contexts[worker_id].user_data = data;
        }
    }

    /// Submit a task to the queue
    pub fn submit(self: *Self, task: Task) !void {
        try self.task_queue.push(task);
    }

    /// Update camera position for dynamic priority calculation
    /// Call this when player moves to ensure closest chunks are processed first
    pub fn updateCameraPos(self: *Self, chunk_x: i32, chunk_z: i32, section_y: i32) void {
        self.task_queue.updateCameraPos(chunk_x, chunk_z, section_y);
    }

    /// Shutdown the thread pool and wait for all workers to finish
    pub fn shutdown(self: *Self) void {
        logger.info("Shutting down thread pool...", .{});

        // Signal shutdown
        self.running.store(false, .release);

        // Push shutdown tasks for each worker
        for (0..self.workers.len) |_| {
            self.task_queue.push(Task{ .task_type = .shutdown }) catch {};
        }

        // Wake all threads
        self.task_queue.broadcast();

        // Wait for all workers
        for (self.workers) |worker| {
            worker.join();
        }

        logger.info("All workers shut down", .{});
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        self.task_queue.deinit();
        self.allocator.free(self.workers);
        self.allocator.free(self.contexts);
    }

    /// Get number of pending tasks
    pub fn pendingTasks(self: *Self) usize {
        return self.task_queue.len();
    }

    /// Get number of currently active workers
    pub fn activeWorkers(self: *Self) usize {
        return self.active_count.load(.acquire);
    }

    /// Check if pool is still running
    pub fn isRunning(self: *Self) bool {
        return self.running.load(.acquire);
    }

    fn workerLoop(ctx: *WorkerContext) void {
        const pool = ctx.pool;

        logger.debug("Worker {} started", .{ctx.id});

        while (pool.running.load(.acquire)) {
            // Wait for a task
            const task = pool.task_queue.pop() orelse continue;

            if (task.task_type == .shutdown) {
                break;
            }

            // Track active workers
            _ = pool.active_count.fetchAdd(1, .acq_rel);
            defer _ = pool.active_count.fetchSub(1, .acq_rel);

            // Process the task
            pool.callback(ctx, task);
        }

        logger.debug("Worker {} exiting", .{ctx.id});
    }
};
