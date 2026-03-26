const tracy = @import("../../platform/tracy.zig");
const GameState = @import("../GameState.zig");
const Entity = GameState.Entity;

const HOTBAR_SIZE = GameState.HOTBAR_SIZE;
const INV_SIZE = GameState.INV_SIZE;
const ARMOR_SLOTS = GameState.ARMOR_SLOTS;
const EQUIP_SLOTS = GameState.EQUIP_SLOTS;
const EYE_OFFSET = GameState.EYE_OFFSET;

/// Get a pointer to the item stack in a unified slot index.
/// Slots 0-8: hotbar, 9-44: main inventory, 45-48: armor, 49-52: equip, 53: offhand.
pub fn slotPtr(state: *GameState, slot: u8) *Entity.ItemStack {
    const inv = state.playerInv();
    if (slot < HOTBAR_SIZE) return &inv.hotbar[slot];
    if (slot < HOTBAR_SIZE + INV_SIZE) return &inv.main[slot - HOTBAR_SIZE];
    if (slot < HOTBAR_SIZE + INV_SIZE + ARMOR_SLOTS) return &inv.armor[slot - HOTBAR_SIZE - INV_SIZE];
    if (slot < HOTBAR_SIZE + INV_SIZE + ARMOR_SLOTS + EQUIP_SLOTS) return &inv.equip[slot - HOTBAR_SIZE - INV_SIZE - ARMOR_SLOTS];
    return &inv.offhand;
}

/// Click a slot: pick up, place, or swap with carried item.
pub fn clickSlot(state: *GameState, slot: u8) void {
    const tz = tracy.zone(@src(), "clickSlot");
    defer tz.end();
    const ptr = slotPtr(state, slot);
    if (state.inv.carried_item.isEmpty() and ptr.isEmpty()) return;
    const tmp = ptr.*;
    ptr.* = state.inv.carried_item;
    state.inv.carried_item = tmp;
}

/// Shift+click: move item between hotbar and main inventory.
/// First tries to merge into a matching stack, then into an empty slot.
pub fn quickMove(state: *GameState, slot: u8) void {
    const inv = state.playerInv();
    const ptr = slotPtr(state, slot);
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

/// Drop items from an arbitrary inventory slot. If `drop_all` is true, drops the entire stack.
pub fn dropFromSlot(state: *GameState, slot: u8, drop_all: bool) void {
    const stack = slotPtr(state, slot);
    if (stack.isEmpty()) return;
    if (state.entities.count >= Entity.MAX_ENTITIES) return;

    const P = Entity.PLAYER;
    const epos = state.entities.pos[P];
    const forward = state.camera.getForward();
    const drop_pos = [3]f32{
        epos[0] + forward.x * 0.5,
        epos[1] + EYE_OFFSET + forward.y * 0.5,
        epos[2] + forward.z * 0.5,
    };
    const drop_count: u8 = if (drop_all or stack.isTool()) stack.count else 1;
    const prev_count = state.entities.count;
    state.entities.spawnItemDropWithDurability(drop_pos, stack.block, drop_count, stack.durability);
    if (state.entities.count <= prev_count) return;

    const last = state.entities.count - 1;
    state.entities.vel[last] = .{
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
pub fn dropCarried(state: *GameState, drop_all: bool) void {
    if (state.inv.carried_item.isEmpty()) return;
    if (state.entities.count >= Entity.MAX_ENTITIES) return;

    const P = Entity.PLAYER;
    const epos = state.entities.pos[P];
    const forward = state.camera.getForward();
    const drop_pos = [3]f32{
        epos[0] + forward.x * 0.5,
        epos[1] + EYE_OFFSET + forward.y * 0.5,
        epos[2] + forward.z * 0.5,
    };
    const drop_count: u8 = if (drop_all or state.inv.carried_item.isTool()) state.inv.carried_item.count else 1;
    const prev_count = state.entities.count;
    state.entities.spawnItemDropWithDurability(drop_pos, state.inv.carried_item.block, drop_count, state.inv.carried_item.durability);
    if (state.entities.count <= prev_count) return;

    const last = state.entities.count - 1;
    state.entities.vel[last] = .{
        forward.x * 5.0,
        forward.y * 5.0 + 2.0,
        forward.z * 5.0,
    };

    if (drop_all or state.inv.carried_item.count <= 1) {
        state.inv.carried_item = Entity.ItemStack.EMPTY;
    } else {
        state.inv.carried_item.count -= 1;
    }
}

pub fn decrementSelectedStack(state: *GameState) void {
    if (state.game_mode == .creative) return; // infinite blocks in creative
    const stack = &state.playerInv().hotbar[state.inv.selected_slot];
    if (stack.count > 1) {
        stack.count -= 1;
    } else {
        stack.* = Entity.ItemStack.EMPTY;
    }
}

/// Try to add an item stack to the player's inventory.
/// Returns true if the entire stack was added, false if inventory is full.
pub fn addToInventory(state: *GameState, item: Entity.ItemStack) bool {
    if (item.isEmpty()) return true;
    var remaining = item.count;
    const inv = state.playerInv();

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
