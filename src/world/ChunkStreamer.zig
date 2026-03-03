const std = @import("std");
const WorldState = @import("WorldState.zig");
const ChunkPool = @import("ChunkPool.zig").ChunkPool;
const Storage = @import("storage/Storage.zig");
const TerrainGen = @import("TerrainGen.zig");
const Chunk = WorldState.Chunk;
const Io = std.Io;

pub const ChunkStreamer = struct {
    const MAX_INPUT = 512;
    pub const MAX_OUTPUT = 64;
    pub const RENDER_DISTANCE: i32 = 6;
    pub const UNLOAD_DISTANCE: i32 = RENDER_DISTANCE + 2;

    // Input queue (main → worker)
    input_queue: [MAX_INPUT]WorldState.ChunkKey,
    input_len: u32,
    input_mutex: Io.Mutex,
    input_cond: Io.Condition,

    // Output queue (worker → main)
    output_queue: [MAX_OUTPUT]LoadResult,
    output_len: u32,
    output_mutex: Io.Mutex,

    // State
    storage: ?*Storage,
    chunk_pool: *ChunkPool,
    seed: u64,
    thread: ?std.Thread,
    shutdown: std.atomic.Value(bool),

    pub const LoadResult = struct {
        key: WorldState.ChunkKey,
        chunk: *Chunk,
    };

    pub fn initInPlace(
        self: *ChunkStreamer,
        storage: ?*Storage,
        chunk_pool: *ChunkPool,
        seed: u64,
    ) void {
        self.* = .{
            .input_queue = undefined,
            .input_len = 0,
            .input_mutex = .init,
            .input_cond = .init,
            .output_queue = undefined,
            .output_len = 0,
            .output_mutex = .init,
            .storage = storage,
            .chunk_pool = chunk_pool,
            .seed = seed,
            .thread = null,
            .shutdown = std.atomic.Value(bool).init(false),
        };
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
        self.input_cond.broadcast(io);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.output_len = 0;
    }

    /// Enqueue a single load request. Thread-safe, deduplicates.
    pub fn requestLoad(self: *ChunkStreamer, key: WorldState.ChunkKey) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.input_mutex.lockUncancelable(io);
        defer self.input_mutex.unlock(io);

        // Dedup
        for (self.input_queue[0..self.input_len]) |k| {
            if (k.eql(key)) return;
        }
        if (self.input_len < MAX_INPUT) {
            self.input_queue[self.input_len] = key;
            self.input_len += 1;
        }
        self.input_cond.signal(io);
    }

    /// Enqueue a batch of load requests. Thread-safe, deduplicates.
    pub fn requestLoadBatch(self: *ChunkStreamer, keys: []const WorldState.ChunkKey) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.input_mutex.lockUncancelable(io);
        defer self.input_mutex.unlock(io);

        for (keys) |key| {
            var found = false;
            for (self.input_queue[0..self.input_len]) |k| {
                if (k.eql(key)) {
                    found = true;
                    break;
                }
            }
            if (!found and self.input_len < MAX_INPUT) {
                self.input_queue[self.input_len] = key;
                self.input_len += 1;
            }
        }
        self.input_cond.signal(io);
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
        return self.input_len;
    }

    fn workerFn(self: *ChunkStreamer) void {
        const io = Io.Threaded.global_single_threaded.io();

        while (!self.shutdown.load(.acquire)) {
            // 1. Wait for input
            var local_keys: [MAX_INPUT]WorldState.ChunkKey = undefined;
            var local_count: u32 = 0;

            self.input_mutex.lockUncancelable(io);
            while (self.input_len == 0 and !self.shutdown.load(.acquire)) {
                self.input_cond.waitUncancelable(io, &self.input_mutex);
            }
            local_count = self.input_len;
            if (local_count > 0) {
                @memcpy(local_keys[0..local_count], self.input_queue[0..local_count]);
                self.input_len = 0;
            }
            self.input_mutex.unlock(io);

            if (self.shutdown.load(.acquire)) break;

            // 2. Process each key
            for (local_keys[0..local_count]) |key| {
                if (self.shutdown.load(.acquire)) break;

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
    }
};
