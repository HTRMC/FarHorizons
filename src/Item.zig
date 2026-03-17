const std = @import("std");

pub const ToolType = enum(u3) { pickaxe, axe, shovel, sword, hoe };
pub const ToolTier = enum(u3) { wood, stone, iron, gold, diamond };

pub const TOOL_BASE: u16 = 256;
pub const TOOL_COUNT: u16 = 25; // 5 tiers × 5 types

pub fn isToolItem(id: u16) bool {
    return id >= TOOL_BASE and id < TOOL_BASE + TOOL_COUNT;
}

pub fn toolFromId(id: u16) ?struct { tool_type: ToolType, tier: ToolTier } {
    if (!isToolItem(id)) return null;
    const offset = id - TOOL_BASE;
    return .{
        .tool_type = @enumFromInt(@as(u3, @intCast(offset % 5))),
        .tier = @enumFromInt(@as(u3, @intCast(offset / 5))),
    };
}

pub fn idFromTool(tool_type: ToolType, tier: ToolTier) u16 {
    return TOOL_BASE + @as(u16, @intFromEnum(tier)) * 5 + @intFromEnum(tool_type);
}

pub const TierStats = struct {
    durability: u16,
    mining_speed: f32,
    attack_bonus: f32,
};

pub fn tierStats(tier: ToolTier) TierStats {
    return switch (tier) {
        .wood => .{ .durability = 59, .mining_speed = 2.0, .attack_bonus = 0.0 },
        .stone => .{ .durability = 131, .mining_speed = 4.0, .attack_bonus = 1.0 },
        .iron => .{ .durability = 250, .mining_speed = 6.0, .attack_bonus = 2.0 },
        .gold => .{ .durability = 32, .mining_speed = 12.0, .attack_bonus = 0.0 },
        .diamond => .{ .durability = 1561, .mining_speed = 8.0, .attack_bonus = 3.0 },
    };
}

pub fn baseAttackDamage(tool_type: ToolType) f32 {
    return switch (tool_type) {
        .sword => 3.0,
        .pickaxe => 1.0,
        .axe => 6.0,
        .shovel => 1.5,
        .hoe => 0.0,
    };
}

pub fn toolName(id: u16) []const u8 {
    if (!isToolItem(id)) return "Unknown";
    return toolNameTable()[@as(usize, id - TOOL_BASE)];
}

fn toolNameTable() *const [TOOL_COUNT][]const u8 {
    const S = struct {
        const table: [TOOL_COUNT][]const u8 = blk: {
            var t: [TOOL_COUNT][]const u8 = undefined;
            const tiers = [5][]const u8{ "Wooden", "Stone", "Iron", "Golden", "Diamond" };
            const types = [5][]const u8{ " Pickaxe", " Axe", " Shovel", " Sword", " Hoe" };
            for (0..5) |tier| {
                for (0..5) |tool| {
                    t[tier * 5 + tool] = tiers[tier] ++ types[tool];
                }
            }
            break :blk t;
        };
    };
    return &S.table;
}

pub fn toolColor(id: u16) [4]f32 {
    const info = toolFromId(id) orelse return .{ 1.0, 1.0, 1.0, 1.0 };
    return switch (info.tier) {
        .wood => .{ 0.6, 0.4, 0.2, 1.0 },
        .stone => .{ 0.6, 0.6, 0.6, 1.0 },
        .iron => .{ 0.85, 0.85, 0.85, 1.0 },
        .gold => .{ 1.0, 0.85, 0.2, 1.0 },
        .diamond => .{ 0.3, 0.9, 0.9, 1.0 },
    };
}

test "tool ID round-trip" {
    const id = idFromTool(.pickaxe, .diamond);
    const info = toolFromId(id).?;
    try std.testing.expectEqual(ToolType.pickaxe, info.tool_type);
    try std.testing.expectEqual(ToolTier.diamond, info.tier);
}

test "tool name table" {
    try std.testing.expect(std.mem.eql(u8, "Diamond Pickaxe", toolName(idFromTool(.pickaxe, .diamond))));
    try std.testing.expect(std.mem.eql(u8, "Wooden Sword", toolName(idFromTool(.sword, .wood))));
    try std.testing.expect(std.mem.eql(u8, "Golden Axe", toolName(idFromTool(.axe, .gold))));
}

test "is tool item" {
    try std.testing.expect(isToolItem(TOOL_BASE));
    try std.testing.expect(isToolItem(TOOL_BASE + 24));
    try std.testing.expect(!isToolItem(TOOL_BASE + 25));
    try std.testing.expect(!isToolItem(0));
    try std.testing.expect(!isToolItem(255));
}
