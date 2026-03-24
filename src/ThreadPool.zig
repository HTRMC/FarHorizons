const std = @import("std");
const Io = std.Io;

pub const ThreadPool = struct {
    const MAX_THREADS = 32;
    const MAX_SOURCES = 8;

    pub const WorkSource = struct {
        ctx: *anyopaque,
        processOneFn: *const fn (ctx: *anyopaque) bool,
    };

    sources: [MAX_SOURCES]WorkSource,
    source_count: u32,

    threads: [MAX_THREADS]?std.Thread,
    thread_count: u32,
    shutdown: std.atomic.Value(bool),

    semaphore: Io.Semaphore,

    pub fn init(self: *ThreadPool) void {
        self.* = .{
            .sources = undefined,
            .source_count = 0,
            .threads = .{null} ** MAX_THREADS,
            .thread_count = 0,
            .shutdown = std.atomic.Value(bool).init(false),
            .semaphore = .{},
        };
    }

    pub fn addSource(self: *ThreadPool, source: WorkSource) void {
        std.debug.assert(self.source_count < MAX_SOURCES);
        self.sources[self.source_count] = source;
        self.source_count += 1;
    }

    pub fn start(self: *ThreadPool) void {
        const cpu_count = std.Thread.getCpuCount() catch 4;
        self.thread_count = @intCast(@min(MAX_THREADS, @max(4, cpu_count -| 1)));
        std.log.info("ThreadPool: {d} worker threads", .{self.thread_count});

        for (0..self.thread_count) |i| {
            self.threads[i] = std.Thread.spawn(
                .{ .stack_size = 4 * 1024 * 1024 },
                workerFn,
                .{self},
            ) catch |err| {
                std.log.err("ThreadPool: failed to spawn thread {d}: {}", .{ i, err });
                continue;
            };
        }
    }

    pub fn stop(self: *ThreadPool) void {
        self.shutdown.store(true, .release);
        const io = Io.Threaded.global_single_threaded.io();
        // Wake all workers so they can see the shutdown flag
        for (0..self.thread_count) |_| {
            self.semaphore.post(io);
        }
        for (0..self.thread_count) |i| {
            if (self.threads[i]) |t| {
                t.join();
                self.threads[i] = null;
            }
        }
    }

    /// Signal that work may be available. Call after enqueuing to a source.
    pub fn notify(self: *ThreadPool) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.semaphore.post(io);
    }

    /// Wake all workers. Use when multiple items are enqueued.
    pub fn notifyAll(self: *ThreadPool) void {
        const io = Io.Threaded.global_single_threaded.io();
        for (0..self.thread_count) |_| {
            self.semaphore.post(io);
        }
    }

    fn workerFn(self: *ThreadPool) void {
        const io = Io.Threaded.global_single_threaded.io();

        while (!self.shutdown.load(.acquire)) {
            var did_work = false;
            for (self.sources[0..self.source_count]) |source| {
                if (source.processOneFn(source.ctx)) {
                    did_work = true;
                    break;
                }
            }
            if (!did_work) {
                self.semaphore.waitUncancelable(io);
            }
        }
    }
};
