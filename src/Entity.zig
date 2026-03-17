const std = @import("std");
const WorldState = @import("world/WorldState.zig");
const BlockState = WorldState.BlockState;

pub const EntityId = u32;
pub const PLAYER: EntityId = 0;
pub const MAX_ENTITIES: u32 = 256;

pub const EntityKind = enum(u8) {
    player,
    item_drop,
};

pub const EntityFlags = packed struct(u8) {
    on_ground: bool = false,
    in_water: bool = false,
    on_ladder: bool = false,
    eyes_in_water: bool = false,
    _pad: u4 = 0,
};

pub const PhysicsParams = struct {
    half_width: f32 = 0.4,
    height: f32 = 1.8,
    walk_speed: f32 = 4.3,
    friction: f32 = 20.0,
    gravity_scale: f32 = 1.0,
};

pub const HOTBAR_SIZE: u8 = 9;
pub const INV_ROWS: u8 = 4;
pub const INV_COLS: u8 = 9;
pub const INV_SIZE: u8 = INV_ROWS * INV_COLS; // 36
pub const ARMOR_SLOTS: u8 = 4;
pub const EQUIP_SLOTS: u8 = 4;

pub const MAX_STACK: u8 = 64;

pub const ItemStack = struct {
    block: BlockState.StateId = BlockState.defaultState(.air),
    count: u8 = 0,

    pub const EMPTY: ItemStack = .{};

    pub fn isEmpty(self: ItemStack) bool {
        return self.count == 0 or BlockState.getBlock(self.block) == .air;
    }

    pub fn of(block: BlockState.StateId, count: u8) ItemStack {
        return .{ .block = block, .count = count };
    }
};

pub const Inventory = struct {
    hotbar: [HOTBAR_SIZE]ItemStack = .{ItemStack.EMPTY} ** HOTBAR_SIZE,
    main: [INV_SIZE]ItemStack = .{ItemStack.EMPTY} ** INV_SIZE,
    armor: [ARMOR_SLOTS]ItemStack = .{ItemStack.EMPTY} ** ARMOR_SLOTS,
    equip: [EQUIP_SLOTS]ItemStack = .{ItemStack.EMPTY} ** EQUIP_SLOTS,
    offhand: ItemStack = ItemStack.EMPTY,
};

pub const DESPAWN_TICKS: u32 = 9000; // 5 minutes at 30Hz
pub const PICKUP_COOLDOWN: u8 = 30;
pub const PICKUP_RADIUS: f32 = 1.5;

pub const EntityStore = struct {
    pos: [MAX_ENTITIES][3]f32 = .{.{ 0, 0, 0 }} ** MAX_ENTITIES,
    vel: [MAX_ENTITIES][3]f32 = .{.{ 0, 0, 0 }} ** MAX_ENTITIES,
    prev_pos: [MAX_ENTITIES][3]f32 = .{.{ 0, 0, 0 }} ** MAX_ENTITIES,
    render_pos: [MAX_ENTITIES][3]f32 = .{.{ 0, 0, 0 }} ** MAX_ENTITIES,
    rotation: [MAX_ENTITIES][2]f32 = .{.{ 0, 0 }} ** MAX_ENTITIES,
    flags: [MAX_ENTITIES]EntityFlags = .{@as(EntityFlags, .{})} ** MAX_ENTITIES,
    kind: [MAX_ENTITIES]EntityKind = .{.player} ** MAX_ENTITIES,
    water_vision_time: [MAX_ENTITIES]u16 = .{0} ** MAX_ENTITIES,
    physics: [MAX_ENTITIES]PhysicsParams = .{PhysicsParams{}} ** MAX_ENTITIES,
    inventory: [MAX_ENTITIES]?*Inventory = .{null} ** MAX_ENTITIES,

    // Item drop specific arrays
    item_block: [MAX_ENTITIES]BlockState.StateId = .{BlockState.defaultState(.air)} ** MAX_ENTITIES,
    item_count: [MAX_ENTITIES]u8 = .{0} ** MAX_ENTITIES,
    age_ticks: [MAX_ENTITIES]u32 = .{0} ** MAX_ENTITIES,
    pickup_cooldown: [MAX_ENTITIES]u8 = .{0} ** MAX_ENTITIES,

    count: u32 = 0,

    pub fn spawn(self: *EntityStore, entity_kind: EntityKind, spawn_pos: [3]f32) EntityId {
        std.debug.assert(self.count < MAX_ENTITIES);
        const id = self.count;
        self.pos[id] = spawn_pos;
        self.vel[id] = .{ 0, 0, 0 };
        self.prev_pos[id] = spawn_pos;
        self.render_pos[id] = spawn_pos;
        self.rotation[id] = .{ 0, 0 };
        self.flags[id] = .{};
        self.kind[id] = entity_kind;
        self.water_vision_time[id] = 0;
        self.physics[id] = .{};
        self.inventory[id] = null;
        self.item_block[id] = BlockState.defaultState(.air);
        self.item_count[id] = 0;
        self.age_ticks[id] = 0;
        self.pickup_cooldown[id] = 0;
        self.count += 1;
        return id;
    }

    /// Spawn an item drop entity at a position with upward velocity.
    pub fn spawnItemDrop(self: *EntityStore, drop_pos: [3]f32, block: BlockState.StateId, count: u8) void {
        if (self.count >= MAX_ENTITIES) return;
        const id = self.spawn(.item_drop, drop_pos);
        self.physics[id] = .{
            .half_width = 0.125,
            .height = 0.25,
            .walk_speed = 0.0,
            .friction = 10.0,
            .gravity_scale = 1.0,
        };
        // Small upward + random-ish horizontal velocity
        self.vel[id] = .{ 0.0, 4.0, 0.0 };
        self.item_block[id] = block;
        self.item_count[id] = count;
        self.age_ticks[id] = 0;
        self.pickup_cooldown[id] = PICKUP_COOLDOWN;
    }

    /// Remove an entity by swap-removing with the last entity.
    pub fn despawn(self: *EntityStore, id: EntityId) void {
        std.debug.assert(id != PLAYER);
        std.debug.assert(id < self.count);
        const last = self.count - 1;
        if (id != last) {
            self.pos[id] = self.pos[last];
            self.vel[id] = self.vel[last];
            self.prev_pos[id] = self.prev_pos[last];
            self.render_pos[id] = self.render_pos[last];
            self.rotation[id] = self.rotation[last];
            self.flags[id] = self.flags[last];
            self.kind[id] = self.kind[last];
            self.water_vision_time[id] = self.water_vision_time[last];
            self.physics[id] = self.physics[last];
            self.inventory[id] = self.inventory[last];
            self.item_block[id] = self.item_block[last];
            self.item_count[id] = self.item_count[last];
            self.age_ticks[id] = self.age_ticks[last];
            self.pickup_cooldown[id] = self.pickup_cooldown[last];
        }
        self.count -= 1;
    }
};
