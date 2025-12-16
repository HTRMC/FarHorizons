/// Blockstate definition and JSON parsing
/// Maps block state properties to model variants
/// Uses assets/namespace/blockstates/*.json format
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Represents a single model variant with rotation options
pub const ModelVariant = struct {
    /// Model resource location (e.g., "farhorizons:block/oak_slab")
    model: []const u8,
    /// X rotation in degrees (0, 90, 180, 270)
    x: i16 = 0,
    /// Y rotation in degrees (0, 90, 180, 270)
    y: i16 = 0,
    /// Lock UVs during rotation
    uvlock: bool = false,
    /// Weight for random model selection (future feature)
    weight: u32 = 1,
};

/// Parsed blockstate definition
/// Contains variant mappings from state keys to model variants
pub const BlockstateDefinition = struct {
    const Self = @This();

    allocator: Allocator,
    /// Map from variant key (e.g., "type=bottom") to ModelVariant
    /// Empty string "" matches blocks with no state properties
    variants: std.StringHashMap(ModelVariant),

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .variants = std.StringHashMap(ModelVariant).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.variants.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.model);
        }
        self.variants.deinit();
    }

    /// Parse a BlockstateDefinition from JSON bytes
    /// Supports variants format:
    /// { "variants": { "type=bottom": { "model": "...", "x": 0, "y": 0 } } }
    pub fn parseFromJson(allocator: Allocator, json_data: []const u8) !Self {
        var definition = Self.init(allocator);
        errdefer definition.deinit();

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_data, .{});
        defer parsed.deinit();

        const root = parsed.value.object;

        // Parse variants
        if (root.get("variants")) |variants_value| {
            if (variants_value == .object) {
                var var_it = variants_value.object.iterator();
                while (var_it.next()) |entry| {
                    const variant_key = try allocator.dupe(u8, entry.key_ptr.*);
                    errdefer allocator.free(variant_key);

                    const variant = try parseVariant(allocator, entry.value_ptr.*);
                    try definition.variants.put(variant_key, variant);
                }
            }
        }

        return definition;
    }

    /// Parse a single ModelVariant from JSON value
    fn parseVariant(allocator: Allocator, value: std.json.Value) !ModelVariant {
        if (value != .object) {
            return error.InvalidVariantFormat;
        }

        const obj = value.object;

        // Model is required
        const model_value = obj.get("model") orelse return error.MissingModelField;
        if (model_value != .string) {
            return error.InvalidModelField;
        }
        const model = try allocator.dupe(u8, model_value.string);

        // Optional rotation and uvlock
        var x: i16 = 0;
        var y: i16 = 0;
        var uvlock: bool = false;
        var weight: u32 = 1;

        if (obj.get("x")) |x_val| {
            if (x_val == .integer) {
                x = @intCast(x_val.integer);
            }
        }

        if (obj.get("y")) |y_val| {
            if (y_val == .integer) {
                y = @intCast(y_val.integer);
            }
        }

        if (obj.get("uvlock")) |uvlock_val| {
            if (uvlock_val == .bool) {
                uvlock = uvlock_val.bool;
            }
        }

        if (obj.get("weight")) |weight_val| {
            if (weight_val == .integer) {
                weight = @intCast(weight_val.integer);
            }
        }

        return .{
            .model = model,
            .x = x,
            .y = y,
            .uvlock = uvlock,
            .weight = weight,
        };
    }

    /// Get the model variant for a given state key
    /// Returns null if no variant matches
    pub fn getVariant(self: *const Self, state_key: []const u8) ?ModelVariant {
        return self.variants.get(state_key);
    }

    /// Get the default variant (empty key "")
    pub fn getDefaultVariant(self: *const Self) ?ModelVariant {
        return self.variants.get("");
    }
};

// Tests
test "BlockstateDefinition parse simple" {
    const json =
        \\{ "variants": { "": { "model": "farhorizons:block/stone" } } }
    ;

    var def = try BlockstateDefinition.parseFromJson(std.testing.allocator, json);
    defer def.deinit();

    const variant = def.getVariant("").?;
    try std.testing.expectEqualStrings("farhorizons:block/stone", variant.model);
    try std.testing.expectEqual(@as(i16, 0), variant.x);
    try std.testing.expectEqual(@as(i16, 0), variant.y);
}

test "BlockstateDefinition parse slab variants" {
    const json =
        \\{
        \\  "variants": {
        \\    "type=bottom": { "model": "farhorizons:block/oak_slab" },
        \\    "type=top": { "model": "farhorizons:block/oak_slab_top" },
        \\    "type=double": { "model": "farhorizons:block/oak_planks" }
        \\  }
        \\}
    ;

    var def = try BlockstateDefinition.parseFromJson(std.testing.allocator, json);
    defer def.deinit();

    const bottom = def.getVariant("type=bottom").?;
    try std.testing.expectEqualStrings("farhorizons:block/oak_slab", bottom.model);

    const top = def.getVariant("type=top").?;
    try std.testing.expectEqualStrings("farhorizons:block/oak_slab_top", top.model);

    const double = def.getVariant("type=double").?;
    try std.testing.expectEqualStrings("farhorizons:block/oak_planks", double.model);
}

test "BlockstateDefinition parse with rotation" {
    const json =
        \\{
        \\  "variants": {
        \\    "axis=x": { "model": "farhorizons:block/oak_log", "x": 90, "y": 90 },
        \\    "axis=y": { "model": "farhorizons:block/oak_log" },
        \\    "axis=z": { "model": "farhorizons:block/oak_log", "x": 90, "uvlock": true }
        \\  }
        \\}
    ;

    var def = try BlockstateDefinition.parseFromJson(std.testing.allocator, json);
    defer def.deinit();

    const x_axis = def.getVariant("axis=x").?;
    try std.testing.expectEqual(@as(i16, 90), x_axis.x);
    try std.testing.expectEqual(@as(i16, 90), x_axis.y);
    try std.testing.expect(!x_axis.uvlock);

    const z_axis = def.getVariant("axis=z").?;
    try std.testing.expectEqual(@as(i16, 90), z_axis.x);
    try std.testing.expectEqual(@as(i16, 0), z_axis.y);
    try std.testing.expect(z_axis.uvlock);
}
