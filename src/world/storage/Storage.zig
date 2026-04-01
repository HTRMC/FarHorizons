const std = @import("std");
const WorldState = @import("../WorldState.zig");
const storage_types = @import("types.zig");
const RegionFile = @import("region_file.zig").RegionFile;
const RegionCache = @import("region_cache.zig").RegionCache;
const ChunkCacheMod = @import("chunk_cache.zig");
const IoPipeline = @import("io_pipeline.zig").IoPipeline;
const dirty_set_mod = @import("dirty_set.zig");
const GameChunkPool = @import("../ChunkPool.zig").ChunkPool;
const app_config = @import("../../app_config.zig");
const tracy = @import("../../platform/tracy.zig");

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

const c_time = struct {
    extern "c" fn time(timer: ?*i64) i64;
};

const Storage = @This();

allocator: std.mem.Allocator,
world_dir: []const u8,
region_dir: []const u8,
seed: u64,
world_type: WorldState.WorldType,
region_cache: RegionCache,
chunk_cache: ChunkCacheMod.ChunkCache,
io_pipeline: IoPipeline,
default_compression: CompressionAlgo,
dirty_set: DirtySet,
dirty_mutex: Io.Mutex,
game_chunk_pool: ?*GameChunkPool,

// Load timing stats (atomically updated by streamer workers)
stats_load_count: std.atomic.Value(u64),
stats_cache_hits: std.atomic.Value(u64),
stats_region_ns: std.atomic.Value(u64),
stats_read_ns: std.atomic.Value(u64),


pub fn init(allocator: std.mem.Allocator, world_name: []const u8) !*Storage {
    const io = Io.Threaded.global_single_threaded.io();
    const sep = std.fs.path.sep_str;

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

    const worlds_dir = try std.fmt.allocPrint(allocator, "{s}{s}worlds", .{ base_path, sep });
    defer allocator.free(worlds_dir);
    ensureDirExists(io, worlds_dir);
    ensureDirExists(io, world_dir);
    ensureDirExists(io, region_dir);

    const playerdata_dir = try std.fmt.allocPrint(allocator, "{s}{s}playerdata", .{ world_dir, sep });
    defer allocator.free(playerdata_dir);
    ensureDirExists(io, playerdata_dir);

    const seed = loadOrCreateSeed(io, allocator, world_dir);
    const world_type = loadWorldType(io, allocator, world_dir);

    const self = try allocator.create(Storage);
    errdefer allocator.destroy(self);

    self.allocator = allocator;
    self.world_dir = world_dir;
    self.region_dir = region_dir;
    self.seed = seed;
    self.world_type = world_type;
    self.region_cache = RegionCache.init(allocator, region_dir);
    self.default_compression = .zstd;
    self.dirty_set = try DirtySet.init(allocator);
    self.dirty_mutex = .init;
    self.game_chunk_pool = null;
    self.stats_load_count = std.atomic.Value(u64).init(0);
    self.stats_cache_hits = std.atomic.Value(u64).init(0);
    self.stats_region_ns = std.atomic.Value(u64).init(0);
    self.stats_read_ns = std.atomic.Value(u64).init(0);

    self.chunk_cache.initInPlace();
    self.io_pipeline.initInPlace(
        &self.region_cache,
        &self.chunk_cache,
        self.default_compression,
    );

    self.io_pipeline.start();

    log.info("Storage initialized: {s}", .{world_dir});
    return self;
}

pub fn deinit(self: *Storage) void {
    const tz = tracy.zone(@src(), "Storage.deinit");
    defer tz.end();
    const pool = self.game_chunk_pool orelse {
        log.warn("Storage.deinit: no game_chunk_pool set, skipping dirty save", .{});
        self.io_pipeline.stop();
        self.dirty_set.deinit(undefined);
        self.region_cache.deinit();
        const allocator = self.allocator;
        allocator.free(self.region_dir);
        allocator.free(self.world_dir);
        log.info("Storage shut down", .{});
        allocator.destroy(self);
        return;
    };
    // Stop IO pipeline first so workers don't contend with saveAllDirty
    // for region file locks. Workers exit after their current operation;
    // remaining queue items are cleaned up by stop().
    {
        const tz2 = tracy.zone(@src(), "Storage.ioPipelineStop");
        defer tz2.end();
        self.io_pipeline.stop();
    }
    self.saveAllDirty(pool);
    self.dirty_set.deinit(pool);
    {
        const tz2 = tracy.zone(@src(), "Storage.regionCacheDeinit");
        defer tz2.end();
        self.region_cache.deinit();
    }
    const allocator = self.allocator;
    allocator.free(self.region_dir);
    allocator.free(self.world_dir);
    log.info("Storage shut down", .{});
    allocator.destroy(self);
}

pub fn flush(self: *Storage) void {
    self.region_cache.flushAll();
}


pub fn markDirty(self: *Storage, world_key: WorldState.ChunkKey, chunk: *Chunk) void {
    const pool = self.game_chunk_pool orelse return;
    const io = Io.Threaded.global_single_threaded.io();
    const key = ChunkKey.init(world_key.cx, world_key.cy, world_key.cz);
    self.dirty_mutex.lockUncancelable(io);
    defer self.dirty_mutex.unlock(io);
    self.dirty_set.markDirty(key, chunk, pool);
}

pub fn tick(self: *Storage) void {
    const tz = tracy.zone(@src(), "storage.tick");
    defer tz.end();
    const io = Io.Threaded.global_single_threaded.io();
    const pool = self.game_chunk_pool orelse return;

    self.dirty_mutex.lockUncancelable(io);
    const dirty_count = self.dirty_set.count();
    if (dirty_count == 0) {
        self.dirty_mutex.unlock(io);
        return;
    }

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

    for (0..result.batch_count) |bi| {
        const batch = &result.batches[bi];
        const batch_data = self.allocator.create(BatchSaveData) catch {
            // Release chunk refs on failure
            for (batch.chunks[0..batch.count]) |chunk_ptr| {
                pool.release(chunk_ptr);
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
            .chunk_pool = pool,
        };
        self.io_pipeline.submitBatchSave(batch_data);
    }
}

pub fn saveAllDirty(self: *Storage, pool: *GameChunkPool) void {
    const tz = tracy.zone(@src(), "storage.saveAllDirty");
    defer tz.end();
    const io = Io.Threaded.global_single_threaded.io();

    var total_saved: u32 = 0;

    // drainBatch caps at MAX_BATCH_SIZE entries per call, so loop until
    // the dirty set is fully drained to avoid silently losing chunks.
    while (true) {
        self.dirty_mutex.lockUncancelable(io);
        const dirty_count = self.dirty_set.count();
        if (dirty_count == 0) {
            self.dirty_mutex.unlock(io);
            break;
        }

        if (total_saved == 0) {
            log.info("Saving {d} dirty chunks...", .{dirty_count});
        }

        const drain_result = self.dirty_set.drainBatch(dirty_count);
        self.dirty_mutex.unlock(io);

        const result = drain_result orelse break;

        for (0..result.batch_count) |bi| {
            const batch = &result.batches[bi];
            const coord = batch.region_coord;
            const region = self.region_cache.getOrOpen(coord) catch {
                log.err("Failed to open region for shutdown save ({d},{d},{d})", .{ coord.rx, coord.ry, coord.rz });
                for (batch.chunks[0..batch.count]) |chunk_ptr| {
                    pool.release(chunk_ptr);
                }
                continue;
            };
            defer self.region_cache.releaseRegion(region);

            var indices: [dirty_set_mod.MAX_BATCH_SIZE]u9 = undefined;
            var temp_blocks_batch: [dirty_set_mod.MAX_BATCH_SIZE][WorldState.BLOCKS_PER_CHUNK]WorldState.StateId = undefined;
            var block_ptrs: [dirty_set_mod.MAX_BATCH_SIZE]*const [WorldState.BLOCKS_PER_CHUNK]WorldState.StateId = undefined;
            for (0..batch.count) |i| {
                indices[i] = batch.indices[i];
                // Lock chunk to snapshot data safely
                const cio = Io.Threaded.global_single_threaded.io();
                batch.chunks[i].mutex.lockUncancelable(cio);
                batch.chunks[i].blocks.getRange(&temp_blocks_batch[i], 0);
                batch.chunks[i].mutex.unlock(cio);
                block_ptrs[i] = &temp_blocks_batch[i];
            }

            region.writeChunkBatch(
                indices[0..batch.count],
                block_ptrs[0..batch.count],
                self.default_compression,
            ) catch |err| {
                log.err("Shutdown batch save failed: {}", .{err});
            };

            for (batch.chunks[0..batch.count]) |chunk_ptr| {
                pool.release(chunk_ptr);
            }
            total_saved += batch.count;
        }
    }

    if (total_saved > 0) {
        log.info("All {d} dirty chunks saved", .{total_saved});
    }
}


/// Load chunk directly into the caller's Chunk. Returns true if found on disk.
/// Decodes directly into PaletteStorage — no flat array intermediate, no cache copies.
pub fn loadChunkInto(self: *Storage, world_key: WorldState.ChunkKey, chunk: *Chunk) bool {
    const tz = tracy.zone(@src(), "storage.loadChunkInto");
    defer tz.end();
    const io = Io.Threaded.global_single_threaded.io();
    const key = ChunkKey.init(world_key.cx, world_key.cy, world_key.cz);

    _ = self.stats_load_count.fetchAdd(1, .monotonic);

    const coord = key.regionCoord();
    const t0 = Io.Clock.now(.awake, io);
    const region = self.region_cache.getOrOpen(coord) catch |err| {
        log.err("loadChunk({d},{d},{d}): open failed: {}", .{ world_key.cx, world_key.cy, world_key.cz, err });
        return false;
    };
    defer self.region_cache.releaseRegion(region);
    const t1 = Io.Clock.now(.awake, io);

    const chunk_index = key.localIndex();
    const found = region.readChunkPalette(chunk_index, &chunk.blocks) catch |err| {
        log.err("loadChunk({d},{d},{d}): read failed: {}", .{ world_key.cx, world_key.cy, world_key.cz, err });
        return false;
    };
    const t2 = Io.Clock.now(.awake, io);

    _ = self.stats_region_ns.fetchAdd(@intCast(t0.durationTo(t1).nanoseconds), .monotonic);
    _ = self.stats_read_ns.fetchAdd(@intCast(t1.durationTo(t2).nanoseconds), .monotonic);

    return found;
}

pub fn saveChunk(self: *Storage, world_key: WorldState.ChunkKey, chunk: *const Chunk) !void {
    const key = ChunkKey.init(world_key.cx, world_key.cy, world_key.cz);
    const coord = key.regionCoord();

    const region = try self.region_cache.getOrOpen(coord);
    defer self.region_cache.releaseRegion(region);

    const chunk_index = key.localIndex();
    var temp_blocks: [WorldState.BLOCKS_PER_CHUNK]WorldState.StateId = undefined;
    chunk.blocks.getRange(&temp_blocks, 0);
    try region.writeChunk(chunk_index, &temp_blocks, self.default_compression);

    self.chunk_cache.put(key, chunk);
}

pub fn chunkExists(self: *Storage, world_key: WorldState.ChunkKey) bool {
    const key = ChunkKey.init(world_key.cx, world_key.cy, world_key.cz);
    const coord = key.regionCoord();

    const region = self.region_cache.getOrOpen(coord) catch return false;
    defer self.region_cache.releaseRegion(region);

    return region.chunkExists(key.localIndex());
}


pub fn requestLoadAsync(
    self: *Storage,
    world_key: WorldState.ChunkKey,
    priority: Priority,
) AsyncHandle {
    const key = ChunkKey.init(world_key.cx, world_key.cy, world_key.cz);

    if (self.chunk_cache.get(key) != null) {
        return AsyncHandle.invalid;
    }

    return self.io_pipeline.requestLoad(key, priority);
}

pub fn pollLoad(self: *Storage, handle: AsyncHandle) ?*const Chunk {
    if (!handle.isValid()) return null;

    const completed = self.io_pipeline.pollLoad(handle) orelse return null;
    if (!completed) return null;

    return null;
}


pub fn loadRegion(
    self: *Storage,
    min: [3]i32,
    max: [3]i32,
) void {
    var cy = min[1];
    while (cy <= max[1]) : (cy += 1) {
        var cz = min[2];
        while (cz <= max[2]) : (cz += 1) {
            var cx = min[0];
            while (cx <= max[0]) : (cx += 1) {
                _ = self.loadChunk(cx, cy, cz);
            }
        }
    }
}


pub fn getCached(self: *Storage, world_key: WorldState.ChunkKey) ?*const Chunk {
    const key = ChunkKey.init(world_key.cx, world_key.cy, world_key.cz);
    return self.chunk_cache.get(key);
}

pub fn invalidateCache(self: *Storage, world_key: WorldState.ChunkKey) void {
    const key = ChunkKey.init(world_key.cx, world_key.cy, world_key.cz);
    self.chunk_cache.invalidate(key);
}


fn ensureDirExists(io: Io, path: []const u8) void {
    Dir.createDirAbsolute(io, path, .default_file) catch {};
}

fn loadOrCreateSeed(io: Io, allocator: std.mem.Allocator, world_dir: []const u8) u64 {
    const sep = std.fs.path.sep_str;
    const seed_path = std.fmt.allocPrintSentinel(allocator, "{s}" ++ sep ++ "seed.dat", .{world_dir}, 0) catch return 0;
    defer allocator.free(seed_path);

    // Try to read existing seed
    if (Dir.openFileAbsolute(io, seed_path, .{})) |file| {
        defer file.close(io);
        var buf: [8]u8 = undefined;
        const n = file.readPositionalAll(io, &buf, 0) catch 0;
        if (n == 8) {
            const seed = std.mem.readInt(u64, &buf, .little);
            log.info("Loaded world seed: {d}", .{seed});
            return seed;
        }
    } else |_| {}

    // Generate new seed from system time
    const seed: u64 = blk: {
        const t: u64 = @bitCast(c_time.time(null));
        // Mix bits for better distribution
        var s = t;
        s ^= s >> 33;
        s *%= 0xff51afd7ed558ccd;
        s ^= s >> 33;
        s *%= 0xc4ceb9fe1a85ec53;
        s ^= s >> 33;
        break :blk s;
    };

    // Save to file
    if (Dir.createFileAbsolute(io, seed_path, .{})) |file| {
        defer file.close(io);
        var le_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &le_bytes, seed, .little);
        file.writePositionalAll(io, &le_bytes, 0) catch {};
    } else |_| {}

    log.info("Generated new world seed: {d}", .{seed});
    return seed;
}

pub fn loadGameTime(self: *const Storage) i64 {
    const tz = tracy.zone(@src(), "storage.loadGameTime");
    defer tz.end();
    const sep = std.fs.path.sep_str;
    const path = std.fmt.allocPrintSentinel(self.allocator, "{s}" ++ sep ++ "game_time.dat", .{self.world_dir}, 0) catch return 0;
    defer self.allocator.free(path);

    const io = Io.Threaded.global_single_threaded.io();
    if (Dir.openFileAbsolute(io, path, .{})) |file| {
        defer file.close(io);
        var buf: [8]u8 = undefined;
        const n = file.readPositionalAll(io, &buf, 0) catch 0;
        if (n == 8) {
            return @bitCast(std.mem.readInt(u64, &buf, .little));
        }
    } else |_| {}
    return 0;
}

pub fn saveGameTime(self: *const Storage, game_time: i64) void {
    const tz = tracy.zone(@src(), "storage.saveGameTime");
    defer tz.end();
    const sep = std.fs.path.sep_str;
    const path = std.fmt.allocPrintSentinel(self.allocator, "{s}" ++ sep ++ "game_time.dat", .{self.world_dir}, 0) catch return;
    defer self.allocator.free(path);

    const io = Io.Threaded.global_single_threaded.io();
    if (Dir.createFileAbsolute(io, path, .{})) |file| {
        defer file.close(io);
        const buf = std.mem.toBytes(std.mem.nativeTo(u64, @bitCast(game_time), .little));
        file.writePositionalAll(io, &buf, 0) catch {};
    } else |_| {}
}

fn loadWorldType(io: Io, allocator: std.mem.Allocator, world_dir: []const u8) WorldState.WorldType {
    const sep = std.fs.path.sep_str;
    const path = std.fmt.allocPrintSentinel(allocator, "{s}" ++ sep ++ "world_type.dat", .{world_dir}, 0) catch return .normal;
    defer allocator.free(path);

    if (Dir.openFileAbsolute(io, path, .{})) |file| {
        defer file.close(io);
        var buf: [1]u8 = undefined;
        const n = file.readPositionalAll(io, &buf, 0) catch 0;
        if (n == 1) {
            inline for (@typeInfo(WorldState.WorldType).@"enum".fields) |field| {
                if (buf[0] == field.value) return @enumFromInt(field.value);
            }
        }
    } else |_| {}
    return .normal;
}

const BinaryTag = @import("BinaryTag.zig");

const Entity = @import("../entity/Entity.zig");

pub const PlayerData = struct {
    x: f32,
    y: f32,
    z: f32,
    yaw: f32,
    pitch: f32,
    game_mode: @import("../GameState.zig").GameMode = .creative,
    health: f32 = 20.0,
    air_supply: u16 = 300,
    inventory: ?*Entity.Inventory = null,
};

/// Singleplayer placeholder UUID. Replace with real UUID when auth is added.
pub const LOCAL_PLAYER_UUID = "00000000-0000-0000-0000-000000000000";

pub fn loadPlayerData(self: *const Storage, uuid: []const u8) ?PlayerData {
    const tz = tracy.zone(@src(), "storage.loadPlayerData");
    defer tz.end();
    const sep = std.fs.path.sep_str;
    const path = std.fmt.allocPrintSentinel(self.allocator, "{s}" ++ sep ++ "playerdata" ++ sep ++ "{s}.dat", .{ self.world_dir, uuid }, 0) catch return null;
    defer self.allocator.free(path);

    const data = BinaryTag.readFile(self.allocator, path) catch return null;
    defer self.allocator.free(data);

    const r = BinaryTag.Reader.init(data);
    const GameMode = @import("../GameState.zig").GameMode;
    const gm_raw: u8 = @bitCast(r.getI8("game_mode") orelse 0);

    // Deserialize inventory if present
    var inv_ptr: ?*Entity.Inventory = null;
    if (r.getBytes("inventory")) |bytes| {
        const TOTAL_SLOTS: u16 = @as(u16, Entity.HOTBAR_SIZE) + Entity.INV_SIZE + Entity.ARMOR_SLOTS + Entity.EQUIP_SLOTS + 1;
        if (bytes.len >= TOTAL_SLOTS * 5) {
            const inv = self.allocator.create(Entity.Inventory) catch null;
            if (inv) |inventory| {
                var offset: usize = 0;
                for (&inventory.hotbar) |*s| {
                    s.block = WorldState.StateId.fromRaw(std.mem.readInt(u16, bytes[offset..][0..2], .little));
                    s.count = bytes[offset + 2];
                    s.durability = std.mem.readInt(u16, bytes[offset + 3 ..][0..2], .little);
                    offset += 5;
                }
                for (&inventory.main) |*s| {
                    s.block = WorldState.StateId.fromRaw(std.mem.readInt(u16, bytes[offset..][0..2], .little));
                    s.count = bytes[offset + 2];
                    s.durability = std.mem.readInt(u16, bytes[offset + 3 ..][0..2], .little);
                    offset += 5;
                }
                for (&inventory.armor) |*s| {
                    s.block = WorldState.StateId.fromRaw(std.mem.readInt(u16, bytes[offset..][0..2], .little));
                    s.count = bytes[offset + 2];
                    s.durability = std.mem.readInt(u16, bytes[offset + 3 ..][0..2], .little);
                    offset += 5;
                }
                for (&inventory.equip) |*s| {
                    s.block = WorldState.StateId.fromRaw(std.mem.readInt(u16, bytes[offset..][0..2], .little));
                    s.count = bytes[offset + 2];
                    s.durability = std.mem.readInt(u16, bytes[offset + 3 ..][0..2], .little);
                    offset += 5;
                }
                inventory.offhand.block = WorldState.StateId.fromRaw(std.mem.readInt(u16, bytes[offset..][0..2], .little));
                inventory.offhand.count = bytes[offset + 2];
                inventory.offhand.durability = std.mem.readInt(u16, bytes[offset + 3 ..][0..2], .little);
                inv_ptr = inventory;
            }
        }
    }

    return .{
        .x = r.getF32("x") orelse return null,
        .y = r.getF32("y") orelse return null,
        .z = r.getF32("z") orelse return null,
        .yaw = r.getF32("yaw") orelse return null,
        .pitch = r.getF32("pitch") orelse return null,
        .game_mode = if (gm_raw == 1) GameMode.survival else GameMode.creative,
        .health = r.getF32("health") orelse 20.0,
        .air_supply = @intCast(@as(u32, @bitCast(r.getI32("air_supply") orelse 300))),
        .inventory = inv_ptr,
    };
}

pub fn savePlayerData(self: *const Storage, uuid: []const u8, data: PlayerData) void {
    const tz = tracy.zone(@src(), "storage.savePlayerData");
    defer tz.end();
    const sep = std.fs.path.sep_str;
    const path = std.fmt.allocPrintSentinel(self.allocator, "{s}" ++ sep ++ "playerdata" ++ sep ++ "{s}.dat", .{ self.world_dir, uuid }, 0) catch return;
    defer self.allocator.free(path);

    var w = BinaryTag.Writer.init(self.allocator);
    defer w.deinit();
    w.putF32("x", data.x);
    w.putF32("y", data.y);
    w.putF32("z", data.z);
    w.putF32("yaw", data.yaw);
    w.putF32("pitch", data.pitch);
    w.putI8("game_mode", @bitCast(@intFromEnum(data.game_mode)));
    w.putF32("health", data.health);
    w.putI32("air_supply", @bitCast(@as(u32, data.air_supply)));

    // Serialize inventory: 54 slots × 5 bytes (u16 id + u8 count + u16 durability)
    if (data.inventory) |inv| {
        const TOTAL_SLOTS: u16 = @as(u16, Entity.HOTBAR_SIZE) + Entity.INV_SIZE + Entity.ARMOR_SLOTS + Entity.EQUIP_SLOTS + 1;
        var inv_buf: [TOTAL_SLOTS * 5]u8 = undefined;
        var offset: usize = 0;
        const slots = inv.hotbar ++ inv.main ++ inv.armor ++ inv.equip ++ [1]Entity.ItemStack{inv.offhand};
        for (slots) |stack| {
            std.mem.writeInt(u16, inv_buf[offset..][0..2], stack.block.toRaw(), .little);
            inv_buf[offset + 2] = stack.count;
            std.mem.writeInt(u16, inv_buf[offset + 3 ..][0..2], stack.durability, .little);
            offset += 5;
        }
        w.putBytes("inventory", &inv_buf);
    }

    const tag_data = w.toOwnedSlice() orelse return;
    defer self.allocator.free(tag_data);

    BinaryTag.writeFile(self.allocator, path, tag_data) catch {};
}

pub fn saveWorldType(allocator: std.mem.Allocator, world_name: []const u8, world_type: WorldState.WorldType) void {
    const io = Io.Threaded.global_single_threaded.io();
    const sep = std.fs.path.sep_str;
    const base_path = app_config.getAppDataPath(allocator) catch return;
    defer allocator.free(base_path);

    const path = std.fmt.allocPrintSentinel(allocator, "{s}" ++ sep ++ "worlds" ++ sep ++ "{s}" ++ sep ++ "world_type.dat", .{ base_path, world_name }, 0) catch return;
    defer allocator.free(path);

    if (Dir.createFileAbsolute(io, path, .{})) |file| {
        defer file.close(io);
        const buf = [1]u8{@intFromEnum(world_type)};
        file.writePositionalAll(io, &buf, 0) catch {};
    } else |_| {}
}
