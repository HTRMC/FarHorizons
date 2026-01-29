const std = @import("std");
const shared = @import("Shared");
const BlockEntry = shared.BlockEntry;

pub const Hotbar = struct {
    const Self = @This();

    pub const SLOT_COUNT: u8 = 9;

    selected_slot: u8 = 0,
    slots: [SLOT_COUNT]?BlockEntry = .{null} ** SLOT_COUNT,

    pub fn init() Self {
        return .{};
    }

    pub fn initWithDefaults() Self {
        var hotbar = Self{};
        // Initialize with some default blocks
        hotbar.slots[0] = BlockEntry.simple(1);  // stone
        hotbar.slots[1] = BlockEntry.simple(3);  // dirt
        hotbar.slots[2] = BlockEntry.simple(4);  // grass_block
        hotbar.slots[3] = BlockEntry.simple(5);  // cobblestone
        hotbar.slots[4] = BlockEntry.simple(6);  // oak_planks
        hotbar.slots[5] = BlockEntry.simple(14); // birch_planks
        hotbar.slots[6] = BlockEntry.simple(13); // birch_log
        hotbar.slots[7] = BlockEntry.simple(10); // crafting_table
        hotbar.slots[8] = BlockEntry.simple(11); // birch_leaves
        return hotbar;
    }

    pub fn selectSlot(self: *Self, slot: u8) void {
        if (slot < SLOT_COUNT) {
            self.selected_slot = slot;
        }
    }

    pub fn scrollSlot(self: *Self, delta: i32) void {
        const current: i32 = @intCast(self.selected_slot);
        var new_slot = current - delta;

        if (new_slot < 0) {
            new_slot = SLOT_COUNT - 1;
        } else if (new_slot >= SLOT_COUNT) {
            new_slot = 0;
        }

        self.selected_slot = @intCast(new_slot);
    }

    pub fn getSelectedSlot(self: *const Self) u8 {
        return self.selected_slot;
    }

    pub fn setSlot(self: *Self, slot: u8, entry: ?BlockEntry) void {
        if (slot < SLOT_COUNT) {
            self.slots[slot] = entry;
        }
    }

    pub fn getSlot(self: *const Self, slot: u8) ?BlockEntry {
        if (slot < SLOT_COUNT) {
            return self.slots[slot];
        }
        return null;
    }

    pub fn getSelectedBlock(self: *const Self) ?BlockEntry {
        return self.slots[self.selected_slot];
    }
};
