const std = @import("std");
const WorldState = @import("WorldState.zig");
const ExtraQuadModel = WorldState.ExtraQuadModel;
const ShapeFace = WorldState.ShapeFace;
const BlockType = WorldState.BlockType;
const app_config = @import("../app_config.zig");

const Io = std.Io;
const Dir = Io.Dir;
const sep = std.fs.path.sep_str;

const NUM_BLOCKS = @typeInfo(BlockType).@"enum".fields.len;

// Texture name → index mapping (must match TextureManager.block_texture_names)
const texture_map = std.StaticStringMap(u8).initComptime(.{
    .{ "glass", 0 },
    .{ "grass_block", 1 },
    .{ "dirt", 2 },
    .{ "stone", 3 },
    .{ "glowstone", 4 },
    .{ "sand", 5 },
    .{ "snow", 6 },
    .{ "water", 7 },
    .{ "gravel", 8 },
    .{ "cobblestone", 9 },
    .{ "oak_log", 10 },
    .{ "oak_planks", 11 },
    .{ "bricks", 12 },
    .{ "bedrock", 13 },
    .{ "gold_ore", 14 },
    .{ "iron_ore", 15 },
    .{ "coal_ore", 16 },
    .{ "diamond_ore", 17 },
    .{ "sponge", 18 },
    .{ "pumice", 19 },
    .{ "wool", 20 },
    .{ "gold_block", 21 },
    .{ "iron_block", 22 },
    .{ "diamond_block", 23 },
    .{ "bookshelf", 24 },
    .{ "obsidian", 25 },
    .{ "oak_leaves", 26 },
    .{ "oak_log_top", 27 },
    .{ "torch", 28 },
    .{ "ladder", 29 },
});

// Face name → face_bucket mapping (south=0/+Z, north=1/-Z, west=2/-X, east=3/+X, up=4/+Y, down=5/-Y)
const face_bucket_map = std.StaticStringMap(u3).initComptime(.{
    .{ "south", 0 },
    .{ "north", 1 },
    .{ "west", 2 },
    .{ "east", 3 },
    .{ "up", 4 },
    .{ "down", 5 },
});

// Face normals for standard directions
const face_normals = [6][3]f32{
    .{ 0, 0, 1 },  // south +Z
    .{ 0, 0, -1 }, // north -Z
    .{ -1, 0, 0 }, // west -X
    .{ 1, 0, 0 },  // east +X
    .{ 0, 1, 0 },  // up +Y
    .{ 0, -1, 0 }, // down -Y
};

const Transform = enum {
    none,
    flip_y,
    rotate_90,
    rotate_180,
    rotate_270,
};

const BlockModelEntry = struct {
    block: BlockType,
    json_file: []const u8,
    transform: Transform,
};

// Maps block types to their JSON model file + transform
const block_model_table = [_]BlockModelEntry{
    .{ .block = .oak_slab_bottom, .json_file = "oak_slab.json", .transform = .none },
    .{ .block = .oak_slab_top, .json_file = "oak_slab.json", .transform = .flip_y },
    .{ .block = .oak_stairs_south, .json_file = "oak_stairs.json", .transform = .none },
    .{ .block = .oak_stairs_north, .json_file = "oak_stairs.json", .transform = .rotate_180 },
    .{ .block = .oak_stairs_east, .json_file = "oak_stairs.json", .transform = .rotate_90 },
    .{ .block = .oak_stairs_west, .json_file = "oak_stairs.json", .transform = .rotate_270 },
    .{ .block = .torch, .json_file = "torch.json", .transform = .none },
    .{ .block = .ladder_south, .json_file = "ladder.json", .transform = .none },
    .{ .block = .ladder_north, .json_file = "ladder.json", .transform = .rotate_180 },
    .{ .block = .ladder_east, .json_file = "ladder.json", .transform = .rotate_90 },
    .{ .block = .ladder_west, .json_file = "ladder.json", .transform = .rotate_270 },
};

pub const BlockModelRegistry = struct {
    allocator: std.mem.Allocator,
    extra_models: []ExtraQuadModel,
    block_shape_faces: [NUM_BLOCKS][]ShapeFace,
    block_face_tex_indices: [NUM_BLOCKS][]u8,

    pub fn init(allocator: std.mem.Allocator) !*BlockModelRegistry {
        const self = try allocator.create(BlockModelRegistry);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.block_shape_faces = .{&.{}} ** NUM_BLOCKS;
        self.block_face_tex_indices = .{&.{}} ** NUM_BLOCKS;

        var extra_models_list: std.ArrayList(ExtraQuadModel) = .empty;
        defer extra_models_list.deinit(allocator);

        // Load JSON files and build the registry
        const assets_path = try app_config.getAssetsPath(allocator);
        defer allocator.free(assets_path);

        const models_dir = try std.fmt.allocPrint(allocator, "{s}" ++ sep ++ "models" ++ sep ++ "block" ++ sep, .{assets_path});
        defer allocator.free(models_dir);

        // Cache loaded JSON model data keyed by filename
        var model_cache = std.StringHashMap([]const u8).init(allocator);
        defer {
            var it = model_cache.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.value_ptr.*);
            }
            model_cache.deinit();
        }

        for (block_model_table) |entry| {
            // Load JSON file (cached)
            const json_data = if (model_cache.get(entry.json_file)) |cached|
                cached
            else blk: {
                const path = try std.fmt.allocPrintSentinel(allocator, "{s}{s}", .{ models_dir, entry.json_file }, 0);
                defer allocator.free(path);

                const io = Io.Threaded.global_single_threaded.io();
                const file = Dir.openFileAbsolute(io, path, .{}) catch |err| {
                    std.log.err("Failed to open model file {s}: {}", .{ entry.json_file, err });
                    continue;
                };
                defer file.close(io);

                const stat = file.stat(io) catch |err| {
                    std.log.err("Failed to stat model file {s}: {}", .{ entry.json_file, err });
                    continue;
                };
                const data = allocator.alloc(u8, stat.size) catch continue;
                const read_n = file.readPositionalAll(io, data, 0) catch |err| {
                    allocator.free(data);
                    std.log.err("Failed to read model file {s}: {}", .{ entry.json_file, err });
                    continue;
                };
                _ = read_n;

                model_cache.put(entry.json_file, data) catch {
                    allocator.free(data);
                    continue;
                };
                break :blk data;
            };

            try loadModel(self, allocator, &extra_models_list, json_data, entry.block, entry.transform);
        }

        self.extra_models = try allocator.dupe(ExtraQuadModel, extra_models_list.items);
        std.log.info("BlockModelLoader: loaded {} extra models for {} block types", .{ self.extra_models.len, block_model_table.len });

        return self;
    }

    pub fn deinit(self: *BlockModelRegistry) void {
        for (0..NUM_BLOCKS) |i| {
            if (self.block_shape_faces[i].len > 0) {
                self.allocator.free(self.block_shape_faces[i]);
            }
            if (self.block_face_tex_indices[i].len > 0) {
                self.allocator.free(self.block_face_tex_indices[i]);
            }
        }
        if (self.extra_models.len > 0) {
            self.allocator.free(self.extra_models);
        }
        self.allocator.destroy(self);
    }

    pub fn totalModelCount(self: *const BlockModelRegistry) u32 {
        return 6 + @as(u32, @intCast(self.extra_models.len));
    }
};

fn loadModel(
    registry: *BlockModelRegistry,
    allocator: std.mem.Allocator,
    extra_models: *std.ArrayList(ExtraQuadModel),
    json_data: []const u8,
    block: BlockType,
    transform: Transform,
) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_data, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    // Parse textures map
    const textures_obj = root.get("textures") orelse return error.MissingTextures;

    // Parse elements
    const elements = (root.get("elements") orelse return error.MissingElements).array.items;

    var shape_faces: std.ArrayList(ShapeFace) = .empty;
    defer shape_faces.deinit(allocator);
    var tex_indices: std.ArrayList(u8) = .empty;
    defer tex_indices.deinit(allocator);

    for (elements) |element| {
        const elem_obj = element.object;
        const from_arr = (elem_obj.get("from") orelse continue).array.items;
        const to_arr = (elem_obj.get("to") orelse continue).array.items;

        const from = [3]f32{
            jsonFloat(from_arr[0]) / 16.0,
            jsonFloat(from_arr[1]) / 16.0,
            jsonFloat(from_arr[2]) / 16.0,
        };
        const to = [3]f32{
            jsonFloat(to_arr[0]) / 16.0,
            jsonFloat(to_arr[1]) / 16.0,
            jsonFloat(to_arr[2]) / 16.0,
        };

        const faces_obj = (elem_obj.get("faces") orelse continue).object;

        var faces_iter = faces_obj.iterator();
        while (faces_iter.next()) |face_entry| {
            const face_name = face_entry.key_ptr.*;
            const face_data = face_entry.value_ptr.*.object;

            // Parse UV
            const uv_arr = (face_data.get("uv") orelse continue).array.items;
            const uv = [4]f32{
                jsonFloat(uv_arr[0]) / 16.0,
                jsonFloat(uv_arr[1]) / 16.0,
                jsonFloat(uv_arr[2]) / 16.0,
                jsonFloat(uv_arr[3]) / 16.0,
            };

            // Parse texture reference
            const tex_ref = (face_data.get("texture") orelse continue).string;
            const tex_name = resolveTexture(tex_ref, textures_obj.object);
            const tex_idx = if (tex_name) |name| texture_map.get(name) orelse 0 else 0;

            // Check cullface
            const has_cullface = face_data.get("cullface") != null;

            // Check for cross faces (special torch-style cross quads)
            if (std.mem.startsWith(u8, face_name, "__cross_")) {
                const quad_model = buildCrossQuad(face_name, uv, transform);
                if (quad_model) |qm| {
                    const model_idx: u9 = @intCast(6 + extra_models.items.len);
                    try extra_models.append(allocator, qm);
                    // Cross faces get face_bucket based on which cross
                    const bucket: u3 = getCrossFaceBucket(face_name);
                    try shape_faces.append(allocator, .{
                        .model_index = model_idx,
                        .face_bucket = bucket,
                        .always_emit = true,
                    });
                    try tex_indices.append(allocator, tex_idx);
                }
                continue;
            }

            const bucket = face_bucket_map.get(face_name) orelse continue;

            // Build the quad from element box + face direction
            var quad_model = buildBoxFaceQuad(from, to, bucket, uv);

            // Apply transform
            quad_model = applyTransform(quad_model, transform, bucket);
            const transformed_bucket = transformBucket(bucket, transform);
            const always_emit = !has_cullface;

            const model_idx: u9 = @intCast(6 + extra_models.items.len);
            try extra_models.append(allocator, quad_model);
            try shape_faces.append(allocator, .{
                .model_index = model_idx,
                .face_bucket = transformed_bucket,
                .always_emit = always_emit,
            });
            try tex_indices.append(allocator, tex_idx);
        }
    }

    const bi = @intFromEnum(block);
    registry.block_shape_faces[bi] = try allocator.dupe(ShapeFace, shape_faces.items);
    registry.block_face_tex_indices[bi] = try allocator.dupe(u8, tex_indices.items);
}

fn jsonFloat(val: std.json.Value) f32 {
    return switch (val) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        else => 0,
    };
}

fn resolveTexture(tex_ref: []const u8, textures: std.json.ObjectMap) ?[]const u8 {
    if (tex_ref.len > 0 and tex_ref[0] == '#') {
        const key = tex_ref[1..];
        if (textures.get(key)) |val| {
            return val.string;
        }
    }
    return tex_ref;
}

/// Build a quad for one face of an axis-aligned box element.
fn buildBoxFaceQuad(from: [3]f32, to: [3]f32, face: u3, uv: [4]f32) ExtraQuadModel {
    // uv: [u0, v0, u1, v1]
    const uv0 = uv[0];
    const uv1 = uv[1];
    const uv2 = uv[2];
    const uv3 = uv[3];

    const x0 = from[0];
    const y0 = from[1];
    const z0 = from[2];
    const x1 = to[0];
    const y1 = to[1];
    const z1 = to[2];

    // Corner winding must match face_vertices convention
    return switch (face) {
        0 => .{ // south (+Z)
            .corners = .{ .{ x0, y0, z1 }, .{ x1, y0, z1 }, .{ x1, y1, z1 }, .{ x0, y1, z1 } },
            .uvs = .{ .{ uv0, uv3 }, .{ uv2, uv3 }, .{ uv2, uv1 }, .{ uv0, uv1 } },
            .normal = face_normals[0],
        },
        1 => .{ // north (-Z)
            .corners = .{ .{ x1, y0, z0 }, .{ x0, y0, z0 }, .{ x0, y1, z0 }, .{ x1, y1, z0 } },
            .uvs = .{ .{ uv0, uv3 }, .{ uv2, uv3 }, .{ uv2, uv1 }, .{ uv0, uv1 } },
            .normal = face_normals[1],
        },
        2 => .{ // west (-X)
            .corners = .{ .{ x0, y0, z0 }, .{ x0, y0, z1 }, .{ x0, y1, z1 }, .{ x0, y1, z0 } },
            .uvs = .{ .{ uv0, uv3 }, .{ uv2, uv3 }, .{ uv2, uv1 }, .{ uv0, uv1 } },
            .normal = face_normals[2],
        },
        3 => .{ // east (+X)
            .corners = .{ .{ x1, y0, z1 }, .{ x1, y0, z0 }, .{ x1, y1, z0 }, .{ x1, y1, z1 } },
            .uvs = .{ .{ uv0, uv3 }, .{ uv2, uv3 }, .{ uv2, uv1 }, .{ uv0, uv1 } },
            .normal = face_normals[3],
        },
        4 => .{ // up (+Y)
            .corners = .{ .{ x0, y1, z1 }, .{ x1, y1, z1 }, .{ x1, y1, z0 }, .{ x0, y1, z0 } },
            .uvs = .{ .{ uv0, uv3 }, .{ uv2, uv3 }, .{ uv2, uv1 }, .{ uv0, uv1 } },
            .normal = face_normals[4],
        },
        5 => .{ // down (-Y)
            .corners = .{ .{ x0, y0, z0 }, .{ x1, y0, z0 }, .{ x1, y0, z1 }, .{ x0, y0, z1 } },
            .uvs = .{ .{ uv0, uv3 }, .{ uv2, uv3 }, .{ uv2, uv1 }, .{ uv0, uv1 } },
            .normal = face_normals[5],
        },
        else => unreachable,
    };
}

/// Build a cross-shaped quad (for torches and similar)
fn buildCrossQuad(face_name: []const u8, uv: [4]f32, transform: Transform) ?ExtraQuadModel {
    _ = transform;
    const uv0 = uv[0];
    const uv1 = uv[1];
    const uv2 = uv[2];
    const uv3 = uv[3];

    if (std.mem.eql(u8, face_name, "__cross_nwse_front")) {
        return .{
            .corners = .{ .{ 0, 0, 0 }, .{ 1, 0, 1 }, .{ 1, 1, 1 }, .{ 0, 1, 0 } },
            .uvs = .{ .{ uv0, uv3 }, .{ uv2, uv3 }, .{ uv2, uv1 }, .{ uv0, uv1 } },
            .normal = .{ 0.707, 0, -0.707 },
        };
    } else if (std.mem.eql(u8, face_name, "__cross_nwse_back")) {
        return .{
            .corners = .{ .{ 1, 0, 1 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }, .{ 1, 1, 1 } },
            .uvs = .{ .{ uv0, uv3 }, .{ uv2, uv3 }, .{ uv2, uv1 }, .{ uv0, uv1 } },
            .normal = .{ -0.707, 0, 0.707 },
        };
    } else if (std.mem.eql(u8, face_name, "__cross_nesw_front")) {
        return .{
            .corners = .{ .{ 1, 0, 0 }, .{ 0, 0, 1 }, .{ 0, 1, 1 }, .{ 1, 1, 0 } },
            .uvs = .{ .{ uv0, uv3 }, .{ uv2, uv3 }, .{ uv2, uv1 }, .{ uv0, uv1 } },
            .normal = .{ 0.707, 0, 0.707 },
        };
    } else if (std.mem.eql(u8, face_name, "__cross_nesw_back")) {
        return .{
            .corners = .{ .{ 0, 0, 1 }, .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 0, 1, 1 } },
            .uvs = .{ .{ uv0, uv3 }, .{ uv2, uv3 }, .{ uv2, uv1 }, .{ uv0, uv1 } },
            .normal = .{ -0.707, 0, -0.707 },
        };
    }
    return null;
}

fn getCrossFaceBucket(face_name: []const u8) u3 {
    if (std.mem.eql(u8, face_name, "__cross_nwse_front")) return 0;
    if (std.mem.eql(u8, face_name, "__cross_nwse_back")) return 1;
    if (std.mem.eql(u8, face_name, "__cross_nesw_front")) return 2;
    if (std.mem.eql(u8, face_name, "__cross_nesw_back")) return 3;
    return 0;
}

/// Apply a transform (rotation, flip) to a quad model's corners and normal.
fn applyTransform(model: ExtraQuadModel, transform: Transform, _: u3) ExtraQuadModel {
    var result = model;

    switch (transform) {
        .none => {},
        .flip_y => {
            // Flip Y: y → 1-y, reverse winding, flip normal Y
            for (0..4) |i| {
                result.corners[i][1] = 1.0 - model.corners[i][1];
            }
            // Reverse winding to maintain correct face orientation
            const tmp_c = result.corners;
            const tmp_u = result.uvs;
            result.corners = .{ tmp_c[3], tmp_c[2], tmp_c[1], tmp_c[0] };
            result.uvs = .{ tmp_u[3], tmp_u[2], tmp_u[1], tmp_u[0] };
            result.normal[1] = -model.normal[1];
        },
        .rotate_90 => {
            // 90° CW around Y: (x,z) → (0.5 + (z-0.5), 0.5 - (x-0.5)) = (z, 1-x)
            for (0..4) |i| {
                const x = model.corners[i][0];
                const z = model.corners[i][2];
                result.corners[i][0] = z;
                result.corners[i][2] = 1.0 - x;
            }
            const nx = model.normal[0];
            const nz = model.normal[2];
            result.normal[0] = nz;
            result.normal[2] = -nx;
        },
        .rotate_180 => {
            // 180° around Y: (x,z) → (1-x, 1-z)
            for (0..4) |i| {
                result.corners[i][0] = 1.0 - model.corners[i][0];
                result.corners[i][2] = 1.0 - model.corners[i][2];
            }
            result.normal[0] = -model.normal[0];
            result.normal[2] = -model.normal[2];
        },
        .rotate_270 => {
            // 270° CW around Y (= 90° CCW): (x,z) → (1-z, x)
            for (0..4) |i| {
                const x = model.corners[i][0];
                const z = model.corners[i][2];
                result.corners[i][0] = 1.0 - z;
                result.corners[i][2] = x;
            }
            const nx = model.normal[0];
            const nz = model.normal[2];
            result.normal[0] = -nz;
            result.normal[2] = nx;
        },
    }

    return result;
}

/// Transform a face bucket direction according to a Y-axis rotation/flip.
fn transformBucket(bucket: u3, transform: Transform) u3 {
    return switch (transform) {
        .none => bucket,
        .flip_y => switch (bucket) {
            4 => 5, // up → down
            5 => 4, // down → up
            else => bucket,
        },
        // south=0(+Z), north=1(-Z), west=2(-X), east=3(+X)
        // 90° CW: south→east, east→north, north→west, west→south
        .rotate_90 => switch (bucket) {
            0 => 3, // south → east
            1 => 2, // north → west
            2 => 0, // west → south
            3 => 1, // east → north
            else => bucket,
        },
        // 180°: south→north, north→south, west→east, east→west
        .rotate_180 => switch (bucket) {
            0 => 1,
            1 => 0,
            2 => 3,
            3 => 2,
            else => bucket,
        },
        // 270° CW: south→west, west→north, north→east, east→south
        .rotate_270 => switch (bucket) {
            0 => 2, // south → west
            1 => 3, // north → east
            2 => 1, // west → north
            3 => 0, // east → south
            else => bucket,
        },
    };
}
