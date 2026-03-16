const T = @import("../BlockTypes.zig");

// 51 simple full-cube blocks (air through oak_leaves), matching Block enum order.
pub const defs = [51]T.BlockDef{
    // air
    .{ .name = "Air", .color = .{ 0.0, 0.0, 0.0, 0.0 }, .tex_indices = .{ .top = -1, .side = -1 }, .is_targetable = false, .base_opaque = false, .base_solid = false, .base_culls_self = false },
    // glass
    .{ .name = "Glass", .color = .{ 0.8, 0.9, 1.0, 0.4 }, .tex_indices = .{ .top = 0, .side = 0 }, .render_layer = .translucent, .base_opaque = false },
    // grass_block
    .{ .name = "Grass", .color = .{ 0.3, 0.7, 0.2, 1.0 }, .tex_indices = .{ .top = 1, .side = 1 } },
    // dirt
    .{ .name = "Dirt", .color = .{ 0.6, 0.4, 0.2, 1.0 }, .tex_indices = .{ .top = 2, .side = 2 } },
    // stone
    .{ .name = "Stone", .tex_indices = .{ .top = 3, .side = 3 } },
    // glowstone
    .{ .name = "Glowstone", .color = .{ 1.0, 0.9, 0.5, 1.0 }, .tex_indices = .{ .top = 4, .side = 4 }, .emitted_light = .{ 255, 200, 100 } },
    // colored glowstones
    .{ .name = "Red Glowstone", .color = .{ 1.0, 0.2, 0.12, 1.0 }, .tex_indices = .{ .top = 34, .side = 34 }, .emitted_light = .{ 255, 50, 30 } },
    .{ .name = "Crimson Glowstone", .color = .{ 0.71, 0.08, 0.16, 1.0 }, .tex_indices = .{ .top = 35, .side = 35 }, .emitted_light = .{ 180, 20, 40 } },
    .{ .name = "Orange Glowstone", .color = .{ 1.0, 0.59, 0.12, 1.0 }, .tex_indices = .{ .top = 36, .side = 36 }, .emitted_light = .{ 255, 150, 30 } },
    .{ .name = "Peach Glowstone", .color = .{ 1.0, 0.71, 0.47, 1.0 }, .tex_indices = .{ .top = 37, .side = 37 }, .emitted_light = .{ 255, 180, 120 } },
    .{ .name = "Lime Glowstone", .color = .{ 0.47, 1.0, 0.16, 1.0 }, .tex_indices = .{ .top = 38, .side = 38 }, .emitted_light = .{ 120, 255, 40 } },
    .{ .name = "Green Glowstone", .color = .{ 0.16, 0.78, 0.24, 1.0 }, .tex_indices = .{ .top = 39, .side = 39 }, .emitted_light = .{ 40, 200, 60 } },
    .{ .name = "Teal Glowstone", .color = .{ 0.12, 0.71, 0.59, 1.0 }, .tex_indices = .{ .top = 40, .side = 40 }, .emitted_light = .{ 30, 180, 150 } },
    .{ .name = "Cyan Glowstone", .color = .{ 0.12, 0.86, 0.86, 1.0 }, .tex_indices = .{ .top = 41, .side = 41 }, .emitted_light = .{ 30, 220, 220 } },
    .{ .name = "Light Blue Glowstone", .color = .{ 0.31, 0.63, 1.0, 1.0 }, .tex_indices = .{ .top = 42, .side = 42 }, .emitted_light = .{ 80, 160, 255 } },
    .{ .name = "Blue Glowstone", .color = .{ 0.16, 0.31, 1.0, 1.0 }, .tex_indices = .{ .top = 43, .side = 43 }, .emitted_light = .{ 40, 80, 255 } },
    .{ .name = "Navy Glowstone", .color = .{ 0.12, 0.16, 0.71, 1.0 }, .tex_indices = .{ .top = 44, .side = 44 }, .emitted_light = .{ 30, 40, 180 } },
    .{ .name = "Indigo Glowstone", .color = .{ 0.39, 0.16, 0.86, 1.0 }, .tex_indices = .{ .top = 45, .side = 45 }, .emitted_light = .{ 100, 40, 220 } },
    .{ .name = "Purple Glowstone", .color = .{ 0.63, 0.2, 1.0, 1.0 }, .tex_indices = .{ .top = 46, .side = 46 }, .emitted_light = .{ 160, 50, 255 } },
    .{ .name = "Magenta Glowstone", .color = .{ 0.86, 0.2, 0.78, 1.0 }, .tex_indices = .{ .top = 47, .side = 47 }, .emitted_light = .{ 220, 50, 200 } },
    .{ .name = "Pink Glowstone", .color = .{ 1.0, 0.43, 0.67, 1.0 }, .tex_indices = .{ .top = 48, .side = 48 }, .emitted_light = .{ 255, 110, 170 } },
    .{ .name = "Hot Pink Glowstone", .color = .{ 1.0, 0.2, 0.47, 1.0 }, .tex_indices = .{ .top = 49, .side = 49 }, .emitted_light = .{ 255, 50, 120 } },
    .{ .name = "White Glowstone", .color = .{ 0.94, 0.94, 1.0, 1.0 }, .tex_indices = .{ .top = 50, .side = 50 }, .emitted_light = .{ 240, 240, 255 } },
    .{ .name = "Warm White Glowstone", .color = .{ 1.0, 0.86, 0.71, 1.0 }, .tex_indices = .{ .top = 51, .side = 51 }, .emitted_light = .{ 255, 220, 180 } },
    .{ .name = "Light Gray Glowstone", .color = .{ 0.71, 0.71, 0.75, 1.0 }, .tex_indices = .{ .top = 52, .side = 52 }, .emitted_light = .{ 180, 180, 190 } },
    .{ .name = "Gray Glowstone", .color = .{ 0.47, 0.47, 0.51, 1.0 }, .tex_indices = .{ .top = 53, .side = 53 }, .emitted_light = .{ 120, 120, 130 } },
    .{ .name = "Brown Glowstone", .color = .{ 0.63, 0.39, 0.2, 1.0 }, .tex_indices = .{ .top = 54, .side = 54 }, .emitted_light = .{ 160, 100, 50 } },
    .{ .name = "Tan Glowstone", .color = .{ 0.78, 0.67, 0.43, 1.0 }, .tex_indices = .{ .top = 55, .side = 55 }, .emitted_light = .{ 200, 170, 110 } },
    .{ .name = "Black Glowstone", .color = .{ 0.16, 0.14, 0.2, 1.0 }, .tex_indices = .{ .top = 56, .side = 56 }, .emitted_light = .{ 40, 35, 50 } },
    // sand
    .{ .name = "Sand", .color = .{ 0.82, 0.75, 0.51, 1.0 }, .tex_indices = .{ .top = 5, .side = 5 } },
    // snow
    .{ .name = "Snow", .color = .{ 0.95, 0.97, 1.0, 1.0 }, .tex_indices = .{ .top = 6, .side = 6 } },
    // water
    .{ .name = "Water", .color = .{ 0.2, 0.4, 0.8, 0.6 }, .tex_indices = .{ .top = 7, .side = 7 }, .render_layer = .translucent, .is_targetable = false, .base_opaque = false, .base_solid = false },
    // gravel
    .{ .name = "Gravel", .color = .{ 0.5, 0.48, 0.47, 1.0 }, .tex_indices = .{ .top = 8, .side = 8 } },
    // cobblestone
    .{ .name = "Cobblestone", .color = .{ 0.45, 0.45, 0.45, 1.0 }, .tex_indices = .{ .top = 9, .side = 9 } },
    // oak_log
    .{ .name = "Oak Log", .color = .{ 0.55, 0.36, 0.2, 1.0 }, .tex_indices = .{ .top = 27, .side = 10 } },
    // oak_planks
    .{ .name = "Oak Planks", .color = .{ 0.7, 0.55, 0.33, 1.0 }, .tex_indices = .{ .top = 11, .side = 11 } },
    // bricks
    .{ .name = "Bricks", .color = .{ 0.6, 0.3, 0.25, 1.0 }, .tex_indices = .{ .top = 12, .side = 12 } },
    // bedrock
    .{ .name = "Bedrock", .color = .{ 0.2, 0.2, 0.2, 1.0 }, .tex_indices = .{ .top = 13, .side = 13 } },
    // gold_ore
    .{ .name = "Gold Ore", .color = .{ 0.75, 0.7, 0.4, 1.0 }, .tex_indices = .{ .top = 14, .side = 14 } },
    // iron_ore
    .{ .name = "Iron Ore", .color = .{ 0.6, 0.55, 0.5, 1.0 }, .tex_indices = .{ .top = 15, .side = 15 } },
    // coal_ore
    .{ .name = "Coal Ore", .color = .{ 0.3, 0.3, 0.3, 1.0 }, .tex_indices = .{ .top = 16, .side = 16 } },
    // diamond_ore
    .{ .name = "Diamond Ore", .color = .{ 0.4, 0.7, 0.8, 1.0 }, .tex_indices = .{ .top = 17, .side = 17 } },
    // sponge
    .{ .name = "Sponge", .color = .{ 0.8, 0.8, 0.3, 1.0 }, .tex_indices = .{ .top = 18, .side = 18 } },
    // pumice
    .{ .name = "Pumice", .color = .{ 0.6, 0.58, 0.55, 1.0 }, .tex_indices = .{ .top = 19, .side = 19 } },
    // wool
    .{ .name = "Wool", .color = .{ 0.9, 0.9, 0.9, 1.0 }, .tex_indices = .{ .top = 20, .side = 20 } },
    // gold_block
    .{ .name = "Gold Block", .color = .{ 0.9, 0.8, 0.2, 1.0 }, .tex_indices = .{ .top = 21, .side = 21 } },
    // iron_block
    .{ .name = "Iron Block", .color = .{ 0.8, 0.8, 0.8, 1.0 }, .tex_indices = .{ .top = 22, .side = 22 } },
    // diamond_block
    .{ .name = "Diamond Block", .color = .{ 0.4, 0.9, 0.9, 1.0 }, .tex_indices = .{ .top = 23, .side = 23 } },
    // bookshelf
    .{ .name = "Bookshelf", .color = .{ 0.55, 0.4, 0.25, 1.0 }, .tex_indices = .{ .top = 24, .side = 24 } },
    // obsidian
    .{ .name = "Obsidian", .color = .{ 0.15, 0.1, 0.2, 1.0 }, .tex_indices = .{ .top = 25, .side = 25 } },
    // oak_leaves
    .{ .name = "Oak Leaves", .color = .{ 0.2, 0.5, 0.15, 0.8 }, .tex_indices = .{ .top = 26, .side = 26 }, .render_layer = .cutout, .base_opaque = false, .base_culls_self = false },
};
