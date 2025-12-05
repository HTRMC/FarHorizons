const std = @import("std");
const Allocator = std.mem.Allocator;

/// Direction enum matching Minecraft's Direction
pub const Direction = enum {
    down,
    up,
    north,
    south,
    west,
    east,

    pub fn fromString(str: []const u8) ?Direction {
        const map = std.StaticStringMap(Direction).initComptime(.{
            .{ "down", .down },
            .{ "up", .up },
            .{ "north", .north },
            .{ "south", .south },
            .{ "west", .west },
            .{ "east", .east },
        });
        return map.get(str);
    }
};

/// Face UV coordinates and texture reference
/// Matches net/minecraft/client/renderer/block/model/BlockElementFace.java
pub const BlockElementFace = struct {
    uv: ?[4]f32 = null, // [u1, v1, u2, v2] - optional, auto-calculated if missing
    texture: []const u8, // texture reference like "#side" or "farhorizons:block/oak_planks"
    cullface: ?Direction = null,
    rotation: i32 = 0, // 0, 90, 180, 270
    tint_index: i32 = -1,
};

/// Element rotation
/// Matches net/minecraft/client/renderer/block/model/BlockElementRotation.java
pub const BlockElementRotation = struct {
    origin: [3]f32,
    axis: u8, // 'x', 'y', or 'z'
    angle: f32,
    rescale: bool = false,
};

/// A single element (cube) in a block model
/// Matches net/minecraft/client/renderer/block/model/BlockElement.java
pub const BlockElement = struct {
    const Self = @This();

    allocator: Allocator,
    from: [3]f32,
    to: [3]f32,
    faces: std.EnumMap(Direction, BlockElementFace),
    rotation: ?BlockElementRotation = null,
    shade: bool = true,
    light_emission: u8 = 0,

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .from = .{ 0, 0, 0 },
            .to = .{ 16, 16, 16 },
            .faces = std.EnumMap(Direction, BlockElementFace){},
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.faces.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value.texture);
        }
    }

    /// Parse a BlockElement from a JSON value
    pub fn parseFromJson(allocator: Allocator, json: std.json.Value) !Self {
        var element = Self.init(allocator);
        errdefer element.deinit();

        const obj = json.object;

        // Parse from
        if (obj.get("from")) |from_value| {
            if (from_value == .array) {
                const arr = from_value.array;
                if (arr.items.len == 3) {
                    element.from[0] = jsonToFloat(arr.items[0]);
                    element.from[1] = jsonToFloat(arr.items[1]);
                    element.from[2] = jsonToFloat(arr.items[2]);
                }
            }
        }

        // Parse to
        if (obj.get("to")) |to_value| {
            if (to_value == .array) {
                const arr = to_value.array;
                if (arr.items.len == 3) {
                    element.to[0] = jsonToFloat(arr.items[0]);
                    element.to[1] = jsonToFloat(arr.items[1]);
                    element.to[2] = jsonToFloat(arr.items[2]);
                }
            }
        }

        // Parse faces
        if (obj.get("faces")) |faces_value| {
            if (faces_value == .object) {
                var faces_it = faces_value.object.iterator();
                while (faces_it.next()) |entry| {
                    const direction = Direction.fromString(entry.key_ptr.*) orelse continue;
                    const face = try parseFace(allocator, entry.value_ptr.*);
                    element.faces.put(direction, face);
                }
            }
        }

        // Parse rotation
        if (obj.get("rotation")) |rot_value| {
            if (rot_value == .object) {
                element.rotation = parseRotation(rot_value.object);
            }
        }

        // Parse shade
        if (obj.get("shade")) |shade_value| {
            if (shade_value == .bool) {
                element.shade = shade_value.bool;
            }
        }

        // Parse light_emission
        if (obj.get("light_emission")) |le_value| {
            if (le_value == .integer) {
                element.light_emission = @intCast(@max(0, @min(15, le_value.integer)));
            }
        }

        return element;
    }

    fn parseFace(allocator: Allocator, json: std.json.Value) !BlockElementFace {
        const obj = json.object;

        var face = BlockElementFace{
            .texture = undefined,
        };

        // Parse texture (required)
        if (obj.get("texture")) |tex_value| {
            if (tex_value == .string) {
                face.texture = try allocator.dupe(u8, tex_value.string);
            } else {
                return error.MissingTexture;
            }
        } else {
            return error.MissingTexture;
        }

        // Parse uv (optional)
        if (obj.get("uv")) |uv_value| {
            if (uv_value == .array) {
                const arr = uv_value.array;
                if (arr.items.len == 4) {
                    face.uv = .{
                        jsonToFloat(arr.items[0]),
                        jsonToFloat(arr.items[1]),
                        jsonToFloat(arr.items[2]),
                        jsonToFloat(arr.items[3]),
                    };
                }
            }
        }

        // Parse cullface (optional)
        if (obj.get("cullface")) |cf_value| {
            if (cf_value == .string) {
                face.cullface = Direction.fromString(cf_value.string);
            }
        }

        // Parse rotation (optional)
        if (obj.get("rotation")) |rot_value| {
            if (rot_value == .integer) {
                face.rotation = @intCast(rot_value.integer);
            }
        }

        // Parse tintindex (optional)
        if (obj.get("tintindex")) |ti_value| {
            if (ti_value == .integer) {
                face.tint_index = @intCast(ti_value.integer);
            }
        }

        return face;
    }

    fn parseRotation(obj: std.json.ObjectMap) ?BlockElementRotation {
        var rotation = BlockElementRotation{
            .origin = .{ 8, 8, 8 }, // Default origin is center
            .axis = 'y',
            .angle = 0,
        };

        // Parse origin
        if (obj.get("origin")) |origin_value| {
            if (origin_value == .array) {
                const arr = origin_value.array;
                if (arr.items.len == 3) {
                    rotation.origin[0] = jsonToFloat(arr.items[0]);
                    rotation.origin[1] = jsonToFloat(arr.items[1]);
                    rotation.origin[2] = jsonToFloat(arr.items[2]);
                }
            }
        }

        // Parse axis
        if (obj.get("axis")) |axis_value| {
            if (axis_value == .string and axis_value.string.len > 0) {
                rotation.axis = axis_value.string[0];
            }
        }

        // Parse angle
        if (obj.get("angle")) |angle_value| {
            rotation.angle = jsonToFloat(angle_value);
        }

        // Parse rescale
        if (obj.get("rescale")) |rescale_value| {
            if (rescale_value == .bool) {
                rotation.rescale = rescale_value.bool;
            }
        }

        return rotation;
    }

    fn jsonToFloat(value: std.json.Value) f32 {
        return switch (value) {
            .integer => |i| @floatFromInt(i),
            .float => |f| @floatCast(f),
            else => 0,
        };
    }
};
