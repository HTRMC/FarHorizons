const std = @import("std");
const zlm = @import("zlm");
const Camera = @import("../renderer/Camera.zig");
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
pub const TICK_INTERVAL: f32 = 1.0 / TICK_RATE;
pub const HOTBAR_SIZE = Entity.HOTBAR_SIZE;
pub const INV_ROWS = Entity.INV_ROWS;
pub const INV_COLS = Entity.INV_COLS;
pub const INV_SIZE = Entity.INV_SIZE;
pub const ARMOR_SLOTS = Entity.ARMOR_SLOTS;
pub const EQUIP_SLOTS = Entity.EQUIP_SLOTS;

pub const MAX_PICKUP_GHOSTS = PlayerInventoryMod.MAX_PICKUP_GHOSTS;
pub const PickupGhost = PlayerInventoryMod.PickupGhost;

// Player physics
const PLAYER_JUMP_VELOCITY: f32 = 8.7;
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

game_time: i64 = 0,
debug_screens: u8 = 0,
show_chunk_borders: bool = false,
show_hitbox: bool = false,
show_ui: bool = true,
delta_time: f32 = 0,
frame_timing: FrameTiming = .{},

prev_camera_pos: zlm.Vec3,
tick_camera_pos: zlm.Vec3,

// ── Remote players (multiplayer) ──
remote_players: RemotePlayerList = .empty,

pub const RemotePlayer = struct {
    id: u32,
    pos: [3]f64,
    prev_pos: [3]f64,
    render_pos: [3]f32 = .{ 0, 0, 0 },
    rotation: [3]f32,
    name: []const u8 = "Player",
};

pub const RemotePlayerList = std.ArrayList(RemotePlayer);

pub const FrameTiming = struct {
    update_ms: f32 = 0,
    render_ms: f32 = 0,
    frame_ms: f32 = 0,
    smooth_update_ms: f32 = 0,
    smooth_render_ms: f32 = 0,
    smooth_frame_ms: f32 = 0,
    smooth_fps: f32 = 0,

    const alpha: f32 = 0.05;

    pub fn smooth(self: *FrameTiming, dt: f32) void {
        self.smooth_update_ms += alpha * (self.update_ms - self.smooth_update_ms);
        self.smooth_render_ms += alpha * (self.render_ms - self.smooth_render_ms);
        self.smooth_frame_ms += alpha * (self.frame_ms - self.smooth_frame_ms);
        const fps: f32 = if (dt > 0) 1.0 / dt else 0;
        self.smooth_fps += alpha * (fps - self.smooth_fps);
    }
};

pub const DirtyChunkSet = WorldStreamingMod.DirtyChunkSet;

pub fn playerInv(self: anytype) if (@TypeOf(self) == *const GameState) *const Entity.Inventory else *Entity.Inventory {
    return self.entities.inventory[Entity.PLAYER].?;
}

/// Get a pointer to the item stack in a unified slot index.
/// Slots 0-8: hotbar, 9-44: main inventory, 45-48: armor, 49-52: equip, 53: offhand.
pub fn slotPtr(self: *GameState, slot: u8) *Entity.ItemStack {
    const inv = self.playerInv();
    if (slot < HOTBAR_SIZE) return &inv.hotbar[slot];
    if (slot < HOTBAR_SIZE + INV_SIZE) return &inv.main[slot - HOTBAR_SIZE];
    if (slot < HOTBAR_SIZE + INV_SIZE + ARMOR_SLOTS) return &inv.armor[slot - HOTBAR_SIZE - INV_SIZE];
    if (slot < HOTBAR_SIZE + INV_SIZE + ARMOR_SLOTS + EQUIP_SLOTS) return &inv.equip[slot - HOTBAR_SIZE - INV_SIZE - ARMOR_SLOTS];
    return &inv.offhand;
}

/// Click a slot: pick up, place, or swap with carried item.
pub fn clickSlot(self: *GameState, slot: u8) void {
    const tz = tracy.zone(@src(), "clickSlot");
    defer tz.end();
    const ptr = self.slotPtr(slot);
    if (self.inv.carried_item.isEmpty() and ptr.isEmpty()) return;
    const tmp = ptr.*;
    ptr.* = self.inv.carried_item;
    self.inv.carried_item = tmp;
}

/// Shift+click: move item between hotbar and main inventory.
/// First tries to merge into a matching stack, then into an empty slot.
pub fn quickMove(self: *GameState, slot: u8) void {
    const inv = self.playerInv();
    const ptr = self.slotPtr(slot);
    if (ptr.isEmpty()) return;

    const target: []Entity.ItemStack = if (slot < HOTBAR_SIZE) &inv.main else &inv.hotbar;

    // Tools: skip merge pass, go straight to empty slot
    if (!ptr.isTool()) {
        // First pass: try to merge into existing matching stacks
        for (target) |*s| {
            if (!s.isEmpty() and !s.isTool() and s.block == ptr.block and s.count < Entity.MAX_STACK) {
                const space = Entity.MAX_STACK - s.count;
                const transfer = @min(space, ptr.count);
                s.count += transfer;
                ptr.count -= transfer;
                if (ptr.count == 0) {
                    ptr.* = Entity.ItemStack.EMPTY;
                    return;
                }
            }
        }
    }

    // Second pass: find empty slot
    for (target) |*s| {
        if (s.isEmpty()) {
            s.* = ptr.*;
            ptr.* = Entity.ItemStack.EMPTY;
            return;
        }
    }
}

pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, world_name: []const u8, world_type_override: ?WorldState.WorldType, game_mode_override: ?GameMode) !GameState {
    const tz = tracy.zone(@src(), "GameState.init");
    defer tz.end();
    var cam = Camera.init(width, height);
    const chunk_map = ChunkMap.init(allocator);
    const chunk_pool = ChunkPool.init(allocator);
    var light_maps = std.AutoHashMap(WorldState.ChunkKey, *LightMap).init(allocator);
    light_maps.ensureTotalCapacity(@import("ChunkMap.zig").PREALLOCATED_CAPACITY) catch {};
    const light_map_pool = LightMapPool.init(allocator);
    const surface_height_map = SurfaceHeightMap.init(allocator);

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
        cam.yaw = pd.yaw;
        cam.pitch = pd.pitch;
    }

    const spawn_key = WorldState.ChunkKey.fromWorldPos(@intFromFloat(spawn_x), @intFromFloat(spawn_y), @intFromFloat(spawn_z));

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
            .initial_load_target = 75,
            .player_dirty_chunks = DirtyChunkSet.init(allocator),
        },
        .game_time = saved_game_time,
        .debug_camera_active = false,
        .overdraw_mode = false,
        .saved_camera = cam,
        .prev_camera_pos = cam.position,
        .tick_camera_pos = cam.position,
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
        .yaw = self.camera.yaw,
        .pitch = self.camera.pitch,
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

/// Update a remote player's position (called from network protocol handler).
pub fn updateRemotePlayer(self: *GameState, id: u32, pos: [3]f64, rotation: [3]f32) void {
    for (self.remote_players.items) |*rp| {
        if (rp.id == id) {
            rp.prev_pos = rp.pos;
            rp.pos = pos;
            rp.rotation = rotation;
            return;
        }
    }
    // New player
    self.remote_players.append(self.allocator, .{
        .id = id,
        .pos = pos,
        .prev_pos = pos,
        .rotation = rotation,
    }) catch {};
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

fn updateWaterState(self: *GameState) void {
    const floori = Physics.floori;
    const P = Entity.PLAYER;
    const epos = self.entities.pos[P];

    // In flying mode, use camera position; in walking mode, use entity position
    const pos_x: f32 = if (self.mode == .flying) self.camera.position.x else epos[0];
    const pos_y: f32 = if (self.mode == .flying) self.camera.position.y - EYE_OFFSET else epos[1];
    const pos_z: f32 = if (self.mode == .flying) self.camera.position.z else epos[2];
    const px = floori(pos_x);
    const pz = floori(pos_z);

    const feet_block = self.chunk_map.getBlock(px, floori(pos_y), pz);
    const eye_block = self.chunk_map.getBlock(px, floori(pos_y + EYE_OFFSET), pz);

    self.entities.flags[P].in_water = (BlockState.getBlock(feet_block) == .water);
    self.entities.flags[P].eyes_in_water = (BlockState.getBlock(eye_block) == .water);

    // Ladder detection: check feet and mid-body
    self.entities.flags[P].on_ladder = isLadder(feet_block) or
        isLadder(self.chunk_map.getBlock(px, floori(pos_y + 0.9), pz));

    // Water vision time: MC 0-600 ticks @20Hz → 0-900 @30Hz
    if (self.entities.flags[P].eyes_in_water) {
        if (self.entities.water_vision_time[P] < 900) self.entities.water_vision_time[P] += 1;
    } else {
        self.entities.water_vision_time[P] = 0;
    }
}

fn isLadder(state: BlockState.StateId) bool {
    return BlockState.getBlock(state) == .ladder;
}

/// Returns 0.0 to 1.0 water vision factor (MC two-phase curve).
pub fn waterVision(self: *const GameState) f32 {
    const t: f32 = @floatFromInt(self.entities.water_vision_time[Entity.PLAYER]);
    const a = std.math.clamp(t / 150.0, 0.0, 1.0);
    const b = std.math.clamp((t - 150.0) / 750.0, 0.0, 1.0);
    return a * 0.6 + b * 0.4;
}

pub fn toggleMode(self: *GameState) void {
    if (self.game_mode == .survival) return; // no flying in survival
    const P = Entity.PLAYER;
    switch (self.mode) {
        .flying => {
            self.entities.pos[P] = .{
                self.camera.position.x,
                self.camera.position.y - EYE_OFFSET,
                self.camera.position.z,
            };
            self.entities.prev_pos[P] = self.entities.pos[P];
            self.entities.vel[P] = .{ 0.0, 0.0, 0.0 };
            self.entities.flags[P].on_ground = false;
            self.jump_requested = false;
            self.jump_cooldown = 5;
            self.combat.fall_start_y = self.entities.pos[P][1];
            self.mode = .walking;
        },
        .walking => {
            const epos = self.entities.pos[P];
            self.camera.position = zlm.Vec3.init(
                epos[0],
                epos[1] + EYE_OFFSET,
                epos[2],
            );
            self.prev_camera_pos = self.camera.position;
            self.mode = .flying;
        },
    }
}

pub fn takeDamage(self: *GameState, amount: f32) void {
    PlayerActions.takeDamage(self, amount);
}

fn dropInventoryWithScatter(self: *GameState, slots: []Entity.ItemStack, pos: [3]f32, random: std.Random) void {
    PlayerActions.dropInventoryWithScatter(self, slots, pos, random);
}

fn spawnScatterDrop(self: *GameState, pos: [3]f32, item: Entity.ItemStack, random: std.Random) void {
    PlayerActions.spawnScatterDrop(self, pos, item, random);
}

fn die(self: *GameState) void {
    PlayerActions.die(self);
}

fn updateFallDamage(self: *GameState) void {
    PlayerActions.updateFallDamage(self);
}

fn updateDrowning(self: *GameState) void {
    PlayerActions.updateDrowning(self);
}

pub fn fixedUpdate(self: *GameState, move_speed: f32) void {
    const P = Entity.PLAYER;
    self.game_time +%= 1;
    self.entities.prev_pos[P] = self.entities.pos[P];
    self.prev_camera_pos = self.camera.position;

    self.updatePlayerMovement(P, move_speed);
    self.updateCombatSystems();
    self.updateEntities();

    self.hit_result = Raycast.raycast(&self.chunk_map, self.camera.position, self.camera.getForward());
    self.entity_hit = Raycast.raycastEntities(&self.entities, self.camera.position, self.camera.getForward());

    self.requestMissingChunks();
    self.worldTick();
    self.streaming.world_tick_pending = true;
    self.reportPipelineStats();
}

fn updatePlayerMovement(self: *GameState, player: u32, move_speed: f32) void {
    self.updateWaterState();

    switch (self.mode) {
        .flying => {
            const forward_input = self.input_move[0];
            const right_input = self.input_move[2];
            const up_input = self.input_move[1];

            if (forward_input != 0.0 or right_input != 0.0 or up_input != 0.0) {
                const speed = move_speed * TICK_INTERVAL;
                self.camera.move(forward_input * speed, right_input * speed, up_input * speed);
            }

            self.entities.pos[player] = .{
                self.camera.position.x,
                self.camera.position.y - EYE_OFFSET,
                self.camera.position.z,
            };
        },
        .walking => {
            const flags = self.entities.flags[player];

            if (self.jump_cooldown > 0) {
                self.jump_cooldown -= 1;
            } else if (self.jump_requested and flags.on_ladder) {
                self.entities.vel[player][1] = Physics.LADDER_CLIMB_SPEED;
            } else if (self.jump_requested and !flags.in_water and flags.on_ground) {
                self.entities.vel[player][1] = PLAYER_JUMP_VELOCITY;
            }
            self.jump_requested = false;

            Physics.updateEntity(&self.entities, player, &self.chunk_map, self.input_move, self.camera.yaw, TICK_INTERVAL);

            const epos = self.entities.pos[player];
            self.camera.position = zlm.Vec3.init(
                epos[0],
                epos[1] + EYE_OFFSET,
                epos[2],
            );
        },
    }
}

fn updateCombatSystems(self: *GameState) void {
    PlayerActions.updateCombatSystems(self);
}

fn updateEntities(self: *GameState) void {
    MobSim.updateEntities(self);
}

fn requestMissingChunks(self: *GameState) void {
    ChunkManagement.requestMissingChunks(self);
}

fn updateBreakProgress(self: *GameState) void {
    PlayerActions.updateBreakProgress(self);
}

fn updateAttackDamage(self: *GameState) void {
    PlayerActions.updateAttackDamage(self);
}

fn updateItemDrops(self: *GameState) void {
    MobSim.updateItemDrops(self);
}

fn updateMobs(self: *GameState) void {
    MobSim.updateMobs(self);
}

fn updateMobCombat(self: *GameState) void {
    MobSim.updateMobCombat(self);
}

/// Try to attack the entity the player is looking at. Returns true if an entity
/// was attacked (so the caller can skip block breaking).
pub fn attackEntity(self: *GameState) bool {
    return PlayerActions.attackEntity(self);
}

fn spawnPickupGhost(self: *GameState, entity_idx: u32) void {
    MobSim.spawnPickupGhost(self, entity_idx);
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
    // Interpolate remote players
    const alpha64: f64 = @floatCast(alpha);
    for (self.remote_players.items) |*rp| {
        rp.render_pos = .{
            @floatCast(rp.prev_pos[0] + (rp.pos[0] - rp.prev_pos[0]) * alpha64),
            @floatCast(rp.prev_pos[1] + (rp.pos[1] - rp.prev_pos[1]) * alpha64),
            @floatCast(rp.prev_pos[2] + (rp.pos[2] - rp.prev_pos[2]) * alpha64),
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
pub fn markDirtyFromNetwork(self: *GameState, wx: i32, wy: i32, wz: i32) void {
    self.markDirty(wx, wy, wz, false);
}

pub fn markDirty(self: *GameState, wx: i32, wy: i32, wz: i32, player: bool) void {
    const affected = WorldState.affectedChunks(wx, wy, wz);
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
    const base_key = WorldState.ChunkKey.fromWorldPos(wx, wy, wz);
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
/// Falls back to full markDirty if the light map isn't ready for incremental updates.
pub fn markDirtyIncremental(self: *GameState, wx: i32, wy: i32, wz: i32, old_block: BlockState.StateId) void {
    const base_key = WorldState.ChunkKey.fromWorldPos(wx, wy, wz);

    // Try to set an incremental update on the center chunk's LightMap.
    if (self.light_maps.get(base_key)) |lm| {
        if (!lm.dirty and lm.incremental == null) {
            lm.incremental = .{
                .lx = @intCast(@mod(wx, @as(i32, WorldState.CHUNK_SIZE))),
                .ly = @intCast(@mod(wy, @as(i32, WorldState.CHUNK_SIZE))),
                .lz = @intCast(@mod(wz, @as(i32, WorldState.CHUNK_SIZE))),
                .old_block = old_block,
            };

            // Enqueue center chunk + geometry-affected neighbors for processing.
            // Don't mark any LightMaps dirty yet — the worker will cascade
            // to face-neighbors only if the incremental update changes boundary values.
            const affected = WorldState.affectedChunks(wx, wy, wz);
            for (affected.keys[0..affected.count]) |key| {
                self.streaming.player_dirty_chunks.add(key);
            }
            return;
        }
    }

    // Fall back to full recompute.
    self.markDirty(wx, wy, wz, true);
}

pub fn breakBlockNoDrop(self: *GameState) void {
    BlockOps.breakBlockNoDrop(self);
}

pub fn breakBlock(self: *GameState) void {
    BlockOps.breakBlock(self);
}

pub fn placeBlock(self: *GameState) void {
    BlockOps.placeBlock(self);
}

pub fn pickBlock(self: *GameState) void {
    BlockOps.pickBlock(self);
}

/// Drop items from an arbitrary inventory slot. If `drop_all` is true, drops the entire stack.
pub fn dropFromSlot(self: *GameState, slot: u8, drop_all: bool) void {
    const stack = self.slotPtr(slot);
    if (stack.isEmpty()) return;
    if (self.entities.count >= Entity.MAX_ENTITIES) return;

    const P = Entity.PLAYER;
    const epos = self.entities.pos[P];
    const forward = self.camera.getForward();
    const drop_pos = [3]f32{
        epos[0] + forward.x * 0.5,
        epos[1] + EYE_OFFSET + forward.y * 0.5,
        epos[2] + forward.z * 0.5,
    };
    const drop_count: u8 = if (drop_all or stack.isTool()) stack.count else 1;
    const prev_count = self.entities.count;
    self.entities.spawnItemDropWithDurability(drop_pos, stack.block, drop_count, stack.durability);
    if (self.entities.count <= prev_count) return;

    const last = self.entities.count - 1;
    self.entities.vel[last] = .{
        forward.x * 5.0,
        forward.y * 5.0 + 2.0,
        forward.z * 5.0,
    };

    if (drop_all or stack.count <= 1) {
        stack.* = Entity.ItemStack.EMPTY;
    } else {
        stack.count -= 1;
    }
}

/// Drop carried item as an entity in the world.
/// If `drop_all` is false, drops only 1 from the stack.
pub fn dropCarried(self: *GameState, drop_all: bool) void {
    if (self.inv.carried_item.isEmpty()) return;
    if (self.entities.count >= Entity.MAX_ENTITIES) return;

    const P = Entity.PLAYER;
    const epos = self.entities.pos[P];
    const forward = self.camera.getForward();
    const drop_pos = [3]f32{
        epos[0] + forward.x * 0.5,
        epos[1] + EYE_OFFSET + forward.y * 0.5,
        epos[2] + forward.z * 0.5,
    };
    const drop_count: u8 = if (drop_all or self.inv.carried_item.isTool()) self.inv.carried_item.count else 1;
    const prev_count = self.entities.count;
    self.entities.spawnItemDropWithDurability(drop_pos, self.inv.carried_item.block, drop_count, self.inv.carried_item.durability);
    if (self.entities.count <= prev_count) return;

    const last = self.entities.count - 1;
    self.entities.vel[last] = .{
        forward.x * 5.0,
        forward.y * 5.0 + 2.0,
        forward.z * 5.0,
    };

    if (drop_all or self.inv.carried_item.count <= 1) {
        self.inv.carried_item = Entity.ItemStack.EMPTY;
    } else {
        self.inv.carried_item.count -= 1;
    }
}

pub fn decrementSelectedStack(self: *GameState) void {
    if (self.game_mode == .creative) return; // infinite blocks in creative
    const stack = &self.playerInv().hotbar[self.inv.selected_slot];
    if (stack.count > 1) {
        stack.count -= 1;
    } else {
        stack.* = Entity.ItemStack.EMPTY;
    }
}

/// Try to add an item stack to the player's inventory.
/// Returns true if the entire stack was added, false if inventory is full.
pub fn addToInventory(self: *GameState, item: Entity.ItemStack) bool {
    if (item.isEmpty()) return true;
    var remaining = item.count;
    const inv = self.playerInv();

    // Tools go to first empty slot only (no merge — unique durability)
    if (item.isTool()) {
        for (&inv.hotbar) |*s| {
            if (s.isEmpty()) {
                s.* = item;
                return true;
            }
        }
        for (&inv.main) |*s| {
            if (s.isEmpty()) {
                s.* = item;
                return true;
            }
        }
        return false;
    }

    // First pass: merge into existing matching stacks (hotbar then main)
    for (&inv.hotbar) |*s| {
        if (!s.isEmpty() and !s.isTool() and s.block == item.block and s.count < Entity.MAX_STACK) {
            const transfer = @min(Entity.MAX_STACK - s.count, remaining);
            s.count += transfer;
            remaining -= transfer;
            if (remaining == 0) return true;
        }
    }
    for (&inv.main) |*s| {
        if (!s.isEmpty() and !s.isTool() and s.block == item.block and s.count < Entity.MAX_STACK) {
            const transfer = @min(Entity.MAX_STACK - s.count, remaining);
            s.count += transfer;
            remaining -= transfer;
            if (remaining == 0) return true;
        }
    }

    // Second pass: find empty slots
    for (&inv.hotbar) |*s| {
        if (s.isEmpty()) {
            s.* = .{ .block = item.block, .count = remaining };
            return true;
        }
    }
    for (&inv.main) |*s| {
        if (s.isEmpty()) {
            s.* = .{ .block = item.block, .count = remaining };
            return true;
        }
    }

    return false;
}

/// Sample block light (RGB) and sky light at a world position with
/// trilinear interpolation across the 8 surrounding blocks.
/// Returns { block_r, block_g, block_b, sky } as floats in [0,1].
pub fn sampleLightAt(self: *const GameState, wx: f32, wy: f32, wz: f32) [4]f32 {
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
    var result = [4]f32{ 0, 0, 0, 0 };
    var total_w: f32 = 0;
    for (0..2) |dz| {
        for (0..2) |dy| {
            for (0..2) |dx| {
                const bx = x0 + @as(i32, @intCast(dx));
                const by = y0 + @as(i32, @intCast(dy));
                const bz = z0 + @as(i32, @intCast(dz));

                // Skip opaque blocks — they have 0 light and would darken the result
                if (BlockState.isOpaque(self.chunk_map.getBlock(bx, by, bz))) continue;

                const wx_ = if (dx == 0) 1.0 - fx else fx;
                const wy_ = if (dy == 0) 1.0 - fy else fy;
                const wz_ = if (dz == 0) 1.0 - fz else fz;
                const w = wx_ * wy_ * wz_;
                total_w += w;

                const sample = self.readLightRaw(bx, by, bz);
                result[0] += sample[0] * w;
                result[1] += sample[1] * w;
                result[2] += sample[2] * w;
                result[3] += sample[3] * w;
            }
        }
    }
    // Normalize by actual weight sum (redistributes opaque block weight)
    if (total_w > 0.001) {
        const inv = 1.0 / total_w;
        result[0] *= inv;
        result[1] *= inv;
        result[2] *= inv;
        result[3] *= inv;
    }
    return result;
}

fn readLightRaw(self: *const GameState, bx: i32, by: i32, bz: i32) [4]f32 {
    const key = WorldState.ChunkKey.fromWorldPos(bx, by, bz);
    const lm = self.light_maps.get(key) orelse return .{ 0, 0, 0, 0 };
    const lx: usize = @intCast(@mod(bx, @as(i32, WorldState.CHUNK_SIZE)));
    const ly: usize = @intCast(@mod(by, @as(i32, WorldState.CHUNK_SIZE)));
    const lz: usize = @intCast(@mod(bz, @as(i32, WorldState.CHUNK_SIZE)));
    const ci = WorldState.chunkIndex(lx, ly, lz);

    // Lock to prevent race with mesh worker recomputing light data
    const io = std.Io.Threaded.global_single_threaded.io();
    const lm_mut: *LightMapMod.LightMap = @constCast(lm);
    lm_mut.mutex.lockUncancelable(io);
    defer lm_mut.mutex.unlock(io);

    const blk = lm.block_light.get(ci);
    const sky = lm.sky_light.get(ci);
    return .{
        @as(f32, @floatFromInt(blk[0])) / 255.0,
        @as(f32, @floatFromInt(blk[1])) / 255.0,
        @as(f32, @floatFromInt(blk[2])) / 255.0,
        @as(f32, @floatFromInt(sky)) / 255.0,
    };
}

pub fn queueChunkSave(self: *GameState, wx: i32, wy: i32, wz: i32) void {
    const s = self.streaming.storage orelse return;
    const key = WorldState.ChunkKey.fromWorldPos(wx, wy, wz);
    const chunk = self.chunk_map.get(key) orelse return;
    s.markDirty(key.cx, key.cy, key.cz, chunk);
}

pub fn worldTick(self: *GameState) void {
    ChunkManagement.worldTick(self);
}

fn reportPipelineStats(self: *GameState) void {
    ChunkManagement.reportPipelineStats(self);
}

fn scanUnloads(self: *GameState) void {
    ChunkManagement.scanUnloads(self);
}

pub fn applyUnloadsToGpu(
    self: *GameState,
    wr: *WorldRenderer,
    deferred_face_frees: []TlsfAllocator.Handle,
    deferred_face_free_count: *u32,
    deferred_light_frees: []TlsfAllocator.Handle,
    deferred_light_free_count: *u32,
) void {
    ChunkManagement.applyUnloadsToGpu(self, wr, deferred_face_frees, deferred_face_free_count, deferred_light_frees, deferred_light_free_count);
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
        const ptr = game_state.slotPtr(@intCast(i));
        try testing.expectEqual(&inv.hotbar[i], ptr);
    }
}

test "slotPtr: inventory slots 9-44" {
    var game_state = makeTestGameState();
    defer destroyTestGameState(&game_state);
    const inv = game_state.playerInv();
    for (0..INV_SIZE) |i| {
        const slot: u8 = @intCast(HOTBAR_SIZE + i);
        const ptr = game_state.slotPtr(slot);
        try testing.expectEqual(&inv.main[i], ptr);
    }
}

test "slotPtr: armor slots 45-48" {
    var game_state = makeTestGameState();
    defer destroyTestGameState(&game_state);
    const inv = game_state.playerInv();
    for (0..ARMOR_SLOTS) |i| {
        const slot: u8 = @intCast(HOTBAR_SIZE + INV_SIZE + i);
        const ptr = game_state.slotPtr(slot);
        try testing.expectEqual(&inv.armor[i], ptr);
    }
}

test "slotPtr: equip slots 49-52" {
    var game_state = makeTestGameState();
    defer destroyTestGameState(&game_state);
    const inv = game_state.playerInv();
    for (0..EQUIP_SLOTS) |i| {
        const slot: u8 = @intCast(HOTBAR_SIZE + INV_SIZE + ARMOR_SLOTS + i);
        const ptr = game_state.slotPtr(slot);
        try testing.expectEqual(&inv.equip[i], ptr);
    }
}

test "slotPtr: offhand slot 53" {
    var game_state = makeTestGameState();
    defer destroyTestGameState(&game_state);
    const inv = game_state.playerInv();
    const ptr = game_state.slotPtr(HOTBAR_SIZE + INV_SIZE + ARMOR_SLOTS + EQUIP_SLOTS);
    try testing.expectEqual(&inv.offhand, ptr);
}

test "clickSlot: pick up item from hotbar" {
    const S = Entity.ItemStack;
    const stone = S.of(BlockState.defaultState(.stone), 32);
    var game_state = makeTestGameState();
    defer destroyTestGameState(&game_state);
    game_state.playerInv().hotbar[0] = stone;
    game_state.inv.carried_item = S.EMPTY;

    game_state.clickSlot(0);

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

    game_state.clickSlot(0);

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

    game_state.clickSlot(0);

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

    game_state.quickMove(0);

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

    game_state.quickMove(HOTBAR_SIZE); // slot 9 = first inventory slot

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

    game_state.quickMove(0);

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

    const result = game_state.addToInventory(S.of(BlockState.defaultState(.stone), 3));
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

    const result = game_state.addToInventory(S.of(BlockState.defaultState(.dirt), 1));
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
