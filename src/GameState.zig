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
pub const Entity = @import("Entity.zig");
pub const Item = @import("Item.zig");
const Raycast = @import("Raycast.zig");
const Storage = @import("world/storage/Storage.zig");
const app_config = @import("app_config.zig");
const WorldRenderer = @import("renderer/vulkan/WorldRenderer.zig").WorldRenderer;
const TlsfAllocator = @import("allocators/TlsfAllocator.zig").TlsfAllocator;
const MeshWorker = @import("world/MeshWorker.zig").MeshWorker;
const LodWorker = @import("world/LodWorker.zig").LodWorker;
const SurfaceHeightMap = @import("world/SurfaceHeightMap.zig").SurfaceHeightMap;
const TransferPipeline = @import("renderer/vulkan/TransferPipeline.zig").TransferPipeline;
const Io = std.Io;

const GameState = @This();

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

pub const MAX_PICKUP_GHOSTS = 8;
pub const PickupGhost = struct {
    active: bool = false,
    start_pos: [3]f32 = .{ 0, 0, 0 },
    block: BlockState.StateId = 0,
    item_count: u8 = 0,
    bob_offset: f32 = 0,
    age_ticks: u32 = 0,
    tick: u8 = 0, // 0-2, animation lasts 3 ticks
};

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

pub fn itemName(id: u16) []const u8 {
    if (Item.isToolItem(id)) return Item.toolName(id);
    return blockName(id);
}

pub fn itemColor(id: u16) [4]f32 {
    if (Item.isToolItem(id)) return Item.toolColor(id);
    return blockColor(id);
}

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
swing_requested: bool,
dirty_chunks: DirtyChunkSet,
debug_camera_active: bool,
third_person: bool = false,
third_person_crosshair: bool = false,
overdraw_mode: bool,
saved_camera: Camera,

selected_slot: u8 = 0,
carried_item: Entity.ItemStack = Entity.ItemStack.EMPTY,
inventory_open: bool = false,

pickup_ghosts: [MAX_PICKUP_GHOSTS]PickupGhost = .{PickupGhost{}} ** MAX_PICKUP_GHOSTS,
render_alpha: f32 = 0,

game_mode: GameMode = .creative,
break_progress: f32 = 0,
breaking_pos: ?[3]i32 = null,
attack_held: bool = false,
attack_damage: f32 = 1.0,
health: f32 = 20.0,
max_health: f32 = 20.0,
air_supply: u16 = 300,
max_air: u16 = 300,
damage_cooldown: u8 = 0,
fall_start_y: f32 = 0.0,
was_on_ground: bool = true,

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

prev_camera_pos: zlm.Vec3,
tick_camera_pos: zlm.Vec3,

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
    const ptr = self.slotPtr(slot);
    if (self.carried_item.isEmpty() and ptr.isEmpty()) return;
    const tmp = ptr.*;
    ptr.* = self.carried_item;
    self.carried_item = tmp;
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
    var cam = Camera.init(width, height);
    const chunk_map = ChunkMap.init(allocator);
    const chunk_pool = ChunkPool.init(allocator);
    var light_maps = std.AutoHashMap(WorldState.ChunkKey, *LightMap).init(allocator);
    light_maps.ensureTotalCapacity(@import("world/ChunkMap.zig").PREALLOCATED_CAPACITY) catch {};
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
            break :blk store;
        },
        .game_mode = game_mode,
        .health = saved_health,
        .air_supply = saved_air,
        .fall_start_y = spawn_y,
        .mode = .walking,
        .input_move = .{ 0.0, 0.0, 0.0 },
        .jump_requested = false,
        .jump_cooldown = 0,
        .hit_result = null,
        .swing_requested = false,
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
        .prev_camera_pos = cam.position,
        .tick_camera_pos = cam.position,
    };
}

pub fn save(self: *GameState) void {
    const s = self.storage orelse return;
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
        .health = self.health,
        .air_supply = self.air_supply,
        .inventory = self.entities.inventory[Entity.PLAYER],
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
    // Free entity inventories
    for (self.entities.inventory[0..self.entities.count]) |inv| {
        if (inv) |ptr| self.allocator.destroy(ptr);
    }
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
            self.fall_start_y = self.entities.pos[P][1];
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
    if (self.game_mode != .survival or self.damage_cooldown > 0) return;
    self.health = @max(self.health - amount, 0.0);
    self.damage_cooldown = 15; // 0.5s invincibility
    if (self.health <= 0.0) self.die();
}

fn dropInventoryWithScatter(self: *GameState, slots: []Entity.ItemStack, pos: [3]f32, random: std.Random) void {
    for (slots) |*stack| {
        if (!stack.isEmpty()) {
            self.spawnScatterDrop(pos, stack.*, random);
            stack.* = Entity.ItemStack.EMPTY;
        }
    }
}

fn spawnScatterDrop(self: *GameState, pos: [3]f32, item: Entity.ItemStack, random: std.Random) void {
    const prev_count = self.entities.count;
    self.entities.spawnItemDropWithDurability(pos, item.block, item.count, item.durability);
    if (self.entities.count <= prev_count) return;

    // MC death scatter: random direction, random speed 0-0.5, upward 0.2
    const last = self.entities.count - 1;
    const speed = random.float(f32) * 0.5;
    const angle = random.float(f32) * std.math.tau;
    self.entities.vel[last] = .{
        -@sin(angle) * speed,
        0.2,
        @cos(angle) * speed,
    };
    self.entities.pickup_cooldown[last] = 60; // 2s before pickup (longer than normal drops)
}

fn die(self: *GameState) void {
    const P = Entity.PLAYER;
    const death_pos = self.entities.pos[P];
    const inv = self.playerInv();

    // Drop all inventory items with MC-style random radial explosion
    var rng = std.Random.DefaultPrng.init(@bitCast(self.game_time));
    const random = rng.random();
    self.dropInventoryWithScatter(&inv.hotbar, death_pos, random);
    self.dropInventoryWithScatter(&inv.main, death_pos, random);
    if (!inv.offhand.isEmpty()) {
        self.spawnScatterDrop(death_pos, inv.offhand, random);
        inv.offhand = Entity.ItemStack.EMPTY;
    }

    // Respawn at world spawn
    const spawn = findSpawn(self.world_seed);
    self.entities.pos[P] = spawn;
    self.entities.prev_pos[P] = spawn;
    self.entities.vel[P] = .{ 0, 0, 0 };
    self.entities.flags[P].on_ground = true;
    self.camera.position = zlm.Vec3.init(spawn[0], spawn[1] + EYE_OFFSET, spawn[2]);
    self.prev_camera_pos = self.camera.position;
    self.tick_camera_pos = self.camera.position;

    self.health = self.max_health;
    self.air_supply = self.max_air;
    self.damage_cooldown = 30; // 1s post-respawn immunity
    self.was_on_ground = true;
    self.fall_start_y = spawn[1];
}

fn updateFallDamage(self: *GameState) void {
    if (self.game_mode != .survival) return;
    const P = Entity.PLAYER;
    const flags = self.entities.flags[P];
    const pos_y = self.entities.pos[P][1];

    if (!self.was_on_ground and flags.on_ground and !flags.in_water) {
        const damage = self.fall_start_y - pos_y - 3.0;
        if (damage > 0) self.takeDamage(damage);
    }

    if (flags.on_ground or flags.in_water) {
        self.fall_start_y = pos_y;
    } else {
        self.fall_start_y = @max(self.fall_start_y, pos_y);
    }

    self.was_on_ground = flags.on_ground;
}

fn updateDrowning(self: *GameState) void {
    if (self.game_mode != .survival) return;
    const P = Entity.PLAYER;
    if (self.entities.flags[P].eyes_in_water) {
        if (self.air_supply > 0) {
            self.air_supply -= 1;
        } else {
            // Drowning damage: 1 HP every 30 ticks (1 second)
            if (@mod(self.game_time, 30) == 0) {
                self.takeDamage(1.0);
            }
        }
    } else {
        self.air_supply = @min(self.air_supply + 5, self.max_air);
    }
}

pub fn fixedUpdate(self: *GameState, move_speed: f32) void {
    const P = Entity.PLAYER;
    self.game_time +%= 1;
    self.entities.prev_pos[P] = self.entities.pos[P];
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

            self.entities.pos[P] = .{
                self.camera.position.x,
                self.camera.position.y - EYE_OFFSET,
                self.camera.position.z,
            };
        },
        .walking => {
            const flags = self.entities.flags[P];

            if (self.jump_cooldown > 0) {
                self.jump_cooldown -= 1;
            } else if (self.jump_requested and flags.on_ladder) {
                // Climb up ladder
                self.entities.vel[P][1] = Physics.LADDER_CLIMB_SPEED;
            } else if (self.jump_requested and !flags.in_water and flags.on_ground) {
                self.entities.vel[P][1] = 8.7;
            }
            self.jump_requested = false;

            Physics.updateEntity(&self.entities, P, &self.chunk_map, self.input_move, self.camera.yaw, TICK_INTERVAL);

            const epos = self.entities.pos[P];
            self.camera.position = zlm.Vec3.init(
                epos[0],
                epos[1] + EYE_OFFSET,
                epos[2],
            );
        },
    }

    // Survival damage systems
    if (self.damage_cooldown > 0) self.damage_cooldown -= 1;
    if (self.mode == .walking) {
        self.updateFallDamage();
        self.updateDrowning();
    }

    // Hold-to-break in survival mode
    self.updateBreakProgress();

    // Update attack damage based on held item
    self.updateAttackDamage();

    // Update item drop entities (iterate backwards for safe despawn)
    self.updateItemDrops();

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

fn updateBreakProgress(self: *GameState) void {
    if (self.game_mode != .survival) return;
    if (!self.attack_held) {
        if (self.break_progress > 0) {
            self.break_progress = 0;
            self.breaking_pos = null;
        }
        return;
    }

    const hit = self.hit_result orelse {
        self.break_progress = 0;
        self.breaking_pos = null;
        return;
    };

    const target_pos = hit.block_pos;

    // Reset if target changed
    if (self.breaking_pos) |bp| {
        if (bp[0] != target_pos[0] or bp[1] != target_pos[1] or bp[2] != target_pos[2]) {
            self.break_progress = 0;
        }
    }
    self.breaking_pos = target_pos;

    const block_state = self.chunk_map.getBlock(target_pos[0], target_pos[1], target_pos[2]);
    const hardness = BlockState.getHardness(block_state);

    // Unbreakable
    if (hardness < 0) return;

    // Instant break
    if (hardness == 0) {
        self.breakBlock();
        self.break_progress = 0;
        self.breaking_pos = null;
        return;
    }

    // Calculate tool multiplier
    var tool_multiplier: f32 = 1.0;
    const held_slot = self.playerInv().hotbar[self.selected_slot];
    if (held_slot.isTool()) {
        if (Item.toolFromId(held_slot.block)) |tool_info| {
            const preferred = BlockState.getPreferredTool(block_state);
            if (preferred != null and preferred.? == tool_info.tool_type) {
                tool_multiplier = Item.tierStats(tool_info.tier).mining_speed;
            }
        }
    }

    const break_time = hardness * 1.5 / tool_multiplier;
    const speed_per_tick = 1.0 / (break_time * TICK_RATE);
    self.break_progress += speed_per_tick;

    if (self.break_progress >= 1.0) {
        // Check if tool can harvest (requires_tool check)
        const can_harvest = !BlockState.requiresTool(block_state) or (tool_multiplier > 1.0);
        if (!can_harvest) {
            // Break the block but don't drop it
            self.breakBlockNoDrop();
        } else {
            self.breakBlock();
        }

        // Durability cost
        if (held_slot.isTool()) {
            const slot = &self.playerInv().hotbar[self.selected_slot];
            if (slot.durability > 1) {
                slot.durability -= 1;
            } else {
                slot.* = Entity.ItemStack.EMPTY;
            }
        }

        self.break_progress = 0;
        self.breaking_pos = null;
    }
}

fn updateAttackDamage(self: *GameState) void {
    const held = self.playerInv().hotbar[self.selected_slot];
    if (held.isTool()) {
        if (Item.toolFromId(held.block)) |info| {
            self.attack_damage = Item.baseAttackDamage(info.tool_type) + Item.tierStats(info.tier).attack_bonus;
            return;
        }
    }
    self.attack_damage = 1.0;
}

fn updateItemDrops(self: *GameState) void {
    const P = Entity.PLAYER;
    const player_pos = self.entities.pos[P];
    const MERGE_RADIUS: f32 = 1.0;

    // Advance pickup ghost animations
    for (&self.pickup_ghosts) |*ghost| {
        if (ghost.active) {
            ghost.tick += 1;
            if (ghost.tick >= 3) ghost.active = false;
        }
    }

    // Iterate backwards so swap-remove is safe
    var i: u32 = self.entities.count;
    while (i > 1) {
        i -= 1;
        if (self.entities.kind[i] != .item_drop) continue;

        // Age and despawn
        self.entities.age_ticks[i] += 1;
        if (self.entities.age_ticks[i] >= Entity.DESPAWN_TICKS) {
            self.entities.despawn(i);
            continue;
        }

        // Cooldown
        if (self.entities.pickup_cooldown[i] > 0) {
            self.entities.pickup_cooldown[i] -= 1;
        }

        // Physics
        self.entities.prev_pos[i] = self.entities.pos[i];
        Physics.updateEntity(&self.entities, i, &self.chunk_map, .{ 0, 0, 0 }, 0, TICK_INTERVAL);

        // AABB-based pickup (1.0 block horizontal, 0.5 block vertical from player feet to head)
        if (self.entities.pickup_cooldown[i] == 0) {
            const dp = self.entities.pos[i];
            const dx = @abs(dp[0] - player_pos[0]);
            const dz = @abs(dp[2] - player_pos[2]);
            const dy_min = dp[1] - (player_pos[1] + 1.8); // above player head
            const dy_max = dp[1] - (player_pos[1] - 0.5); // below player feet
            if (dx < 1.0 and dz < 1.0 and dy_min < 0.5 and dy_max > -0.5) {
                const item = Entity.ItemStack{
                    .block = self.entities.item_block[i],
                    .count = self.entities.item_count[i],
                    .durability = self.entities.item_durability[i],
                };
                if (self.addToInventory(item)) {
                    // Spawn pickup ghost animation before despawning
                    self.spawnPickupGhost(i);
                    self.entities.despawn(i);
                    continue;
                }
            }
        }

        // Merge nearby item drops of the same type (skip tools — unique durability)
        // MC-style throttle: every 2 ticks if moving, every 40 ticks if stationary
        const merge_interval: u32 = if (self.entities.flags[i].on_ground) 40 else 2;
        if (!Item.isToolItem(self.entities.item_block[i]) and self.entities.item_count[i] < Entity.MAX_STACK and @mod(self.entities.age_ticks[i], merge_interval) == 0) {
            var j: u32 = 1;
            while (j < i) {
                if (self.entities.kind[j] != .item_drop or
                    self.entities.item_block[j] != self.entities.item_block[i] or
                    Item.isToolItem(self.entities.item_block[j]))
                {
                    j += 1;
                    continue;
                }
                const dp = self.entities.pos[j];
                const ip = self.entities.pos[i];
                const mdx = dp[0] - ip[0];
                const mdy = dp[1] - ip[1];
                const mdz = dp[2] - ip[2];
                if (mdx * mdx + mdy * mdy + mdz * mdz < MERGE_RADIUS * MERGE_RADIUS) {
                    // Merge newer (i) into older (j) so the grounded item survives
                    const space = Entity.MAX_STACK - self.entities.item_count[j];
                    if (space > 0) {
                        const transfer = @min(space, self.entities.item_count[i]);
                        self.entities.item_count[j] += transfer;
                        self.entities.item_count[i] -= transfer;
                        if (self.entities.item_count[i] == 0) {
                            self.entities.despawn(i);
                            break; // i is gone, move on
                        }
                    }
                }
                j += 1;
            }
        }
    }
}

fn spawnPickupGhost(self: *GameState, entity_idx: u32) void {
    // Find first inactive slot (or oldest if all active)
    var best: usize = 0;
    var best_tick: u8 = 0;
    for (self.pickup_ghosts, 0..) |ghost, idx| {
        if (!ghost.active) {
            best = idx;
            break;
        }
        if (ghost.tick > best_tick) {
            best_tick = ghost.tick;
            best = idx;
        }
    }
    self.pickup_ghosts[best] = .{
        .active = true,
        .start_pos = self.entities.render_pos[entity_idx],
        .block = self.entities.item_block[entity_idx],
        .item_count = self.entities.item_count[entity_idx],
        .bob_offset = self.entities.bob_offset[entity_idx],
        .age_ticks = self.entities.age_ticks[entity_idx],
        .tick = 0,
    };
}

pub fn interpolateForRender(self: *GameState, alpha: f32) void {
    self.render_alpha = alpha;
    const P = Entity.PLAYER;
    self.tick_camera_pos = self.camera.position;
    // Interpolate all entities
    for (0..self.entities.count) |i| {
        self.entities.render_pos[i] = lerpArray3(self.entities.prev_pos[i], self.entities.pos[i], alpha);
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

pub fn breakBlockNoDrop(self: *GameState) void {
    self.breakBlockImpl(false);
}

pub fn breakBlock(self: *GameState) void {
    self.breakBlockImpl(true);
}

fn breakBlockImpl(self: *GameState, allow_drop: bool) void {
    self.swing_requested = true;
    const hit = self.hit_result orelse return;
    const wx = hit.block_pos[0];
    const wy = hit.block_pos[1];
    const wz = hit.block_pos[2];
    const old_block = self.chunk_map.getBlock(wx, wy, wz);

    const air = BlockState.defaultState(.air);

    // Don't drop bedrock or water
    const drop_block = BlockState.getBlock(old_block);
    const should_drop = allow_drop and drop_block != .bedrock and drop_block != .water and drop_block != .air;

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
        if (should_drop) {
            const drop_pos = [3]f32{
                @as(f32, @floatFromInt(wx)) + 0.5,
                @as(f32, @floatFromInt(wy)) + 0.5,
                @as(f32, @floatFromInt(wz)) + 0.5,
            };
            self.entities.spawnItemDrop(drop_pos, BlockState.getCanonicalState(old_block), 1);
        }
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
    if (should_drop) {
        const drop_pos = [3]f32{
            @as(f32, @floatFromInt(wx)) + 0.5,
            @as(f32, @floatFromInt(wy)) + 0.5,
            @as(f32, @floatFromInt(wz)) + 0.5,
        };
        self.entities.spawnItemDrop(drop_pos, BlockState.getCanonicalState(old_block), 1);
    }
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
    self.swing_requested = true;

    // If clicking on a door, toggle it instead of placing
    const clicked_block = self.chunk_map.getBlock(hit.block_pos[0], hit.block_pos[1], hit.block_pos[2]);
    if (BlockState.isDoor(clicked_block)) {
        self.toggleDoor(hit.block_pos[0], hit.block_pos[1], hit.block_pos[2], clicked_block);
        return;
    }

    const stack = &self.playerInv().hotbar[self.selected_slot];
    if (stack.isEmpty()) return;
    if (stack.isTool()) return; // tools can't be placed as blocks
    var block_state = stack.block;

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
            self.decrementSelectedStack();
            return;
        }
    }

    const n = hit.direction.normal();
    const px = hit.block_pos[0] + n[0];
    const py = hit.block_pos[1] + n[1];
    const pz = hit.block_pos[2] + n[2];
    if (BlockState.isSolid(self.chunk_map.getBlock(px, py, pz))) return;
    if (BlockState.isSolid(block_state) and blockOverlapsPlayer(px, py, pz, self.entities.pos[Entity.PLAYER])) return;

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
        self.decrementSelectedStack();
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
    self.decrementSelectedStack();
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
    if (self.carried_item.isEmpty()) return;
    if (self.entities.count >= Entity.MAX_ENTITIES) return;

    const P = Entity.PLAYER;
    const epos = self.entities.pos[P];
    const forward = self.camera.getForward();
    const drop_pos = [3]f32{
        epos[0] + forward.x * 0.5,
        epos[1] + EYE_OFFSET + forward.y * 0.5,
        epos[2] + forward.z * 0.5,
    };
    const drop_count: u8 = if (drop_all or self.carried_item.isTool()) self.carried_item.count else 1;
    const prev_count = self.entities.count;
    self.entities.spawnItemDropWithDurability(drop_pos, self.carried_item.block, drop_count, self.carried_item.durability);
    if (self.entities.count <= prev_count) return;

    const last = self.entities.count - 1;
    self.entities.vel[last] = .{
        forward.x * 5.0,
        forward.y * 5.0 + 2.0,
        forward.z * 5.0,
    };

    if (drop_all or self.carried_item.count <= 1) {
        self.carried_item = Entity.ItemStack.EMPTY;
    } else {
        self.carried_item.count -= 1;
    }
}

fn decrementSelectedStack(self: *GameState) void {
    if (self.game_mode == .creative) return; // infinite blocks in creative
    const stack = &self.playerInv().hotbar[self.selected_slot];
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

pub fn pickBlock(self: *GameState) void {
    const hit = self.hit_result orelse return;
    const raw_state = self.chunk_map.getBlock(hit.block_pos[0], hit.block_pos[1], hit.block_pos[2]);
    if (raw_state == BlockState.defaultState(.air)) return;

    // Normalize oriented variants to their canonical form for inventory
    const block_state = BlockState.getCanonicalState(raw_state);

    // If already in hotbar, just select that slot
    const inv = self.playerInv();
    for (inv.hotbar, 0..) |slot, i| {
        if (slot.block == block_state) {
            self.selected_slot = @intCast(i);
            return;
        }
    }

    // Survival: only select, never spawn items
    if (self.game_mode == .survival) return;

    // Creative: replace the current slot with a full stack
    // If current slot holds a tool, find first non-tool slot instead
    var target_slot = self.selected_slot;
    if (inv.hotbar[target_slot].isTool()) {
        for (inv.hotbar, 0..) |s, idx| {
            if (!s.isTool()) {
                target_slot = @intCast(idx);
                break;
            }
        }
    }
    inv.hotbar[target_slot] = .{ .block = block_state, .count = Entity.MAX_STACK };
    self.selected_slot = target_slot;
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

fn blockOverlapsPlayer(bx: i32, by: i32, bz: i32, pos: [3]f32) bool {
    const fbx: f32 = @floatFromInt(bx);
    const fby: f32 = @floatFromInt(by);
    const fbz: f32 = @floatFromInt(bz);
    return fbx + 1.0 > pos[0] - Physics.PLAYER_HALF_W and fbx < pos[0] + Physics.PLAYER_HALF_W and
        fby + 1.0 > pos[1] and fby < pos[1] + Physics.PLAYER_HEIGHT and
        fbz + 1.0 > pos[2] - Physics.PLAYER_HALF_W and fbz < pos[2] + Physics.PLAYER_HALF_W;
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
    gs.entities = Entity.EntityStore{};
    _ = gs.entities.spawn(.player, .{ 0, 0, 0 });
    const inv = testing.allocator.create(Entity.Inventory) catch @panic("alloc failed");
    inv.* = .{
        .hotbar = .{Entity.ItemStack.of(BlockState.defaultState(.grass_block), 64)} ** HOTBAR_SIZE,
    };
    gs.entities.inventory[Entity.PLAYER] = inv;
    gs.carried_item = Entity.ItemStack.EMPTY;
    gs.selected_slot = 0;
    return gs;
}

fn destroyTestGameState(gs: *GameState) void {
    if (gs.entities.inventory[Entity.PLAYER]) |inv| {
        testing.allocator.destroy(inv);
    }
}

test "slotPtr: hotbar slots 0-8" {
    var gs = makeTestGameState();
    defer destroyTestGameState(&gs);
    const inv = gs.playerInv();
    for (0..HOTBAR_SIZE) |i| {
        const ptr = gs.slotPtr(@intCast(i));
        try testing.expectEqual(&inv.hotbar[i], ptr);
    }
}

test "slotPtr: inventory slots 9-44" {
    var gs = makeTestGameState();
    defer destroyTestGameState(&gs);
    const inv = gs.playerInv();
    for (0..INV_SIZE) |i| {
        const slot: u8 = @intCast(HOTBAR_SIZE + i);
        const ptr = gs.slotPtr(slot);
        try testing.expectEqual(&inv.main[i], ptr);
    }
}

test "slotPtr: armor slots 45-48" {
    var gs = makeTestGameState();
    defer destroyTestGameState(&gs);
    const inv = gs.playerInv();
    for (0..ARMOR_SLOTS) |i| {
        const slot: u8 = @intCast(HOTBAR_SIZE + INV_SIZE + i);
        const ptr = gs.slotPtr(slot);
        try testing.expectEqual(&inv.armor[i], ptr);
    }
}

test "slotPtr: equip slots 49-52" {
    var gs = makeTestGameState();
    defer destroyTestGameState(&gs);
    const inv = gs.playerInv();
    for (0..EQUIP_SLOTS) |i| {
        const slot: u8 = @intCast(HOTBAR_SIZE + INV_SIZE + ARMOR_SLOTS + i);
        const ptr = gs.slotPtr(slot);
        try testing.expectEqual(&inv.equip[i], ptr);
    }
}

test "slotPtr: offhand slot 53" {
    var gs = makeTestGameState();
    defer destroyTestGameState(&gs);
    const inv = gs.playerInv();
    const ptr = gs.slotPtr(HOTBAR_SIZE + INV_SIZE + ARMOR_SLOTS + EQUIP_SLOTS);
    try testing.expectEqual(&inv.offhand, ptr);
}

test "clickSlot: pick up item from hotbar" {
    const S = Entity.ItemStack;
    const stone = S.of(BlockState.defaultState(.stone), 32);
    var gs = makeTestGameState();
    defer destroyTestGameState(&gs);
    gs.playerInv().hotbar[0] = stone;
    gs.carried_item = S.EMPTY;

    gs.clickSlot(0);

    try testing.expect(gs.playerInv().hotbar[0].isEmpty());
    try testing.expectEqual(stone.block, gs.carried_item.block);
    try testing.expectEqual(stone.count, gs.carried_item.count);
}

test "clickSlot: swap carried with slot" {
    const S = Entity.ItemStack;
    const stone = S.of(BlockState.defaultState(.stone), 32);
    const dirt = S.of(BlockState.defaultState(.dirt), 16);
    var gs = makeTestGameState();
    defer destroyTestGameState(&gs);
    gs.playerInv().hotbar[0] = stone;
    gs.carried_item = dirt;

    gs.clickSlot(0);

    try testing.expectEqual(dirt.block, gs.playerInv().hotbar[0].block);
    try testing.expectEqual(dirt.count, gs.playerInv().hotbar[0].count);
    try testing.expectEqual(stone.block, gs.carried_item.block);
    try testing.expectEqual(stone.count, gs.carried_item.count);
}

test "clickSlot: both empty does nothing" {
    const S = Entity.ItemStack;
    var gs = makeTestGameState();
    defer destroyTestGameState(&gs);
    gs.playerInv().hotbar[0] = S.EMPTY;
    gs.carried_item = S.EMPTY;

    gs.clickSlot(0);

    try testing.expect(gs.playerInv().hotbar[0].isEmpty());
    try testing.expect(gs.carried_item.isEmpty());
}

test "quickMove: hotbar to inventory" {
    const S = Entity.ItemStack;
    const stone = S.of(BlockState.defaultState(.stone), 32);
    var gs = makeTestGameState();
    defer destroyTestGameState(&gs);
    const inv = gs.playerInv();
    inv.hotbar[0] = stone;
    inv.main[0] = S.EMPTY;

    gs.quickMove(0);

    try testing.expect(inv.hotbar[0].isEmpty());
    try testing.expectEqual(stone.block, inv.main[0].block);
    try testing.expectEqual(stone.count, inv.main[0].count);
}

test "quickMove: inventory to hotbar" {
    const S = Entity.ItemStack;
    const stone = S.of(BlockState.defaultState(.stone), 32);
    const dirt = S.of(BlockState.defaultState(.dirt), 64);
    var gs = makeTestGameState();
    defer destroyTestGameState(&gs);
    const inv = gs.playerInv();
    inv.hotbar = .{dirt} ** HOTBAR_SIZE; // fill hotbar except slot 2
    inv.hotbar[2] = S.EMPTY;
    inv.main[0] = stone;

    gs.quickMove(HOTBAR_SIZE); // slot 9 = first inventory slot

    try testing.expectEqual(stone.block, inv.hotbar[2].block);
    try testing.expectEqual(stone.count, inv.hotbar[2].count);
    try testing.expect(inv.main[0].isEmpty());
}

test "quickMove: no empty target does nothing" {
    const S = Entity.ItemStack;
    const stone = S.of(BlockState.defaultState(.stone), 32);
    const dirt = S.of(BlockState.defaultState(.dirt), 64);
    var gs = makeTestGameState();
    defer destroyTestGameState(&gs);
    const inv = gs.playerInv();
    inv.hotbar[0] = stone;
    inv.main = .{dirt} ** INV_SIZE; // all full, different block

    gs.quickMove(0);

    // Item stays in place
    try testing.expectEqual(stone.block, inv.hotbar[0].block);
    try testing.expectEqual(stone.count, inv.hotbar[0].count);
}

test "addToInventory: merges into existing stack" {
    const S = Entity.ItemStack;
    var gs = makeTestGameState();
    defer destroyTestGameState(&gs);
    const inv = gs.playerInv();
    inv.hotbar[0] = S.of(BlockState.defaultState(.stone), 60);
    inv.hotbar[1] = S.EMPTY;

    const result = gs.addToInventory(S.of(BlockState.defaultState(.stone), 3));
    try testing.expect(result);
    try testing.expectEqual(@as(u8, 63), inv.hotbar[0].count);
}

test "addToInventory: fills empty slot when no match" {
    const S = Entity.ItemStack;
    var gs = makeTestGameState();
    defer destroyTestGameState(&gs);
    const inv = gs.playerInv();
    for (&inv.hotbar) |*s| s.* = S.EMPTY;
    for (&inv.main) |*s| s.* = S.EMPTY;

    const result = gs.addToInventory(S.of(BlockState.defaultState(.dirt), 1));
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
