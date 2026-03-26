const std = @import("std");
const WorldState = @import("WorldState.zig");
const ChunkPool = @import("ChunkPool.zig").ChunkPool;
const Storage = @import("storage/Storage.zig");
const TerrainGen = @import("TerrainGen.zig");
const tracy = @import("../platform/tracy.zig");
const Chunk = WorldState.Chunk;
const ThreadPool = @import("../platform/ThreadPool.zig").ThreadPool;
const Io = std.Io;

pub const ChunkStreamer = struct {
    pub const MAX_OUTPUT = 512;
    pub const RENDER_DISTANCE: i32 = 16;
    pub const UNLOAD_DISTANCE: i32 = RENDER_DISTANCE + 2;

    const ChunkKey = WorldState.ChunkKey;

    // Output queue (worker → main)
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
    }

    pub fn stop(self: *ChunkStreamer) void {
        // Release any chunks still in the output queue
        for (self.output_queue[0..self.output_len]) |result| {
            self.chunk_pool.release(result.chunk);
        }
        self.output_len = 0;
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

    /// Process one chunk load task. Called by ThreadPool workers.
    /// Returns true if processed, false if output is full (caller should re-enqueue).
    pub fn processTask(self: *ChunkStreamer, key: ChunkKey) bool {
        const io = Io.Threaded.global_single_threaded.io();

        // Check output capacity before doing expensive work
        self.output_mutex.lockUncancelable(io);
        const output_full = self.output_len >= MAX_OUTPUT;
        self.output_mutex.unlock(io);
        if (output_full) return false;

        const tz = tracy.zone(@src(), "chunkStreamer.processTask");
        defer tz.end();

        // Skip stale chunks the player has moved away from
        const player_snapshot = if (self.pool) |p| p.player_chunk else ChunkKey{ .cx = 0, .cy = 0, .cz = 0 };
        const ud: i64 = UNLOAD_DISTANCE;
        if (distSq(key, player_snapshot) > ud * ud) {
            _ = self.stats_stale.fetchAdd(1, .monotonic);
            return true;
        }

        // Load from storage or generate
        const chunk = self.chunk_pool.acquire();
        var loaded = false;
        if (self.storage) |s| {
            if (s.loadChunkInto(key.cx, key.cy, key.cz, chunk)) {
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
            // Save to disk immediately so next join loads from cache
            if (self.storage) |s| {
                s.markDirty(key.cx, key.cy, key.cz, chunk);
            }
        }

        // Push to output queue
        self.output_mutex.lockUncancelable(io);
        if (self.output_len >= MAX_OUTPUT) {
            self.output_mutex.unlock(io);
            self.chunk_pool.release(chunk);
            _ = self.stats_output_waits.fetchAdd(1, .monotonic);
            return false;
        }
        self.output_queue[self.output_len] = .{ .key = key, .chunk = chunk };
        self.output_len += 1;
        self.output_mutex.unlock(io);

        return true;
    }
};
