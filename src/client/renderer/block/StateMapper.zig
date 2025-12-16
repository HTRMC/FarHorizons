/// StateMapper - Converts BlockState to variant key strings
/// Maps the packed BlockState properties to variant keys
/// like "type=bottom", "axis=y", "facing=north,half=bottom,shape=straight", etc.
const std = @import("std");
const shared = @import("Shared");
const BlockState = shared.BlockState;

pub const StateMapper = struct {
    /// Convert BlockState to variant key based on block type
    /// The block name suffix determines which properties are relevant:
    /// - *_slab: uses "type" property (bottom/top/double)
    /// - *_log, *_wood, *_pillar: uses "axis" property (x/y/z)
    /// - *_stairs: uses "facing", "half", "shape" properties
    /// - other blocks: returns "" (empty key for default variant)
    ///
    /// Returns a static string slice (no allocation needed)
    pub fn toVariantKey(block_name: []const u8, state: BlockState) []const u8 {
        // Check for stair blocks
        if (std.mem.endsWith(u8, block_name, "_stairs")) {
            return stairStateToKey(state);
        }

        // Check for slab blocks
        if (std.mem.endsWith(u8, block_name, "_slab")) {
            return slabTypeToKey(state.slab_type);
        }

        // Check for log/wood/pillar blocks (rotatable)
        if (std.mem.endsWith(u8, block_name, "_log") or
            std.mem.endsWith(u8, block_name, "_wood") or
            std.mem.endsWith(u8, block_name, "_pillar"))
        {
            return axisToKey(state.axis);
        }

        // Default: empty key (matches "" variant)
        return "";
    }

    /// Convert slab type to variant key
    fn slabTypeToKey(slab_type: BlockState.SlabType) []const u8 {
        return switch (slab_type) {
            .bottom => "type=bottom",
            .top => "type=top",
            .double => "type=double",
            _ => "type=bottom",
        };
    }

    /// Convert axis to variant key
    fn axisToKey(axis: BlockState.Axis) []const u8 {
        return switch (axis) {
            .x => "axis=x",
            .y => "axis=y",
            .z => "axis=z",
            _ => "axis=y",
        };
    }

    /// Convert stair state to variant key
    /// Format: "facing=north,half=bottom,shape=straight"
    fn stairStateToKey(state: BlockState) []const u8 {
        const facing = state.getStairFacing();
        const half = state.getStairHalf();
        const shape = state.getStairShape();

        // Lookup in comptime-generated table
        // Index = facing * 10 + half * 5 + shape
        const idx = @as(usize, @intFromEnum(facing)) * 10 +
            @as(usize, @intFromEnum(half)) * 5 +
            @as(usize, @intFromEnum(shape));

        if (idx < STAIR_VARIANT_KEYS.len) {
            return STAIR_VARIANT_KEYS[idx];
        }
        return STAIR_VARIANT_KEYS[0]; // Default fallback
    }

    /// Pre-computed variant key strings for stairs (40 combinations)
    const STAIR_VARIANT_KEYS = [40][]const u8{
        // facing=north (0)
        "facing=north,half=bottom,shape=straight",
        "facing=north,half=bottom,shape=inner_left",
        "facing=north,half=bottom,shape=inner_right",
        "facing=north,half=bottom,shape=outer_left",
        "facing=north,half=bottom,shape=outer_right",
        "facing=north,half=top,shape=straight",
        "facing=north,half=top,shape=inner_left",
        "facing=north,half=top,shape=inner_right",
        "facing=north,half=top,shape=outer_left",
        "facing=north,half=top,shape=outer_right",
        // facing=south (1)
        "facing=south,half=bottom,shape=straight",
        "facing=south,half=bottom,shape=inner_left",
        "facing=south,half=bottom,shape=inner_right",
        "facing=south,half=bottom,shape=outer_left",
        "facing=south,half=bottom,shape=outer_right",
        "facing=south,half=top,shape=straight",
        "facing=south,half=top,shape=inner_left",
        "facing=south,half=top,shape=inner_right",
        "facing=south,half=top,shape=outer_left",
        "facing=south,half=top,shape=outer_right",
        // facing=east (2)
        "facing=east,half=bottom,shape=straight",
        "facing=east,half=bottom,shape=inner_left",
        "facing=east,half=bottom,shape=inner_right",
        "facing=east,half=bottom,shape=outer_left",
        "facing=east,half=bottom,shape=outer_right",
        "facing=east,half=top,shape=straight",
        "facing=east,half=top,shape=inner_left",
        "facing=east,half=top,shape=inner_right",
        "facing=east,half=top,shape=outer_left",
        "facing=east,half=top,shape=outer_right",
        // facing=west (3)
        "facing=west,half=bottom,shape=straight",
        "facing=west,half=bottom,shape=inner_left",
        "facing=west,half=bottom,shape=inner_right",
        "facing=west,half=bottom,shape=outer_left",
        "facing=west,half=bottom,shape=outer_right",
        "facing=west,half=top,shape=straight",
        "facing=west,half=top,shape=inner_left",
        "facing=west,half=top,shape=inner_right",
        "facing=west,half=top,shape=outer_left",
        "facing=west,half=top,shape=outer_right",
    };

    /// Check if a block name uses stair properties
    pub fn usesStair(block_name: []const u8) bool {
        return std.mem.endsWith(u8, block_name, "_stairs");
    }

    /// Check if a block name uses slab-type properties
    pub fn usesSlab(block_name: []const u8) bool {
        return std.mem.endsWith(u8, block_name, "_slab");
    }

    /// Check if a block name uses axis properties
    pub fn usesAxis(block_name: []const u8) bool {
        return std.mem.endsWith(u8, block_name, "_log") or
            std.mem.endsWith(u8, block_name, "_wood") or
            std.mem.endsWith(u8, block_name, "_pillar");
    }

    /// Check if block has any state-dependent properties
    pub fn hasStateProperties(block_name: []const u8) bool {
        return usesSlab(block_name) or usesAxis(block_name) or usesStair(block_name);
    }
};

// Tests for stairs
test "StateMapper stair types" {
    // Test straight stair
    const state_north = BlockState.stair(.north, .bottom, .straight);
    try std.testing.expectEqualStrings(
        "facing=north,half=bottom,shape=straight",
        StateMapper.toVariantKey("oak_stairs", state_north),
    );

    // Test inner corner
    const state_east_top_inner = BlockState.stair(.east, .top, .inner_left);
    try std.testing.expectEqualStrings(
        "facing=east,half=top,shape=inner_left",
        StateMapper.toVariantKey("oak_stairs", state_east_top_inner),
    );

    // Test outer corner
    const state_west_outer = BlockState.stair(.west, .bottom, .outer_right);
    try std.testing.expectEqualStrings(
        "facing=west,half=bottom,shape=outer_right",
        StateMapper.toVariantKey("oak_stairs", state_west_outer),
    );
}

// Tests
test "StateMapper slab types" {
    const state_bottom = BlockState{ .slab_type = .bottom };
    const state_top = BlockState{ .slab_type = .top };
    const state_double = BlockState{ .slab_type = .double };

    try std.testing.expectEqualStrings("type=bottom", StateMapper.toVariantKey("oak_slab", state_bottom));
    try std.testing.expectEqualStrings("type=top", StateMapper.toVariantKey("oak_slab", state_top));
    try std.testing.expectEqualStrings("type=double", StateMapper.toVariantKey("oak_slab", state_double));

    // Works with any *_slab suffix
    try std.testing.expectEqualStrings("type=bottom", StateMapper.toVariantKey("spruce_slab", state_bottom));
    try std.testing.expectEqualStrings("type=top", StateMapper.toVariantKey("birch_slab", state_top));
}

test "StateMapper axis types" {
    const state_x = BlockState{ .axis = .x };
    const state_y = BlockState{ .axis = .y };
    const state_z = BlockState{ .axis = .z };

    try std.testing.expectEqualStrings("axis=x", StateMapper.toVariantKey("oak_log", state_x));
    try std.testing.expectEqualStrings("axis=y", StateMapper.toVariantKey("oak_log", state_y));
    try std.testing.expectEqualStrings("axis=z", StateMapper.toVariantKey("oak_log", state_z));

    // Works with different suffixes
    try std.testing.expectEqualStrings("axis=x", StateMapper.toVariantKey("stripped_oak_wood", state_x));
    try std.testing.expectEqualStrings("axis=z", StateMapper.toVariantKey("quartz_pillar", state_z));
}

test "StateMapper simple blocks" {
    const state = BlockState{};

    // Blocks without special suffixes return empty key
    try std.testing.expectEqualStrings("", StateMapper.toVariantKey("stone", state));
    try std.testing.expectEqualStrings("", StateMapper.toVariantKey("dirt", state));
    try std.testing.expectEqualStrings("", StateMapper.toVariantKey("oak_planks", state));
}
