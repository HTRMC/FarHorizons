const EntityId = @import("../entity.zig").EntityId;

/// Breeding component - love mode for animals
/// Extracted from Animal.zig
pub const Breeding = struct {
    /// Love mode timer (> 0 = in love, can breed)
    in_love: i32 = 0,

    /// ID of entity/player who caused love mode
    love_cause_id: ?u64 = null,

    // Constants from Animal
    pub const LOVE_MODE_DURATION: i32 = 600; // 30 seconds
    pub const PARENT_AGE_AFTER_BREEDING: i32 = 6000; // 5 minute cooldown

    pub fn init() Breeding {
        return .{};
    }

    /// Check if in love mode
    pub fn isInLove(self: *const Breeding) bool {
        return self.in_love > 0;
    }

    /// Get remaining love time
    pub fn getInLoveTime(self: *const Breeding) i32 {
        return self.in_love;
    }

    /// Enter love mode (called when fed breeding food)
    pub fn setInLove(self: *Breeding, cause_id: ?u64) void {
        self.in_love = LOVE_MODE_DURATION;
        self.love_cause_id = cause_id;
    }

    /// Reset love mode
    pub fn resetLove(self: *Breeding) void {
        self.in_love = 0;
        self.love_cause_id = null;
    }

    /// Check if can enter love mode (not already in love)
    pub fn canFallInLove(self: *const Breeding) bool {
        return self.in_love <= 0;
    }

    /// Tick the breeding system
    /// Returns true if should spawn heart particles
    pub fn tick(self: *Breeding) bool {
        if (self.in_love > 0) {
            self.in_love -= 1;
            // Spawn particles every 10 ticks
            return (@mod(self.in_love, 10)) == 0;
        }
        return false;
    }
};
