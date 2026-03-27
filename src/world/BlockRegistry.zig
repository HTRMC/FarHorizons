const WorldState = @import("WorldState.zig");
const BlockState = WorldState.BlockState;
const Item = @import("item/Item.zig");

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
        .crafting_table => "Crafting Table",
        .stick => "Stick",
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
        .crafting_table => .{ 0.6, 0.45, 0.25, 1.0 },
        .stick => .{ 0.55, 0.4, 0.2, 1.0 },
    };
}

pub fn itemName(id: BlockState.StateId) []const u8 {
    if (Item.isToolItem(id)) return Item.toolName(id);
    return blockName(id);
}

pub fn itemColor(id: BlockState.StateId) [4]f32 {
    if (Item.isToolItem(id)) return Item.toolColor(id);
    return blockColor(id);
}
