const T = @import("../BlockTypes.zig");

// 28 simple full-cube blocks (air through oak_leaves), matching Block enum order.
pub const defs = [28]T.BlockDef{
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
