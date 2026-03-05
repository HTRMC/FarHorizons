const std = @import("std");
const zlm = @import("zlm");
const Camera = @import("renderer/Camera.zig");
const WorldState = @import("world/WorldState.zig");
const ChunkMap = @import("world/ChunkMap.zig").ChunkMap;
const ChunkPool = @import("world/ChunkPool.zig").ChunkPool;
pub const ChunkStreamer = @import("world/ChunkStreamer.zig").ChunkStreamer;
const TerrainGen = @import("world/TerrainGen.zig");
const Physics = @import("Physics.zig");
const Raycast = @import("Raycast.zig");
const Storage = @import("world/storage/Storage.zig");
const WorldRenderer = @import("renderer/vulkan/WorldRenderer.zig").WorldRenderer;
const TlsfAllocator = @import("allocators/TlsfAllocator.zig").TlsfAllocator;
const MeshWorker = @import("world/MeshWorker.zig").MeshWorker;
const TransferPipeline = @import("renderer/vulkan/TransferPipeline.zig").TransferPipeline;
const Io = std.Io;

const GameState = @This();

pub const MovementMode = enum { flying, walking };
pub const EYE_OFFSET: f32 = 1.62;
pub const TICK_RATE: f32 = 30.0;
pub const TICK_INTERVAL: f32 = 1.0 / TICK_RATE;
pub const HOTBAR_SIZE: u8 = 9;

// Initial load radius in chunks (per axis from center)
const LOAD_RADIUS_XZ: i32 = 2;
const LOAD_RADIUS_Y: i32 = 1;
const MAX_PENDING_UNLOADS: u32 = 256;

pub fn blockName(block: WorldState.BlockType) []const u8 {
    return switch (block) {
        .air => "Air",
        .glass => "Glass",
        .grass_block => "Grass",
        .dirt => "Dirt",
        .stone => "Stone",
        .glowstone => "Glowstone",
        .sand => "Sand",
        .snow => "Snow",
        .water => "Water",
        .gravel => "Gravel",
        .cobblestone => "Cobblestone",
        .oak_log => "Oak Log",
        .oak_planks => "Oak Planks",
        .bricks => "Bricks",
        .bedrock => "Bedrock",
        .gold_ore => "Gold Ore",
        .iron_ore => "Iron Ore",
        .coal_ore => "Coal Ore",
        .diamond_ore => "Diamond Ore",
        .sponge => "Sponge",
        .pumice => "Pumice",
        .wool => "Wool",
        .gold_block => "Gold Block",
        .iron_block => "Iron Block",
        .diamond_block => "Diamond Block",
        .bookshelf => "Bookshelf",
        .obsidian => "Obsidian",
        .oak_leaves => "Oak Leaves",
    };
}

pub fn blockColor(block: WorldState.BlockType) [4]f32 {
    return switch (block) {
        .air => .{ 0.0, 0.0, 0.0, 0.0 },
        .glass => .{ 0.8, 0.9, 1.0, 0.4 },
        .grass_block => .{ 0.3, 0.7, 0.2, 1.0 },
        .dirt => .{ 0.6, 0.4, 0.2, 1.0 },
        .stone => .{ 0.5, 0.5, 0.5, 1.0 },
        .glowstone => .{ 1.0, 0.9, 0.5, 1.0 },
        .sand => .{ 0.82, 0.75, 0.51, 1.0 },
        .snow => .{ 0.95, 0.97, 1.0, 1.0 },
        .water => .{ 0.2, 0.4, 0.8, 0.6 },
        .gravel => .{ 0.5, 0.48, 0.47, 1.0 },
        .cobblestone => .{ 0.45, 0.45, 0.45, 1.0 },
        .oak_log => .{ 0.55, 0.36, 0.2, 1.0 },
        .oak_planks => .{ 0.7, 0.55, 0.33, 1.0 },
        .bricks => .{ 0.6, 0.3, 0.25, 1.0 },
        .bedrock => .{ 0.2, 0.2, 0.2, 1.0 },
        .gold_ore => .{ 0.75, 0.7, 0.4, 1.0 },
        .iron_ore => .{ 0.6, 0.55, 0.5, 1.0 },
        .coal_ore => .{ 0.3, 0.3, 0.3, 1.0 },
        .diamond_ore => .{ 0.4, 0.7, 0.8, 1.0 },
        .sponge => .{ 0.8, 0.8, 0.3, 1.0 },
        .pumice => .{ 0.6, 0.58, 0.55, 1.0 },
        .wool => .{ 0.9, 0.9, 0.9, 1.0 },
        .gold_block => .{ 0.9, 0.8, 0.2, 1.0 },
        .iron_block => .{ 0.8, 0.8, 0.8, 1.0 },
        .diamond_block => .{ 0.4, 0.9, 0.9, 1.0 },
        .bookshelf => .{ 0.55, 0.4, 0.25, 1.0 },
        .obsidian => .{ 0.15, 0.1, 0.2, 1.0 },
        .oak_leaves => .{ 0.2, 0.5, 0.15, 0.8 },
    };
}

allocator: std.mem.Allocator,
camera: Camera,
chunk_map: ChunkMap,
chunk_pool: ChunkPool,
entity_pos: [3]f32,
entity_vel: [3]f32,
entity_on_ground: bool,
mode: MovementMode,
input_move: [3]f32,
jump_requested: bool,
jump_cooldown: u8,
hit_result: ?Raycast.BlockHitResult,
dirty_chunks: DirtyChunkSet,
debug_camera_active: bool,
overdraw_mode: bool,
saved_camera: Camera,

selected_slot: u8 = 0,
hotbar: [HOTBAR_SIZE]WorldState.BlockType = .{ .grass_block, .dirt, .stone, .sand, .snow, .gravel, .glass, .glowstone, .water },
offhand: WorldState.BlockType = .air,

world_seed: u64,
world_type: WorldState.WorldType,
storage: ?*Storage,
streamer: ChunkStreamer,
player_chunk: WorldState.ChunkKey,
streaming_initialized: bool,
world_tick_pending: bool = false,

// Player-caused dirty chunks — fed to MeshWorker every frame for low latency
player_dirty_chunks: DirtyChunkSet = DirtyChunkSet.empty(),

// Pending unloads (collected by worldTick, applied by renderer)
pending_unload_keys: [MAX_PENDING_UNLOADS]WorldState.ChunkKey = undefined,
pending_unload_count: u16 = 0,
unload_scan_cursor: u32 = 0,

// Async initial load (ready when player's chunk is loaded+meshed AND count >= target)
initial_load_target: u32 = 0,
initial_load_ready: bool = true,

// Pipeline references for stats reporting (set by renderer)
mesh_worker: ?*MeshWorker = null,
transfer_pipeline: ?*TransferPipeline = null,
stats_last_time: ?Io.Timestamp = null,

debug_screens: u8 = 0,
delta_time: f32 = 0,
frame_timing: FrameTiming = .{},

prev_entity_pos: [3]f32,
prev_camera_pos: zlm.Vec3,
tick_camera_pos: zlm.Vec3,
render_entity_pos: [3]f32,

pub const FrameTiming = struct {
    update_ms: f32 = 0,
    render_ms: f32 = 0,
    frame_ms: f32 = 0,
};

pub const DirtyChunkSet = struct {
    const MAX_DIRTY = 512;
    keys: [MAX_DIRTY]WorldState.ChunkKey,
    count: u16,

    pub fn empty() DirtyChunkSet {
        return .{ .keys = undefined, .count = 0 };
    }

    pub fn add(self: *DirtyChunkSet, key: WorldState.ChunkKey) void {
        for (self.keys[0..self.count]) |k| {
            if (k.eql(key)) return;
        }
        if (self.count < MAX_DIRTY) {
            self.keys[self.count] = key;
            self.count += 1;
        }
    }

    pub fn clear(self: *DirtyChunkSet) void {
        self.count = 0;
    }
};

pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, world_name: []const u8, world_type_override: ?WorldState.WorldType) !GameState {
    var cam = Camera.init(width, height);
    const chunk_map = ChunkMap.init(allocator);
    const chunk_pool = ChunkPool.init(allocator);

    const storage_inst = Storage.init(allocator, world_name) catch |err| blk: {
        std.log.warn("Storage init failed: {}, world will not be saved", .{err});
        break :blk null;
    };

    const world_seed: u64 = if (storage_inst) |s| s.seed else 0;
    const world_type: WorldState.WorldType = if (world_type_override) |wt| wt else if (storage_inst) |s| s.world_type else .normal;

    // Save world type for new worlds
    if (world_type_override != null) {
        Storage.saveWorldType(allocator, world_name, world_type);
    }

    // Compute spawn position
    const spawn_x: i32 = if (world_type == .debug) 5 else 16;
    const spawn_z: i32 = if (world_type == .debug) 4 else 16;
    const spawn_y: f32 = if (world_type == .debug)
        3.0
    else
        @as(f32, @floatFromInt(TerrainGen.sampleHeight(spawn_x, spawn_z, world_seed))) + 2.0;

    cam.position = zlm.Vec3.init(@floatFromInt(spawn_x), spawn_y + EYE_OFFSET, @floatFromInt(spawn_z));

    const spawn_key = WorldState.ChunkKey.fromWorldPos(spawn_x, @intFromFloat(spawn_y), spawn_z);

    return .{
        .allocator = allocator,
        .camera = cam,
        .chunk_map = chunk_map,
        .chunk_pool = chunk_pool,
        .entity_pos = .{ @floatFromInt(spawn_x), spawn_y, @floatFromInt(spawn_z) },
        .entity_vel = .{ 0.0, 0.0, 0.0 },
        .entity_on_ground = false,
        .mode = .flying,
        .input_move = .{ 0.0, 0.0, 0.0 },
        .jump_requested = false,
        .jump_cooldown = 0,
        .hit_result = null,
        .dirty_chunks = DirtyChunkSet.empty(),
        .world_seed = world_seed,
        .world_type = world_type,
        .storage = storage_inst,
        .streamer = undefined,
        .player_chunk = spawn_key,
        .streaming_initialized = false,
        .initial_load_ready = false,
        .initial_load_target = 75,
        .debug_camera_active = false,
        .overdraw_mode = false,
        .saved_camera = cam,
        .prev_entity_pos = .{ @floatFromInt(spawn_x), spawn_y, @floatFromInt(spawn_z) },
        .prev_camera_pos = cam.position,
        .tick_camera_pos = cam.position,
        .render_entity_pos = .{ @floatFromInt(spawn_x), spawn_y, @floatFromInt(spawn_z) },
    };
}

pub fn save(self: *GameState) void {
    const s = self.storage orelse return;
    const io = std.Io.Threaded.global_single_threaded.io();
    const save_start = std.Io.Clock.now(.awake, io);

    const dirty_start = std.Io.Clock.now(.awake, io);
    s.saveAllDirty();
    const dirty_ns: i64 = @intCast(dirty_start.durationTo(std.Io.Clock.now(.awake, io)).nanoseconds);

    const flush_start = std.Io.Clock.now(.awake, io);
    s.flush();
    const flush_ns: i64 = @intCast(flush_start.durationTo(std.Io.Clock.now(.awake, io)).nanoseconds);

    const total_ns: i64 = @intCast(save_start.durationTo(std.Io.Clock.now(.awake, io)).nanoseconds);
    std.log.info("[save] dirty={d:.1}ms, flush={d:.1}ms, total={d:.1}ms", .{
        @as(f64, @floatFromInt(dirty_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(flush_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(total_ns)) / 1_000_000.0,
    });
}

pub fn deinit(self: *GameState) void {
    if (self.storage) |s| s.deinit();
    self.chunk_map.deinit();
    self.chunk_pool.deinit();
}

pub fn toggleDebugCamera(self: *GameState) void {
    if (self.debug_camera_active) {
        self.camera = self.saved_camera;
        self.prev_camera_pos = self.camera.position;
        self.tick_camera_pos = self.camera.position;
        self.debug_camera_active = false;
    } else {
        self.saved_camera = self.camera;
        self.debug_camera_active = true;
    }
}

pub fn toggleMode(self: *GameState) void {
    switch (self.mode) {
        .flying => {
            self.entity_pos = .{
                self.camera.position.x,
                self.camera.position.y - EYE_OFFSET,
                self.camera.position.z,
            };
            self.prev_entity_pos = self.entity_pos;
            self.entity_vel = .{ 0.0, 0.0, 0.0 };
            self.entity_on_ground = false;
            self.jump_requested = false;
            self.jump_cooldown = 5;
            self.mode = .walking;
        },
        .walking => {
            self.camera.position = zlm.Vec3.init(
                self.entity_pos[0],
                self.entity_pos[1] + EYE_OFFSET,
                self.entity_pos[2],
            );
            self.prev_camera_pos = self.camera.position;
            self.mode = .flying;
        },
    }
}

pub fn fixedUpdate(self: *GameState, move_speed: f32) void {
    self.prev_entity_pos = self.entity_pos;
    self.prev_camera_pos = self.camera.position;

    switch (self.mode) {
        .flying => {
            const forward_input = self.input_move[0];
            const right_input = self.input_move[2];
            const up_input = self.input_move[1];

            if (forward_input != 0.0 or right_input != 0.0 or up_input != 0.0) {
                const speed = move_speed * TICK_INTERVAL;
                self.camera.move(forward_input * speed, right_input * speed, up_input * speed);
            }
        },
        .walking => {
            if (self.jump_cooldown > 0) {
                self.jump_cooldown -= 1;
                self.jump_requested = false;
            } else if (self.jump_requested and self.entity_on_ground) {
                self.entity_vel[1] = 8.7;
                self.jump_requested = false;
            }

            Physics.updateEntity(self, TICK_INTERVAL);

            self.camera.position = zlm.Vec3.init(
                self.entity_pos[0],
                self.entity_pos[1] + EYE_OFFSET,
                self.entity_pos[2],
            );
        },
    }

    self.hit_result = Raycast.raycast(&self.chunk_map, self.camera.position, self.camera.getForward());

    // Request load for missing chunks within render distance (runs at tick rate).
    // Iterates center-outward so the first batch contains chunks near the player,
    // not biased toward the bottom of the sphere.
    if (self.streaming_initialized) {
        const rd = ChunkStreamer.RENDER_DISTANCE;
        const rd_sq = rd * rd;
        const pc = self.player_chunk;
        var batch: [1024]WorldState.ChunkKey = undefined;
        var batch_len: u32 = 0;

        var shell: i32 = 0;
        outer: while (shell <= rd) : (shell += 1) {
            var dy: i32 = -shell;
            while (dy <= shell) : (dy += 1) {
                var dz: i32 = -shell;
                while (dz <= shell) : (dz += 1) {
                    var dx: i32 = -shell;
                    while (dx <= shell) : (dx += 1) {
                        // Only process the surface of this Chebyshev shell
                        if (@max(@abs(dx), @abs(dy), @abs(dz)) != shell) {
                            dx = shell - 1; // skip interior (next iter → shell)
                            continue;
                        }
                        if (dx * dx + dy * dy + dz * dz > rd_sq) continue;
                        const key = WorldState.ChunkKey{
                            .cx = pc.cx + dx,
                            .cy = pc.cy + dy,
                            .cz = pc.cz + dz,
                        };
                        if (self.chunk_map.get(key) == null) {
                            batch[batch_len] = key;
                            batch_len += 1;
                            if (batch_len >= batch.len) break :outer;
                        }
                    }
                }
            }
        }

        if (batch_len > 0) {
            self.streamer.requestLoadBatch(batch[0..batch_len]);
        }
    }

    self.worldTick();
    self.world_tick_pending = true;

    // Pipeline stats reporter — sample every 2 seconds
    self.reportPipelineStats();
}

pub fn interpolateForRender(self: *GameState, alpha: f32) void {
    self.tick_camera_pos = self.camera.position;
    self.render_entity_pos = lerpArray3(self.prev_entity_pos, self.entity_pos, alpha);
    switch (self.mode) {
        .flying => {
            self.camera.position = lerpVec3(self.prev_camera_pos, self.tick_camera_pos, alpha);
        },
        .walking => {
            self.camera.position = zlm.Vec3.init(
                self.render_entity_pos[0],
                self.render_entity_pos[1] + EYE_OFFSET,
                self.render_entity_pos[2],
            );
        },
    }
}

pub fn restoreAfterRender(self: *GameState) void {
    switch (self.mode) {
        .flying => {
            self.camera.position = self.tick_camera_pos;
        },
        .walking => {
            self.camera.position = zlm.Vec3.init(
                self.entity_pos[0],
                self.entity_pos[1] + EYE_OFFSET,
                self.entity_pos[2],
            );
        },
    }
}

fn markDirty(self: *GameState, wx: i32, wy: i32, wz: i32, player: bool) void {
    const affected = WorldState.affectedChunks(wx, wy, wz);
    const target = if (player) &self.player_dirty_chunks else &self.dirty_chunks;
    for (affected.keys[0..affected.count]) |key| {
        target.add(key);
    }
}

pub fn breakBlock(self: *GameState) void {
    const hit = self.hit_result orelse return;
    const wx = hit.block_pos[0];
    const wy = hit.block_pos[1];
    const wz = hit.block_pos[2];
    self.chunk_map.setBlock(wx, wy, wz, .air);
    self.markDirty(wx, wy, wz, true);
    self.queueChunkSave(wx, wy, wz);
    self.hit_result = Raycast.raycast(&self.chunk_map, self.camera.position, self.camera.getForward());
}

pub fn placeBlock(self: *GameState) void {
    const block_type = self.hotbar[self.selected_slot];
    if (block_type == .air) return;
    const hit = self.hit_result orelse return;
    const n = hit.direction.normal();
    const px = hit.block_pos[0] + n[0];
    const py = hit.block_pos[1] + n[1];
    const pz = hit.block_pos[2] + n[2];
    if (WorldState.block_properties.isSolid(self.chunk_map.getBlock(px, py, pz))) return;
    self.chunk_map.setBlock(px, py, pz, block_type);
    self.markDirty(px, py, pz, true);
    self.queueChunkSave(px, py, pz);
    self.hit_result = Raycast.raycast(&self.chunk_map, self.camera.position, self.camera.getForward());
}

fn queueChunkSave(self: *GameState, wx: i32, wy: i32, wz: i32) void {
    const s = self.storage orelse return;
    const key = WorldState.ChunkKey.fromWorldPos(wx, wy, wz);
    const chunk = self.chunk_map.get(key) orelse return;
    s.markDirty(key.cx, key.cy, key.cz, 0, chunk);
}

pub fn worldTick(self: *GameState) void {
    // Update player chunk from camera position
    const pos = self.camera.position;
    const current_chunk = WorldState.ChunkKey.fromWorldPos(
        @intFromFloat(@floor(pos.x)),
        @intFromFloat(@floor(pos.y)),
        @intFromFloat(@floor(pos.z)),
    );

    if (!current_chunk.eql(self.player_chunk) or !self.streaming_initialized) {
        self.player_chunk = current_chunk;
        self.streaming_initialized = true;
    }

    // Drain streamer output
    var results: [ChunkStreamer.MAX_OUTPUT]ChunkStreamer.LoadResult = undefined;
    const count = self.streamer.drainOutput(&results);
    for (results[0..count]) |result| {
        // Skip if chunk was already loaded (e.g. by double request)
        if (self.chunk_map.get(result.key) != null) {
            self.chunk_pool.release(result.chunk);
            continue;
        }
        self.chunk_map.put(result.key, result.chunk);
        self.dirty_chunks.add(result.key);
        // Mark neighbors dirty so they re-mesh with the new neighbor present
        const offsets = [6][3]i32{ .{ -1, 0, 0 }, .{ 1, 0, 0 }, .{ 0, -1, 0 }, .{ 0, 1, 0 }, .{ 0, 0, -1 }, .{ 0, 0, 1 } };
        for (offsets) |off| {
            const nk = WorldState.ChunkKey{
                .cx = result.key.cx + off[0],
                .cy = result.key.cy + off[1],
                .cz = result.key.cz + off[2],
            };
            if (self.chunk_map.get(nk) != null) {
                self.dirty_chunks.add(nk);
            }
        }
    }

    // Scan for chunks to unload (incremental cursor)
    self.scanUnloads();

    // Sync streamer player position + tick storage
    self.streamer.syncPlayerChunk(self.player_chunk);
    if (self.storage) |s| {
        s.tick();
    }

    // Track initial load readiness
    if (!self.initial_load_ready) {
        const chunk_count = self.chunk_map.count();
        const player_loaded = self.chunk_map.get(self.player_chunk) != null;
        if (chunk_count >= self.initial_load_target and player_loaded) {
            self.initial_load_ready = true;
        }
    }
}

fn reportPipelineStats(self: *GameState) void {
    const io = Io.Threaded.global_single_threaded.io();
    const now = Io.Clock.now(.awake, io);

    const last = self.stats_last_time orelse {
        self.stats_last_time = now;
        return;
    };

    const elapsed_ns: i64 = @intCast(last.durationTo(now).nanoseconds);
    if (elapsed_ns < 2_000_000_000) return;
    self.stats_last_time = now;

    const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

    // Read + reset streamer counters
    const s_loaded = self.streamer.stats_loaded.swap(0, .monotonic);
    const s_generated = self.streamer.stats_generated.swap(0, .monotonic);
    const s_stale = self.streamer.stats_stale.swap(0, .monotonic);
    const s_waits = self.streamer.stats_output_waits.swap(0, .monotonic);
    const s_total = s_loaded + s_generated;

    // Read + reset mesh worker counters
    var m_meshed: u64 = 0;
    var m_light: u64 = 0;
    var m_hidden: u64 = 0;
    var m_stale: u64 = 0;
    var m_waits: u64 = 0;
    if (self.mesh_worker) |mw| {
        m_meshed = mw.stats_meshed.swap(0, .monotonic);
        m_light = mw.stats_light_only.swap(0, .monotonic);
        m_hidden = mw.stats_hidden.swap(0, .monotonic);
        m_stale = mw.stats_stale.swap(0, .monotonic);
        m_waits = mw.stats_output_waits.swap(0, .monotonic);
    }
    const m_total = m_meshed + m_light;

    // Read + reset transfer pipeline counters
    var t_transferred: u64 = 0;
    var t_dropped: u64 = 0;
    if (self.transfer_pipeline) |tp| {
        t_transferred = tp.stats_transferred.swap(0, .monotonic);
        t_dropped = tp.stats_dropped.swap(0, .monotonic);
    }

    // Sample queue depths (non-atomic, diagnostic only)
    const si = self.streamer.input_heap.count();
    const so = self.streamer.output_len;
    var mi: usize = 0;
    var mo: u32 = 0;
    if (self.mesh_worker) |mw| {
        mi = mw.input_heap.count();
        mo = mw.output_len;
    }
    var co: u32 = 0;
    if (self.transfer_pipeline) |tp| {
        co = tp.committed_len;
    }

    std.log.info("[Pipeline {d:.1}s] stream: {d:.0}/s (gen:{} disk:{} stale:{} waits:{}) | mesh: {d:.0}/s (full:{} light:{} hidden:{} stale:{} waits:{}) | gpu: {d:.0}/s (drop:{}) | queues: si:{} so:{} mi:{} mo:{} co:{}", .{
        elapsed_s,
        @as(f64, @floatFromInt(s_total)) / elapsed_s,
        s_generated,
        s_loaded,
        s_stale,
        s_waits,
        @as(f64, @floatFromInt(m_total)) / elapsed_s,
        m_meshed,
        m_light,
        m_hidden,
        m_stale,
        m_waits,
        @as(f64, @floatFromInt(t_transferred)) / elapsed_s,
        t_dropped,
        si,
        so,
        mi,
        mo,
        co,
    });

    // Storage timing breakdown
    if (self.storage) |s| {
        const st_loads = s.stats_load_count.swap(0, .monotonic);
        const st_hits = s.stats_cache_hits.swap(0, .monotonic);
        const st_region_ns = s.stats_region_ns.swap(0, .monotonic);
        const st_read_ns = s.stats_read_ns.swap(0, .monotonic);
        const st_disk = st_loads - st_hits;
        if (st_disk > 0) {
            std.log.info("[Storage] loads:{} hits:{} disk:{} | avg region_open:{d:.0}us read+decomp:{d:.0}us total:{d:.0}us", .{
                st_loads,
                st_hits,
                st_disk,
                @as(f64, @floatFromInt(st_region_ns)) / @as(f64, @floatFromInt(st_disk)) / 1000.0,
                @as(f64, @floatFromInt(st_read_ns)) / @as(f64, @floatFromInt(st_disk)) / 1000.0,
                @as(f64, @floatFromInt(st_region_ns + st_read_ns)) / @as(f64, @floatFromInt(st_disk)) / 1000.0,
            });
        }
    }
}

fn scanUnloads(self: *GameState) void {
    // Only scan when previous unloads have been applied
    if (self.pending_unload_count > 0) return;

    const ud = ChunkStreamer.UNLOAD_DISTANCE;
    const ud_sq = ud * ud;
    const pc = self.player_chunk;
    const SCAN_BUDGET: u32 = 512;

    const map_size: u32 = @intCast(self.chunk_map.count());
    if (map_size == 0) return;

    var scanned: u32 = 0;
    var skipped: u32 = 0;
    var it = self.chunk_map.iterator();

    // Skip cursor entries
    while (skipped < self.unload_scan_cursor) {
        if (it.next() == null) {
            // Wrapped around — reset cursor and restart
            self.unload_scan_cursor = 0;
            it = self.chunk_map.iterator();
            break;
        }
        skipped += 1;
    }

    while (scanned < SCAN_BUDGET) : (scanned += 1) {
        const entry = it.next() orelse {
            self.unload_scan_cursor = 0;
            break;
        };
        self.unload_scan_cursor += 1;

        const key = entry.key_ptr.*;
        const dx = key.cx - pc.cx;
        const dy = key.cy - pc.cy;
        const dz = key.cz - pc.cz;
        if (dx * dx + dy * dy + dz * dz > ud_sq) {
            if (self.pending_unload_count < MAX_PENDING_UNLOADS) {
                self.pending_unload_keys[self.pending_unload_count] = key;
                self.pending_unload_count += 1;
            }
        }
    }
}

pub fn applyUnloadsToGpu(
    self: *GameState,
    wr: *WorldRenderer,
    deferred_face_frees: []TlsfAllocator.Handle,
    deferred_face_free_count: *u32,
    deferred_light_frees: []TlsfAllocator.Handle,
    deferred_light_free_count: *u32,
) void {
    for (self.pending_unload_keys[0..self.pending_unload_count]) |key| {
        // Free GPU TLSF allocs via deferred mechanism
        if (wr.chunk_slot_map.get(key)) |slot| {
            if (wr.chunk_face_alloc[slot]) |fa| {
                if (fa.handle != TlsfAllocator.null_handle) {
                    const idx = deferred_face_free_count.*;
                    if (idx < deferred_face_frees.len) {
                        deferred_face_frees[idx] = fa.handle;
                        deferred_face_free_count.* = idx + 1;
                    }
                }
            }
            if (wr.chunk_light_alloc[slot]) |la| {
                if (la.handle != TlsfAllocator.null_handle) {
                    const idx = deferred_light_free_count.*;
                    if (idx < deferred_light_frees.len) {
                        deferred_light_frees[idx] = la.handle;
                        deferred_light_free_count.* = idx + 1;
                    }
                }
            }
        }
        wr.releaseSlot(key);

        if (self.chunk_map.remove(key)) |chunk| {
            self.chunk_pool.release(chunk);
        }
    }
    self.pending_unload_count = 0;
}

fn lerpVec3(a: zlm.Vec3, b: zlm.Vec3, t: f32) zlm.Vec3 {
    return zlm.Vec3.init(
        a.x + (b.x - a.x) * t,
        a.y + (b.y - a.y) * t,
        a.z + (b.z - a.z) * t,
    );
}

fn lerpArray3(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    return .{
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
    };
}
