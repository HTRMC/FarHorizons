const std = @import("std");
const zlm = @import("zlm");
const Camera = @import("renderer/Camera.zig");
const WorldState = @import("world/WorldState.zig");
const BlockState = WorldState.BlockState;
const ChunkMap = @import("world/ChunkMap.zig").ChunkMap;
const ChunkPool = @import("world/ChunkPool.zig").ChunkPool;
const LightMapMod = @import("world/LightMap.zig");
const LightMap = LightMapMod.LightMap;
const LightMapPool = LightMapMod.LightMapPool;
pub const ChunkStreamer = @import("world/ChunkStreamer.zig").ChunkStreamer;
const TerrainGen = @import("world/TerrainGen.zig");
const Physics = @import("Physics.zig");
const Raycast = @import("Raycast.zig");
const Storage = @import("world/storage/Storage.zig");
const WorldRenderer = @import("renderer/vulkan/WorldRenderer.zig").WorldRenderer;
const TlsfAllocator = @import("allocators/TlsfAllocator.zig").TlsfAllocator;
const MeshWorker = @import("world/MeshWorker.zig").MeshWorker;
const LodWorker = @import("world/LodWorker.zig").LodWorker;
const SurfaceHeightMap = @import("world/SurfaceHeightMap.zig").SurfaceHeightMap;
const TransferPipeline = @import("renderer/vulkan/TransferPipeline.zig").TransferPipeline;
const Io = std.Io;

const GameState = @This();

pub const MovementMode = enum { flying, walking };
pub const EYE_OFFSET: f32 = 1.62;
pub const TICK_RATE: f32 = 30.0;
pub const TICK_INTERVAL: f32 = 1.0 / TICK_RATE;
pub const HOTBAR_SIZE: u8 = 9;
pub const INV_ROWS: u8 = 4;
pub const INV_COLS: u8 = 9;
pub const INV_SIZE: u8 = INV_ROWS * INV_COLS; // 36
pub const ARMOR_SLOTS: u8 = 4; // head, chest, legs, feet
pub const EQUIP_SLOTS: u8 = 4;

// Day/night cycle: 36000 ticks at 30Hz = 20 minutes per full day
pub const DAY_CYCLE: i64 = 36000;

pub const DayNightResult = struct {
    ambient_light: [3]f32,
    sky_color: [3]f32,
};

pub fn dayNightCycle(game_time: i64) DayNightResult {
    // dayTime is symmetric around midnight: 0 at midnight, DAY_CYCLE/2 at noon
    const cycle = @mod(game_time, DAY_CYCLE);
    const half = @divTrunc(DAY_CYCLE, 2);
    const day_time = @as(i64, @intCast(@abs(cycle - half)));

    const quarter = @divTrunc(DAY_CYCLE, 4);
    const sixteenth = @divTrunc(DAY_CYCLE, 16);

    const night_end = quarter - sixteenth; // 2250
    const day_start = quarter + sixteenth; // 3750

    if (day_time < night_end) {
        // Full night
        return .{
            .ambient_light = .{ 0.1, 0.1, 0.1 },
            .sky_color = .{ 0.02, 0.02, 0.06 },
        };
    } else if (day_time > day_start) {
        // Full day
        return .{
            .ambient_light = .{ 1.0, 1.0, 1.0 },
            .sky_color = .{ 0.224, 0.643, 0.918 },
        };
    } else {
        // Sunrise/sunset transition
        const range: f32 = @floatFromInt(day_start - night_end);
        const t: f32 = @as(f32, @floatFromInt(day_time - night_end)) / range;
        // Smoothstep for natural feel
        const s = t * t * (3.0 - 2.0 * t);

        // Ambient interpolation
        const ambient = 0.1 + 0.9 * s;

        // Sky color: night → warm sunrise/sunset → day
        // Red/orange leads, blue trails for warm sunrise tones
        const r_t = @min(1.0, s * 1.4); // red leads
        const g_t = s; // green is normal
        const b_t = @max(0.0, s * 0.7 + 0.3 * s * s); // blue trails

        return .{
            .ambient_light = .{ ambient, ambient, ambient },
            .sky_color = .{
                0.02 + (0.224 - 0.02) * r_t + 0.3 * r_t * (1.0 - r_t), // warm red bump
                0.02 + (0.643 - 0.02) * g_t + 0.1 * g_t * (1.0 - g_t), // slight warm green
                0.06 + (0.918 - 0.06) * b_t,
            },
        };
    }
}

// Initial load radius in chunks (per axis from center)
const LOAD_RADIUS_XZ: i32 = 2;
const LOAD_RADIUS_Y: i32 = 1;
const MAX_PENDING_UNLOADS: u32 = 256;

pub fn blockName(state: BlockState.StateId) []const u8 {
    return switch (BlockState.getBlock(state)) {
        .air => "Air",
        .glass => "Glass",
        .grass_block => "Grass",
        .dirt => "Dirt",
        .stone => "Stone",
        .glowstone => "Glowstone",
        .red_glowstone => "Red Glowstone",
        .crimson_glowstone => "Crimson Glowstone",
        .orange_glowstone => "Orange Glowstone",
        .peach_glowstone => "Peach Glowstone",
        .lime_glowstone => "Lime Glowstone",
        .green_glowstone => "Green Glowstone",
        .teal_glowstone => "Teal Glowstone",
        .cyan_glowstone => "Cyan Glowstone",
        .light_blue_glowstone => "Light Blue Glowstone",
        .blue_glowstone => "Blue Glowstone",
        .navy_glowstone => "Navy Glowstone",
        .indigo_glowstone => "Indigo Glowstone",
        .purple_glowstone => "Purple Glowstone",
        .magenta_glowstone => "Magenta Glowstone",
        .pink_glowstone => "Pink Glowstone",
        .hot_pink_glowstone => "Hot Pink Glowstone",
        .white_glowstone => "White Glowstone",
        .warm_white_glowstone => "Warm White Glowstone",
        .light_gray_glowstone => "Light Gray Glowstone",
        .gray_glowstone => "Gray Glowstone",
        .brown_glowstone => "Brown Glowstone",
        .tan_glowstone => "Tan Glowstone",
        .black_glowstone => "Black Glowstone",
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
        .oak_slab => "Oak Slab",
        .oak_stairs => "Oak Stairs",
        .torch => "Torch",
        .ladder => "Ladder",
        .oak_door => "Oak Door",
        .oak_fence => "Oak Fence",
    };
}

pub fn blockColor(state: BlockState.StateId) [4]f32 {
    return switch (BlockState.getBlock(state)) {
        .air => .{ 0.0, 0.0, 0.0, 0.0 },
        .glass => .{ 0.8, 0.9, 1.0, 0.4 },
        .grass_block => .{ 0.3, 0.7, 0.2, 1.0 },
        .dirt => .{ 0.6, 0.4, 0.2, 1.0 },
        .stone => .{ 0.5, 0.5, 0.5, 1.0 },
        .glowstone => .{ 1.0, 0.9, 0.5, 1.0 },
        .red_glowstone => .{ 1.0, 0.2, 0.12, 1.0 },
        .crimson_glowstone => .{ 0.71, 0.08, 0.16, 1.0 },
        .orange_glowstone => .{ 1.0, 0.59, 0.12, 1.0 },
        .peach_glowstone => .{ 1.0, 0.71, 0.47, 1.0 },
        .lime_glowstone => .{ 0.47, 1.0, 0.16, 1.0 },
        .green_glowstone => .{ 0.16, 0.78, 0.24, 1.0 },
        .teal_glowstone => .{ 0.12, 0.71, 0.59, 1.0 },
        .cyan_glowstone => .{ 0.12, 0.86, 0.86, 1.0 },
        .light_blue_glowstone => .{ 0.31, 0.63, 1.0, 1.0 },
        .blue_glowstone => .{ 0.16, 0.31, 1.0, 1.0 },
        .navy_glowstone => .{ 0.12, 0.16, 0.71, 1.0 },
        .indigo_glowstone => .{ 0.39, 0.16, 0.86, 1.0 },
        .purple_glowstone => .{ 0.63, 0.2, 1.0, 1.0 },
        .magenta_glowstone => .{ 0.86, 0.2, 0.78, 1.0 },
        .pink_glowstone => .{ 1.0, 0.43, 0.67, 1.0 },
        .hot_pink_glowstone => .{ 1.0, 0.2, 0.47, 1.0 },
        .white_glowstone => .{ 0.94, 0.94, 1.0, 1.0 },
        .warm_white_glowstone => .{ 1.0, 0.86, 0.71, 1.0 },
        .light_gray_glowstone => .{ 0.71, 0.71, 0.75, 1.0 },
        .gray_glowstone => .{ 0.47, 0.47, 0.51, 1.0 },
        .brown_glowstone => .{ 0.63, 0.39, 0.2, 1.0 },
        .tan_glowstone => .{ 0.78, 0.67, 0.43, 1.0 },
        .black_glowstone => .{ 0.16, 0.14, 0.2, 1.0 },
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
        .oak_slab => .{ 0.7, 0.55, 0.33, 1.0 },
        .oak_stairs => .{ 0.7, 0.55, 0.33, 1.0 },
        .torch => .{ 0.9, 0.7, 0.2, 1.0 },
        .ladder => .{ 0.6, 0.45, 0.25, 1.0 },
        .oak_door => .{ 0.7, 0.55, 0.33, 1.0 },
        .oak_fence => .{ 0.7, 0.55, 0.33, 1.0 },
    };
}

allocator: std.mem.Allocator,
camera: Camera,
chunk_map: ChunkMap,
chunk_pool: ChunkPool,
light_maps: std.AutoHashMap(WorldState.ChunkKey, *LightMap),
light_map_pool: LightMapPool,
surface_height_map: SurfaceHeightMap,
entity_pos: [3]f32,
entity_vel: [3]f32,
entity_on_ground: bool,
entity_in_water: bool,
eyes_in_water: bool,
water_vision_time: u16,
entity_on_ladder: bool,
mode: MovementMode,
input_move: [3]f32,
jump_requested: bool,
jump_cooldown: u8,
hit_result: ?Raycast.BlockHitResult,
dirty_chunks: DirtyChunkSet,
debug_camera_active: bool,
third_person: bool = false,
third_person_crosshair: bool = false,
overdraw_mode: bool,
saved_camera: Camera,

selected_slot: u8 = 0,
hotbar: [HOTBAR_SIZE]BlockState.StateId = .{
    BlockState.defaultState(.grass_block), BlockState.defaultState(.dirt),  BlockState.defaultState(.stone),
    BlockState.defaultState(.sand),        BlockState.defaultState(.snow),  BlockState.defaultState(.gravel),
    BlockState.defaultState(.glass),       BlockState.defaultState(.glowstone), BlockState.defaultState(.water),
},
inventory: [INV_SIZE]BlockState.StateId = .{
    BlockState.defaultState(.cobblestone), BlockState.defaultState(.oak_log),      BlockState.defaultState(.oak_planks),   BlockState.defaultState(.bricks),       BlockState.defaultState(.bedrock),       BlockState.defaultState(.gold_ore),      BlockState.defaultState(.iron_ore),      BlockState.defaultState(.coal_ore),      BlockState.defaultState(.diamond_ore),
    BlockState.defaultState(.sponge),      BlockState.defaultState(.pumice),       BlockState.defaultState(.wool),         BlockState.defaultState(.gold_block),   BlockState.defaultState(.iron_block),    BlockState.defaultState(.diamond_block), BlockState.defaultState(.bookshelf),     BlockState.defaultState(.obsidian),      BlockState.defaultState(.oak_leaves),
    BlockState.fromBlockProps(.oak_slab, @intFromEnum(BlockState.SlabType.bottom)), BlockState.fromBlockProps(.oak_stairs, @intFromEnum(BlockState.Facing.south)), BlockState.defaultState(.torch), BlockState.fromBlockProps(.ladder, @intFromEnum(BlockState.Facing.south)), BlockState.makeDoorState(.south, .bottom, false), BlockState.defaultState(.oak_fence), BlockState.defaultState(.red_glowstone), BlockState.defaultState(.crimson_glowstone), BlockState.defaultState(.orange_glowstone),
    BlockState.defaultState(.peach_glowstone), BlockState.defaultState(.lime_glowstone), BlockState.defaultState(.green_glowstone), BlockState.defaultState(.teal_glowstone), BlockState.defaultState(.cyan_glowstone), BlockState.defaultState(.light_blue_glowstone), BlockState.defaultState(.blue_glowstone), BlockState.defaultState(.navy_glowstone), BlockState.defaultState(.indigo_glowstone),
},
armor: [ARMOR_SLOTS]BlockState.StateId = .{BlockState.defaultState(.air)} ** ARMOR_SLOTS,
equip: [EQUIP_SLOTS]BlockState.StateId = .{BlockState.defaultState(.air)} ** EQUIP_SLOTS,
offhand: BlockState.StateId = BlockState.defaultState(.air),
carried_item: BlockState.StateId = BlockState.defaultState(.air),
inventory_open: bool = false,

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
pending_unload_keys: [MAX_PENDING_UNLOADS]WorldState.ChunkKey = undefined,
pending_unload_count: u16 = 0,
unload_scan_cursor: u32 = 0,

// Async initial load (ready when player's chunk is loaded+meshed AND count >= target)
initial_load_target: u32 = 0,
initial_load_ready: bool = true,

// Pipeline references for stats reporting (set by renderer)
mesh_worker: ?*MeshWorker = null,
lod_worker: ?*LodWorker = null,
transfer_pipeline: ?*TransferPipeline = null,
stats_last_time: ?Io.Timestamp = null,

game_time: i64 = 0,
debug_screens: u8 = 0,
show_chunk_borders: bool = false,
show_hitbox: bool = false,
show_ui: bool = true,
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

/// Get a pointer to the block in a unified slot index.
/// Slots 0-8: hotbar, 9-44: main inventory, 45-48: armor, 49-52: equip, 53: offhand.
pub fn slotPtr(self: *GameState, slot: u8) *BlockState.StateId {
    if (slot < HOTBAR_SIZE) return &self.hotbar[slot];
    if (slot < HOTBAR_SIZE + INV_SIZE) return &self.inventory[slot - HOTBAR_SIZE];
    if (slot < HOTBAR_SIZE + INV_SIZE + ARMOR_SLOTS) return &self.armor[slot - HOTBAR_SIZE - INV_SIZE];
    if (slot < HOTBAR_SIZE + INV_SIZE + ARMOR_SLOTS + EQUIP_SLOTS) return &self.equip[slot - HOTBAR_SIZE - INV_SIZE - ARMOR_SLOTS];
    return &self.offhand;
}

/// Click a slot: pick up, place, or swap with carried item.
pub fn clickSlot(self: *GameState, slot: u8) void {
    const ptr = self.slotPtr(slot);
    if (self.carried_item == BlockState.defaultState(.air) and ptr.* == BlockState.defaultState(.air)) return;
    const tmp = ptr.*;
    ptr.* = self.carried_item;
    self.carried_item = tmp;
}

/// Shift+click: move item between hotbar and main inventory.
/// Hotbar items go to first empty main slot, main/armor/offhand items go to first empty hotbar slot.
pub fn quickMove(self: *GameState, slot: u8) void {
    const air = BlockState.defaultState(.air);
    const ptr = self.slotPtr(slot);
    if (ptr.* == air) return;

    if (slot < HOTBAR_SIZE) {
        // Hotbar → main inventory
        for (&self.inventory) |*s| {
            if (s.* == air) {
                s.* = ptr.*;
                ptr.* = air;
                return;
            }
        }
    } else {
        // Main/armor/offhand → hotbar
        for (&self.hotbar) |*s| {
            if (s.* == air) {
                s.* = ptr.*;
                ptr.* = air;
                return;
            }
        }
    }
}

pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, world_name: []const u8, world_type_override: ?WorldState.WorldType) !GameState {
    var cam = Camera.init(width, height);
    const chunk_map = ChunkMap.init(allocator);
    const chunk_pool = ChunkPool.init(allocator);
    const light_maps = std.AutoHashMap(WorldState.ChunkKey, *LightMap).init(allocator);
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
        .entity_pos = .{ spawn_x, spawn_y, spawn_z },
        .entity_vel = .{ 0.0, 0.0, 0.0 },
        .entity_on_ground = false,
        .entity_in_water = false,
        .eyes_in_water = false,
        .water_vision_time = 0,
        .entity_on_ladder = false,
        .mode = .walking,
        .input_move = .{ 0.0, 0.0, 0.0 },
        .jump_requested = false,
        .jump_cooldown = 0,
        .hit_result = null,
        .dirty_chunks = DirtyChunkSet.init(allocator),
        .player_dirty_chunks = DirtyChunkSet.init(allocator),
        .world_seed = world_seed,
        .world_type = world_type,
        .storage = storage_inst,
        .streamer = undefined,
        .player_chunk = spawn_key,
        .streaming_initialized = false,
        .initial_load_ready = false,
        .initial_load_target = 75,
        .game_time = saved_game_time,
        .debug_camera_active = false,
        .overdraw_mode = false,
        .saved_camera = cam,
        .prev_entity_pos = .{ spawn_x, spawn_y, spawn_z },
        .prev_camera_pos = cam.position,
        .tick_camera_pos = cam.position,
        .render_entity_pos = .{ spawn_x, spawn_y, spawn_z },
    };
}

pub fn save(self: *GameState) void {
    const s = self.storage orelse return;
    const io = std.Io.Threaded.global_single_threaded.io();
    const save_start = std.Io.Clock.now(.awake, io);

    s.savePlayerData(Storage.LOCAL_PLAYER_UUID, .{
        .x = self.entity_pos[0],
        .y = self.entity_pos[1],
        .z = self.entity_pos[2],
        .yaw = self.camera.yaw,
        .pitch = self.camera.pitch,
    });

    s.saveGameTime(self.game_time);

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
    self.dirty_chunks.deinit();
    self.player_dirty_chunks.deinit();
    if (self.storage) |s| s.deinit();
    var lm_it = self.light_maps.iterator();
    while (lm_it.next()) |entry| {
        self.light_map_pool.release(entry.value_ptr.*);
    }
    self.light_maps.deinit();
    self.light_map_pool.deinit();
    self.surface_height_map.deinit();
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

fn updateWaterState(self: *GameState) void {
    const floori = Physics.floori;

    // In flying mode, use camera position; in walking mode, use entity position
    const pos_x: f32 = if (self.mode == .flying) self.camera.position.x else self.entity_pos[0];
    const pos_y: f32 = if (self.mode == .flying) self.camera.position.y - EYE_OFFSET else self.entity_pos[1];
    const pos_z: f32 = if (self.mode == .flying) self.camera.position.z else self.entity_pos[2];
    const px = floori(pos_x);
    const pz = floori(pos_z);

    const feet_block = self.chunk_map.getBlock(px, floori(pos_y), pz);
    const eye_block = self.chunk_map.getBlock(px, floori(pos_y + EYE_OFFSET), pz);

    self.entity_in_water = (BlockState.getBlock(feet_block) == .water);
    self.eyes_in_water = (BlockState.getBlock(eye_block) == .water);

    // Ladder detection: check feet and mid-body
    self.entity_on_ladder = isLadder(feet_block) or
        isLadder(self.chunk_map.getBlock(px, floori(pos_y + 0.9), pz));

    // Water vision time: MC 0-600 ticks @20Hz → 0-900 @30Hz
    if (self.eyes_in_water) {
        if (self.water_vision_time < 900) self.water_vision_time += 1;
    } else {
        self.water_vision_time = 0;
    }
}

fn isLadder(state: BlockState.StateId) bool {
    return BlockState.getBlock(state) == .ladder;
}

/// Returns 0.0 to 1.0 water vision factor (MC two-phase curve).
pub fn waterVision(self: *const GameState) f32 {
    const t: f32 = @floatFromInt(self.water_vision_time);
    const a = std.math.clamp(t / 150.0, 0.0, 1.0);
    const b = std.math.clamp((t - 150.0) / 750.0, 0.0, 1.0);
    return a * 0.6 + b * 0.4;
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
    self.game_time +%= 1;
    self.prev_entity_pos = self.entity_pos;
    self.prev_camera_pos = self.camera.position;

    // Detect water state before physics (both modes need it for fog)
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

            self.entity_pos = .{
                self.camera.position.x,
                self.camera.position.y - EYE_OFFSET,
                self.camera.position.z,
            };
        },
        .walking => {

            if (self.jump_cooldown > 0) {
                self.jump_cooldown -= 1;
            } else if (self.jump_requested and self.entity_on_ladder) {
                // Climb up ladder
                self.entity_vel[1] = Physics.LADDER_CLIMB_SPEED;
            } else if (self.jump_requested and !self.entity_in_water and self.entity_on_ground) {
                self.entity_vel[1] = 8.7;
            }
            self.jump_requested = false;

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
        if (self.light_maps.get(key)) |lm| {
            lm.dirty = true;
        }
    }
    // Always dirty face-neighbor LightMaps so light propagation updates
    // (block changes can affect light reaching neighboring chunks)
    const base_key = WorldState.ChunkKey.fromWorldPos(wx, wy, wz);
    const offsets = [6][3]i32{ .{ -1, 0, 0 }, .{ 1, 0, 0 }, .{ 0, -1, 0 }, .{ 0, 1, 0 }, .{ 0, 0, -1 }, .{ 0, 0, 1 } };
    for (offsets) |off| {
        const nk = WorldState.ChunkKey{
            .cx = base_key.cx + off[0],
            .cy = base_key.cy + off[1],
            .cz = base_key.cz + off[2],
        };
        if (self.light_maps.get(nk)) |nlm| {
            nlm.dirty = true;
        }
        target.add(nk);
    }
}

/// Try to use incremental light update for a single block change.
/// Falls back to full markDirty if the light map isn't ready for incremental updates.
fn markDirtyIncremental(self: *GameState, wx: i32, wy: i32, wz: i32, old_block: BlockState.StateId) void {
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
                self.player_dirty_chunks.add(key);
            }
            return;
        }
    }

    // Fall back to full recompute.
    self.markDirty(wx, wy, wz, true);
}

pub fn breakBlock(self: *GameState) void {
    const hit = self.hit_result orelse return;
    const wx = hit.block_pos[0];
    const wy = hit.block_pos[1];
    const wz = hit.block_pos[2];
    const old_block = self.chunk_map.getBlock(wx, wy, wz);

    const air = BlockState.defaultState(.air);

    // Door breaking: remove both halves
    if (BlockState.isDoor(old_block)) {
        self.chunk_map.setBlock(wx, wy, wz, air);
        self.markDirtyIncremental(wx, wy, wz, old_block);
        self.queueChunkSave(wx, wy, wz);

        // Find and remove the other half
        const other_y: i32 = if (BlockState.isDoorBottom(old_block)) wy + 1 else wy - 1;
        const other_block = self.chunk_map.getBlock(wx, other_y, wz);
        if (BlockState.isDoor(other_block)) {
            self.chunk_map.setBlock(wx, other_y, wz, air);
            self.markDirtyIncremental(wx, other_y, wz, other_block);
            self.queueChunkSave(wx, other_y, wz);

            const key2 = WorldState.ChunkKey.fromWorldPos(wx, other_y, wz);
            const lx2: usize = @intCast(@mod(wx, @as(i32, WorldState.CHUNK_SIZE)));
            const lz2: usize = @intCast(@mod(wz, @as(i32, WorldState.CHUNK_SIZE)));
            self.surface_height_map.rebuildColumnAt(key2.cx, key2.cz, lx2, lz2, &self.chunk_map);
        }

        const key = WorldState.ChunkKey.fromWorldPos(wx, wy, wz);
        const local_x: usize = @intCast(@mod(wx, @as(i32, WorldState.CHUNK_SIZE)));
        const local_z: usize = @intCast(@mod(wz, @as(i32, WorldState.CHUNK_SIZE)));
        self.surface_height_map.rebuildColumnAt(key.cx, key.cz, local_x, local_z, &self.chunk_map);
        self.updateFenceNeighbors(wx, wy, wz);
        self.updateStairNeighbors(wx, wy, wz);
        self.hit_result = Raycast.raycast(&self.chunk_map, self.camera.position, self.camera.getForward());
        return;
    }

    self.chunk_map.setBlock(wx, wy, wz, air);
    // Rebuild surface height for this column (broken block may have been the surface)
    const key = WorldState.ChunkKey.fromWorldPos(wx, wy, wz);
    const local_x: usize = @intCast(@mod(wx, @as(i32, WorldState.CHUNK_SIZE)));
    const local_z: usize = @intCast(@mod(wz, @as(i32, WorldState.CHUNK_SIZE)));
    self.surface_height_map.rebuildColumnAt(key.cx, key.cz, local_x, local_z, &self.chunk_map);
    self.markDirtyIncremental(wx, wy, wz, old_block);
    self.queueChunkSave(wx, wy, wz);
    self.updateFenceNeighbors(wx, wy, wz);
    self.updateStairNeighbors(wx, wy, wz);
    self.hit_result = Raycast.raycast(&self.chunk_map, self.camera.position, self.camera.getForward());
}

fn toggleDoor(self: *GameState, wx: i32, wy: i32, wz: i32, block: BlockState.StateId) void {
    // Toggle this half
    const new_block = BlockState.toggleDoor(block);
    const old_block = self.chunk_map.getBlock(wx, wy, wz);
    self.chunk_map.setBlock(wx, wy, wz, new_block);
    self.markDirtyIncremental(wx, wy, wz, old_block);
    self.queueChunkSave(wx, wy, wz);

    // Toggle the other half
    const other_y: i32 = if (BlockState.isDoorBottom(block)) wy + 1 else wy - 1;
    const other_block = self.chunk_map.getBlock(wx, other_y, wz);
    if (BlockState.isDoor(other_block)) {
        const new_other = BlockState.toggleDoor(other_block);
        self.chunk_map.setBlock(wx, other_y, wz, new_other);
        self.markDirtyIncremental(wx, other_y, wz, other_block);
        self.queueChunkSave(wx, other_y, wz);
    }

    self.hit_result = Raycast.raycast(&self.chunk_map, self.camera.position, self.camera.getForward());
}

/// Check 4 horizontal neighbors and update any fences to reflect new connections.
fn updateFenceNeighbors(self: *GameState, wx: i32, wy: i32, wz: i32) void {
    const deltas = [4][2]i32{ .{ 0, -1 }, .{ 0, 1 }, .{ 1, 0 }, .{ -1, 0 } };
    for (deltas) |d| {
        const nx = wx + d[0];
        const nz = wz + d[1];
        const neighbor = self.chunk_map.getBlock(nx, wy, nz);
        if (!BlockState.isFence(neighbor)) continue;

        const new_variant = BlockState.fenceFromConnections(
            BlockState.connectsToFence(self.chunk_map.getBlock(nx, wy, nz - 1)),
            BlockState.connectsToFence(self.chunk_map.getBlock(nx, wy, nz + 1)),
            BlockState.connectsToFence(self.chunk_map.getBlock(nx + 1, wy, nz)),
            BlockState.connectsToFence(self.chunk_map.getBlock(nx - 1, wy, nz)),
        );
        if (new_variant != neighbor) {
            self.chunk_map.setBlock(nx, wy, nz, new_variant);
            self.markDirtyIncremental(nx, wy, nz, neighbor);
            self.queueChunkSave(nx, wy, nz);
        }
    }
}

/// Update stair shape of the block at (wx,wy,wz) and its 4 horizontal neighbors.
fn updateStairNeighbors(self: *GameState, wx: i32, wy: i32, wz: i32) void {
    // Update the placed stair itself
    self.updateSingleStairShape(wx, wy, wz);
    // Update 4 horizontal neighbors
    const deltas = [4][2]i32{ .{ 0, -1 }, .{ 0, 1 }, .{ 1, 0 }, .{ -1, 0 } };
    for (deltas) |d| {
        self.updateSingleStairShape(wx + d[0], wy, wz + d[1]);
    }
}

fn updateSingleStairShape(self: *GameState, wx: i32, wy: i32, wz: i32) void {
    const state = self.chunk_map.getBlock(wx, wy, wz);
    if (!BlockState.isStairs(state)) return;
    const facing = BlockState.getFacing(state).?;
    const half = BlockState.getHalf(state).?;
    const new_shape = computeStairShape(self, wx, wy, wz, facing, half);
    const old_shape = BlockState.getStairShape(state).?;
    if (new_shape != old_shape) {
        const new_state = BlockState.makeStairState(facing, half, new_shape);
        self.chunk_map.setBlock(wx, wy, wz, new_state);
        self.markDirtyIncremental(wx, wy, wz, state);
        self.queueChunkSave(wx, wy, wz);
    }
}

/// Minecraft's stair shape algorithm:
/// 1. Check block in the facing direction (step side): perpendicular stair → outer corner
/// 2. Check block opposite to facing (back side): perpendicular stair → inner corner
fn computeStairShape(self: *GameState, wx: i32, wy: i32, wz: i32, facing: BlockState.Facing, half: BlockState.Half) BlockState.StairShape {
    const fd = facingDelta(facing);
    // Check step side (in facing direction) → inner corner (fills the inside of a turn)
    const step_neighbor = self.chunk_map.getBlock(wx + fd[0], wy, wz + fd[1]);
    if (BlockState.isStairs(step_neighbor)) {
        const sf = BlockState.getFacing(step_neighbor).?;
        const sh = BlockState.getHalf(step_neighbor).?;
        if (sh == half and isPerpendicular(facing, sf)) {
            if (isLeftOf(facing, sf)) return .inner_left;
            return .inner_right;
        }
    }
    // Check back side (opposite to facing) → outer corner (outside of a turn)
    const back_neighbor = self.chunk_map.getBlock(wx - fd[0], wy, wz - fd[1]);
    if (BlockState.isStairs(back_neighbor)) {
        const bf = BlockState.getFacing(back_neighbor).?;
        const bh = BlockState.getHalf(back_neighbor).?;
        if (bh == half and isPerpendicular(facing, bf)) {
            if (isLeftOf(facing, bf)) return .outer_left;
            return .outer_right;
        }
    }
    return .straight;
}

/// Delta to move in the facing direction (towards the step/open side).
fn facingDelta(facing: BlockState.Facing) [2]i32 {
    return switch (facing) {
        .south => .{ 0, 1 }, // step at +Z
        .north => .{ 0, -1 }, // step at -Z
        .east => .{ 1, 0 }, // step at +X
        .west => .{ -1, 0 }, // step at -X
    };
}

fn isPerpendicular(a: BlockState.Facing, b: BlockState.Facing) bool {
    // south/north are Z-axis, east/west are X-axis
    const a_axis = @intFromEnum(a) >> 1; // 0=Z-axis, 1=X-axis
    const b_axis = @intFromEnum(b) >> 1;
    return a_axis != b_axis;
}

fn isLeftOf(facing: BlockState.Facing, other: BlockState.Facing) bool {
    // "Left of" means: if you face `facing`, is `other` pointing to your left?
    return switch (facing) {
        .south => other == .east,
        .north => other == .west,
        .east => other == .north,
        .west => other == .south,
    };
}

/// Minecraft-style slab replacement: determines if placing a slab on an existing slab
/// should merge into a double slab. A bottom slab can be replaced when clicking its top
/// face or the upper half of a side face; a top slab when clicking its bottom face or
/// the lower half of a side face.
fn slabCanBeReplaced(existing: BlockState.StateId, hit: Raycast.BlockHitResult) bool {
    const slab_type = BlockState.getSlabType(existing) orelse return false;
    const above = hit.hit_pos[1] - @floor(hit.hit_pos[1]) > 0.5;
    return switch (slab_type) {
        .bottom => hit.direction == .up or (above and hit.direction != .down),
        .top => hit.direction == .down or (!above and hit.direction != .up),
        .double => false,
    };
}

fn resolveOrientation(block_state: BlockState.StateId, yaw: f32, hit: Raycast.BlockHitResult) BlockState.StateId {
    const block = BlockState.getBlock(block_state);
    switch (block) {
        .oak_stairs => {
            const pi = std.math.pi;
            const norm_yaw = @mod(yaw, 2.0 * pi);
            const facing: BlockState.Facing = if (norm_yaw >= 0.25 * pi and norm_yaw < 0.75 * pi)
                .east
            else if (norm_yaw >= 0.75 * pi and norm_yaw < 1.25 * pi)
                .north
            else if (norm_yaw >= 1.25 * pi and norm_yaw < 1.75 * pi)
                .west
            else
                .south;
            // Determine half: clicking bottom face → top, clicking top face → bottom
            // Clicking side: upper portion → top, lower portion → bottom
            const half: BlockState.Half = if (hit.direction == .down)
                .top
            else if (hit.direction == .up)
                .bottom
            else blk: {
                const frac_y = hit.hit_pos[1] - @floor(hit.hit_pos[1]);
                break :blk if (frac_y >= 0.5) .top else .bottom;
            };
            return BlockState.makeStairState(facing, half, .straight);
        },
        .oak_slab => {
            if (hit.direction == .down) return BlockState.fromBlockProps(.oak_slab, @intFromEnum(BlockState.SlabType.top));
            if (hit.direction == .up) return BlockState.fromBlockProps(.oak_slab, @intFromEnum(BlockState.SlabType.bottom));
            const frac_y = hit.hit_pos[1] - @floor(hit.hit_pos[1]);
            if (frac_y >= 0.5) return BlockState.fromBlockProps(.oak_slab, @intFromEnum(BlockState.SlabType.top));
            return BlockState.fromBlockProps(.oak_slab, @intFromEnum(BlockState.SlabType.bottom));
        },
        .torch => {
            return switch (hit.direction) {
                .up => BlockState.fromBlockProps(.torch, @intFromEnum(BlockState.Placement.standing)),
                .south => BlockState.fromBlockProps(.torch, @intFromEnum(BlockState.Placement.wall_north)),
                .north => BlockState.fromBlockProps(.torch, @intFromEnum(BlockState.Placement.wall_south)),
                .east => BlockState.fromBlockProps(.torch, @intFromEnum(BlockState.Placement.wall_west)),
                .west => BlockState.fromBlockProps(.torch, @intFromEnum(BlockState.Placement.wall_east)),
                .down => BlockState.fromBlockProps(.torch, @intFromEnum(BlockState.Placement.standing)),
            };
        },
        .ladder => {
            return switch (hit.direction) {
                .south => BlockState.fromBlockProps(.ladder, @intFromEnum(BlockState.Facing.south)),
                .north => BlockState.fromBlockProps(.ladder, @intFromEnum(BlockState.Facing.north)),
                .east => BlockState.fromBlockProps(.ladder, @intFromEnum(BlockState.Facing.east)),
                .west => BlockState.fromBlockProps(.ladder, @intFromEnum(BlockState.Facing.west)),
                else => block_state,
            };
        },
        .oak_door => {
            const pi = std.math.pi;
            const norm_yaw = @mod(yaw, 2.0 * pi);
            const facing: BlockState.Facing = if (norm_yaw >= 0.25 * pi and norm_yaw < 0.75 * pi)
                .east
            else if (norm_yaw >= 0.75 * pi and norm_yaw < 1.25 * pi)
                .north
            else if (norm_yaw >= 1.25 * pi and norm_yaw < 1.75 * pi)
                .west
            else
                .south;
            return BlockState.makeDoorState(facing, .bottom, false);
        },
        .oak_fence => return BlockState.defaultState(.oak_fence),
        else => return block_state,
    }
}

pub fn placeBlock(self: *GameState) void {
    const hit = self.hit_result orelse return;

    const air = BlockState.defaultState(.air);

    // If clicking on a door, toggle it instead of placing
    const clicked_block = self.chunk_map.getBlock(hit.block_pos[0], hit.block_pos[1], hit.block_pos[2]);
    if (BlockState.isDoor(clicked_block)) {
        self.toggleDoor(hit.block_pos[0], hit.block_pos[1], hit.block_pos[2], clicked_block);
        return;
    }

    var block_state = self.hotbar[self.selected_slot];
    if (block_state == air) return;

    // Double slab: placing a slab on a compatible existing slab merges into a full block
    if (BlockState.getBlock(block_state) == .oak_slab) {
        if (slabCanBeReplaced(clicked_block, hit)) {
            const bx = hit.block_pos[0];
            const by = hit.block_pos[1];
            const bz = hit.block_pos[2];
            const double_slab = BlockState.fromBlockProps(.oak_slab, @intFromEnum(BlockState.SlabType.double));
            self.chunk_map.setBlock(bx, by, bz, double_slab);
            if (BlockState.isOpaque(double_slab)) {
                const key = WorldState.ChunkKey.fromWorldPos(bx, by, bz);
                const local_x: usize = @intCast(@mod(bx, @as(i32, WorldState.CHUNK_SIZE)));
                const local_z: usize = @intCast(@mod(bz, @as(i32, WorldState.CHUNK_SIZE)));
                self.surface_height_map.updateBlockPlaced(key.cx, key.cz, local_x, local_z, by);
            }
            self.markDirtyIncremental(bx, by, bz, clicked_block);
            self.queueChunkSave(bx, by, bz);
            self.updateFenceNeighbors(bx, by, bz);
            self.hit_result = Raycast.raycast(&self.chunk_map, self.camera.position, self.camera.getForward());
            return;
        }
    }

    const n = hit.direction.normal();
    const px = hit.block_pos[0] + n[0];
    const py = hit.block_pos[1] + n[1];
    const pz = hit.block_pos[2] + n[2];
    if (BlockState.isSolid(self.chunk_map.getBlock(px, py, pz))) return;
    if (BlockState.isSolid(block_state) and blockOverlapsPlayer(px, py, pz, self.entity_pos)) return;

    // Orient stairs based on player yaw, and slabs based on hit face/position
    block_state = resolveOrientation(block_state, self.camera.yaw, hit);

    // Fence placement: calculate connections from neighbors
    if (BlockState.isFence(block_state)) {
        block_state = BlockState.fenceFromConnections(
            BlockState.connectsToFence(self.chunk_map.getBlock(px, py, pz - 1)),
            BlockState.connectsToFence(self.chunk_map.getBlock(px, py, pz + 1)),
            BlockState.connectsToFence(self.chunk_map.getBlock(px + 1, py, pz)),
            BlockState.connectsToFence(self.chunk_map.getBlock(px - 1, py, pz)),
        );
    }

    // Door placement: need space for both halves
    if (BlockState.isDoor(block_state)) {
        // Check that the block above is free
        const above = self.chunk_map.getBlock(px, py + 1, pz);
        if (BlockState.isSolid(above)) return;
        if (BlockState.getBlock(above) != .air and BlockState.getBlock(above) != .water) return;

        // Place bottom half
        const old_bottom = self.chunk_map.getBlock(px, py, pz);
        self.chunk_map.setBlock(px, py, pz, block_state);
        self.markDirtyIncremental(px, py, pz, old_bottom);
        self.queueChunkSave(px, py, pz);

        // Place top half
        const top_type = BlockState.doorBottomToTop(block_state);
        const old_top = self.chunk_map.getBlock(px, py + 1, pz);
        self.chunk_map.setBlock(px, py + 1, pz, top_type);
        self.markDirtyIncremental(px, py + 1, pz, old_top);
        self.queueChunkSave(px, py + 1, pz);

        self.hit_result = Raycast.raycast(&self.chunk_map, self.camera.position, self.camera.getForward());
        return;
    }

    const old_block = self.chunk_map.getBlock(px, py, pz);
    self.chunk_map.setBlock(px, py, pz, block_state);
    // Update surface height if placing an opaque block
    if (BlockState.isOpaque(block_state)) {
        const key = WorldState.ChunkKey.fromWorldPos(px, py, pz);
        const local_x: usize = @intCast(@mod(px, @as(i32, WorldState.CHUNK_SIZE)));
        const local_z: usize = @intCast(@mod(pz, @as(i32, WorldState.CHUNK_SIZE)));
        self.surface_height_map.updateBlockPlaced(key.cx, key.cz, local_x, local_z, py);
    }
    self.markDirtyIncremental(px, py, pz, old_block);
    self.queueChunkSave(px, py, pz);

    // Update neighboring fences and stairs when placing any block
    self.updateFenceNeighbors(px, py, pz);
    self.updateStairNeighbors(px, py, pz);

    self.hit_result = Raycast.raycast(&self.chunk_map, self.camera.position, self.camera.getForward());
}

pub fn pickBlock(self: *GameState) void {
    const hit = self.hit_result orelse return;
    const raw_state = self.chunk_map.getBlock(hit.block_pos[0], hit.block_pos[1], hit.block_pos[2]);
    if (raw_state == BlockState.defaultState(.air)) return;

    // Normalize oriented variants to their canonical form for inventory
    const block_state = BlockState.getCanonicalState(raw_state);

    // If already in hotbar, just select that slot
    for (self.hotbar, 0..) |slot_block, i| {
        if (slot_block == block_state) {
            self.selected_slot = @intCast(i);
            return;
        }
    }

    // Otherwise replace the current slot
    self.hotbar[self.selected_slot] = block_state;
}

fn blockOverlapsPlayer(bx: i32, by: i32, bz: i32, pos: [3]f32) bool {
    const fbx: f32 = @floatFromInt(bx);
    const fby: f32 = @floatFromInt(by);
    const fbz: f32 = @floatFromInt(bz);
    return fbx + 1.0 > pos[0] - Physics.HALF_W and fbx < pos[0] + Physics.HALF_W and
        fby + 1.0 > pos[1] and fby < pos[1] + Physics.HEIGHT and
        fbz + 1.0 > pos[2] - Physics.HALF_W and fbz < pos[2] + Physics.HALF_W;
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
        self.surface_height_map.updateFromChunk(result.key, result.chunk);
        const lm = self.light_map_pool.acquire();
        self.light_maps.put(result.key, lm) catch {};
        self.dirty_chunks.add(result.key);
        // Mark neighbors dirty so they re-mesh with the new neighbor present
        // Also mark their LightMaps dirty so light recomputes with the new chunk's data
        const offsets = [6][3]i32{ .{ -1, 0, 0 }, .{ 1, 0, 0 }, .{ 0, -1, 0 }, .{ 0, 1, 0 }, .{ 0, 0, -1 }, .{ 0, 0, 1 } };
        for (offsets) |off| {
            const nk = WorldState.ChunkKey{
                .cx = result.key.cx + off[0],
                .cy = result.key.cy + off[1],
                .cz = result.key.cz + off[2],
            };
            if (self.chunk_map.get(nk) != null) {
                self.dirty_chunks.add(nk);
                if (self.light_maps.get(nk)) |nlm| {
                    nlm.dirty = true;
                }
            }
        }
    }

    // Scan for chunks to unload (incremental cursor)
    self.scanUnloads();

    // Sync streamer + LOD worker player position + tick storage
    self.streamer.syncPlayerChunk(self.player_chunk);
    if (self.lod_worker) |lw| {
        lw.syncPlayerChunk(self.player_chunk);
    }
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

        if (self.light_maps.fetchRemove(key)) |lm_kv| {
            self.light_map_pool.release(lm_kv.value);
        }
        if (self.chunk_map.remove(key)) |chunk| {
            self.chunk_pool.release(chunk);
        }
        // Clean up surface height column if no chunks remain in this column
        if (!SurfaceHeightMap.hasChunksInColumn(key.cx, key.cz, &self.chunk_map)) {
            self.surface_height_map.removeColumn(key.cx, key.cz);
        }
    }
    self.pending_unload_count = 0;
}

/// Spiral search from (0,0) outward to find a valid spawn on dry land.
/// Checks that the spawn and surrounding area are above sea level.
fn findSpawn(seed: u64) [3]f32 {
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
    var gs: GameState = undefined;
    gs.hotbar = .{BlockState.defaultState(.grass_block)} ** HOTBAR_SIZE;
    gs.inventory = .{BlockState.defaultState(.air)} ** INV_SIZE;
    gs.armor = .{BlockState.defaultState(.air)} ** ARMOR_SLOTS;
    gs.equip = .{BlockState.defaultState(.air)} ** EQUIP_SLOTS;
    gs.offhand = BlockState.defaultState(.air);
    gs.carried_item = BlockState.defaultState(.air);
    gs.selected_slot = 0;
    return gs;
}

test "slotPtr: hotbar slots 0-8" {
    var gs = makeTestGameState();
    for (0..HOTBAR_SIZE) |i| {
        const ptr = gs.slotPtr(@intCast(i));
        try testing.expectEqual(&gs.hotbar[i], ptr);
    }
}

test "slotPtr: inventory slots 9-44" {
    var gs = makeTestGameState();
    for (0..INV_SIZE) |i| {
        const slot: u8 = @intCast(HOTBAR_SIZE + i);
        const ptr = gs.slotPtr(slot);
        try testing.expectEqual(&gs.inventory[i], ptr);
    }
}

test "slotPtr: armor slots 45-48" {
    var gs = makeTestGameState();
    for (0..ARMOR_SLOTS) |i| {
        const slot: u8 = @intCast(HOTBAR_SIZE + INV_SIZE + i);
        const ptr = gs.slotPtr(slot);
        try testing.expectEqual(&gs.armor[i], ptr);
    }
}

test "slotPtr: equip slots 49-52" {
    var gs = makeTestGameState();
    for (0..EQUIP_SLOTS) |i| {
        const slot: u8 = @intCast(HOTBAR_SIZE + INV_SIZE + ARMOR_SLOTS + i);
        const ptr = gs.slotPtr(slot);
        try testing.expectEqual(&gs.equip[i], ptr);
    }
}

test "slotPtr: offhand slot 53" {
    var gs = makeTestGameState();
    const ptr = gs.slotPtr(HOTBAR_SIZE + INV_SIZE + ARMOR_SLOTS + EQUIP_SLOTS);
    try testing.expectEqual(&gs.offhand, ptr);
}

test "clickSlot: pick up item from hotbar" {
    const air = BlockState.defaultState(.air);
    const stone = BlockState.defaultState(.stone);
    var gs = makeTestGameState();
    gs.hotbar[0] = stone;
    gs.carried_item = air;

    gs.clickSlot(0);

    try testing.expectEqual(air, gs.hotbar[0]);
    try testing.expectEqual(stone, gs.carried_item);
}

test "clickSlot: swap carried with slot" {
    const stone = BlockState.defaultState(.stone);
    const dirt = BlockState.defaultState(.dirt);
    var gs = makeTestGameState();
    gs.hotbar[0] = stone;
    gs.carried_item = dirt;

    gs.clickSlot(0);

    try testing.expectEqual(dirt, gs.hotbar[0]);
    try testing.expectEqual(stone, gs.carried_item);
}

test "clickSlot: both empty does nothing" {
    const air = BlockState.defaultState(.air);
    var gs = makeTestGameState();
    gs.hotbar[0] = air;
    gs.carried_item = air;

    gs.clickSlot(0);

    try testing.expectEqual(air, gs.hotbar[0]);
    try testing.expectEqual(air, gs.carried_item);
}

test "quickMove: hotbar to inventory" {
    const air = BlockState.defaultState(.air);
    const stone = BlockState.defaultState(.stone);
    var gs = makeTestGameState();
    gs.hotbar[0] = stone;
    gs.inventory[0] = air;

    gs.quickMove(0);

    try testing.expectEqual(air, gs.hotbar[0]);
    try testing.expectEqual(stone, gs.inventory[0]);
}

test "quickMove: inventory to hotbar" {
    const air = BlockState.defaultState(.air);
    const stone = BlockState.defaultState(.stone);
    const dirt = BlockState.defaultState(.dirt);
    var gs = makeTestGameState();
    gs.hotbar = .{dirt} ** HOTBAR_SIZE; // fill hotbar except slot 2
    gs.hotbar[2] = air;
    gs.inventory[0] = stone;

    gs.quickMove(HOTBAR_SIZE); // slot 9 = first inventory slot

    try testing.expectEqual(stone, gs.hotbar[2]);
    try testing.expectEqual(air, gs.inventory[0]);
}

test "quickMove: no empty target does nothing" {
    const stone = BlockState.defaultState(.stone);
    const dirt = BlockState.defaultState(.dirt);
    var gs = makeTestGameState();
    gs.hotbar[0] = stone;
    gs.inventory = .{dirt} ** INV_SIZE; // all full

    gs.quickMove(0);

    // Item stays in place
    try testing.expectEqual(stone, gs.hotbar[0]);
}

test "slot boundary constants" {
    // Verify slot layout: hotbar(9) + inventory(36) + armor(4) + equip(4) + offhand(1) = 54
    try testing.expectEqual(@as(u8, 9), HOTBAR_SIZE);
    try testing.expectEqual(@as(u8, 36), INV_SIZE);
    try testing.expectEqual(@as(u8, 4), ARMOR_SLOTS);
    try testing.expectEqual(@as(u8, 4), EQUIP_SLOTS);
    try testing.expectEqual(@as(u8, 54), HOTBAR_SIZE + INV_SIZE + ARMOR_SLOTS + EQUIP_SLOTS + 1);
}
