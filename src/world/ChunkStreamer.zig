const std = @import("std");
const WorldState = @import("WorldState.zig");
const ChunkPool = @import("ChunkPool.zig").ChunkPool;
const Storage = @import("storage/Storage.zig");
const TerrainGen = @import("TerrainGen.zig");
const Chunk = WorldState.Chunk;
const Io = std.Io;

pub const ChunkStreamer = struct {
    pub const MAX_OUTPUT = 64;
    pub const RENDER_DISTANCE: i32 = 16;
    pub const UNLOAD_DISTANCE: i32 = RENDER_DISTANCE + 2;

    // Pre-allocate for full sphere volume (4/3 π r³ ≈ 17157 at rd=16)
    const HEAP_CAPACITY = 18000;
    const WORKER_BATCH = 64;

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
    thread: ?std.Thread,
    shutdown: std.atomic.Value(bool),

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
            .thread = null,
            .shutdown = std.atomic.Value(bool).init(false),
        };
        // Re-set context pointer after self.* assignment overwrote it
        self.input_heap.context = self;
        // Pre-allocate for full sphere to avoid runtime allocations
        self.input_heap.ensureTotalCapacity(allocator, HEAP_CAPACITY) catch {};
        self.input_set.ensureTotalCapacity(@intCast(HEAP_CAPACITY)) catch {};
    }

    pub fn start(self: *ChunkStreamer) void {
        self.thread = std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, workerFn, .{self}) catch |err| {
            std.log.err("Failed to spawn chunk streamer thread: {}", .{err});
            return;
        };
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
        if (self.thread) |t| {
            t.join();
            self.thread = null;
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
        self.input_cond.signal(io);
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
                if (self.shutdown.load(.acquire)) break;

                // Skip stale chunks the player has moved away from
                if (distSq(key, player_snapshot) > ud_sq) continue;

                const chunk = self.chunk_pool.acquire();

                var loaded = false;
                if (self.storage) |s| {
                    if (s.loadChunk(key.cx, key.cy, key.cz, 0)) |cached_chunk| {
                        chunk.* = cached_chunk.*;
                        loaded = true;
                    }
                }

                if (!loaded) {
                    TerrainGen.generateChunk(chunk, key, self.seed);
                    // Save newly generated chunk to storage
                    if (self.storage) |s| {
                        s.saveChunk(key.cx, key.cy, key.cz, 0, chunk) catch {};
                    }
                }

                // Push to output queue — wait if full (backpressure)
                self.output_mutex.lockUncancelable(io);
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
