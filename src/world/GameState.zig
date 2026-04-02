const std = @import("std");
const zlm = @import("zlm");
const Camera = @import("../renderer/Camera.zig");
const Angle = @import("../math/Angle.zig");
const Degrees = Angle.Degrees;
const WorldState = @import("WorldState.zig");
const BlockState = WorldState.BlockState;
const ChunkMap = @import("ChunkMap.zig").ChunkMap;
const ChunkPool = @import("ChunkPool.zig").ChunkPool;
const LightMapMod = @import("LightMap.zig");
const LightMap = LightMapMod.LightMap;
const LightMapPool = LightMapMod.LightMapPool;
pub const ChunkStreamer = @import("ChunkStreamer.zig").ChunkStreamer;
const TerrainGen = @import("TerrainGen.zig");
const tracy = @import("../platform/tracy.zig");
const Physics = @import("entity/Physics.zig");
pub const Entity = @import("entity/Entity.zig");
pub const Item = @import("item/Item.zig");
const Raycast = @import("Raycast.zig");
const Storage = @import("storage/Storage.zig");
const app_config = @import("../app_config.zig");
const WorldRenderer = @import("../renderer/vulkan/WorldRenderer.zig").WorldRenderer;
const TlsfAllocator = @import("../allocators/TlsfAllocator.zig").TlsfAllocator;
const MeshWorker = @import("MeshWorker.zig").MeshWorker;
const SurfaceHeightMap = @import("SurfaceHeightMap.zig").SurfaceHeightMap;
const TransferPipeline = @import("../renderer/vulkan/TransferPipeline.zig").TransferPipeline;
const Io = std.Io;

const GameState = @This();
const BlockOps = @import("BlockOps.zig");
const ChunkManagement = @import("ChunkManagement.zig");
const MobSim = @import("entity/MobSim.zig");
const PlayerActions = @import("entity/PlayerActions.zig");
const PlayerMovement = @import("entity/PlayerMovement.zig");
pub const Stats = @import("Stats.zig");

pub const PlayerCombat = @import("entity/PlayerCombat.zig").PlayerCombat;
const WorldStreamingMod = @import("WorldStreaming.zig");
pub const WorldStreamingState = WorldStreamingMod.WorldStreamingState;
const PlayerInventoryMod = @import("entity/PlayerInventory.zig");
pub const PlayerInventory = PlayerInventoryMod.PlayerInventory;
pub const BlockRegistry = @import("BlockRegistry.zig");
pub const blockName = BlockRegistry.blockName;
pub const blockColor = BlockRegistry.blockColor;
pub const itemName = BlockRegistry.itemName;
pub const itemColor = BlockRegistry.itemColor;
pub const dayNightCycle = BlockRegistry.dayNightCycle;
pub const DayNightResult = BlockRegistry.DayNightResult;
pub const DAY_CYCLE = BlockRegistry.DAY_CYCLE;

pub const GameMode = enum(u8) { creative = 0, survival = 1 };
pub const MovementMode = enum { flying, walking };
pub const EYE_OFFSET: f32 = 1.62;
pub const TICK_RATE: f32 = 30.0;

/// Duration in seconds. Prevents mixing with tick counts or raw frame deltas.
pub const DeltaSeconds = struct {
    value: f32,

    pub const zero: DeltaSeconds = .{ .value = 0 };

    pub fn scale(self: DeltaSeconds, factor: f32) f32 {
        return factor * self.value;
    }
};

pub const TICK_INTERVAL: DeltaSeconds = .{ .value = 1.0 / TICK_RATE };
pub const HOTBAR_SIZE = Entity.HOTBAR_SIZE;
pub const INV_ROWS = Entity.INV_ROWS;
pub const INV_COLS = Entity.INV_COLS;
pub const INV_SIZE = Entity.INV_SIZE;
pub const ARMOR_SLOTS = Entity.ARMOR_SLOTS;
pub const EQUIP_SLOTS = Entity.EQUIP_SLOTS;

pub const MAX_PICKUP_GHOSTS = PlayerInventoryMod.MAX_PICKUP_GHOSTS;
pub const PickupGhost = PlayerInventoryMod.PickupGhost;

// Player physics
pub const PLAYER_JUMP_VELOCITY: f32 = 8.7;
const MOB_JUMP_VELOCITY: f32 = 8.0;
pub const BREAK_TIME_MULTIPLIER: f32 = 1.5;
pub const KNOCKBACK_STRENGTH: f32 = 5.0;
pub const KNOCKBACK_UPWARD: f32 = 4.0;
pub const DAMAGE_COOLDOWN_TICKS: u8 = 15; // 0.5s at 30Hz
pub const RESPAWN_IMMUNITY_TICKS: u8 = 30; // 1s at 30Hz
pub const ATTACK_COOLDOWN_TICKS: u8 = 15; // 0.5s at 30Hz
pub const DEATH_DROP_PICKUP_COOLDOWN: u16 = 60; // 2s before pickup

// Initial load radius in chunks (per axis from center)
const LOAD_RADIUS_XZ: i32 = 2;
const LOAD_RADIUS_Y: i32 = 1;
const MAX_PENDING_UNLOADS = WorldStreamingMod.MAX_PENDING_UNLOADS;

allocator: std.mem.Allocator,
camera: Camera,
chunk_map: ChunkMap,
chunk_pool: ChunkPool,
light_maps: std.AutoHashMap(WorldState.ChunkKey, *LightMap),
light_map_pool: LightMapPool,
surface_height_map: SurfaceHeightMap,
entities: Entity.EntityStore,
mode: MovementMode,
input_move: [3]f32,
jump_requested: bool,
jump_cooldown: u8,
hit_result: ?Raycast.BlockHitResult,
entity_hit: ?Raycast.EntityHitResult = null,
swing_requested: bool,
dirty_chunks: WorldStreamingMod.DirtyChunkSet,
debug_camera_active: bool,
third_person: bool = false,
third_person_crosshair: bool = false,
overdraw_mode: bool,
saved_camera: Camera,

inv: PlayerInventory = .{},
render_alpha: f32 = 0,

game_mode: GameMode = .creative,
combat: PlayerCombat = .{},
streaming: WorldStreamingState,
multiplayer_client: bool = false,
stats: Stats = .{},

game_time: i64 = 0,
debug_screens: u8 = 0,
show_chunk_borders: bool = false,
show_hitbox: bool = false,
show_ui: bool = true,
delta_time: DeltaSeconds = DeltaSeconds.zero,
frame_timing: FrameTiming = .{},

prev_camera_pos: zlm.Vec3,
tick_camera_pos: zlm.Vec3,

// ── Network chunk reception (thread-safe queue) ──
pending_chunks: [MAX_PENDING_CHUNKS]PendingChunk = undefined,
pending_chunks_write: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
pending_chunks_read: usize = 0,

// ── Network block changes (thread-safe queue) ──
pending_blocks: [MAX_PENDING_BLOCKS]PendingBlock = undefined,
pending_blocks_write: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
pending_blocks_read: usize = 0,

// ── Remote players (multiplayer) ──
remote_players: RemotePlayerList = .empty,
pending_updates: [MAX_PENDING_UPDATES]PendingUpdate = undefined,
pending_write: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
pending_read: usize = 0,

pub const INTERPOLATION_STEPS: u8 = 3;
const MAX_PENDING_UPDATES: usize = 64;

pub const RemotePlayer = struct {
    id: u32,
    target_pos: [3]f64,       // Position received from server (interpolation target)
    current_pos: [3]f64,      // Current interpolated position (updated each tick)
    render_pos: [3]f32 = .{ 0, 0, 0 }, // Final render position (sub-tick interpolated)
    prev_render_pos: [3]f32 = .{ 0, 0, 0 }, // Previous tick render position for sub-tick lerp
    target_rotation: [3]f32,  // Rotation target
    current_rotation: [3]f32 = .{ 0, 0, 0 },
    steps_remaining: u8 = 0,  // Steps left to reach target
    name: []const u8 = "Player",
};

pub const RemotePlayerList = std.ArrayList(RemotePlayer);

const PendingUpdate = struct {
    id: u32,
    pos: [3]f64,
    rotation: [3]f32,
};

const MAX_PENDING_CHUNKS: usize = 128;

const PendingChunk = struct {
    key: WorldState.ChunkKey,
    chunk: *WorldState.Chunk,
};

const MAX_PENDING_BLOCKS: usize = 256;

const PendingBlock = struct {
    pos: WorldState.WorldBlockPos,
    new_block: WorldState.StateId,
};

pub const FrameTiming = struct {
    update_ms: f32 = 0,
    render_ms: f32 = 0,
    frame_ms: f32 = 0,
    smooth_update_ms: f32 = 0,
    smooth_render_ms: f32 = 0,
    smooth_frame_ms: f32 = 0,
    smooth_fps: f32 = 0,

    const alpha: f32 = 0.05;

    pub fn smooth(self: *FrameTiming, dt: DeltaSeconds) void {
        self.smooth_update_ms += alpha * (self.update_ms - self.smooth_update_ms);
        self.smooth_render_ms += alpha * (self.render_ms - self.smooth_render_ms);
        self.smooth_frame_ms += alpha * (self.frame_ms - self.smooth_frame_ms);
        const fps: f32 = if (dt.value > 0) 1.0 / dt.value else 0;
        self.smooth_fps += alpha * (fps - self.smooth_fps);
    }
};

pub const DirtyChunkSet = WorldStreamingMod.DirtyChunkSet;

pub fn playerInv(self: anytype) if (@TypeOf(self) == *const GameState) *const Entity.Inventory else *Entity.Inventory {
    return self.entities.inventory[Entity.PLAYER].?;
}

pub const InventoryOps = @import("entity/InventoryOps.zig");

pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, world_name: []const u8, world_type_override: ?WorldState.WorldType, game_mode_override: ?GameMode, skip_storage: bool) !GameState {
    const tz = tracy.zone(@src(), "GameState.init");
    defer tz.end();
    var cam = Camera.init(width, height);
    const chunk_map = ChunkMap.init(allocator);
    const chunk_pool = ChunkPool.init(allocator);
    var light_maps = std.AutoHashMap(WorldState.ChunkKey, *LightMap).init(allocator);
    light_maps.ensureTotalCapacity(@import("ChunkMap.zig").PREALLOCATED_CAPACITY) catch {};
    const light_map_pool = LightMapPool.init(allocator);
    const surface_height_map = SurfaceHeightMap.init(allocator);

    const storage_inst = if (skip_storage) null else Storage.init(allocator, world_name) catch |err| blk: {
        std.log.warn("Storage init failed: {}, world will not be saved", .{err});
        break :blk null;
    };

    const world_seed: u64 = if (storage_inst) |s| s.seed else 0;
    const world_type: WorldState.WorldType = if (world_type_override) |wt| wt else if (storage_inst) |s| s.world_type else .normal;

    // Save world type for new worlds
    if (world_type_override != null) {
        Storage.saveWorldType(allocator, world_name, world_type);
    }

    // Load saved game time
    const saved_game_time: i64 = if (storage_inst) |s| s.loadGameTime() else 0;

    // Load saved player position or find a valid spawn on land
    const player_data = if (storage_inst) |s| s.loadPlayerData(Storage.LOCAL_PLAYER_UUID) else null;

    // Determine game mode: override > game_mode.dat > saved > default
    const game_mode: GameMode = if (game_mode_override) |gm| gm else blk: {
        if (app_config.hasWorldGameMode(allocator, world_name))
            break :blk app_config.loadWorldGameMode(allocator, world_name);
        break :blk if (player_data) |pd| pd.game_mode else .creative;
    };
    const saved_health: f32 = if (player_data) |pd| pd.health else 20.0;
    const saved_air: u16 = if (player_data) |pd| pd.air_supply else 300;

    const spawn_pos = if (player_data) |pd|
        [3]f32{ pd.x, pd.y, pd.z }
    else if (world_type == .debug)
        [3]f32{ 5.0, 3.0, 4.0 }
    else
        findSpawn(world_seed);

    const spawn_x = spawn_pos[0];
    const spawn_y = spawn_pos[1];
    const spawn_z = spawn_pos[2];

    cam.position = zlm.Vec3.init(spawn_x, spawn_y + EYE_OFFSET, spawn_z);
    if (player_data) |pd| {
        cam.yaw = Angle.deg(pd.yaw);
        cam.pitch = Angle.deg(pd.pitch);
    }

    const spawn_key = WorldState.WorldBlockPos.init(@intFromFloat(spawn_x), @intFromFloat(spawn_y), @intFromFloat(spawn_z)).toChunkKey();

    return .{
        .allocator = allocator,
        .camera = cam,
        .chunk_map = chunk_map,
        .chunk_pool = chunk_pool,
        .light_maps = light_maps,
        .light_map_pool = light_map_pool,
        .surface_height_map = surface_height_map,
        .entities = blk: {
            var store = Entity.EntityStore{};
            _ = store.spawn(.player, .{ spawn_x, spawn_y, spawn_z });
            // Use saved inventory if available, otherwise create default
            const inv = if (player_data != null and player_data.?.inventory != null)
                player_data.?.inventory.?
            else
                allocator.create(Entity.Inventory) catch return error.OutOfMemory;
            if (player_data == null or player_data.?.inventory == null) {
                if (game_mode == .creative) {
                    const S = Entity.ItemStack.of;
                    const T = Entity.ItemStack.ofTool;
                    inv.* = .{
                        .hotbar = .{
                            S(BlockState.defaultState(.grass_block), 64), S(BlockState.defaultState(.dirt), 64),  S(BlockState.defaultState(.stone), 64),
                            S(BlockState.defaultState(.sand), 64),        S(BlockState.defaultState(.snow), 64),  S(BlockState.defaultState(.gravel), 64),
                            S(BlockState.defaultState(.glass), 64),       S(BlockState.defaultState(.glowstone), 64), S(BlockState.defaultState(.water), 64),
                        },
                        .equip = .{
                            T(.pickaxe, .diamond), T(.axe, .diamond), T(.shovel, .diamond), T(.sword, .diamond),
                        },
                        .main = .{
                            S(BlockState.defaultState(.cobblestone), 64), S(BlockState.defaultState(.oak_log), 64),      S(BlockState.defaultState(.oak_planks), 64),   S(BlockState.defaultState(.bricks), 64),       S(BlockState.defaultState(.bedrock), 64),       S(BlockState.defaultState(.gold_ore), 64),      S(BlockState.defaultState(.iron_ore), 64),      S(BlockState.defaultState(.coal_ore), 64),      S(BlockState.defaultState(.diamond_ore), 64),
                            S(BlockState.defaultState(.sponge), 64),      S(BlockState.defaultState(.pumice), 64),       S(BlockState.defaultState(.wool), 64),         S(BlockState.defaultState(.gold_block), 64),   S(BlockState.defaultState(.iron_block), 64),    S(BlockState.defaultState(.diamond_block), 64), S(BlockState.defaultState(.bookshelf), 64),     S(BlockState.defaultState(.obsidian), 64),      S(BlockState.defaultState(.oak_leaves), 64),
                            S(BlockState.fromBlockProps(.oak_slab, @intFromEnum(BlockState.SlabType.bottom)), 64), S(BlockState.fromBlockProps(.oak_stairs, @intFromEnum(BlockState.Facing.south)), 64), S(BlockState.defaultState(.torch), 64), S(BlockState.fromBlockProps(.ladder, @intFromEnum(BlockState.Facing.south)), 64), S(BlockState.makeDoorState(.south, .bottom, false), 64), S(BlockState.defaultState(.oak_fence), 64), S(BlockState.defaultState(.red_glowstone), 64), S(BlockState.defaultState(.crimson_glowstone), 64), S(BlockState.defaultState(.orange_glowstone), 64),
                            S(BlockState.defaultState(.peach_glowstone), 64), S(BlockState.defaultState(.lime_glowstone), 64), S(BlockState.defaultState(.green_glowstone), 64), S(BlockState.defaultState(.teal_glowstone), 64), S(BlockState.defaultState(.cyan_glowstone), 64), S(BlockState.defaultState(.light_blue_glowstone), 64), S(BlockState.defaultState(.blue_glowstone), 64), S(BlockState.defaultState(.navy_glowstone), 64), S(BlockState.defaultState(.indigo_glowstone), 64),
                        },
                    };
                } else {
                    inv.* = .{};
                }
            }
            store.inventory[Entity.PLAYER] = inv;

            // Spawn a few pigs near the player
            store.spawnPig(.{ spawn_x + 5.0, spawn_y + 1.0, spawn_z + 3.0 });
            store.spawnPig(.{ spawn_x - 4.0, spawn_y + 1.0, spawn_z + 6.0 });
            store.spawnPig(.{ spawn_x + 3.0, spawn_y + 1.0, spawn_z - 5.0 });
            store.spawnPig(.{ spawn_x - 6.0, spawn_y + 1.0, spawn_z - 3.0 });

            break :blk store;
        },
        .game_mode = game_mode,
        .combat = .{
            .health = saved_health,
            .air_supply = saved_air,
            .fall_start_y = spawn_y,
        },
        .mode = .walking,
        .input_move = .{ 0.0, 0.0, 0.0 },
        .jump_requested = false,
        .jump_cooldown = 0,
        .hit_result = null,
        .swing_requested = false,
        .dirty_chunks = DirtyChunkSet.init(allocator),
        .streaming = .{
            .world_seed = world_seed,
            .world_type = world_type,
            .storage = storage_inst,
            .streamer = undefined,
            .player_chunk = spawn_key,
            .streaming_initialized = false,
            .initial_load_ready = false,
            .initial_load_target = if (skip_storage) @as(u32, 1) else 75,
            .player_dirty_chunks = DirtyChunkSet.init(allocator),
        },
        .game_time = saved_game_time,
        .debug_camera_active = false,
        .overdraw_mode = false,
        .saved_camera = cam,
        .prev_camera_pos = cam.position,
        .tick_camera_pos = cam.position,
        .multiplayer_client = skip_storage,
        .stats = if (!skip_storage) Stats.init() else .{},
    };
}

pub fn save(self: *GameState) void {
    const tz = tracy.zone(@src(), "GameState.save");
    defer tz.end();

    const s = self.streaming.storage orelse return;
    const io = std.Io.Threaded.global_single_threaded.io();
    const save_start = std.Io.Clock.now(.awake, io);

    const pos = self.entities.pos[Entity.PLAYER];
    s.savePlayerData(Storage.LOCAL_PLAYER_UUID, .{
        .x = pos[0],
        .y = pos[1],
        .z = pos[2],
        .yaw = self.camera.yaw.value,
        .pitch = self.camera.pitch.value,
        .game_mode = self.game_mode,
        .health = self.combat.health,
        .air_supply = self.combat.air_supply,
        .inventory = self.entities.inventory[Entity.PLAYER],
    });

    s.saveGameTime(self.game_time);

    const dirty_start = std.Io.Clock.now(.awake, io);
    s.saveAllDirty(&self.chunk_pool);
    const dirty_ns: i64 = @intCast(dirty_start.durationTo(std.Io.Clock.now(.awake, io)).nanoseconds);

    const flush_start = std.Io.Clock.now(.awake, io);
    {
        const tz2 = tracy.zone(@src(), "storage.flush");
        defer tz2.end();
        s.flush();
    }
    const flush_ns: i64 = @intCast(flush_start.durationTo(std.Io.Clock.now(.awake, io)).nanoseconds);

    const total_ns: i64 = @intCast(save_start.durationTo(std.Io.Clock.now(.awake, io)).nanoseconds);
    std.log.info("[save] dirty={d:.1}ms, flush={d:.1}ms, total={d:.1}ms", .{
        @as(f64, @floatFromInt(dirty_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(flush_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(total_ns)) / 1_000_000.0,
    });
}

/// Queue a remote player position update (called from network thread — thread-safe).
pub fn updateRemotePlayer(self: *GameState, id: u32, pos: [3]f64, rotation: [3]f32) void {
    const write = self.pending_write.load(.acquire);
    const next = (write + 1) % MAX_PENDING_UPDATES;
    // Drop update if buffer is full (read is main-thread only, so relaxed is fine)
    if (next == self.pending_read) return;
    self.pending_updates[write] = .{ .id = id, .pos = pos, .rotation = rotation };
    self.pending_write.store(next, .release);
}

/// Drain pending updates into remote_players (called from main thread only).
fn drainRemotePlayerUpdates(self: *GameState) void {
    const write = self.pending_write.load(.acquire);
    while (self.pending_read != write) {
        const update = self.pending_updates[self.pending_read];
        self.pending_read = (self.pending_read + 1) % MAX_PENDING_UPDATES;
        self.applyRemotePlayerUpdate(update.id, update.pos, update.rotation);
    }
}

fn applyRemotePlayerUpdate(self: *GameState, id: u32, pos: [3]f64, rotation: [3]f32) void {
    for (self.remote_players.items) |*rp| {
        if (rp.id == id) {
            rp.target_pos = pos;
            rp.target_rotation = rotation;
            rp.steps_remaining = INTERPOLATION_STEPS;
            return;
        }
    }
    // New player — snap to position immediately
    const render_pos: [3]f32 = .{
        @floatCast(pos[0]),
        @floatCast(pos[1]),
        @floatCast(pos[2]),
    };
    self.remote_players.append(self.allocator, .{
        .id = id,
        .target_pos = pos,
        .current_pos = pos,
        .render_pos = render_pos,
        .prev_render_pos = render_pos,
        .target_rotation = rotation,
        .current_rotation = rotation,
    }) catch {};
}

/// Advance remote player interpolation by one tick.
pub fn tickRemotePlayers(self: *GameState) void {
    self.drainRemotePlayerUpdates();
    for (self.remote_players.items) |*rp| {
        rp.prev_render_pos = .{
            @floatCast(rp.current_pos[0]),
            @floatCast(rp.current_pos[1]),
            @floatCast(rp.current_pos[2]),
        };
        if (rp.steps_remaining > 0) {
            const t: f64 = 1.0 / @as(f64, @floatFromInt(rp.steps_remaining));
            rp.current_pos[0] += (rp.target_pos[0] - rp.current_pos[0]) * t;
            rp.current_pos[1] += (rp.target_pos[1] - rp.current_pos[1]) * t;
            rp.current_pos[2] += (rp.target_pos[2] - rp.current_pos[2]) * t;
            rp.current_rotation[0] += (rp.target_rotation[0] - rp.current_rotation[0]) * @as(f32, @floatCast(t));
            rp.current_rotation[1] += (rp.target_rotation[1] - rp.current_rotation[1]) * @as(f32, @floatCast(t));
            rp.current_rotation[2] += (rp.target_rotation[2] - rp.current_rotation[2]) * @as(f32, @floatCast(t));
            rp.steps_remaining -= 1;
        }
    }
}

/// Apply a server position correction to the local player. Snaps immediately (no interpolation).
pub fn applyPositionCorrection(
    self: *GameState,
    pos: [3]f64,
    vel: [3]f64,
    rotation: [2]f32,
    relatives: @import("../network/protocols/position_correction.zig").Relative,
) void {
    // Position: apply as absolute or relative
    const new_x: f64 = if (relatives.x) @as(f64, self.camera.position.x) + pos[0] else pos[0];
    const new_y: f64 = if (relatives.y) @as(f64, self.camera.position.y) + pos[1] else pos[1];
    const new_z: f64 = if (relatives.z) @as(f64, self.camera.position.z) + pos[2] else pos[2];

    // Rotation: apply as absolute or relative
    const new_pitch: Degrees = if (relatives.pitch) Degrees.add(self.camera.pitch, Angle.deg(rotation[0])) else Angle.deg(rotation[0]);
    const new_yaw: Degrees = if (relatives.yaw) Degrees.add(self.camera.yaw, Angle.deg(rotation[1])) else Angle.deg(rotation[1]);

    // Velocity: apply as absolute or relative
    const p = Entity.PLAYER;
    const new_vel: [3]f32 = .{
        if (relatives.vel_x) self.entities.vel[p][0] + @as(f32, @floatCast(vel[0])) else @floatCast(vel[0]),
        if (relatives.vel_y) self.entities.vel[p][1] + @as(f32, @floatCast(vel[1])) else @floatCast(vel[1]),
        if (relatives.vel_z) self.entities.vel[p][2] + @as(f32, @floatCast(vel[2])) else @floatCast(vel[2]),
    };

    // Snap camera position
    self.camera.position.x = @floatCast(new_x);
    self.camera.position.y = @floatCast(new_y);
    self.camera.position.z = @floatCast(new_z);
    self.camera.pitch = new_pitch;
    self.camera.yaw = new_yaw;

    // Snap entity position (entity pos is camera pos minus eye offset for walking mode)
    self.entities.pos[p] = .{
        @floatCast(new_x),
        @floatCast(new_y - EYE_OFFSET),
        @floatCast(new_z),
    };
    self.entities.vel[p] = new_vel;

    // Sync interpolation state to prevent rubber-banding
    self.prev_camera_pos = self.camera.position;
    self.tick_camera_pos = self.camera.position;
    self.entities.prev_pos[p] = self.entities.pos[p];

    std.log.info("Position corrected to ({d:.2}, {d:.2}, {d:.2})", .{ new_x, new_y, new_z });
}

/// Remove a remote player.
pub fn removeRemotePlayer(self: *GameState, id: u32) void {
    for (self.remote_players.items, 0..) |rp, i| {
        if (rp.id == id) {
            _ = self.remote_players.swapRemove(i);
            return;
        }
    }
}

pub fn deinit(self: *GameState) void {
    const tz = tracy.zone(@src(), "GameState.deinit");
    defer tz.end();
    self.remote_players.deinit(self.allocator);
    // Free entity inventories
    for (self.entities.inventory[0..self.entities.count]) |inv| {
        if (inv) |ptr| self.allocator.destroy(ptr);
    }
    self.dirty_chunks.deinit();
    self.streaming.player_dirty_chunks.deinit();
    {
        const tz2 = tracy.zone(@src(), "deinit.storage");
        defer tz2.end();
        if (self.streaming.storage) |s| s.deinit();
    }
    {
        const tz2 = tracy.zone(@src(), "deinit.lightMaps");
        defer tz2.end();
        var lm_it = self.light_maps.iterator();
        while (lm_it.next()) |entry| {
            self.light_map_pool.release(entry.value_ptr.*);
        }
        self.light_maps.deinit();
        self.light_map_pool.deinit();
    }
    self.surface_height_map.deinit();
    {
        const tz2 = tracy.zone(@src(), "deinit.chunkMap");
        defer tz2.end();
        self.chunk_map.deinit();
    }
    {
        const tz2 = tracy.zone(@src(), "deinit.chunkPool");
        defer tz2.end();
        self.chunk_pool.deinit();
    }
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

pub fn fixedUpdate(self: *GameState, move_speed: f32) void {
    const P = Entity.PLAYER;
    const P_RAW = P;
    self.game_time +%= 1;
    self.entities.prev_pos[P_RAW] = self.entities.pos[P_RAW];
    self.prev_camera_pos = self.camera.position;

    self.drainNetworkBlockChanges();
    PlayerMovement.updatePlayerMovement(self, P, move_speed);
    PlayerActions.updateCombatSystems(self);
    MobSim.updateEntities(self);
    self.tickRemotePlayers();

    self.hit_result = Raycast.raycast(&self.chunk_map, self.camera.position, self.camera.getForward());
    self.entity_hit = Raycast.raycastEntities(&self.entities, self.camera.position, self.camera.getForward());

    ChunkManagement.requestMissingChunks(self);
    ChunkManagement.worldTick(self);
    self.streaming.world_tick_pending = true;
    ChunkManagement.reportPipelineStats(self);
    if (!self.multiplayer_client) self.stats.tick();
}

pub fn interpolateForRender(self: *GameState, alpha: f32) void {
    self.render_alpha = alpha;
    const P = Entity.PLAYER;
    self.tick_camera_pos = self.camera.position;
    // Interpolate all entities
    for (0..self.entities.count) |i| {
        self.entities.render_pos[i] = lerpArray3(self.entities.prev_pos[i], self.entities.pos[i], alpha);
        self.entities.render_walk_anim[i] = self.entities.prev_walk_anim[i] + (self.entities.walk_anim[i] - self.entities.prev_walk_anim[i]) * alpha;
    }
    // Interpolate remote players (sub-tick smoothing between prev and current)
    for (self.remote_players.items) |*rp| {
        rp.render_pos = .{
            rp.prev_render_pos[0] + (@as(f32, @floatCast(rp.current_pos[0])) - rp.prev_render_pos[0]) * alpha,
            rp.prev_render_pos[1] + (@as(f32, @floatCast(rp.current_pos[1])) - rp.prev_render_pos[1]) * alpha,
            rp.prev_render_pos[2] + (@as(f32, @floatCast(rp.current_pos[2])) - rp.prev_render_pos[2]) * alpha,
        };
    }
    switch (self.mode) {
        .flying => {
            self.camera.position = lerpVec3(self.prev_camera_pos, self.tick_camera_pos, alpha);
        },
        .walking => {
            const rpos = self.entities.render_pos[P];
            self.camera.position = zlm.Vec3.init(
                rpos[0],
                rpos[1] + EYE_OFFSET,
                rpos[2],
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
            const epos = self.entities.pos[Entity.PLAYER];
            self.camera.position = zlm.Vec3.init(
                epos[0],
                epos[1] + EYE_OFFSET,
                epos[2],
            );
        },
    }
}

/// Mark a block position dirty from a network update (triggers remesh).
/// Queue a decoded chunk from the network thread (thread-safe).
pub fn queueNetworkChunk(self: *GameState, key: WorldState.ChunkKey, chunk: *WorldState.Chunk) void {
    const write = self.pending_chunks_write.load(.acquire);
    const next = (write + 1) % MAX_PENDING_CHUNKS;
    if (next == self.pending_chunks_read) {
        // Full — release chunk back to pool
        self.chunk_pool.release(chunk);
        return;
    }
    self.pending_chunks[write] = .{ .key = key, .chunk = chunk };
    self.pending_chunks_write.store(next, .release);
}

/// Apply queued network chunks on the main thread.
pub fn drainNetworkChunks(self: *GameState) void {
    const write = self.pending_chunks_write.load(.acquire);
    while (self.pending_chunks_read != write) {
        const pc = self.pending_chunks[self.pending_chunks_read];
        self.pending_chunks_read = (self.pending_chunks_read + 1) % MAX_PENDING_CHUNKS;

        // If chunk already loaded, replace it with server data
        if (self.chunk_map.get(pc.key) != null) {
            // Remove old and replace
            if (self.chunk_map.remove(pc.key)) |old| {
                self.chunk_pool.release(old);
            }
        }
        self.chunk_map.put(pc.key, pc.chunk);
        self.surface_height_map.updateFromChunk(pc.key, pc.chunk);

        // Allocate light map if not present
        if (self.light_maps.get(pc.key) == null) {
            const lm = self.light_map_pool.acquire();
            self.light_maps.put(pc.key, lm) catch {
                self.light_map_pool.release(lm);
            };
        }

        // Submit light task
        if (self.streaming.pool) |pool| pool.submitLight(pc.key);
    }
}

/// Queue a block change from the network thread (thread-safe).
pub fn queueNetworkBlockChange(self: *GameState, pos: WorldState.WorldBlockPos, new_block: WorldState.StateId) void {
    const write = self.pending_blocks_write.load(.acquire);
    const next = (write + 1) % MAX_PENDING_BLOCKS;
    if (next == self.pending_blocks_read) return; // full, drop
    self.pending_blocks[write] = .{ .pos = pos, .new_block = new_block };
    self.pending_blocks_write.store(next, .release);
}

/// Apply queued network block changes on the main thread.
fn drainNetworkBlockChanges(self: *GameState) void {
    const write = self.pending_blocks_write.load(.acquire);
    while (self.pending_blocks_read != write) {
        const b = self.pending_blocks[self.pending_blocks_read];
        self.pending_blocks_read = (self.pending_blocks_read + 1) % MAX_PENDING_BLOCKS;
        self.chunk_map.setBlock(b.pos, b.new_block);
        self.markDirty(b.pos, false);
    }
}

pub fn markDirty(self: *GameState, pos: WorldState.WorldBlockPos, player: bool) void {
    const affected = WorldState.affectedChunks(pos);
    const target = if (player) &self.streaming.player_dirty_chunks else &self.dirty_chunks;
    for (affected.keys[0..affected.count]) |key| {
        target.add(key);
        if (self.light_maps.get(key)) |lm| {
            lm.dirty = true;
        }
    }
    // Mark face-neighbor chunks for re-mesh (geometry + light border refresh).
    // Don't mark their LightMaps dirty — the MeshWorker will submit light-only
    // refreshes for neighbors when boundaries change.
    const base_key = pos.toChunkKey();
    const offsets = [6][3]i32{ .{ -1, 0, 0 }, .{ 1, 0, 0 }, .{ 0, -1, 0 }, .{ 0, 1, 0 }, .{ 0, 0, -1 }, .{ 0, 0, 1 } };
    for (offsets) |off| {
        const nk = WorldState.ChunkKey{
            .cx = base_key.cx + off[0],
            .cy = base_key.cy + off[1],
            .cz = base_key.cz + off[2],
        };
        target.add(nk);
    }
}

/// Try to use incremental light update for a single block change.
/// Falls back to full markDirty if the light map isn't ready for incremental updates,
/// or if the old block was a light emitter (incremental removal can't clear stale
/// propagated values from neighbors — needs full recompute from scratch).
pub fn markDirtyIncremental(self: *GameState, pos: WorldState.WorldBlockPos, old_block: BlockState.StateId) void {
    const base_key = pos.toChunkKey();

    // Try to set an incremental update on the center chunk's LightMap.
    if (self.light_maps.get(base_key)) |lm| {
        if (!lm.dirty and lm.incremental == null) {
            const local = pos.toLocal();
            lm.incremental = .{
                .local = local,
                .old_block = old_block,
            };

            // Enqueue center chunk + geometry-affected neighbors for processing.
            // Don't mark any LightMaps dirty yet — the worker will cascade
            // to face-neighbors only if the incremental update changes boundary values.
            const affected = WorldState.affectedChunks(pos);
            for (affected.keys[0..affected.count]) |key| {
                self.streaming.player_dirty_chunks.add(key);
            }
            return;
        }
    }

    // Fall back to full recompute.
    self.markDirty(pos, true);
}

/// Sample block light (RGB) and sky light at a world position with
/// trilinear interpolation across the 8 surrounding blocks.
pub fn sampleLightAt(self: *const GameState, wx: f32, wy: f32, wz: f32) WorldState.NormalizedLight {
    // Center sampling in the block: offset by -0.5 so interpolation
    // transitions at block centers rather than block edges
    const sx = wx - 0.5;
    const sy = wy - 0.5;
    const sz = wz - 0.5;
    const x0: i32 = @intFromFloat(@floor(sx));
    const y0: i32 = @intFromFloat(@floor(sy));
    const z0: i32 = @intFromFloat(@floor(sz));
    const fx = sx - @as(f32, @floatFromInt(x0));
    const fy = sy - @as(f32, @floatFromInt(y0));
    const fz = sz - @as(f32, @floatFromInt(z0));

    // Sample 8 corners, skipping opaque blocks
    var block_accum = [3]f32{ 0, 0, 0 };
    var sky_accum: f32 = 0;
    var total_w: f32 = 0;
    for (0..2) |dz| {
        for (0..2) |dy| {
            for (0..2) |dx| {
                const block_pos = WorldState.WorldBlockPos.init(
                    x0 + @as(i32, @intCast(dx)),
                    y0 + @as(i32, @intCast(dy)),
                    z0 + @as(i32, @intCast(dz)),
                );

                // Skip opaque blocks — they have 0 light and would darken the result
                if (BlockState.isOpaque(self.chunk_map.getBlock(block_pos))) continue;

                const wx_ = if (dx == 0) 1.0 - fx else fx;
                const wy_ = if (dy == 0) 1.0 - fy else fy;
                const wz_ = if (dz == 0) 1.0 - fz else fz;
                const w = wx_ * wy_ * wz_;
                total_w += w;

                const sample = self.readLightRaw(block_pos);
                block_accum[0] += sample.block[0] * w;
                block_accum[1] += sample.block[1] * w;
                block_accum[2] += sample.block[2] * w;
                sky_accum += sample.sky * w;
            }
        }
    }
    // Normalize by actual weight sum (redistributes opaque block weight)
    if (total_w > 0.001) {
        const inv = 1.0 / total_w;
        block_accum[0] *= inv;
        block_accum[1] *= inv;
        block_accum[2] *= inv;
        sky_accum *= inv;
    }
    return .{ .block = block_accum, .sky = sky_accum };
}

fn readLightRaw(self: *const GameState, pos: WorldState.WorldBlockPos) WorldState.NormalizedLight {
    const lm = self.light_maps.get(pos.toChunkKey()) orelse return WorldState.NormalizedLight.dark;
    const ci = pos.toLocal().toIndex();

    // Lock to prevent race with mesh worker recomputing light data.
    // @constCast is safe: mutex is interior-mutable (logically separate from data).
    const io = std.Io.Threaded.global_single_threaded.io();
    const lm_mut: *LightMapMod.LightMap = @constCast(lm);
    lm_mut.mutex.lockUncancelable(io);
    defer lm_mut.mutex.unlock(io);

    return WorldState.NormalizedLight.fromRaw(lm.block_light.get(ci), lm.sky_light.get(ci));
}

pub fn queueChunkSave(self: *GameState, pos: WorldState.WorldBlockPos) void {
    const s = self.streaming.storage orelse return;
    const key = pos.toChunkKey();
    const chunk = self.chunk_map.get(key) orelse return;
    s.markDirty(key, chunk);
}

/// Spiral search from (0,0) outward to find a valid spawn on dry land.
/// Checks that the spawn and surrounding area are above sea level.
pub fn findSpawn(seed: u64) [3]f32 {
    const SEA_LEVEL = 0;
    // Ulam spiral: search 51x51 area
    var x: i32 = 0;
    var z: i32 = 0;
    var dx: i32 = 0;
    var dz: i32 = -1;

    const side = 51;
    const max_iter = side * side;

    var i: u32 = 0;
    while (i < max_iter) : (i += 1) {
        const half = @divFloor(side, 2);
        if (x >= -half and x <= half and z >= -half and z <= half) {
            if (isDryLand(x, z, seed, SEA_LEVEL)) {
                const surface_y = TerrainGen.sampleGridHeight(x, z, seed);
                return .{ @as(f32, @floatFromInt(x)) + 0.5, @floatFromInt(surface_y), @as(f32, @floatFromInt(z)) + 0.5 };
            }
        }

        // Spiral step
        if (x == z or (x < 0 and x == -z) or (x > 0 and x == 1 - z)) {
            const old_dx = dx;
            dx = -dz;
            dz = old_dx;
        }
        x += dx;
        z += dz;
    }

    // Fallback: just use (0, 0) surface
    const fallback_y = TerrainGen.sampleGridHeight(0, 0, seed);
    return .{ 0.5, @floatFromInt(@max(fallback_y, SEA_LEVEL + 1)), 0.5 };
}

/// Check that the spawn point and a 5x5 area around it are all above sea level.
fn isDryLand(cx: i32, cz: i32, seed: u64, sea_level: i32) bool {
    var dz: i32 = -2;
    while (dz <= 2) : (dz += 1) {
        var ddx: i32 = -2;
        while (ddx <= 2) : (ddx += 1) {
            const h = TerrainGen.sampleGridHeight(cx + ddx, cz + dz, seed);
            if (h <= sea_level) return false;
        }
    }
    return true;
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

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn makeTestGameState() GameState {
    var game_state: GameState = undefined;
    game_state.entities = Entity.EntityStore{};
    _ = game_state.entities.spawn(.player, .{ 0, 0, 0 });
    const inv = testing.allocator.create(Entity.Inventory) catch @panic("alloc failed");
    inv.* = .{
        .hotbar = .{Entity.ItemStack.of(BlockState.defaultState(.grass_block), 64)} ** HOTBAR_SIZE,
    };
    game_state.entities.inventory[Entity.PLAYER] = inv;
    game_state.inv.carried_item = Entity.ItemStack.EMPTY;
    game_state.inv.selected_slot = 0;
    return game_state;
}

fn destroyTestGameState(game_state: *GameState) void {
    if (game_state.entities.inventory[Entity.PLAYER]) |inv| {
        testing.allocator.destroy(inv);
    }
}

test "slotPtr: hotbar slots 0-8" {
    var game_state = makeTestGameState();
    defer destroyTestGameState(&game_state);
    const inv = game_state.playerInv();
    for (0..HOTBAR_SIZE) |i| {
        const ptr = InventoryOps.slotPtr(&game_state,@intCast(i));
        try testing.expectEqual(&inv.hotbar[i], ptr);
    }
}

test "slotPtr: inventory slots 9-44" {
    var game_state = makeTestGameState();
    defer destroyTestGameState(&game_state);
    const inv = game_state.playerInv();
    for (0..INV_SIZE) |i| {
        const slot: u8 = @intCast(HOTBAR_SIZE + i);
        const ptr = InventoryOps.slotPtr(&game_state,slot);
        try testing.expectEqual(&inv.main[i], ptr);
    }
}

test "slotPtr: armor slots 45-48" {
    var game_state = makeTestGameState();
    defer destroyTestGameState(&game_state);
    const inv = game_state.playerInv();
    for (0..ARMOR_SLOTS) |i| {
        const slot: u8 = @intCast(HOTBAR_SIZE + INV_SIZE + i);
        const ptr = InventoryOps.slotPtr(&game_state,slot);
        try testing.expectEqual(&inv.armor[i], ptr);
    }
}

test "slotPtr: equip slots 49-52" {
    var game_state = makeTestGameState();
    defer destroyTestGameState(&game_state);
    const inv = game_state.playerInv();
    for (0..EQUIP_SLOTS) |i| {
        const slot: u8 = @intCast(HOTBAR_SIZE + INV_SIZE + ARMOR_SLOTS + i);
        const ptr = InventoryOps.slotPtr(&game_state,slot);
        try testing.expectEqual(&inv.equip[i], ptr);
    }
}

test "slotPtr: offhand slot 53" {
    var game_state = makeTestGameState();
    defer destroyTestGameState(&game_state);
    const inv = game_state.playerInv();
    const ptr = InventoryOps.slotPtr(&game_state,HOTBAR_SIZE + INV_SIZE + ARMOR_SLOTS + EQUIP_SLOTS);
    try testing.expectEqual(&inv.offhand, ptr);
}

test "clickSlot: pick up item from hotbar" {
    const S = Entity.ItemStack;
    const stone = S.of(BlockState.defaultState(.stone), 32);
    var game_state = makeTestGameState();
    defer destroyTestGameState(&game_state);
    game_state.playerInv().hotbar[0] = stone;
    game_state.inv.carried_item = S.EMPTY;

    InventoryOps.clickSlot(&game_state,0);

    try testing.expect(game_state.playerInv().hotbar[0].isEmpty());
    try testing.expectEqual(stone.block, game_state.inv.carried_item.block);
    try testing.expectEqual(stone.count, game_state.inv.carried_item.count);
}

test "clickSlot: swap carried with slot" {
    const S = Entity.ItemStack;
    const stone = S.of(BlockState.defaultState(.stone), 32);
    const dirt = S.of(BlockState.defaultState(.dirt), 16);
    var game_state = makeTestGameState();
    defer destroyTestGameState(&game_state);
    game_state.playerInv().hotbar[0] = stone;
    game_state.inv.carried_item = dirt;

    InventoryOps.clickSlot(&game_state,0);

    try testing.expectEqual(dirt.block, game_state.playerInv().hotbar[0].block);
    try testing.expectEqual(dirt.count, game_state.playerInv().hotbar[0].count);
    try testing.expectEqual(stone.block, game_state.inv.carried_item.block);
    try testing.expectEqual(stone.count, game_state.inv.carried_item.count);
}

test "clickSlot: both empty does nothing" {
    const S = Entity.ItemStack;
    var game_state = makeTestGameState();
    defer destroyTestGameState(&game_state);
    game_state.playerInv().hotbar[0] = S.EMPTY;
    game_state.inv.carried_item = S.EMPTY;

    InventoryOps.clickSlot(&game_state,0);

    try testing.expect(game_state.playerInv().hotbar[0].isEmpty());
    try testing.expect(game_state.inv.carried_item.isEmpty());
}

test "quickMove: hotbar to inventory" {
    const S = Entity.ItemStack;
    const stone = S.of(BlockState.defaultState(.stone), 32);
    var game_state = makeTestGameState();
    defer destroyTestGameState(&game_state);
    const inv = game_state.playerInv();
    inv.hotbar[0] = stone;
    inv.main[0] = S.EMPTY;

    InventoryOps.quickMove(&game_state,0);

    try testing.expect(inv.hotbar[0].isEmpty());
    try testing.expectEqual(stone.block, inv.main[0].block);
    try testing.expectEqual(stone.count, inv.main[0].count);
}

test "quickMove: inventory to hotbar" {
    const S = Entity.ItemStack;
    const stone = S.of(BlockState.defaultState(.stone), 32);
    const dirt = S.of(BlockState.defaultState(.dirt), 64);
    var game_state = makeTestGameState();
    defer destroyTestGameState(&game_state);
    const inv = game_state.playerInv();
    inv.hotbar = .{dirt} ** HOTBAR_SIZE; // fill hotbar except slot 2
    inv.hotbar[2] = S.EMPTY;
    inv.main[0] = stone;

    InventoryOps.quickMove(&game_state,HOTBAR_SIZE); // slot 9 = first inventory slot

    try testing.expectEqual(stone.block, inv.hotbar[2].block);
    try testing.expectEqual(stone.count, inv.hotbar[2].count);
    try testing.expect(inv.main[0].isEmpty());
}

test "quickMove: no empty target does nothing" {
    const S = Entity.ItemStack;
    const stone = S.of(BlockState.defaultState(.stone), 32);
    const dirt = S.of(BlockState.defaultState(.dirt), 64);
    var game_state = makeTestGameState();
    defer destroyTestGameState(&game_state);
    const inv = game_state.playerInv();
    inv.hotbar[0] = stone;
    inv.main = .{dirt} ** INV_SIZE; // all full, different block

    InventoryOps.quickMove(&game_state,0);

    // Item stays in place
    try testing.expectEqual(stone.block, inv.hotbar[0].block);
    try testing.expectEqual(stone.count, inv.hotbar[0].count);
}

test "addToInventory: merges into existing stack" {
    const S = Entity.ItemStack;
    var game_state = makeTestGameState();
    defer destroyTestGameState(&game_state);
    const inv = game_state.playerInv();
    inv.hotbar[0] = S.of(BlockState.defaultState(.stone), 60);
    inv.hotbar[1] = S.EMPTY;

    const result = InventoryOps.addToInventory(&game_state,S.of(BlockState.defaultState(.stone), 3));
    try testing.expect(result);
    try testing.expectEqual(@as(u8, 63), inv.hotbar[0].count);
}

test "addToInventory: fills empty slot when no match" {
    const S = Entity.ItemStack;
    var game_state = makeTestGameState();
    defer destroyTestGameState(&game_state);
    const inv = game_state.playerInv();
    for (&inv.hotbar) |*s| s.* = S.EMPTY;
    for (&inv.main) |*s| s.* = S.EMPTY;

    const result = InventoryOps.addToInventory(&game_state,S.of(BlockState.defaultState(.dirt), 1));
    try testing.expect(result);
    try testing.expectEqual(BlockState.defaultState(.dirt), inv.hotbar[0].block);
    try testing.expectEqual(@as(u8, 1), inv.hotbar[0].count);
}

test "slot boundary constants" {
    // Verify slot layout: hotbar(9) + inventory(36) + armor(4) + equip(4) + offhand(1) = 54
    try testing.expectEqual(@as(u8, 9), HOTBAR_SIZE);
    try testing.expectEqual(@as(u8, 36), INV_SIZE);
    try testing.expectEqual(@as(u8, 4), ARMOR_SLOTS);
    try testing.expectEqual(@as(u8, 4), EQUIP_SLOTS);
    try testing.expectEqual(@as(u8, 54), HOTBAR_SIZE + INV_SIZE + ARMOR_SLOTS + EQUIP_SLOTS + 1);
}
