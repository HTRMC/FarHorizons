const steam = @import("../platform/steam.zig");
const log = @import("std").log.scoped(.Stats);

blocks_mined: i32 = 0,
blocks_placed: i32 = 0,
entities_killed: i32 = 0,
items_crafted: i32 = 0,
flush_timer: u32 = 0,

const Self = @This();
const FLUSH_INTERVAL: u32 = 30 * 60; // 60 seconds at 30Hz

pub fn init() Self {
    const stats = Self{
        .blocks_mined = steam.getStatInt("blocks_mined") orelse 0,
        .blocks_placed = steam.getStatInt("blocks_placed") orelse 0,
        .entities_killed = steam.getStatInt("entities_killed") orelse 0,
        .items_crafted = steam.getStatInt("items_crafted") orelse 0,
    };
    log.info("Stats loaded: mined={}, placed={}, killed={}, crafted={}", .{
        stats.blocks_mined,
        stats.blocks_placed,
        stats.entities_killed,
        stats.items_crafted,
    });
    return stats;
}

pub fn flush(self: *Self) void {
    _ = steam.setStatInt("blocks_mined", self.blocks_mined);
    _ = steam.setStatInt("blocks_placed", self.blocks_placed);
    _ = steam.setStatInt("entities_killed", self.entities_killed);
    _ = steam.setStatInt("items_crafted", self.items_crafted);
    _ = steam.storeStats();
}

pub fn tick(self: *Self) void {
    self.flush_timer += 1;
    if (self.flush_timer >= FLUSH_INTERVAL) {
        self.flush();
        self.flush_timer = 0;
    }
}
