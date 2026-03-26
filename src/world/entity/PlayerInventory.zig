const WorldState = @import("../WorldState.zig");
const BlockState = WorldState.BlockState;
const Entity = @import("Entity.zig");

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

pub const PlayerInventory = struct {
    selected_slot: u8 = 0,
    carried_item: Entity.ItemStack = Entity.ItemStack.EMPTY,
    inventory_open: bool = false,
    open_workbench_requested: bool = false,
    pickup_ghosts: [MAX_PICKUP_GHOSTS]PickupGhost = .{PickupGhost{}} ** MAX_PICKUP_GHOSTS,
};
