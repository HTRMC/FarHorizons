/// ThreadPool - Worker thread management for async chunk operations
const std = @import("std");
const shared = @import("Shared");
const Logger = shared.Logger;

/// Task types that workers can process
pub const TaskType = enum {
    generate_and_mesh,
    shutdown,
};

/// A task for the worker threads
pub const Task = struct {
    task_type: TaskType,
    /// Opaque pointer to task-specific data
    data: ?*anyopaque = null,
};

/// Thread-safe task queue
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
    task_queue: ThreadSafeQueue(Task),
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

        logger.info("Initializing thread pool with {} workers", .{worker_count});

        return Self{
            .allocator = allocator,
            .workers = try allocator.alloc(std.Thread, worker_count),
            .contexts = try allocator.alloc(WorkerContext, worker_count),
            .task_queue = ThreadSafeQueue(Task).init(allocator),
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
