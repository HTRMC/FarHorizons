/// StateMapper - Converts BlockState to variant key strings
/// Maps the packed BlockState properties to Minecraft-style variant keys
/// like "type=bottom", "axis=y", etc.
const std = @import("std");
const shared = @import("Shared");
const BlockState = shared.BlockState;

pub const StateMapper = struct {
    /// Convert BlockState to variant key based on block type
    /// The block name suffix determines which properties are relevant:
    /// - *_slab: uses "type" property (bottom/top/double)
    /// - *_log, *_wood, *_pillar: uses "axis" property (x/y/z)
    /// - other blocks: returns "" (empty key for default variant)
    ///
    /// Returns a static string slice (no allocation needed)
    pub fn toVariantKey(block_name: []const u8, state: BlockState) []const u8 {
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
        return usesSlab(block_name) or usesAxis(block_name);
    }
};

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
