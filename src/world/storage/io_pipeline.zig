const std = @import("std");
const storage_types = @import("types.zig");
const RegionFile = @import("region_file.zig").RegionFile;
const RegionCache = @import("region_cache.zig").RegionCache;
const ChunkCache = @import("chunk_cache.zig").ChunkCache;
const chunk_codec = @import("chunk_codec.zig");
const compression = @import("compression.zig");
const WorldState = @import("../WorldState.zig");
const dirty_set_mod = @import("dirty_set.zig");

const ChunkKey = storage_types.ChunkKey;
const RegionCoord = storage_types.RegionCoord;
const Priority = storage_types.Priority;
const AsyncHandle = storage_types.AsyncHandle;
const CompressionAlgo = storage_types.CompressionAlgo;
const Chunk = WorldState.Chunk;
const Io = std.Io;

const log = std.log.scoped(.io_pipeline);

const MAX_QUEUE_SIZE = 1024;
const MAX_WORKERS = 4;

pub const IoPipeline = struct {
    queue: [MAX_QUEUE_SIZE]Request,
    queue_len: u32,
    queue_mutex: Io.Mutex,
    queue_cond: Io.Condition,

    results: [MAX_QUEUE_SIZE]RequestResult,
    results_len: u32,
    results_mutex: Io.Mutex,

    workers: [MAX_WORKERS]?std.Thread,
    worker_count: u32,
    shutdown: std.atomic.Value(bool),

    region_cache: *RegionCache,
    chunk_cache: *ChunkCache,
    default_compression: CompressionAlgo,

    next_handle_id: u32,
    io: Io,

    pub const Request = struct {
        kind: Kind,
        key: ChunkKey,
        priority: Priority,
        handle_id: u32,
        chunk_data: ?*const Chunk,
        batch: ?*BatchSaveData,

        const Kind = enum { load, save, batch_save };
    };

    pub const RequestResult = struct {
        handle_id: u32,
        key: ChunkKey,
        success: bool,
    };

    pub const BatchSaveData = struct {
        region_coord: RegionCoord,
        count: u32,
        indices: [MAX_BATCH_SIZE]u9,
        chunks: [MAX_BATCH_SIZE]*Chunk,
        keys: [MAX_BATCH_SIZE]ChunkKey,
        allocator: std.mem.Allocator,

        pub const MAX_BATCH_SIZE = dirty_set_mod.MAX_BATCH_SIZE;

        pub fn deinit(self: *BatchSaveData) void {
            for (self.chunks[0..self.count]) |chunk_ptr| {
                self.allocator.destroy(chunk_ptr);
            }
            self.allocator.destroy(self);
        }
    };

    pub fn initInPlace(
        self: *IoPipeline,
        region_cache: *RegionCache,
        chunk_cache: *ChunkCache,
        default_compression: CompressionAlgo,
    ) void {
        self.queue_len = 0;
        self.queue_mutex = .init;
        self.queue_cond = .init;
        self.results_len = 0;
        self.results_mutex = .init;
        self.workers = [_]?std.Thread{null} ** MAX_WORKERS;
        self.worker_count = 0;
        self.shutdown = std.atomic.Value(bool).init(false);
        self.region_cache = region_cache;
        self.chunk_cache = chunk_cache;
        self.default_compression = default_compression;
        self.next_handle_id = 0;
        self.io = Io.Threaded.global_single_threaded.io();
    }

    pub fn start(self: *IoPipeline) void {
        const cpu_count = std.Thread.getCpuCount() catch 2;
        self.worker_count = @intCast(@min(MAX_WORKERS, cpu_count));

        for (0..self.worker_count) |i| {
            self.workers[i] = std.Thread.spawn(.{}, workerFn, .{self}) catch |err| {
                log.err("Failed to spawn I/O worker {d}: {}", .{ i, err });
                continue;
            };
        }
    }

    pub fn stop(self: *IoPipeline) void {
        self.shutdown.store(true, .release);

        self.queue_mutex.lockUncancelable(self.io);
        self.queue_cond.broadcast(self.io);
        self.queue_mutex.unlock(self.io);

        for (&self.workers) |*w| {
            if (w.*) |thread| {
                thread.join();
                w.* = null;
            }
        }
    }

    pub fn requestLoad(self: *IoPipeline, key: ChunkKey, priority: Priority) AsyncHandle {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);

        if (self.queue_len >= MAX_QUEUE_SIZE) {
            log.warn("I/O queue full, dropping load request", .{});
            return AsyncHandle.invalid;
        }

        const handle_id = self.next_handle_id;
        self.next_handle_id +%= 1;

        const insert_idx = self.findInsertIndex(priority);
        if (insert_idx < self.queue_len) {
            var i = self.queue_len;
            while (i > insert_idx) : (i -= 1) {
                self.queue[i] = self.queue[i - 1];
            }
        }

        self.queue[insert_idx] = .{
            .kind = .load,
            .key = key,
            .priority = priority,
            .handle_id = handle_id,
            .chunk_data = null,
            .batch = null,
        };
        self.queue_len += 1;

        self.queue_cond.signal(self.io);
        return .{ .id = handle_id };
    }

    pub fn submitBatchSave(self: *IoPipeline, batch: *BatchSaveData) void {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);

        if (self.queue_len >= MAX_QUEUE_SIZE) {
            log.warn("I/O queue full, batch save deferred", .{});
            batch.deinit();
            return;
        }

        const handle_id = self.next_handle_id;
        self.next_handle_id +%= 1;

        self.queue[self.queue_len] = .{
            .kind = .batch_save,
            .key = ChunkKey.init(0, 0, 0, 0),
            .priority = .save,
            .handle_id = handle_id,
            .chunk_data = null,
            .batch = batch,
        };
        self.queue_len += 1;

        self.queue_cond.signal(self.io);
    }

    pub fn getLoadQueueDepth(self: *IoPipeline) u32 {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);

        var load_count: u32 = 0;
        for (self.queue[0..self.queue_len]) |req| {
            if (req.kind == .load) load_count += 1;
        }
        return load_count;
    }

    pub fn pollLoad(self: *IoPipeline, handle: AsyncHandle) ?bool {
        self.results_mutex.lockUncancelable(self.io);
        defer self.results_mutex.unlock(self.io);

        for (0..self.results_len) |i| {
            if (self.results[i].handle_id == handle.id) {
                const success = self.results[i].success;
                self.results_len -= 1;
                if (i < self.results_len) {
                    self.results[i] = self.results[self.results_len];
                }
                return success;
            }
        }
        return null;
    }

    fn findInsertIndex(self: *const IoPipeline, priority: Priority) u32 {
        const pval = @intFromEnum(priority);
        for (0..self.queue_len) |i| {
            if (@intFromEnum(self.queue[i].priority) > pval) {
                return @intCast(i);
            }
        }
        return self.queue_len;
    }

    fn workerFn(self: *IoPipeline) void {
        while (true) {
            const request = self.dequeue() orelse return;

            switch (request.kind) {
                .load => self.executeLoad(request),
                .save => self.executeSave(request),
                .batch_save => self.executeBatchSave(request),
            }
        }
    }

    fn dequeue(self: *IoPipeline) ?Request {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);

        while (self.queue_len == 0) {
            if (self.shutdown.load(.acquire)) return null;
            self.queue_cond.waitUncancelable(self.io, &self.queue_mutex);
        }

        const request = self.queue[0];
        self.queue_len -= 1;
        if (self.queue_len > 0) {
            for (0..self.queue_len) |i| {
                self.queue[i] = self.queue[i + 1];
            }
        }
        return request;
    }

    fn executeLoad(self: *IoPipeline, request: Request) void {
        const key = request.key;
        const coord = key.regionCoord();
        const region = self.region_cache.getOrOpen(coord) catch {
            self.postResult(request.handle_id, key, false);
            return;
        };
        defer self.region_cache.releaseRegion(region);

        const chunk_index = key.localIndex();
        var chunk: Chunk = undefined;
        const found = region.readChunk(chunk_index, &chunk.blocks) catch {
            self.postResult(request.handle_id, key, false);
            return;
        };

        if (found) {
            self.chunk_cache.put(key, &chunk);
            self.postResult(request.handle_id, key, true);
        } else {
            self.postResult(request.handle_id, key, false);
        }
    }

    fn executeSave(self: *IoPipeline, request: Request) void {
        const key = request.key;
        const chunk = request.chunk_data orelse return;
        const coord = key.regionCoord();
        const region = self.region_cache.getOrOpen(coord) catch {
            log.err("Failed to open region for save", .{});
            return;
        };
        defer self.region_cache.releaseRegion(region);

        const chunk_index = key.localIndex();
        region.writeChunk(chunk_index, &chunk.blocks, self.default_compression) catch |err| {
            log.err("Failed to save chunk: {}", .{err});
        };
    }

    fn executeBatchSave(self: *IoPipeline, request: Request) void {
        const batch = request.batch orelse return;
        defer batch.deinit();

        const coord = batch.region_coord;
        const region = self.region_cache.getOrOpen(coord) catch {
            log.err("Failed to open region for batch save", .{});
            return;
        };
        defer self.region_cache.releaseRegion(region);

        var indices: [BatchSaveData.MAX_BATCH_SIZE]u9 = undefined;
        var block_ptrs: [BatchSaveData.MAX_BATCH_SIZE]*const [WorldState.BLOCKS_PER_CHUNK]WorldState.BlockType = undefined;
        for (0..batch.count) |i| {
            indices[i] = batch.indices[i];
            block_ptrs[i] = &batch.chunks[i].blocks;
        }

        region.writeChunkBatch(
            indices[0..batch.count],
            block_ptrs[0..batch.count],
            self.default_compression,
        ) catch |err| {
            log.err("Batch save failed for region ({d},{d},{d}): {}", .{
                coord.rx, coord.ry, coord.rz, err,
            });
        };
    }

    fn postResult(self: *IoPipeline, handle_id: u32, key: ChunkKey, success: bool) void {
        self.results_mutex.lockUncancelable(self.io);
        defer self.results_mutex.unlock(self.io);

        if (self.results_len < MAX_QUEUE_SIZE) {
            self.results[self.results_len] = .{
                .handle_id = handle_id,
                .key = key,
                .success = success,
            };
            self.results_len += 1;
        }
    }
};
