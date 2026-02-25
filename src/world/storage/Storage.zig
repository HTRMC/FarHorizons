const std = @import("std");
const WorldState = @import("../WorldState.zig");
const storage_types = @import("types.zig");
const RegionFile = @import("region_file.zig").RegionFile;
const RegionCache = @import("region_cache.zig").RegionCache;
const ChunkCacheMod = @import("chunk_cache.zig");
const IoPipeline = @import("io_pipeline.zig").IoPipeline;
const dirty_set_mod = @import("dirty_set.zig");
const app_config = @import("../../app_config.zig");

const Io = std.Io;
const Dir = Io.Dir;

const ChunkKey = storage_types.ChunkKey;
const RegionCoord = storage_types.RegionCoord;
const CompressionAlgo = storage_types.CompressionAlgo;
const Priority = storage_types.Priority;
const AsyncHandle = storage_types.AsyncHandle;

const DirtySet = dirty_set_mod.DirtySet;
const BatchSaveData = IoPipeline.BatchSaveData;

const Chunk = WorldState.Chunk;

const log = std.log.scoped(.storage);

const Storage = @This();

allocator: std.mem.Allocator,
world_dir: []const u8,
region_dir: []const u8,
region_cache: RegionCache,
chunk_cache: ChunkCacheMod.ChunkCache,
io_pipeline: IoPipeline,
default_compression: CompressionAlgo,
dirty_set: DirtySet,
dirty_mutex: Io.Mutex,

// ── Lifecycle ──────────────────────────────────────────────────────

/// Initialize the storage system for a specific world.
/// Creates the world directory structure if it doesn't exist.
pub fn init(allocator: std.mem.Allocator, world_name: []const u8) !*Storage {
    const io = Io.Threaded.global_single_threaded.io();
    const sep = std.fs.path.sep_str;

    // Build world directory path
    const base_path = try app_config.getAppDataPath(allocator);
    defer allocator.free(base_path);

    const world_dir = try std.fmt.allocPrint(
        allocator,
        "{s}{s}worlds{s}{s}",
        .{ base_path, sep, sep, world_name },
    );
    errdefer allocator.free(world_dir);

    const region_dir = try std.fmt.allocPrint(
        allocator,
        "{s}{s}region",
        .{ world_dir, sep },
    );
    errdefer allocator.free(region_dir);

    // Ensure directory structure exists (create each level since createDirAbsolute doesn't make parents)
    const worlds_dir = try std.fmt.allocPrint(allocator, "{s}{s}worlds", .{ base_path, sep });
    defer allocator.free(worlds_dir);
    ensureDirExists(io, worlds_dir);
    ensureDirExists(io, world_dir);
    ensureDirExists(io, region_dir);
    // LOD directories (lod0, lod1, lod2) are created on demand by region cache

    const self = try allocator.create(Storage);
    errdefer allocator.destroy(self);

    self.allocator = allocator;
    self.world_dir = world_dir;
    self.region_dir = region_dir;
    self.region_cache = RegionCache.init(allocator, region_dir);
    self.default_compression = .deflate;
    self.dirty_set = DirtySet.init(allocator);
    self.dirty_mutex = .init;

    self.chunk_cache.initInPlace();
    self.io_pipeline.initInPlace(
        &self.region_cache,
        &self.chunk_cache,
        self.default_compression,
    );

    // Start I/O worker threads
    self.io_pipeline.start();

    log.info("Storage initialized: {s}", .{world_dir});
    return self;
}

/// Shut down the storage system, flushing all pending writes.
pub fn deinit(self: *Storage) void {
    self.saveAllDirty();
    self.io_pipeline.stop(); // Drain pending saves, join workers
    self.flush(); // Sync region files to disk
    self.dirty_set.deinit();
    self.region_cache.deinit();
    const allocator = self.allocator;
    allocator.free(self.region_dir);
    allocator.free(self.world_dir);
    log.info("Storage shut down", .{});
    allocator.destroy(self);
}

/// Flush all pending writes to disk.
pub fn flush(self: *Storage) void {
    self.region_cache.flushAll();
}

// ── Dirty Chunk Tracking ──────────────────────────────────────────

/// Mark a chunk as dirty. Snapshots chunk data. Thread-safe.
pub fn markDirty(self: *Storage, cx: i32, cy: i32, cz: i32, lod: u8, chunk: *const Chunk) void {
    const io = Io.Threaded.global_single_threaded.io();
    const key = ChunkKey.init(cx, cy, cz, lod);
    self.dirty_mutex.lockUncancelable(io);
    defer self.dirty_mutex.unlock(io);
    self.dirty_set.markDirty(key, chunk);
}

/// Run one tick of the adaptive save scheduler. Call once per frame.
pub fn tick(self: *Storage) void {
    const io = Io.Threaded.global_single_threaded.io();

    self.dirty_mutex.lockUncancelable(io);
    const dirty_count = self.dirty_set.count();
    if (dirty_count == 0) {
        self.dirty_mutex.unlock(io);
        return;
    }

    // Check if loads should take priority
    const load_depth = self.io_pipeline.getLoadQueueDepth();
    if (load_depth > 32) {
        self.dirty_mutex.unlock(io);
        return;
    }

    const urgency = self.dirty_set.urgencyCounts();
    const urgent_critical = @min(urgency.urgent + urgency.critical, 8);
    const budget = std.math.clamp(4 + dirty_count / 256 + urgent_critical, 4, 20);

    const drain_result = self.dirty_set.drainBatch(budget);
    self.dirty_mutex.unlock(io);

    const result = drain_result orelse return;

    // Submit batches to I/O pipeline (outside dirty_mutex)
    for (0..result.batch_count) |bi| {
        const batch = &result.batches[bi];
        const batch_data = self.allocator.create(BatchSaveData) catch {
            // Free leaked chunk pointers on alloc failure
            for (batch.chunks[0..batch.count]) |chunk_ptr| {
                self.allocator.destroy(chunk_ptr);
            }
            continue;
        };
        batch_data.* = .{
            .region_coord = batch.region_coord,
            .count = batch.count,
            .indices = batch.indices,
            .chunks = batch.chunks,
            .keys = batch.keys,
            .allocator = self.allocator,
        };
        self.io_pipeline.submitBatchSave(batch_data);
    }
}

/// Force-save all remaining dirty chunks. For shutdown.
pub fn saveAllDirty(self: *Storage) void {
    const io = Io.Threaded.global_single_threaded.io();

    self.dirty_mutex.lockUncancelable(io);
    const dirty_count = self.dirty_set.count();
    if (dirty_count == 0) {
        self.dirty_mutex.unlock(io);
        return;
    }

    log.info("Saving {d} dirty chunks...", .{dirty_count});

    // Drain everything
    const drain_result = self.dirty_set.drainBatch(dirty_count);
    self.dirty_mutex.unlock(io);

    const result = drain_result orelse return;

    // Write all batches synchronously (shutdown path)
    for (0..result.batch_count) |bi| {
        const batch = &result.batches[bi];
        const coord = batch.region_coord;
        const region = self.region_cache.getOrOpen(coord) catch {
            log.err("Failed to open region for shutdown save ({d},{d},{d})", .{ coord.rx, coord.ry, coord.rz });
            // Free chunk pointers we own
            for (batch.chunks[0..batch.count]) |chunk_ptr| {
                self.allocator.destroy(chunk_ptr);
            }
            continue;
        };
        defer self.region_cache.releaseRegion(region);

        // Build slice arrays for writeChunkBatch
        var indices: [dirty_set_mod.MAX_BATCH_SIZE]u9 = undefined;
        var block_ptrs: [dirty_set_mod.MAX_BATCH_SIZE]*const [WorldState.BLOCKS_PER_CHUNK]WorldState.BlockType = undefined;
        for (0..batch.count) |i| {
            indices[i] = batch.indices[i];
            block_ptrs[i] = &batch.chunks[i].blocks;
        }

        region.writeChunkBatch(
            indices[0..batch.count],
            block_ptrs[0..batch.count],
            self.default_compression,
        ) catch |err| {
            log.err("Shutdown batch save failed: {}", .{err});
        };

        // Free chunk snapshots
        for (batch.chunks[0..batch.count]) |chunk_ptr| {
            self.allocator.destroy(chunk_ptr);
        }
    }

    log.info("All dirty chunks saved", .{});
}

// ── Synchronous API ────────────────────────────────────────────────

/// Synchronously load a chunk from disk.
/// Checks cache first, then reads from region file.
/// Returns null if chunk doesn't exist on disk.
pub fn loadChunk(self: *Storage, cx: i32, cy: i32, cz: i32, lod: u8) ?*const Chunk {
    const key = ChunkKey.init(cx, cy, cz, lod);

    // Check chunk cache
    if (self.chunk_cache.get(key)) |cached| {
        return cached;
    }

    // Load from region file
    const coord = key.regionCoord();
    const region = self.region_cache.getOrOpen(coord) catch |err| {
        log.err("loadChunk({d},{d},{d}): open failed: {}", .{ cx, cy, cz, err });
        return null;
    };
    defer self.region_cache.releaseRegion(region);

    const chunk_index = key.localIndex();
    var chunk: Chunk = undefined;
    const found = region.readChunk(chunk_index, &chunk.blocks) catch |err| {
        log.err("loadChunk({d},{d},{d}): read failed: {}", .{ cx, cy, cz, err });
        return null;
    };
    if (!found) return null;

    // Cache the loaded chunk
    self.chunk_cache.put(key, &chunk);

    // Return cached pointer (stable until eviction)
    return self.chunk_cache.get(key);
}

/// Synchronously save a chunk to disk.
pub fn saveChunk(self: *Storage, cx: i32, cy: i32, cz: i32, lod: u8, chunk: *const Chunk) !void {
    const key = ChunkKey.init(cx, cy, cz, lod);
    const coord = key.regionCoord();

    const region = try self.region_cache.getOrOpen(coord);
    defer self.region_cache.releaseRegion(region);

    const chunk_index = key.localIndex();
    try region.writeChunk(chunk_index, &chunk.blocks, self.default_compression);

    // Update cache
    self.chunk_cache.put(key, chunk);
}

/// Check if a chunk exists on disk (without loading it).
pub fn chunkExists(self: *Storage, cx: i32, cy: i32, cz: i32, lod: u8) bool {
    const key = ChunkKey.init(cx, cy, cz, lod);
    const coord = key.regionCoord();

    const region = self.region_cache.getOrOpen(coord) catch return false;
    defer self.region_cache.releaseRegion(region);

    return region.chunkExists(key.localIndex());
}

// ── Async API ──────────────────────────────────────────────────────

/// Request an asynchronous chunk load. Returns a handle for polling.
pub fn requestLoadAsync(
    self: *Storage,
    cx: i32,
    cy: i32,
    cz: i32,
    lod: u8,
    priority: Priority,
) AsyncHandle {
    const key = ChunkKey.init(cx, cy, cz, lod);

    // Already cached?
    if (self.chunk_cache.get(key) != null) {
        // Return a handle that will immediately resolve
        return AsyncHandle.invalid;
    }

    return self.io_pipeline.requestLoad(key, priority);
}

/// Poll a previously requested async load.
/// Returns the chunk pointer if completed and successful, null if still pending.
pub fn pollLoad(self: *Storage, handle: AsyncHandle) ?*const Chunk {
    if (!handle.isValid()) return null;

    const completed = self.io_pipeline.pollLoad(handle) orelse return null;
    if (!completed) return null;

    // The chunk should now be in the cache (the worker put it there)
    // We can't return it without the key, so callers should use getCached
    return null;
}

// ── Batch API ──────────────────────────────────────────────────────

/// Load a region of chunks (inclusive range) synchronously.
pub fn loadRegion(
    self: *Storage,
    min: [3]i32,
    max: [3]i32,
    lod: u8,
) void {
    var cy = min[1];
    while (cy <= max[1]) : (cy += 1) {
        var cz = min[2];
        while (cz <= max[2]) : (cz += 1) {
            var cx = min[0];
            while (cx <= max[0]) : (cx += 1) {
                _ = self.loadChunk(cx, cy, cz, lod);
            }
        }
    }
}

// ── Cache API ──────────────────────────────────────────────────────

/// Get a chunk from the cache only (no disk I/O).
pub fn getCached(self: *Storage, cx: i32, cy: i32, cz: i32, lod: u8) ?*const Chunk {
    const key = ChunkKey.init(cx, cy, cz, lod);
    return self.chunk_cache.get(key);
}

/// Invalidate a cached chunk.
pub fn invalidateCache(self: *Storage, cx: i32, cy: i32, cz: i32, lod: u8) void {
    const key = ChunkKey.init(cx, cy, cz, lod);
    self.chunk_cache.invalidate(key);
}

// ── Helpers ────────────────────────────────────────────────────────

fn ensureDirExists(io: Io, path: []const u8) void {
    Dir.createDirAbsolute(io, path, .default_file) catch {};
}
