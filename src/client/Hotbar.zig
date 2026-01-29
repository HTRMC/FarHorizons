const std = @import("std");

pub const Hotbar = struct {
    const Self = @This();

    pub const SLOT_COUNT: u8 = 9;

    selected_slot: u8 = 0,

    pub fn init() Self {
        return .{};
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
};
