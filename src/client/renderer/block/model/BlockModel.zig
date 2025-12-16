const std = @import("std");
const Allocator = std.mem.Allocator;
const BlockElement = @import("BlockElement.zig").BlockElement;

/// Represents a block model JSON file
pub const BlockModel = struct {
    const Self = @This();

    allocator: Allocator,
    parent: ?[]const u8 = null,
    textures: std.StringHashMap([]const u8),
    elements: ?[]BlockElement = null,
    ambient_occlusion: ?bool = null,
    gui_light: ?[]const u8 = null,

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .textures = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.parent) |p| self.allocator.free(p);

        var it = self.textures.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.textures.deinit();

        if (self.elements) |elements| {
            for (elements) |*elem| {
                elem.deinit();
            }
            self.allocator.free(elements);
        }

        if (self.gui_light) |gl| self.allocator.free(gl);
    }

    /// Parse a BlockModel from JSON bytes
    pub fn parseFromJson(allocator: Allocator, json_data: []const u8) !Self {
        var model = Self.init(allocator);
        errdefer model.deinit();

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_data, .{});
        defer parsed.deinit();

        const root = parsed.value.object;

        // Parse parent
        if (root.get("parent")) |parent_value| {
            if (parent_value == .string) {
                model.parent = try allocator.dupe(u8, parent_value.string);
            }
        }

        // Parse textures
        if (root.get("textures")) |textures_value| {
            if (textures_value == .object) {
                var tex_it = textures_value.object.iterator();
                while (tex_it.next()) |entry| {
                    if (entry.value_ptr.* == .string) {
                        const key = try allocator.dupe(u8, entry.key_ptr.*);
                        errdefer allocator.free(key);
                        const value = try allocator.dupe(u8, entry.value_ptr.string);
                        try model.textures.put(key, value);
                    }
                }
            }
        }

        // Parse elements
        if (root.get("elements")) |elements_value| {
            if (elements_value == .array) {
                const arr = elements_value.array;
                var elements = try allocator.alloc(BlockElement, arr.items.len);
                errdefer allocator.free(elements);

                for (arr.items, 0..) |elem_json, i| {
                    elements[i] = try BlockElement.parseFromJson(allocator, elem_json);
                }
                model.elements = elements;
            }
        }

        // Parse ambient occlusion
        if (root.get("ambientocclusion")) |ao_value| {
            if (ao_value == .bool) {
                model.ambient_occlusion = ao_value.bool;
            }
        }

        // Parse gui_light
        if (root.get("gui_light")) |gl_value| {
            if (gl_value == .string) {
                model.gui_light = try allocator.dupe(u8, gl_value.string);
            }
        }

        return model;
    }

    /// Resolve texture reference (handles #texture_name references)
    pub fn resolveTexture(self: *const Self, texture_ref: []const u8) ?[]const u8 {
        if (texture_ref.len > 0 and texture_ref[0] == '#') {
            // It's a reference to another texture slot
            const slot_name = texture_ref[1..];
            if (self.textures.get(slot_name)) |resolved| {
                // Recursively resolve in case of chained references
                return self.resolveTexture(resolved);
            }
            return null;
        }
        return texture_ref;
    }
};
