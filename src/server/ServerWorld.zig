const std = @import("std");
const WorldState = @import("../world/WorldState.zig");
const ChunkMap = @import("../world/ChunkMap.zig").ChunkMap;
const ChunkPool = @import("../world/ChunkPool.zig").ChunkPool;
const ChunkStreamer = @import("../world/ChunkStreamer.zig").ChunkStreamer;
const Storage = @import("../world/storage/Storage.zig");
const LightMap = @import("../world/LightMap.zig").LightMap;
const LightMapPool = @import("../world/LightMap.zig").LightMapPool;
const LightEngine = @import("../world/LightEngine.zig");
const SurfaceHeightMap = @import("../world/SurfaceHeightMap.zig").SurfaceHeightMap;
const ThreadPool = @import("../platform/ThreadPool.zig").ThreadPool;

pub const ServerWorld = @This();

allocator: std.mem.Allocator,

// World data (authoritative)
chunk_map: ChunkMap,
chunk_pool: ChunkPool,
light_maps: std.AutoHashMap(WorldState.ChunkKey, *LightMap),
light_map_pool: LightMapPool,
surface_height_map: SurfaceHeightMap,

// Persistence
storage: ?*Storage,
world_name: []const u8,
seed: u64,
world_type: WorldState.WorldType,

// Streaming
streamer: ChunkStreamer,
pool: ?*ThreadPool = null,

// Game time
game_time: i64 = 0,

pub fn init(allocator: std.mem.Allocator, world_name: []const u8, world_type_override: ?WorldState.WorldType) !*ServerWorld {
    const self = try allocator.create(ServerWorld);
    errdefer allocator.destroy(self);

    const storage_inst = Storage.init(allocator, world_name) catch |err| blk: {
        std.log.warn("Storage init failed: {}, world will not be saved", .{err});
        break :blk null;
    };

    const world_seed: u64 = if (storage_inst) |s| s.seed else 0;
    const world_type: WorldState.WorldType = if (world_type_override) |wt| wt else if (storage_inst) |s| s.world_type else .normal;

    if (world_type_override != null) {
        Storage.saveWorldType(allocator, world_name, world_type);
    }

    const saved_game_time: i64 = if (storage_inst) |s| s.loadGameTime() else 0;

    self.* = .{
        .allocator = allocator,
        .chunk_map = ChunkMap.init(allocator),
        .chunk_pool = ChunkPool.init(allocator),
        .light_maps = std.AutoHashMap(WorldState.ChunkKey, *LightMap).init(allocator),
        .light_map_pool = LightMapPool.init(allocator),
        .surface_height_map = SurfaceHeightMap.init(allocator),
        .storage = storage_inst,
        .world_name = world_name,
        .seed = world_seed,
        .world_type = world_type,
        .streamer = undefined,
        .game_time = saved_game_time,
    };

    self.streamer.initInPlace(
        allocator,
        storage_inst,
        &self.chunk_pool,
        world_seed,
        world_type,
    );

    return self;
}

pub fn deinit(self: *ServerWorld) void {
    self.streamer.stop();
    // Deinit light maps
    var lm_it = self.light_maps.iterator();
    while (lm_it.next()) |entry| {
        self.light_map_pool.release(entry.value_ptr.*);
    }
    self.light_maps.deinit();
    self.light_map_pool.deinit();
    self.surface_height_map.deinit();
    if (self.storage) |s| s.deinit();
    self.chunk_map.deinit();
    self.chunk_pool.deinit();
    self.allocator.destroy(self);
}

/// Save world state to disk.
pub fn save(self: *ServerWorld) void {
    if (self.storage) |s| {
        s.saveGameTime(self.game_time);
        s.saveAllDirty(&self.chunk_pool);
        s.flush();
    }
}

/// Set a block at world coordinates (authoritative). Returns true if the block changed.
pub fn setBlock(self: *ServerWorld, pos: WorldState.WorldBlockPos, new_block: WorldState.StateId) bool {
    const key = pos.toChunkKey();
    const chunk = self.chunk_map.get(key) orelse return false;
    const local = pos.toLocal();
    const idx = local.toIndex();

    const old_block = chunk.blocks.get(idx);
    if (old_block == new_block) return false;

    chunk.blocks.set(idx, new_block);

    // Mark dirty for save
    if (self.storage) |s| s.markDirty(key, chunk);

    return true;
}

/// Get a block at world coordinates.
pub fn getBlock(self: *ServerWorld, pos: WorldState.WorldBlockPos) WorldState.StateId {
    const key = pos.toChunkKey();
    const chunk = self.chunk_map.get(key) orelse return WorldState.BlockState.defaultState(.air);
    const local = pos.toLocal();
    return chunk.blocks.get(local.toIndex());
}

/// Drain loaded chunks from the streamer into the chunk map.
pub fn drainLoadedChunks(self: *ServerWorld) u32 {
    var buf: [ChunkStreamer.MAX_OUTPUT]ChunkStreamer.LoadResult = undefined;
    const count = self.streamer.drainOutput(&buf);
    for (buf[0..count]) |result| {
        self.chunk_map.put(result.key, result.chunk);
        // Allocate light map for this chunk
        const lm = self.light_map_pool.acquire();
        self.light_maps.put(result.key, lm) catch {
            self.light_map_pool.release(lm);
        };
        self.surface_height_map.updateFromChunk(result.key, result.chunk);
    }
    return count;
}

/// Check if a chunk is loaded.
pub fn hasChunk(self: *ServerWorld, key: WorldState.ChunkKey) bool {
    return self.chunk_map.get(key) != null;
}
