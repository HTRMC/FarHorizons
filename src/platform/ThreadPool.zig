const std = @import("std");
const WorldState = @import("../world/WorldState.zig");
const Io = std.Io;

pub const ThreadPool = struct {
    const MAX_THREADS = 32;
    const HEAP_CAPACITY = 20000;

    const ChunkKey = WorldState.ChunkKey;

    pub const TaskKind = enum(u3) {
        chunk_load,
        light,
        mesh,
        mesh_light_only,
    };

    pub const Task = struct {
        key: ChunkKey,
        kind: TaskKind,
    };

    const Heap = std.PriorityQueue(Task, *ThreadPool, taskDistCmp);
    const LoadDedup = std.AutoHashMap(ChunkKey, void);
    const MeshDedup = std.AutoHashMap(ChunkKey, bool); // value = light_only

    // Single priority heap + dedup
    heap: Heap,
    load_dedup: LoadDedup,
    light_dedup: LoadDedup,
    mesh_dedup: MeshDedup,
    heap_mutex: Io.Mutex,
    player_chunk: ChunkKey,

    // Processing targets (set before start)
    streamer: ?*@import("../world/ChunkStreamer.zig").ChunkStreamer,
    mesh_worker: ?*@import("../world/MeshWorker.zig").MeshWorker,

    // Thread management
    threads: [MAX_THREADS]?std.Thread,
    thread_count: u32,
    shutdown: std.atomic.Value(bool),
    semaphore: Io.Semaphore,
    allocator: std.mem.Allocator,

    // Task count tracking (for stats display)
    load_task_count: std.atomic.Value(u32),
    mesh_task_count: std.atomic.Value(u32),

    fn taskDistCmp(self: *ThreadPool, a: Task, b: Task) std.math.Order {
        const pc = self.player_chunk;
        return std.math.order(distSq(a.key, pc), distSq(b.key, pc));
    }

    fn distSq(a: ChunkKey, b: ChunkKey) i64 {
        const dx: i64 = a.cx - b.cx;
        const dy: i64 = a.cy - b.cy;
        const dz: i64 = a.cz - b.cz;
        return dx * dx + dy * dy + dz * dz;
    }

    pub fn init(self: *ThreadPool, allocator: std.mem.Allocator) void {
        self.* = .{
            .heap = Heap.initContext(self),
            .load_dedup = LoadDedup.init(allocator),
            .light_dedup = LoadDedup.init(allocator),
            .mesh_dedup = MeshDedup.init(allocator),
            .heap_mutex = .init,
            .player_chunk = .{ .cx = 0, .cy = 0, .cz = 0 },
            .streamer = null,
            .mesh_worker = null,
            .threads = .{null} ** MAX_THREADS,
            .thread_count = 0,
            .shutdown = std.atomic.Value(bool).init(false),
            .semaphore = .{},
            .allocator = allocator,
            .load_task_count = std.atomic.Value(u32).init(0),
            .mesh_task_count = std.atomic.Value(u32).init(0),
        };
        self.heap.context = self;
        self.heap.ensureTotalCapacity(allocator, HEAP_CAPACITY) catch {};
        self.load_dedup.ensureTotalCapacity(@intCast(HEAP_CAPACITY)) catch {};
        self.light_dedup.ensureTotalCapacity(@intCast(HEAP_CAPACITY)) catch {};
        self.mesh_dedup.ensureTotalCapacity(@intCast(HEAP_CAPACITY)) catch {};
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
        const tracy = @import("tracy.zig");
        self.shutdown.store(true, .release);
        const io = Io.Threaded.global_single_threaded.io();
        for (0..self.thread_count) |_| {
            self.semaphore.post(io);
        }
        {
            const tz = tracy.zone(@src(), "ThreadPool.joinAll");
            defer tz.end();
            for (0..self.thread_count) |i| {
                if (self.threads[i]) |t| {
                    t.join();
                    self.threads[i] = null;
                }
            }
        }
        self.heap.deinit(self.allocator);
        self.load_dedup.deinit();
        self.light_dedup.deinit();
        self.mesh_dedup.deinit();
    }

    // ── Submit methods ────────────────────────────────────────────

    pub fn submitChunkLoad(self: *ThreadPool, key: ChunkKey) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.heap_mutex.lockUncancelable(io);
        defer self.heap_mutex.unlock(io);

        if (self.load_dedup.contains(key)) return;
        self.load_dedup.put(key, {}) catch return;
        self.heap.push(self.allocator, .{ .key = key, .kind = .chunk_load }) catch {
            _ = self.load_dedup.remove(key);
            return;
        };
        _ = self.load_task_count.fetchAdd(1, .monotonic);
        self.semaphore.post(io);
    }

    pub fn submitChunkLoadBatch(self: *ThreadPool, keys: []const ChunkKey) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.heap_mutex.lockUncancelable(io);
        defer self.heap_mutex.unlock(io);

        var added: u32 = 0;
        for (keys) |key| {
            if (self.load_dedup.contains(key)) continue;
            self.load_dedup.put(key, {}) catch continue;
            self.heap.push(self.allocator, .{ .key = key, .kind = .chunk_load }) catch {
                _ = self.load_dedup.remove(key);
                continue;
            };
            added += 1;
        }
        if (added > 0) {
            _ = self.load_task_count.fetchAdd(added, .monotonic);
            for (0..@min(added, self.thread_count)) |_| {
                self.semaphore.post(io);
            }
        }
    }

    pub fn submitLight(self: *ThreadPool, key: ChunkKey) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.heap_mutex.lockUncancelable(io);
        defer self.heap_mutex.unlock(io);

        if (self.light_dedup.contains(key)) return;
        self.light_dedup.put(key, {}) catch return;
        self.heap.push(self.allocator, .{ .key = key, .kind = .light }) catch {
            _ = self.light_dedup.remove(key);
            return;
        };
        _ = self.mesh_task_count.fetchAdd(1, .monotonic);
        self.semaphore.post(io);
    }

    pub fn submitLightBatch(self: *ThreadPool, keys: []const ChunkKey) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.heap_mutex.lockUncancelable(io);
        defer self.heap_mutex.unlock(io);

        var added: u32 = 0;
        for (keys) |key| {
            if (self.light_dedup.contains(key)) continue;
            self.light_dedup.put(key, {}) catch continue;
            self.heap.push(self.allocator, .{ .key = key, .kind = .light }) catch {
                _ = self.light_dedup.remove(key);
                continue;
            };
            added += 1;
        }
        if (added > 0) {
            _ = self.mesh_task_count.fetchAdd(added, .monotonic);
            for (0..@min(added, self.thread_count)) |_| {
                self.semaphore.post(io);
            }
        }
    }

    pub fn submitMesh(self: *ThreadPool, key: ChunkKey) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.heap_mutex.lockUncancelable(io);
        defer self.heap_mutex.unlock(io);

        if (self.mesh_dedup.getPtr(key)) |existing| {
            // Upgrade light-only to full mesh
            if (existing.*) existing.* = false;
            return;
        }
        self.mesh_dedup.put(key, false) catch return;
        self.heap.push(self.allocator, .{ .key = key, .kind = .mesh }) catch {
            _ = self.mesh_dedup.remove(key);
            return;
        };
        _ = self.mesh_task_count.fetchAdd(1, .monotonic);
        self.semaphore.post(io);
    }

    pub fn submitMeshBatch(self: *ThreadPool, keys: []const ChunkKey) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.heap_mutex.lockUncancelable(io);
        defer self.heap_mutex.unlock(io);

        var added: u32 = 0;
        for (keys) |key| {
            if (self.mesh_dedup.getPtr(key)) |existing| {
                if (existing.*) existing.* = false;
                continue;
            }
            self.mesh_dedup.put(key, false) catch continue;
            self.heap.push(self.allocator, .{ .key = key, .kind = .mesh }) catch {
                _ = self.mesh_dedup.remove(key);
                continue;
            };
            added += 1;
        }
        if (added > 0) {
            _ = self.mesh_task_count.fetchAdd(added, .monotonic);
            for (0..@min(added, self.thread_count)) |_| {
                self.semaphore.post(io);
            }
        }
    }

    pub fn submitMeshLightOnlyBatch(self: *ThreadPool, keys: []const ChunkKey) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.heap_mutex.lockUncancelable(io);
        defer self.heap_mutex.unlock(io);

        var added: u32 = 0;
        for (keys) |key| {
            if (self.mesh_dedup.contains(key)) continue;
            self.mesh_dedup.put(key, true) catch continue;
            self.heap.push(self.allocator, .{ .key = key, .kind = .mesh_light_only }) catch {
                _ = self.mesh_dedup.remove(key);
                continue;
            };
            added += 1;
        }
        if (added > 0) {
            _ = self.mesh_task_count.fetchAdd(added, .monotonic);
            for (0..@min(added, self.thread_count)) |_| {
                self.semaphore.post(io);
            }
        }
    }

    // ── Player position ───────────────────────────────────────────

    pub fn syncPlayerChunk(self: *ThreadPool, pc: ChunkKey) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.heap_mutex.lockUncancelable(io);
        const old = self.player_chunk;
        self.player_chunk = pc;
        if (!old.eql(pc)) self.reheapify();
        self.heap_mutex.unlock(io);
    }

    fn reheapify(self: *ThreadPool) void {
        const items = self.heap.items;
        if (items.len <= 1) return;
        var i = items.len >> 1;
        while (i > 0) {
            i -= 1;
            const target = items[i];
            var idx = i;
            while (true) {
                var child = (std.math.mul(usize, idx, 2) catch break) | 1;
                if (child >= items.len) break;
                const right = child + 1;
                if (right < items.len and taskDistCmp(self, items[right], items[child]) == .lt) {
                    child = right;
                }
                if (taskDistCmp(self, target, items[child]) == .lt) break;
                items[idx] = items[child];
                idx = child;
            }
            items[idx] = target;
        }
    }

    // ── Notify (call when output queue is drained) ────────────────

    pub fn notify(self: *ThreadPool) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.semaphore.post(io);
    }

    pub fn notifyAll(self: *ThreadPool) void {
        const io = Io.Threaded.global_single_threaded.io();
        for (0..self.thread_count) |_| {
            self.semaphore.post(io);
        }
    }

    // ── Stats ─────────────────────────────────────────────────────

    pub fn loadQueueDepth(self: *const ThreadPool) u32 {
        return self.load_task_count.load(.monotonic);
    }

    pub fn meshQueueDepth(self: *const ThreadPool) u32 {
        return self.mesh_task_count.load(.monotonic);
    }

    // ── Internal ──────────────────────────────────────────────────

    fn popTask(self: *ThreadPool, io: Io) ?Task {
        self.heap_mutex.lockUncancelable(io);
        defer self.heap_mutex.unlock(io);

        // Pop entries, skipping stale ones (already processed)
        while (self.heap.pop()) |task| {
            switch (task.kind) {
                .chunk_load => {
                    if (self.load_dedup.remove(task.key)) {
                        _ = self.load_task_count.fetchSub(1, .monotonic);
                        return task;
                    }
                },
                .light => {
                    if (self.light_dedup.remove(task.key)) {
                        _ = self.mesh_task_count.fetchSub(1, .monotonic);
                        return task;
                    }
                },
                .mesh, .mesh_light_only => {
                    if (self.mesh_dedup.fetchRemove(task.key)) |entry| {
                        _ = self.mesh_task_count.fetchSub(1, .monotonic);
                        const actual_kind: TaskKind = if (entry.value) .mesh_light_only else .mesh;
                        return .{ .key = task.key, .kind = actual_kind };
                    }
                },
            }
        }
        return null;
    }

    fn workerFn(self: *ThreadPool) void {
        const io = Io.Threaded.global_single_threaded.io();

        while (!self.shutdown.load(.acquire)) {
            const task = self.popTask(io) orelse {
                self.semaphore.waitUncancelable(io);
                continue;
            };

            const processed = switch (task.kind) {
                .chunk_load => if (self.streamer) |s| s.processTask(task.key) else true,
                .light => if (self.mesh_worker) |mw| mw.processLightTask(task.key) else true,
                .mesh => if (self.mesh_worker) |mw| mw.processTask(task.key, false) else true,
                .mesh_light_only => if (self.mesh_worker) |mw| mw.processTask(task.key, true) else true,
            };

            if (!processed) {
                // Output was full — re-enqueue and wait for drain
                switch (task.kind) {
                    .chunk_load => self.submitChunkLoad(task.key),
                    .light => self.submitLight(task.key),
                    .mesh => self.submitMesh(task.key),
                    .mesh_light_only => self.submitMeshLightOnlyBatch(&.{task.key}),
                }
                self.semaphore.waitUncancelable(io);
            }
        }
    }
};
