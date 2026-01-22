/// ThreadPool - Worker thread management for async chunk operations
const std = @import("std");
const shared = @import("Shared");
const Logger = shared.Logger;
const ChunkPos = shared.ChunkPos;
const profiler = shared.profiler;

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

/// Dynamic priority queue for tasks - C2ME's DynamicPriorityQueue pattern
/// Uses fixed-size priority buckets instead of linear scan for O(p) dequeue
/// Priority is based on Chebyshev distance within bounded window (8-chunk radius)
pub const DynamicPriorityQueue = struct {
    const Self = @This();

    /// Number of priority buckets (C2ME uses 64, configurable up to 256)
    const PRIORITY_BUCKETS: usize = 64;

    /// Distance window for dynamic prioritization (8-chunk radius like C2ME)
    /// Beyond this, all chunks get MAX_PRIORITY (lowest urgency)
    const PRIORITY_WINDOW_RADIUS: i32 = 8;

    /// Maximum priority value (lowest urgency)
    const MAX_PRIORITY: u8 = PRIORITY_BUCKETS - 1;

    /// Maximum remesh tasks to process per poll cycle
    /// Prevents remesh spam from starving new chunk generation
    const MAX_REMESH_PER_CYCLE: u32 = 2;

    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},

    /// Fixed-size array of priority buckets (C2ME pattern)
    /// Each bucket is a FIFO queue for tasks at that priority level
    /// Priority 0 = highest urgency (closest chunks), 63 = lowest
    buckets: [PRIORITY_BUCKETS]std.ArrayListUnmanaged(Task),

    /// Task count per bucket for quick skip-ahead optimization
    /// Allows dequeue to skip empty buckets without scanning
    bucket_counts: [PRIORITY_BUCKETS]std.atomic.Value(u32),

    allocator: std.mem.Allocator,

    /// Current camera/player chunk position (updated atomically by main thread)
    camera_x: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    camera_z: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    camera_y: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),

    /// Remesh tasks processed in current cycle
    remesh_count: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Self {
        var self = Self{
            .allocator = allocator,
            .buckets = undefined,
            .bucket_counts = undefined,
        };

        // Initialize all buckets as empty
        for (0..PRIORITY_BUCKETS) |i| {
            self.buckets[i] = .{};
            self.bucket_counts[i] = std.atomic.Value(u32).init(0);
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        for (0..PRIORITY_BUCKETS) |i| {
            self.buckets[i].deinit(self.allocator);
        }
    }

    /// Update camera position (called from main thread when player moves)
    pub fn updateCameraPos(self: *Self, x: i32, z: i32, y: i32) void {
        self.camera_x.store(x, .release);
        self.camera_z.store(z, .release);
        self.camera_y.store(y, .release);
    }

    /// Calculate priority based on Chebyshev distance (C2ME pattern)
    /// Priority 0 = closest (1 chunk away), MAX_PRIORITY = farthest or outside window
    /// Only chunks within PRIORITY_WINDOW_RADIUS get distance-based priority
    fn calculatePriority(self: *Self, pos: ChunkPos) u8 {
        const cam_x = self.camera_x.load(.acquire);
        const cam_z = self.camera_z.load(.acquire);
        const cam_y = self.camera_y.load(.acquire);

        // Calculate Chebyshev distance (max of absolute differences)
        const dx = @abs(@as(i64, pos.x) - @as(i64, cam_x));
        const dz = @abs(@as(i64, pos.z) - @as(i64, cam_z));
        const dy = @abs(@as(i64, pos.section_y) - @as(i64, cam_y));

        const horizontal_dist = @max(dx, dz);

        // C2ME pattern: Only prioritize chunks within 8-chunk window
        // This prevents large coordinates from affecting performance
        if (horizontal_dist > PRIORITY_WINDOW_RADIUS) {
            return MAX_PRIORITY;
        }

        // Vertical distance matters less (divide by 2)
        const chebyshev_dist = @max(horizontal_dist, @divFloor(dy, 2));

        // Clamp to valid priority range
        if (chebyshev_dist >= MAX_PRIORITY) {
            return MAX_PRIORITY;
        }

        return @intCast(chebyshev_dist);
    }

    /// Add a task to the queue (C2ME bucket-based approach)
    /// Priority is calculated at insertion time and task goes into appropriate bucket
    pub fn push(self: *Self, task: Task) !void {
        // Shutdown tasks always go to highest priority bucket (0)
        const priority: u8 = if (task.task_type == .shutdown)
            0
        else
            self.calculatePriority(task.chunk_pos);

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.buckets[priority].append(self.allocator, task);
        _ = self.bucket_counts[priority].fetchAdd(1, .release);
        self.condition.signal();
    }

    /// Remove and return the highest priority task, blocking if empty
    /// C2ME pattern: O(p) scan where p = number of priority buckets (64)
    /// Uses bucket counts for quick skip-ahead optimization
    pub fn pop(self: *Self) ?Task {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.isEmptyUnlocked()) {
            self.condition.wait(&self.mutex);
        }

        return self.dequeueFromBuckets();
    }

    /// Try to pop without blocking
    pub fn tryPop(self: *Self) ?Task {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.isEmptyUnlocked()) return null;
        return self.dequeueFromBuckets();
    }

    /// Dequeue task from highest priority non-empty bucket (must hold mutex)
    /// C2ME pattern: Scan buckets from 0 (highest priority) to MAX_PRIORITY
    /// Skip empty buckets using atomic counts for optimization
    fn dequeueFromBuckets(self: *Self) ?Task {
        const zone = profiler.trace(@src());
        defer zone.end();

        // Scan from highest priority (0) to lowest (MAX_PRIORITY)
        for (0..PRIORITY_BUCKETS) |priority| {
            // Quick check: skip empty buckets without locking
            if (self.bucket_counts[priority].load(.acquire) == 0) {
                continue;
            }

            // Try to pop from this bucket
            if (self.buckets[priority].items.len > 0) {
                // FIFO within bucket: pop from front for fairness
                const task = self.buckets[priority].orderedRemove(0);
                _ = self.bucket_counts[priority].fetchSub(1, .release);

                // Handle remesh quota
                if (task.chunk_task_kind == .remesh) {
                    self.remesh_count += 1;
                    // If we hit remesh quota, consider resetting on next generate
                } else {
                    // Reset remesh counter when processing generate tasks
                    if (self.remesh_count >= MAX_REMESH_PER_CYCLE) {
                        self.remesh_count = 0;
                    }
                }

                return task;
            }
        }

        return null;
    }

    /// Check if queue is empty (unlocked version for internal use)
    fn isEmptyUnlocked(self: *Self) bool {
        // Quick check: sum all bucket counts
        var total: u32 = 0;
        for (0..PRIORITY_BUCKETS) |i| {
            total += self.bucket_counts[i].load(.acquire);
        }
        return total == 0;
    }

    /// Check if queue is empty
    pub fn isEmpty(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.isEmptyUnlocked();
    }

    /// Get current length (sum of all bucket counts)
    pub fn len(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var total: usize = 0;
        for (0..PRIORITY_BUCKETS) |i| {
            total += self.bucket_counts[i].load(.acquire);
        }
        return total;
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

        // Set Tracy thread name for profiler visibility
        switch (ctx.id) {
            0 => profiler.setThreadName("ChunkWorker0"),
            1 => profiler.setThreadName("ChunkWorker1"),
            2 => profiler.setThreadName("ChunkWorker2"),
            3 => profiler.setThreadName("ChunkWorker3"),
            4 => profiler.setThreadName("ChunkWorker4"),
            5 => profiler.setThreadName("ChunkWorker5"),
            6 => profiler.setThreadName("ChunkWorker6"),
            7 => profiler.setThreadName("ChunkWorker7"),
            else => profiler.setThreadName("ChunkWorkerN"),
        }

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
