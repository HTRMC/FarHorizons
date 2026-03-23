const std = @import("std");
const WorldState = @import("WorldState.zig");
const ChunkPool = @import("ChunkPool.zig").ChunkPool;
const Storage = @import("storage/Storage.zig");
const TerrainGen = @import("TerrainGen.zig");
const tracy = @import("../platform/tracy.zig");
const Chunk = WorldState.Chunk;
const Io = std.Io;

pub const ChunkStreamer = struct {
    pub const MAX_OUTPUT = 512;
    pub const RENDER_DISTANCE: i32 = 16;
    pub const UNLOAD_DISTANCE: i32 = RENDER_DISTANCE + 2;

    // Pre-allocate for full sphere volume (4/3 π r³ ≈ 17157 at rd=16)
    const HEAP_CAPACITY = 18000;
    const WORKER_BATCH = 16;
    const MAX_WORKERS = 12;

    const ChunkKey = WorldState.ChunkKey;
    const Heap = std.PriorityQueue(ChunkKey, *ChunkStreamer, chunkDistCmp);
    const DedupSet = std.AutoHashMap(ChunkKey, void);

    // Input queue (main → worker) — min-heap by distance² to player
    input_heap: Heap,
    input_set: DedupSet,
    input_mutex: Io.Mutex,
    input_cond: Io.Condition,
    player_chunk: ChunkKey,

    // Output queue (worker → main) with backpressure
    output_queue: [MAX_OUTPUT]LoadResult,
    output_len: u32,
    output_mutex: Io.Mutex,
    output_drained_cond: Io.Condition,

    // State
    allocator: std.mem.Allocator,
    storage: ?*Storage,
    chunk_pool: *ChunkPool,
    seed: u64,
    world_type: WorldState.WorldType,
    threads: [MAX_WORKERS]?std.Thread,
    worker_count: u32,
    shutdown: std.atomic.Value(bool),

    // Pipeline stats (atomically updated by workers)
    stats_loaded: std.atomic.Value(u64),
    stats_generated: std.atomic.Value(u64),
    stats_stale: std.atomic.Value(u64),
    stats_output_waits: std.atomic.Value(u64),

    pub const LoadResult = struct {
        key: ChunkKey,
        chunk: *Chunk,
    };

    fn chunkDistCmp(self: *ChunkStreamer, a: ChunkKey, b: ChunkKey) std.math.Order {
        const pc = self.player_chunk;
        const da = distSq(a, pc);
        const db = distSq(b, pc);
        return std.math.order(da, db);
    }

    fn distSq(a: ChunkKey, b: ChunkKey) i64 {
        const dx: i64 = a.cx - b.cx;
        const dy: i64 = a.cy - b.cy;
        const dz: i64 = a.cz - b.cz;
        return dx * dx + dy * dy + dz * dz;
    }

    pub fn initInPlace(
        self: *ChunkStreamer,
        allocator: std.mem.Allocator,
        storage: ?*Storage,
        chunk_pool: *ChunkPool,
        seed: u64,
        world_type: WorldState.WorldType,
    ) void {
        self.* = .{
            .input_heap = Heap.initContext(self),
            .input_set = DedupSet.init(allocator),
            .input_mutex = .init,
            .input_cond = .init,
            .player_chunk = .{ .cx = 0, .cy = 0, .cz = 0 },
            .output_queue = undefined,
            .output_len = 0,
            .output_mutex = .init,
            .output_drained_cond = .init,
            .allocator = allocator,
            .storage = storage,
            .chunk_pool = chunk_pool,
            .seed = seed,
            .world_type = world_type,
            .threads = .{null} ** MAX_WORKERS,
            .worker_count = 0,
            .shutdown = std.atomic.Value(bool).init(false),
            .stats_loaded = std.atomic.Value(u64).init(0),
            .stats_generated = std.atomic.Value(u64).init(0),
            .stats_stale = std.atomic.Value(u64).init(0),
            .stats_output_waits = std.atomic.Value(u64).init(0),
        };
        // Re-set context pointer after self.* assignment overwrote it
        self.input_heap.context = self;
        // Pre-allocate for full sphere to avoid runtime allocations
        self.input_heap.ensureTotalCapacity(allocator, HEAP_CAPACITY) catch |err| {
            std.log.err("ChunkStreamer: failed to pre-allocate input heap: {}", .{err});
        };
        self.input_set.ensureTotalCapacity(@intCast(HEAP_CAPACITY)) catch |err| {
            std.log.err("ChunkStreamer: failed to pre-allocate input set: {}", .{err});
        };
    }

    pub fn start(self: *ChunkStreamer) void {
        const cpu_count = std.Thread.getCpuCount() catch 2;
        // Use ~1/8 of logical cores for streaming (I/O-bound), min 2
        self.worker_count = @intCast(@min(MAX_WORKERS, @max(2, cpu_count / 8)));
        std.log.info("ChunkStreamer: {d} worker threads", .{self.worker_count});

        for (0..self.worker_count) |i| {
            self.threads[i] = std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, workerFn, .{self}) catch |err| {
                std.log.err("Failed to spawn chunk streamer thread {d}: {}", .{ i, err });
                continue;
            };
        }
    }

    pub fn stop(self: *ChunkStreamer) void {
        self.shutdown.store(true, .release);
        const io = Io.Threaded.global_single_threaded.io();
        // Wake worker if blocked on input or output backpressure
        self.input_mutex.lockUncancelable(io);
        self.input_cond.broadcast(io);
        self.input_mutex.unlock(io);
        self.output_mutex.lockUncancelable(io);
        self.output_drained_cond.broadcast(io);
        self.output_mutex.unlock(io);
        for (0..self.worker_count) |i| {
            if (self.threads[i]) |t| {
                t.join();
                self.threads[i] = null;
            }
        }
        // Release any chunks still in the output queue
        for (self.output_queue[0..self.output_len]) |result| {
            self.chunk_pool.release(result.chunk);
        }
        self.output_len = 0;
        // Free heap/set memory
        self.input_heap.deinit(self.allocator);
        self.input_set.deinit();
    }

    /// Enqueue a single load request. Thread-safe, deduplicates.
    pub fn requestLoad(self: *ChunkStreamer, key: ChunkKey) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.input_mutex.lockUncancelable(io);
        defer self.input_mutex.unlock(io);

        if (self.input_set.contains(key)) return;
        self.input_set.put(key, {}) catch return;
        self.input_heap.push(self.allocator, key) catch return;
        self.input_cond.signal(io);
    }

    /// Enqueue a batch of load requests. Thread-safe, deduplicates.
    pub fn requestLoadBatch(self: *ChunkStreamer, keys: []const ChunkKey) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.input_mutex.lockUncancelable(io);
        defer self.input_mutex.unlock(io);

        for (keys) |key| {
            if (self.input_set.contains(key)) continue;
            self.input_set.put(key, {}) catch continue;
            self.input_heap.push(self.allocator, key) catch continue;
        }
        self.input_cond.broadcast(io);
    }

    /// Update player chunk for priority ordering. Thread-safe.
    /// Re-heapifies the input queue when player moves to a different chunk
    /// so that distance-based priority reflects the new position.
    pub fn syncPlayerChunk(self: *ChunkStreamer, pc: ChunkKey) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.input_mutex.lockUncancelable(io);
        const old = self.player_chunk;
        self.player_chunk = pc;
        if (!old.eql(pc)) self.reheapify();
        self.input_mutex.unlock(io);
    }

    /// Floyd's bottom-up heapify — O(n), in-place. Caller must hold input_mutex.
    fn reheapify(self: *ChunkStreamer) void {
        const items = self.input_heap.items;
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
                if (right < items.len and chunkDistCmp(self, items[right], items[child]) == .lt) {
                    child = right;
                }
                if (chunkDistCmp(self, target, items[child]) == .lt) break;
                items[idx] = items[child];
                idx = child;
            }
            items[idx] = target;
        }
    }

    /// Drain completed load results. Returns number of results copied to out_buf.
    pub fn drainOutput(self: *ChunkStreamer, out_buf: []LoadResult) u32 {
        const io = Io.Threaded.global_single_threaded.io();
        self.output_mutex.lockUncancelable(io);
        defer {
            self.output_drained_cond.signal(io);
            self.output_mutex.unlock(io);
        }

        const n = @min(self.output_len, @as(u32, @intCast(out_buf.len)));
        if (n > 0) {
            @memcpy(out_buf[0..n], self.output_queue[0..n]);
            // Shift remaining
            const remaining = self.output_len - n;
            if (remaining > 0) {
                std.mem.copyForwards(
                    LoadResult,
                    self.output_queue[0..remaining],
                    self.output_queue[n..self.output_len],
                );
            }
            self.output_len = remaining;
        }
        return n;
    }

    /// Current input queue depth (for debug display).
    pub fn inputQueueDepth(self: *ChunkStreamer) u32 {
        const io = Io.Threaded.global_single_threaded.io();
        self.input_mutex.lockUncancelable(io);
        defer self.input_mutex.unlock(io);
        return @intCast(self.input_heap.count());
    }

    fn workerFn(self: *ChunkStreamer) void {
        const io = Io.Threaded.global_single_threaded.io();

        while (!self.shutdown.load(.acquire)) {
            // 1. Drain a batch from the heap (closest chunks first)
            var local_keys: [WORKER_BATCH]ChunkKey = undefined;
            var local_count: u32 = 0;

            self.input_mutex.lockUncancelable(io);
            while (self.input_heap.count() == 0 and !self.shutdown.load(.acquire)) {
                self.input_cond.waitUncancelable(io, &self.input_mutex);
            }
            if (self.shutdown.load(.acquire)) {
                self.input_mutex.unlock(io);
                break;
            }
            while (local_count < WORKER_BATCH) {
                const key = self.input_heap.pop() orelse break;
                _ = self.input_set.remove(key);
                local_keys[local_count] = key;
                local_count += 1;
            }
            const player_snapshot = self.player_chunk;
            self.input_mutex.unlock(io);

            // 2. Process the batch
            const ud: i64 = UNLOAD_DISTANCE;
            const ud_sq = ud * ud;
            for (local_keys[0..local_count]) |key| {
                const tz = tracy.zone(@src(), "chunkStreamer.processChunk");
                defer tz.end();

                if (self.shutdown.load(.acquire)) break;

                // Skip stale chunks the player has moved away from
                if (distSq(key, player_snapshot) > ud_sq) {
                    _ = self.stats_stale.fetchAdd(1, .monotonic);
                    continue;
                }

                const chunk = self.chunk_pool.acquire();

                var loaded = false;
                if (self.storage) |s| {
                    if (s.loadChunk(key.cx, key.cy, key.cz)) |cached_chunk| {
                        chunk.* = cached_chunk.*;
                        loaded = true;
                        _ = self.stats_loaded.fetchAdd(1, .monotonic);
                    }
                }

                if (!loaded) {
                    switch (self.world_type) {
                        .normal => TerrainGen.generateChunk(chunk, key, self.seed),
                        .debug => WorldState.generateDebugChunk(chunk, key),
                    }
                    _ = self.stats_generated.fetchAdd(1, .monotonic);
                }

                // Push to output queue — wait if full (backpressure)
                self.output_mutex.lockUncancelable(io);
                if (self.output_len >= MAX_OUTPUT) _ = self.stats_output_waits.fetchAdd(1, .monotonic);
                while (self.output_len >= MAX_OUTPUT and !self.shutdown.load(.acquire)) {
                    self.output_drained_cond.waitUncancelable(io, &self.output_mutex);
                }
                if (self.shutdown.load(.acquire)) {
                    self.output_mutex.unlock(io);
                    self.chunk_pool.release(chunk);
                    break;
                }
                self.output_queue[self.output_len] = .{
                    .key = key,
                    .chunk = chunk,
                };
                self.output_len += 1;
                self.output_mutex.unlock(io);
            }
        }
    }
};
