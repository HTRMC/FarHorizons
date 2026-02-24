const std = @import("std");
const storage_types = @import("types.zig");
const RegionFile = @import("region_file.zig").RegionFile;
const RegionCache = @import("region_cache.zig").RegionCache;
const ChunkCache = @import("chunk_cache.zig").ChunkCache;
const chunk_codec = @import("chunk_codec.zig");
const compression = @import("compression.zig");
const WorldState = @import("../WorldState.zig");

const ChunkKey = storage_types.ChunkKey;
const Priority = storage_types.Priority;
const AsyncHandle = storage_types.AsyncHandle;
const CompressionAlgo = storage_types.CompressionAlgo;
const Chunk = WorldState.Chunk;
const Io = std.Io;

const log = std.log.scoped(.io_pipeline);

const MAX_QUEUE_SIZE = 1024;
const MAX_WORKERS = 4;

/// Async I/O pipeline with a thread pool and priority queue.
/// Handles background chunk loading and saving.
pub const IoPipeline = struct {
    // Queue
    queue: [MAX_QUEUE_SIZE]Request,
    queue_len: u32,
    queue_mutex: Io.Mutex,
    queue_cond: Io.Condition,

    // Results
    results: [MAX_QUEUE_SIZE]RequestResult,
    results_len: u32,
    results_mutex: Io.Mutex,

    // Write-behind: pending writes keyed by chunk
    pending_saves: [MAX_QUEUE_SIZE]?PendingSave,
    pending_count: u32,

    // Workers
    workers: [MAX_WORKERS]?std.Thread,
    worker_count: u32,
    shutdown: std.atomic.Value(bool),

    // References to shared state
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
        // For save requests
        chunk_data: ?*const Chunk,

        const Kind = enum { load, save };
    };

    pub const RequestResult = struct {
        handle_id: u32,
        key: ChunkKey,
        success: bool,
    };

    const PendingSave = struct {
        key: ChunkKey,
        chunk: Chunk,
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
        self.pending_count = 0;
        self.workers = [_]?std.Thread{null} ** MAX_WORKERS;
        self.worker_count = 0;
        self.shutdown = std.atomic.Value(bool).init(false);
        self.region_cache = region_cache;
        self.chunk_cache = chunk_cache;
        self.default_compression = default_compression;
        self.next_handle_id = 0;
        self.io = Io.Threaded.global_single_threaded.io();
        for (&self.pending_saves) |*slot| {
            slot.* = null;
        }
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

        // Wake all workers
        self.queue_cond.broadcast(self.io);

        for (&self.workers) |*w| {
            if (w.*) |thread| {
                thread.join();
                w.* = null;
            }
        }
    }

    /// Enqueue an async load request. Returns a handle for polling.
    pub fn requestLoad(self: *IoPipeline, key: ChunkKey, priority: Priority) AsyncHandle {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);

        if (self.queue_len >= MAX_QUEUE_SIZE) {
            log.warn("I/O queue full, dropping load request", .{});
            return AsyncHandle.invalid;
        }

        const handle_id = self.next_handle_id;
        self.next_handle_id +%= 1;

        // Insert in priority order
        const insert_idx = self.findInsertIndex(priority);
        if (insert_idx < self.queue_len) {
            // Shift elements down
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
        };
        self.queue_len += 1;

        self.queue_cond.signal(self.io);
        return .{ .id = handle_id };
    }

    /// Enqueue an async save request.
    /// If the same chunk already has a pending save, it's replaced (write-behind).
    pub fn requestSave(self: *IoPipeline, key: ChunkKey, chunk: *const Chunk) void {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);

        // Write-behind: check for existing pending save for this chunk
        for (&self.pending_saves) |*slot| {
            if (slot.*) |*pending| {
                if (pending.key.eql(key)) {
                    // Replace with latest data
                    pending.chunk = chunk.*;
                    return;
                }
            }
        }

        // Store in pending saves buffer
        for (&self.pending_saves) |*slot| {
            if (slot.* == null) {
                slot.* = .{
                    .key = key,
                    .chunk = chunk.*,
                };
                self.pending_count += 1;
                break;
            }
        }

        if (self.queue_len >= MAX_QUEUE_SIZE) {
            log.warn("I/O queue full, save will be deferred", .{});
            return;
        }

        const handle_id = self.next_handle_id;
        self.next_handle_id +%= 1;

        // Saves go at the end (lowest priority)
        self.queue[self.queue_len] = .{
            .kind = .save,
            .key = key,
            .priority = .save,
            .handle_id = handle_id,
            .chunk_data = null, // Data will be read from pending_saves
        };
        self.queue_len += 1;

        self.queue_cond.signal(self.io);
    }

    /// Poll for a completed load request.
    pub fn pollLoad(self: *IoPipeline, handle: AsyncHandle) ?bool {
        self.results_mutex.lockUncancelable(self.io);
        defer self.results_mutex.unlock(self.io);

        for (0..self.results_len) |i| {
            if (self.results[i].handle_id == handle.id) {
                const success = self.results[i].success;
                // Remove from results
                self.results_len -= 1;
                if (i < self.results_len) {
                    self.results[i] = self.results[self.results_len];
                }
                return success;
            }
        }
        return null; // Not yet completed
    }

    fn findInsertIndex(self: *const IoPipeline, priority: Priority) u32 {
        // Find position to maintain priority ordering (lower enum = higher priority)
        const pval = @intFromEnum(priority);
        for (0..self.queue_len) |i| {
            if (@intFromEnum(self.queue[i].priority) > pval) {
                return @intCast(i);
            }
        }
        return self.queue_len;
    }

    /// Worker thread function.
    /// Keeps processing until shutdown is set AND the queue is empty.
    fn workerFn(self: *IoPipeline) void {
        while (true) {
            const request = self.dequeue() orelse return;

            switch (request.kind) {
                .load => self.executeLoad(request),
                .save => self.executeSave(request),
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

        // Take the highest priority request (first element)
        const request = self.queue[0];
        self.queue_len -= 1;
        if (self.queue_len > 0) {
            // Shift remaining items up
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

        // Get chunk data from pending saves
        var chunk_data: ?Chunk = null;
        {
            self.queue_mutex.lockUncancelable(self.io);
            defer self.queue_mutex.unlock(self.io);
            for (&self.pending_saves) |*slot| {
                if (slot.*) |pending| {
                    if (pending.key.eql(key)) {
                        chunk_data = pending.chunk;
                        slot.* = null;
                        self.pending_count -= 1;
                        break;
                    }
                }
            }
        }

        const chunk = chunk_data orelse return;

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
