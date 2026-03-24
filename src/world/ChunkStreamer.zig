const std = @import("std");
const WorldState = @import("WorldState.zig");
const ChunkPool = @import("ChunkPool.zig").ChunkPool;
const Storage = @import("storage/Storage.zig");
const TerrainGen = @import("TerrainGen.zig");
const tracy = @import("../platform/tracy.zig");
const Chunk = WorldState.Chunk;
const ThreadPool = @import("../ThreadPool.zig").ThreadPool;
const Io = std.Io;

pub const ChunkStreamer = struct {
    pub const MAX_OUTPUT = 512;
    pub const RENDER_DISTANCE: i32 = 16;
    pub const UNLOAD_DISTANCE: i32 = RENDER_DISTANCE + 2;

    const HEAP_CAPACITY = 18000;

    const ChunkKey = WorldState.ChunkKey;
    const Heap = std.PriorityQueue(ChunkKey, *ChunkStreamer, chunkDistCmp);
    const DedupSet = std.AutoHashMap(ChunkKey, void);

    // Input queue — min-heap by distance² to player
    input_heap: Heap,
    input_set: DedupSet,
    input_mutex: Io.Mutex,
    player_chunk: ChunkKey,

    // Output queue (worker → main) with backpressure
    output_queue: [MAX_OUTPUT]LoadResult,
    output_len: u32,
    output_mutex: Io.Mutex,

    // State
    allocator: std.mem.Allocator,
    storage: ?*Storage,
    chunk_pool: *ChunkPool,
    seed: u64,
    world_type: WorldState.WorldType,
    pool: ?*ThreadPool,

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
            .player_chunk = .{ .cx = 0, .cy = 0, .cz = 0 },
            .output_queue = undefined,
            .output_len = 0,
            .output_mutex = .init,
            .allocator = allocator,
            .storage = storage,
            .chunk_pool = chunk_pool,
            .seed = seed,
            .world_type = world_type,
            .pool = null,
            .stats_loaded = std.atomic.Value(u64).init(0),
            .stats_generated = std.atomic.Value(u64).init(0),
            .stats_stale = std.atomic.Value(u64).init(0),
            .stats_output_waits = std.atomic.Value(u64).init(0),
        };
        self.input_heap.context = self;
        self.input_heap.ensureTotalCapacity(allocator, HEAP_CAPACITY) catch |err| {
            std.log.err("ChunkStreamer: failed to pre-allocate input heap: {}", .{err});
        };
        self.input_set.ensureTotalCapacity(@intCast(HEAP_CAPACITY)) catch |err| {
            std.log.err("ChunkStreamer: failed to pre-allocate input set: {}", .{err});
        };
    }

    pub fn stop(self: *ChunkStreamer) void {
        // Release any chunks still in the output queue
        for (self.output_queue[0..self.output_len]) |result| {
            self.chunk_pool.release(result.chunk);
        }
        self.output_len = 0;
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
        if (self.pool) |p| p.notify();
    }

    /// Enqueue a batch of load requests. Thread-safe, deduplicates.
    pub fn requestLoadBatch(self: *ChunkStreamer, keys: []const ChunkKey) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.input_mutex.lockUncancelable(io);
        defer self.input_mutex.unlock(io);

        var added: u32 = 0;
        for (keys) |key| {
            if (self.input_set.contains(key)) continue;
            self.input_set.put(key, {}) catch continue;
            self.input_heap.push(self.allocator, key) catch continue;
            added += 1;
        }
        if (added > 0) {
            if (self.pool) |p| p.notifyAll();
        }
    }

    /// Update player chunk for priority ordering. Thread-safe.
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

        const n = @min(self.output_len, @as(u32, @intCast(out_buf.len)));
        if (n > 0) {
            @memcpy(out_buf[0..n], self.output_queue[0..n]);
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
        self.output_mutex.unlock(io);
        // Wake pool workers that may have skipped due to full output
        if (n > 0) {
            if (self.pool) |p| p.notifyAll();
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

    /// Process one chunk load task. Called by ThreadPool workers.
    /// Returns true if work was found (even if skipped), false if no work available.
    pub fn processOne(self: *ChunkStreamer) bool {
        const io = Io.Threaded.global_single_threaded.io();

        // Check output capacity before doing expensive work
        self.output_mutex.lockUncancelable(io);
        const output_full = self.output_len >= MAX_OUTPUT;
        self.output_mutex.unlock(io);
        if (output_full) return false;

        // Pop one key from the input heap
        self.input_mutex.lockUncancelable(io);
        const key = self.input_heap.pop() orelse {
            self.input_mutex.unlock(io);
            return false;
        };
        _ = self.input_set.remove(key);
        const player_snapshot = self.player_chunk;
        self.input_mutex.unlock(io);

        const tz = tracy.zone(@src(), "chunkStreamer.processChunk");
        defer tz.end();

        // Skip stale chunks the player has moved away from
        const ud: i64 = UNLOAD_DISTANCE;
        if (distSq(key, player_snapshot) > ud * ud) {
            _ = self.stats_stale.fetchAdd(1, .monotonic);
            return true;
        }

        // Load from storage or generate
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

        // Push to output queue
        self.output_mutex.lockUncancelable(io);
        if (self.output_len >= MAX_OUTPUT) {
            // Output became full between check and push — drop
            self.output_mutex.unlock(io);
            self.chunk_pool.release(chunk);
            _ = self.stats_output_waits.fetchAdd(1, .monotonic);
            return true;
        }
        self.output_queue[self.output_len] = .{ .key = key, .chunk = chunk };
        self.output_len += 1;
        self.output_mutex.unlock(io);

        return true;
    }

    fn processOneErased(ctx: *anyopaque) bool {
        const self: *ChunkStreamer = @ptrCast(@alignCast(ctx));
        return self.processOne();
    }

    pub fn workSource(self: *ChunkStreamer) ThreadPool.WorkSource {
        return .{
            .ctx = @ptrCast(self),
            .processOneFn = processOneErased,
        };
    }
};
