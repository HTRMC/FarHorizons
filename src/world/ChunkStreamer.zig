const std = @import("std");
const WorldState = @import("WorldState.zig");
const ChunkPool = @import("ChunkPool.zig").ChunkPool;
const Storage = @import("storage/Storage.zig");
const TerrainGen = @import("TerrainGen.zig");
const Chunk = WorldState.Chunk;
const Io = std.Io;

pub const ChunkStreamer = struct {
    const MAX_INPUT = 4096;
    pub const MAX_OUTPUT = 64;
    pub const RENDER_DISTANCE: i32 = 16;
    pub const UNLOAD_DISTANCE: i32 = RENDER_DISTANCE + 2;

    const ChunkKey = WorldState.ChunkKey;
    const Heap = std.PriorityQueue(ChunkKey, *ChunkStreamer, chunkDistCmp);
    const DedupSet = std.AutoHashMap(ChunkKey, void);

    // Input queue (main → worker) — min-heap by distance² to player
    input_heap: Heap,
    input_set: DedupSet,
    input_mutex: Io.Mutex,
    input_cond: Io.Condition,
    player_chunk: ChunkKey,

    // Output queue (worker → main)
    output_queue: [MAX_OUTPUT]LoadResult,
    output_len: u32,
    output_mutex: Io.Mutex,

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
            .allocator = allocator,
            .storage = storage,
            .chunk_pool = chunk_pool,
            .seed = seed,
            .thread = null,
            .shutdown = std.atomic.Value(bool).init(false),
        };
        // Re-set context pointer after self.* assignment overwrote it
        self.input_heap.context = self;
        // Pre-allocate to avoid runtime allocations on hot path
        self.input_heap.ensureTotalCapacity(allocator, MAX_INPUT) catch {};
        self.input_set.ensureTotalCapacity(@intCast(MAX_INPUT)) catch {};
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
        self.input_mutex.lockUncancelable(io);
        self.input_cond.broadcast(io);
        self.input_mutex.unlock(io);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
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
    pub fn syncPlayerChunk(self: *ChunkStreamer, pc: ChunkKey) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.input_mutex.lockUncancelable(io);
        self.player_chunk = pc;
        self.input_mutex.unlock(io);
    }

    /// Drain completed load results. Returns number of results copied to out_buf.
    pub fn drainOutput(self: *ChunkStreamer, out_buf: []LoadResult) u32 {
        const io = Io.Threaded.global_single_threaded.io();
        self.output_mutex.lockUncancelable(io);
        defer self.output_mutex.unlock(io);

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
            // 1. Pop one item from heap (closest chunk first)
            var key: ChunkKey = undefined;

            self.input_mutex.lockUncancelable(io);
            while (self.input_heap.count() == 0 and !self.shutdown.load(.acquire)) {
                self.input_cond.waitUncancelable(io, &self.input_mutex);
            }
            if (self.shutdown.load(.acquire)) {
                self.input_mutex.unlock(io);
                break;
            }
            key = self.input_heap.pop().?;
            _ = self.input_set.remove(key);
            self.input_mutex.unlock(io);

            // 2. Process the chunk
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

            // Push to output queue
            self.output_mutex.lockUncancelable(io);
            if (self.output_len < MAX_OUTPUT) {
                self.output_queue[self.output_len] = .{
                    .key = key,
                    .chunk = chunk,
                };
                self.output_len += 1;
            } else {
                // Output full — release chunk back to pool
                self.chunk_pool.release(chunk);
            }
            self.output_mutex.unlock(io);
        }
    }
};
