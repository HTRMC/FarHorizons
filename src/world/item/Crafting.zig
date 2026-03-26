const std = @import("std");
const GameState = @import("../GameState.zig");
const InventoryOps = GameState.InventoryOps;
const Entity = @import("../entity/Entity.zig");
const BlockState = @import("../WorldState.zig").BlockState;
const Item = @import("Item.zig");

pub const MAX_INGREDIENTS = 4;

pub const Ingredient = struct {
    item: u16,
    count: u8,
};

pub const Recipe = struct {
    output: Ingredient,
    inputs: [MAX_INGREDIENTS]Ingredient,
    input_count: u8,
    requires_workbench: bool,
};

const B = BlockState.defaultState;
const empty_input = Ingredient{ .item = 0, .count = 0 };

fn hand(output_item: u16, output_count: u8, in0: Ingredient, in1: Ingredient, in2: Ingredient, in3: Ingredient) Recipe {
    var input_count: u8 = 0;
    const inputs = [4]Ingredient{ in0, in1, in2, in3 };
    for (inputs) |inp| {
        if (inp.count > 0) input_count += 1;
    }
    return .{
        .output = .{ .item = output_item, .count = output_count },
        .inputs = inputs,
        .input_count = input_count,
        .requires_workbench = false,
    };
}

fn bench(output_item: u16, output_count: u8, in0: Ingredient, in1: Ingredient, in2: Ingredient, in3: Ingredient) Recipe {
    var input_count: u8 = 0;
    const inputs = [4]Ingredient{ in0, in1, in2, in3 };
    for (inputs) |inp| {
        if (inp.count > 0) input_count += 1;
    }
    return .{
        .output = .{ .item = output_item, .count = output_count },
        .inputs = inputs,
        .input_count = input_count,
        .requires_workbench = true,
    };
}

fn ing(item: u16, count: u8) Ingredient {
    return .{ .item = item, .count = count };
}

fn toolIng(tool_type: Item.ToolType, tier: Item.ToolTier, count: u8) Ingredient {
    return .{ .item = Item.idFromTool(tool_type, tier), .count = count };
}

fn toolRecipe(tool_type: Item.ToolType, tier: Item.ToolTier, material: u16) Recipe {
    return bench(
        Item.idFromTool(tool_type, tier),
        1,
        ing(material, toolMaterialCount(tool_type)),
        ing(B(.stick), toolStickCount(tool_type)),
        empty_input,
        empty_input,
    );
}

fn toolMaterialCount(tool_type: Item.ToolType) u8 {
    return switch (tool_type) {
        .pickaxe => 3,
        .axe => 3,
        .shovel => 1,
        .sword => 2,
        .hoe => 2,
    };
}

fn toolStickCount(tool_type: Item.ToolType) u8 {
    return switch (tool_type) {
        .pickaxe => 2,
        .axe => 2,
        .shovel => 2,
        .sword => 1,
        .hoe => 2,
    };
}

pub const recipes: []const Recipe = &.{
    // === Hand recipes ===
    // Oak log -> planks x4
    hand(B(.oak_planks), 4, ing(B(.oak_log), 1), empty_input, empty_input, empty_input),
    // Planks x2 -> sticks x4
    hand(B(.stick), 4, ing(B(.oak_planks), 2), empty_input, empty_input, empty_input),
    // Planks x4 -> crafting table
    hand(B(.crafting_table), 1, ing(B(.oak_planks), 4), empty_input, empty_input, empty_input),
    // Stick + coal ore -> torch x4
    hand(B(.torch), 4, ing(B(.stick), 1), ing(B(.coal_ore), 1), empty_input, empty_input),

    // === Workbench: Tools (5 types x 5 tiers) ===
    // Wood tools (planks)
    toolRecipe(.pickaxe, .wood, B(.oak_planks)),
    toolRecipe(.axe, .wood, B(.oak_planks)),
    toolRecipe(.shovel, .wood, B(.oak_planks)),
    toolRecipe(.sword, .wood, B(.oak_planks)),
    toolRecipe(.hoe, .wood, B(.oak_planks)),
    // Stone tools (cobblestone)
    toolRecipe(.pickaxe, .stone, B(.cobblestone)),
    toolRecipe(.axe, .stone, B(.cobblestone)),
    toolRecipe(.shovel, .stone, B(.cobblestone)),
    toolRecipe(.sword, .stone, B(.cobblestone)),
    toolRecipe(.hoe, .stone, B(.cobblestone)),
    // Iron tools (iron_ore)
    toolRecipe(.pickaxe, .iron, B(.iron_ore)),
    toolRecipe(.axe, .iron, B(.iron_ore)),
    toolRecipe(.shovel, .iron, B(.iron_ore)),
    toolRecipe(.sword, .iron, B(.iron_ore)),
    toolRecipe(.hoe, .iron, B(.iron_ore)),
    // Gold tools (gold_ore)
    toolRecipe(.pickaxe, .gold, B(.gold_ore)),
    toolRecipe(.axe, .gold, B(.gold_ore)),
    toolRecipe(.shovel, .gold, B(.gold_ore)),
    toolRecipe(.sword, .gold, B(.gold_ore)),
    toolRecipe(.hoe, .gold, B(.gold_ore)),
    // Diamond tools (diamond_ore)
    toolRecipe(.pickaxe, .diamond, B(.diamond_ore)),
    toolRecipe(.axe, .diamond, B(.diamond_ore)),
    toolRecipe(.shovel, .diamond, B(.diamond_ore)),
    toolRecipe(.sword, .diamond, B(.diamond_ore)),
    toolRecipe(.hoe, .diamond, B(.diamond_ore)),

    // === Workbench: Building ===
    // Door: planks x6
    bench(B(.oak_door), 1, ing(B(.oak_planks), 6), empty_input, empty_input, empty_input),
    // Fence: planks x4 + sticks x2
    bench(B(.oak_fence), 3, ing(B(.oak_planks), 4), ing(B(.stick), 2), empty_input, empty_input),
    // Stairs: planks x6
    bench(B(.oak_stairs), 4, ing(B(.oak_planks), 6), empty_input, empty_input, empty_input),
    // Slab: planks x3
    bench(B(.oak_slab), 6, ing(B(.oak_planks), 3), empty_input, empty_input, empty_input),
    // Ladder: sticks x7
    bench(B(.ladder), 3, ing(B(.stick), 7), empty_input, empty_input, empty_input),
    // Bookshelf: planks x6 + books (use oak_planks x6 simplified)
    bench(B(.bookshelf), 1, ing(B(.oak_planks), 6), empty_input, empty_input, empty_input),

    // === Workbench: Ore -> Block conversions ===
    // Gold ore x9 -> gold block
    bench(B(.gold_block), 1, ing(B(.gold_ore), 9), empty_input, empty_input, empty_input),
    // Iron ore x9 -> iron block
    bench(B(.iron_block), 1, ing(B(.iron_ore), 9), empty_input, empty_input, empty_input),
    // Diamond ore x9 -> diamond block
    bench(B(.diamond_block), 1, ing(B(.diamond_ore), 9), empty_input, empty_input, empty_input),

    // === Workbench: Block -> Ore (decompose) ===
    // Gold block -> gold ore x9
    bench(B(.gold_ore), 9, ing(B(.gold_block), 1), empty_input, empty_input, empty_input),
    // Iron block -> iron ore x9
    bench(B(.iron_ore), 9, ing(B(.iron_block), 1), empty_input, empty_input, empty_input),
    // Diamond block -> diamond ore x9
    bench(B(.diamond_ore), 9, ing(B(.diamond_block), 1), empty_input, empty_input, empty_input),
};

/// Count how many of a given item the player has across hotbar + main inventory.
pub fn countItem(game_state: *GameState, item_id: u16) u16 {
    var total: u16 = 0;
    const inv = game_state.playerInv();
    for (&inv.hotbar) |*s| {
        if (!s.isEmpty() and s.block == item_id) total += s.count;
    }
    for (&inv.main) |*s| {
        if (!s.isEmpty() and s.block == item_id) total += s.count;
    }
    return total;
}

/// Check if the player has enough materials for a recipe.
pub fn canCraft(game_state: *GameState, recipe: *const Recipe) bool {
    for (0..recipe.input_count) |i| {
        const inp = recipe.inputs[i];
        if (countItem(game_state, inp.item) < inp.count) return false;
    }
    return true;
}

/// Remove items from inventory (main first, then hotbar).
fn removeItems(game_state: *GameState, item_id: u16, count: u8) void {
    var remaining: u8 = count;
    const inv = game_state.playerInv();

    // Remove from main first
    for (&inv.main) |*s| {
        if (remaining == 0) break;
        if (!s.isEmpty() and s.block == item_id) {
            const take = @min(s.count, remaining);
            s.count -= take;
            remaining -= take;
            if (s.count == 0) s.* = Entity.ItemStack.EMPTY;
        }
    }
    // Then hotbar
    for (&inv.hotbar) |*s| {
        if (remaining == 0) break;
        if (!s.isEmpty() and s.block == item_id) {
            const take = @min(s.count, remaining);
            s.count -= take;
            remaining -= take;
            if (s.count == 0) s.* = Entity.ItemStack.EMPTY;
        }
    }
}

/// Attempt to craft a recipe. Returns true on success.
pub fn craft(game_state: *GameState, recipe: *const Recipe) bool {
    if (!canCraft(game_state, recipe)) return false;

    // Deduct inputs
    for (0..recipe.input_count) |i| {
        const inp = recipe.inputs[i];
        removeItems(game_state, inp.item, inp.count);
    }

    // Add output
    const output = recipe.output;
    if (Item.isToolItem(output.item)) {
        const info = Item.toolFromId(output.item) orelse return true;
        _ = InventoryOps.addToInventory(game_state,Entity.ItemStack.ofTool(info.tool_type, info.tier));
    } else {
        _ = InventoryOps.addToInventory(game_state,Entity.ItemStack.of(output.item, output.count));
    }

    return true;
}
