const std = @import("std");
const WorldState = @import("world/WorldState.zig");
const ChunkStreamer = @import("world/ChunkStreamer.zig").ChunkStreamer;
const Storage = @import("world/storage/Storage.zig");
const MeshWorker = @import("world/MeshWorker.zig").MeshWorker;
const ThreadPool = @import("ThreadPool.zig").ThreadPool;
const TransferPipeline = @import("renderer/vulkan/TransferPipeline.zig").TransferPipeline;
const Io = std.Io;

pub const MAX_PENDING_UNLOADS: u32 = 256;

pub const DirtyChunkSet = struct {
    map: std.AutoArrayHashMap(WorldState.ChunkKey, void),

    pub fn init(allocator: std.mem.Allocator) DirtyChunkSet {
        return .{ .map = std.AutoArrayHashMap(WorldState.ChunkKey, void).init(allocator) };
    }

    pub fn deinit(self: *DirtyChunkSet) void {
        self.map.deinit();
    }

    pub fn add(self: *DirtyChunkSet, key: WorldState.ChunkKey) void {
        self.map.put(key, {}) catch {};
    }

    pub fn clear(self: *DirtyChunkSet) void {
        self.map.clearRetainingCapacity();
    }

    pub fn count(self: *const DirtyChunkSet) u32 {
        return @intCast(self.map.count());
    }

    pub fn keys(self: *const DirtyChunkSet) []const WorldState.ChunkKey {
        return self.map.keys();
    }
};

pub const WorldStreamingState = struct {
    world_seed: u64,
    world_type: WorldState.WorldType,
    storage: ?*Storage,
    streamer: ChunkStreamer,
    player_chunk: WorldState.ChunkKey,
    streaming_initialized: bool,
    world_tick_pending: bool = false,

    // Player-caused dirty chunks — fed to MeshWorker every frame for low latency
    player_dirty_chunks: DirtyChunkSet,

    // Pending unloads (collected by worldTick, applied by renderer)
    pending_unload_keys: [MAX_PENDING_UNLOADS]WorldState.ChunkKey = std.mem.zeroes([MAX_PENDING_UNLOADS]WorldState.ChunkKey),
    pending_unload_count: u16 = 0,
    unload_scan_cursor: u32 = 0,

    // Async initial load (ready when player's chunk is loaded+meshed AND count >= target)
    initial_load_target: u32 = 0,
    initial_load_ready: bool = true,

    // Pipeline references for stats reporting (set by renderer)
    pool: ?*ThreadPool = null,
    mesh_worker: ?*MeshWorker = null,
    transfer_pipeline: ?*TransferPipeline = null,
    stats_last_time: ?Io.Timestamp = null,
};
