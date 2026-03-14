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
    .{ "torch_fire", 30 },
    .{ "torch_fire_particle", 31 },
    .{ "oak_door_bottom", 32 },
    .{ "oak_door_top", 33 },
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

const ElementRotation = struct {
    angle_deg: f32,
    axis: u8, // 'x', 'y', or 'z'
    origin: [3]f32,
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
    .{ .block = .torch, .json_file = "torch_standing.json", .transform = .none },
    .{ .block = .torch_wall_west, .json_file = "torch_wall.json", .transform = .none },
    .{ .block = .torch_wall_east, .json_file = "torch_wall.json", .transform = .rotate_180 },
    .{ .block = .torch_wall_south, .json_file = "torch_wall.json", .transform = .rotate_90 },
    .{ .block = .torch_wall_north, .json_file = "torch_wall.json", .transform = .rotate_270 },
    .{ .block = .ladder_south, .json_file = "ladder.json", .transform = .none },
    .{ .block = .ladder_north, .json_file = "ladder.json", .transform = .rotate_180 },
    .{ .block = .ladder_east, .json_file = "ladder.json", .transform = .rotate_90 },
    .{ .block = .ladder_west, .json_file = "ladder.json", .transform = .rotate_270 },
    // Oak door bottom half (left hinge): facing determines closed rotation, open adds 90°
    .{ .block = .oak_door_bottom_east, .json_file = "oak_door_bottom.json", .transform = .none },
    .{ .block = .oak_door_bottom_east_open, .json_file = "oak_door_bottom.json", .transform = .rotate_90 },
    .{ .block = .oak_door_bottom_south, .json_file = "oak_door_bottom.json", .transform = .rotate_90 },
    .{ .block = .oak_door_bottom_south_open, .json_file = "oak_door_bottom.json", .transform = .rotate_180 },
    .{ .block = .oak_door_bottom_west, .json_file = "oak_door_bottom.json", .transform = .rotate_180 },
    .{ .block = .oak_door_bottom_west_open, .json_file = "oak_door_bottom.json", .transform = .rotate_270 },
    .{ .block = .oak_door_bottom_north, .json_file = "oak_door_bottom.json", .transform = .rotate_270 },
    .{ .block = .oak_door_bottom_north_open, .json_file = "oak_door_bottom.json", .transform = .none },
    // Oak door top half
    .{ .block = .oak_door_top_east, .json_file = "oak_door_top.json", .transform = .none },
    .{ .block = .oak_door_top_east_open, .json_file = "oak_door_top.json", .transform = .rotate_90 },
    .{ .block = .oak_door_top_south, .json_file = "oak_door_top.json", .transform = .rotate_90 },
    .{ .block = .oak_door_top_south_open, .json_file = "oak_door_top.json", .transform = .rotate_180 },
    .{ .block = .oak_door_top_west, .json_file = "oak_door_top.json", .transform = .rotate_180 },
    .{ .block = .oak_door_top_west_open, .json_file = "oak_door_top.json", .transform = .rotate_270 },
    .{ .block = .oak_door_top_north, .json_file = "oak_door_top.json", .transform = .rotate_270 },
    .{ .block = .oak_door_top_north_open, .json_file = "oak_door_top.json", .transform = .none },
    // Oak fence: 16 connection variants, each with its own model
    .{ .block = .oak_fence_post, .json_file = "oak_fence_post.json", .transform = .none },
    .{ .block = .oak_fence_n, .json_file = "oak_fence_n.json", .transform = .none },
    .{ .block = .oak_fence_s, .json_file = "oak_fence_s.json", .transform = .none },
    .{ .block = .oak_fence_e, .json_file = "oak_fence_e.json", .transform = .none },
    .{ .block = .oak_fence_w, .json_file = "oak_fence_w.json", .transform = .none },
    .{ .block = .oak_fence_ns, .json_file = "oak_fence_ns.json", .transform = .none },
    .{ .block = .oak_fence_ne, .json_file = "oak_fence_ne.json", .transform = .none },
    .{ .block = .oak_fence_nw, .json_file = "oak_fence_nw.json", .transform = .none },
    .{ .block = .oak_fence_se, .json_file = "oak_fence_se.json", .transform = .none },
    .{ .block = .oak_fence_sw, .json_file = "oak_fence_sw.json", .transform = .none },
    .{ .block = .oak_fence_ew, .json_file = "oak_fence_ew.json", .transform = .none },
    .{ .block = .oak_fence_nse, .json_file = "oak_fence_nse.json", .transform = .none },
    .{ .block = .oak_fence_nsw, .json_file = "oak_fence_nsw.json", .transform = .none },
    .{ .block = .oak_fence_new, .json_file = "oak_fence_new.json", .transform = .none },
    .{ .block = .oak_fence_sew, .json_file = "oak_fence_sew.json", .transform = .none },
    .{ .block = .oak_fence_nsew, .json_file = "oak_fence_nsew.json", .transform = .none },
};

pub const BlockModelRegistry = struct {
    allocator: std.mem.Allocator,
    extra_models: []ExtraQuadModel,
    block_shape_faces: [NUM_BLOCKS][]ShapeFace,
    block_face_tex_indices: [NUM_BLOCKS][]u8,
    /// Per-block, per-face: 4×4 bitmap of which cells this block covers on the face boundary.
    /// Bit layout: bit = row * 4 + col, where row/col are 0..3 subdivisions of the face plane.
    /// For vertical faces (S/N/E/W): col = horizontal axis, row = Y (0=bottom, 3=top).
    /// For horizontal faces (up/down): col = X, row = Z.
    /// 0xFFFF = full face coverage. Used for Minecraft-style VoxelShape occlusion culling.
    block_face_bitmaps: [NUM_BLOCKS][6]u16,

    pub fn init(allocator: std.mem.Allocator) !*BlockModelRegistry {
        const self = try allocator.create(BlockModelRegistry);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.block_shape_faces = .{&.{}} ** NUM_BLOCKS;
        self.block_face_tex_indices = .{&.{}} ** NUM_BLOCKS;
        self.block_face_bitmaps = .{.{0} ** 6} ** NUM_BLOCKS;

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
        return WorldState.EXTRA_MODEL_BASE + @as(u32, @intCast(self.extra_models.len));
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

    // Track 4×4 bitmaps per face direction (accumulated after transform)
    var face_bitmaps: [6]u16 = .{0} ** 6;

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

        // Parse optional element rotation
        const elem_rotation: ?ElementRotation = if (elem_obj.get("rotation")) |rot_val| blk: {
            const rot = rot_val.object;
            const angle_val = rot.get("angle") orelse break :blk null;
            const axis_val = rot.get("axis") orelse break :blk null;
            const origin_val = rot.get("origin") orelse break :blk null;
            const angle = jsonFloat(angle_val);
            const axis_str = axis_val.string;
            const origin_arr = origin_val.array.items;
            break :blk ElementRotation{
                .angle_deg = angle,
                .axis = axis_str[0],
                .origin = .{
                    jsonFloat(origin_arr[0]) / 16.0,
                    jsonFloat(origin_arr[1]) / 16.0,
                    jsonFloat(origin_arr[2]) / 16.0,
                },
            };
        } else null;

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
                    const model_idx: u9 = @intCast(WorldState.EXTRA_MODEL_BASE + extra_models.items.len);
                    try extra_models.append(allocator, qm);
                    // Cross faces get face_bucket based on which cross
                    const bucket: u3 = getCrossFaceBucket(face_name);
                    try shape_faces.append(allocator, .{
                        .model_index = model_idx,
                        .face_bucket = bucket,
                        .always_emit = true,
                        .face_bitmap = 0,
                    });
                    try tex_indices.append(allocator, tex_idx);
                }
                continue;
            }

            const bucket = face_bucket_map.get(face_name) orelse continue;

            // Compute per-quad bitmap and accumulate block-level bitmap
            const transformed_bucket = transformBucket(bucket, transform);
            var quad_bitmap: u16 = 0;
            if (has_cullface) {
                const tb = transformBox(from, to, transform);
                quad_bitmap = elementFaceBitmap(tb[0], tb[1], transformed_bucket);
                face_bitmaps[transformed_bucket] |= quad_bitmap;
            }

            // Build the quad from element box + face direction
            var quad_model = buildBoxFaceQuad(from, to, bucket, uv);

            // Apply element rotation (e.g. tilted wall torch)
            if (elem_rotation) |rot| {
                quad_model = applyElementRotation(quad_model, rot);
            }

            // Apply transform
            quad_model = applyTransform(quad_model, transform, bucket);
            const always_emit = !has_cullface;

            const model_idx: u9 = @intCast(WorldState.EXTRA_MODEL_BASE + extra_models.items.len);
            try extra_models.append(allocator, quad_model);
            try shape_faces.append(allocator, .{
                .model_index = model_idx,
                .face_bucket = transformed_bucket,
                .always_emit = always_emit,
                .face_bitmap = quad_bitmap,
            });
            try tex_indices.append(allocator, tex_idx);
        }
    }

    const bi = @intFromEnum(block);
    registry.block_shape_faces[bi] = try allocator.dupe(ShapeFace, shape_faces.items);
    registry.block_face_tex_indices[bi] = try allocator.dupe(u8, tex_indices.items);

    // Store accumulated bitmaps (already in transformed space)
    registry.block_face_bitmaps[bi] = face_bitmaps;
}

/// Compute a 4×4 bitmap of which cells this element covers on the given block boundary face.
/// Returns 0 if the element doesn't touch that boundary.
/// Bit layout: bit = row * 4 + col (row 0 = min of second axis, col 0 = min of first axis).
pub fn elementFaceBitmap(from: [3]f32, to: [3]f32, face: u3) u16 {
    const eps = 0.001;

    // Determine the two axes that form the face plane and check boundary condition
    var axis_a_min: f32 = undefined;
    var axis_a_max: f32 = undefined;
    var axis_b_min: f32 = undefined;
    var axis_b_max: f32 = undefined;
    var on_boundary = false;

    switch (face) {
        0 => { // south +Z: boundary at z=1, face plane = XY
            on_boundary = @abs(to[2] - 1.0) < eps;
            axis_a_min = from[0]; axis_a_max = to[0]; // X → col
            axis_b_min = from[1]; axis_b_max = to[1]; // Y → row
        },
        1 => { // north -Z: boundary at z=0, face plane = XY
            on_boundary = @abs(from[2]) < eps;
            axis_a_min = from[0]; axis_a_max = to[0];
            axis_b_min = from[1]; axis_b_max = to[1];
        },
        2 => { // west -X: boundary at x=0, face plane = ZY
            on_boundary = @abs(from[0]) < eps;
            axis_a_min = from[2]; axis_a_max = to[2]; // Z → col
            axis_b_min = from[1]; axis_b_max = to[1]; // Y → row
        },
        3 => { // east +X: boundary at x=1, face plane = ZY
            on_boundary = @abs(to[0] - 1.0) < eps;
            axis_a_min = from[2]; axis_a_max = to[2];
            axis_b_min = from[1]; axis_b_max = to[1];
        },
        4 => { // up +Y: boundary at y=1, face plane = XZ
            on_boundary = @abs(to[1] - 1.0) < eps;
            axis_a_min = from[0]; axis_a_max = to[0]; // X → col
            axis_b_min = from[2]; axis_b_max = to[2]; // Z → row
        },
        5 => { // down -Y: boundary at y=0, face plane = XZ
            on_boundary = @abs(from[1]) < eps;
            axis_a_min = from[0]; axis_a_max = to[0];
            axis_b_min = from[2]; axis_b_max = to[2];
        },
        else => return 0,
    }

    if (!on_boundary) return 0;

    // Compute which 4×4 cells are covered
    var bitmap: u16 = 0;
    for (0..4) |row| {
        const row_min: f32 = @as(f32, @floatFromInt(row)) / 4.0;
        const row_max: f32 = @as(f32, @floatFromInt(row + 1)) / 4.0;
        if (axis_b_max <= row_min + eps or axis_b_min >= row_max - eps) continue;

        for (0..4) |col| {
            const col_min: f32 = @as(f32, @floatFromInt(col)) / 4.0;
            const col_max: f32 = @as(f32, @floatFromInt(col + 1)) / 4.0;
            if (axis_a_max <= col_min + eps or axis_a_min >= col_max - eps) continue;

            bitmap |= @as(u16, 1) << @intCast(row * 4 + col);
        }
    }

    return bitmap;
}

/// Transform element box coordinates according to a Y-axis rotation/flip.
/// Returns { transformed_from, transformed_to } with from < to guaranteed.
fn transformBox(from: [3]f32, to: [3]f32, transform: Transform) struct { [3]f32, [3]f32 } {
    return switch (transform) {
        .none => .{ from, to },
        .flip_y => .{
            .{ from[0], 1.0 - to[1], from[2] },
            .{ to[0], 1.0 - from[1], to[2] },
        },
        .rotate_90 => .{ // (x,z) → (z, 1-x)
            .{ from[2], from[1], 1.0 - to[0] },
            .{ to[2], to[1], 1.0 - from[0] },
        },
        .rotate_180 => .{ // (x,z) → (1-x, 1-z)
            .{ 1.0 - to[0], from[1], 1.0 - to[2] },
            .{ 1.0 - from[0], to[1], 1.0 - from[2] },
        },
        .rotate_270 => .{ // (x,z) → (1-z, x)
            .{ 1.0 - to[2], from[1], from[0] },
            .{ 1.0 - from[2], to[1], to[0] },
        },
    };
}

fn jsonFloat(val: std.json.Value) f32 {
    return switch (val) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        else => 0,
    };
}

fn resolveTexture(tex_ref: []const u8, textures: std.json.ObjectMap) ?[]const u8 {
    var name = tex_ref;
    if (name.len > 0 and name[0] == '#') {
        const key = name[1..];
        if (textures.get(key)) |val| {
            name = val.string;
        } else return null;
    }
    // Strip path prefix (e.g. "block/torch/torch_fire" → "torch_fire")
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |idx| {
        name = name[idx + 1 ..];
    }
    return name;
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

/// Rotate a point around an axis through origin by angle_rad.
fn rotatePoint(point: [3]f32, origin: [3]f32, axis: u8, sin_a: f32, cos_a: f32) [3]f32 {
    const p = [3]f32{ point[0] - origin[0], point[1] - origin[1], point[2] - origin[2] };
    const r = switch (axis) {
        'x' => [3]f32{ p[0], p[1] * cos_a - p[2] * sin_a, p[1] * sin_a + p[2] * cos_a },
        'y' => [3]f32{ p[0] * cos_a + p[2] * sin_a, p[1], -p[0] * sin_a + p[2] * cos_a },
        'z' => [3]f32{ p[0] * cos_a - p[1] * sin_a, p[0] * sin_a + p[1] * cos_a, p[2] },
        else => p,
    };
    return .{ r[0] + origin[0], r[1] + origin[1], r[2] + origin[2] };
}

/// Rotate a normal vector (no translation) around an axis.
fn rotateNormal(normal: [3]f32, axis: u8, sin_a: f32, cos_a: f32) [3]f32 {
    return switch (axis) {
        'x' => .{ normal[0], normal[1] * cos_a - normal[2] * sin_a, normal[1] * sin_a + normal[2] * cos_a },
        'y' => .{ normal[0] * cos_a + normal[2] * sin_a, normal[1], -normal[0] * sin_a + normal[2] * cos_a },
        'z' => .{ normal[0] * cos_a - normal[1] * sin_a, normal[0] * sin_a + normal[1] * cos_a, normal[2] },
        else => normal,
    };
}

/// Apply Blockbench element rotation (angle around axis through origin).
fn applyElementRotation(model: ExtraQuadModel, rot: ElementRotation) ExtraQuadModel {
    const angle_rad = rot.angle_deg * (std.math.pi / 180.0);
    const sin_a = @sin(angle_rad);
    const cos_a = @cos(angle_rad);

    var result = model;
    for (0..4) |i| {
        result.corners[i] = rotatePoint(model.corners[i], rot.origin, rot.axis, sin_a, cos_a);
    }
    result.normal = rotateNormal(model.normal, rot.axis, sin_a, cos_a);
    return result;
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

// ── Tests ──────────────────────────────────────────────────────────────────

test "elementFaceBitmap: full block face" {
    // Element spanning entire block: [0,0,0]→[1,1,1]
    const from = [3]f32{ 0, 0, 0 };
    const to = [3]f32{ 1, 1, 1 };
    // Every face should have full coverage = 0xFFFF
    for (0..6) |f| {
        try std.testing.expectEqual(@as(u16, 0xFFFF), elementFaceBitmap(from, to, @intCast(f)));
    }
}

test "elementFaceBitmap: bottom slab" {
    // Bottom slab: [0,0,0]→[1,0.5,1]
    const from = [3]f32{ 0, 0, 0 };
    const to = [3]f32{ 1, 0.5, 1 };

    // down (y=0): full XZ coverage → 0xFFFF
    try std.testing.expectEqual(@as(u16, 0xFFFF), elementFaceBitmap(from, to, 5));
    // south (+Z, z=1): bottom 2 rows of XY (y 0→0.5) → rows 0-1 set, rows 2-3 clear
    // Row 0 (y 0..0.25): bits 0-3, Row 1 (y 0.25..0.5): bits 4-7
    try std.testing.expectEqual(@as(u16, 0x00FF), elementFaceBitmap(from, to, 0));
    // north: same pattern
    try std.testing.expectEqual(@as(u16, 0x00FF), elementFaceBitmap(from, to, 1));
    // west: same pattern (col=Z, row=Y)
    try std.testing.expectEqual(@as(u16, 0x00FF), elementFaceBitmap(from, to, 2));
    // east: same pattern
    try std.testing.expectEqual(@as(u16, 0x00FF), elementFaceBitmap(from, to, 3));
    // up (+Y, y=1): element doesn't reach y=1 → 0
    try std.testing.expectEqual(@as(u16, 0), elementFaceBitmap(from, to, 4));
}

test "elementFaceBitmap: stairs upper back" {
    // Upper back of stairs: [0,0.5,0]→[1,1,0.5]
    const from = [3]f32{ 0, 0.5, 0 };
    const to = [3]f32{ 1, 1, 0.5 };

    // north (-Z, z=0): top 2 rows of XY (y 0.5→1) → rows 2-3 set
    try std.testing.expectEqual(@as(u16, 0xFF00), elementFaceBitmap(from, to, 1));
    // up (+Y, y=1): X spans 0→1 (all cols), Z spans 0→0.5 (rows 0-1)
    // Row 0 (z 0..0.25): bits 0-3, Row 1 (z 0.25..0.5): bits 4-7 = 0x00FF
    try std.testing.expectEqual(@as(u16, 0x00FF), elementFaceBitmap(from, to, 4));
    // west (-X, x=0): z 0→0.5 = cols 0-1, y 0.5→1 = rows 2-3
    // Row 2: bits 8,9; Row 3: bits 12,13 = 0x3300
    try std.testing.expectEqual(@as(u16, 0x3300), elementFaceBitmap(from, to, 2));
    // south (+Z): element doesn't reach z=1 → 0
    try std.testing.expectEqual(@as(u16, 0), elementFaceBitmap(from, to, 0));
    // down (-Y): element doesn't reach y=0 → 0
    try std.testing.expectEqual(@as(u16, 0), elementFaceBitmap(from, to, 5));
}

test "elementFaceBitmap: ladder thin panel" {
    // Ladder panel: [0,0,0]→[1,1,1/16]
    const from = [3]f32{ 0, 0, 0 };
    const to = [3]f32{ 1, 1, 1.0 / 16.0 };

    // north (-Z, z=0): full XY → 0xFFFF
    try std.testing.expectEqual(@as(u16, 0xFFFF), elementFaceBitmap(from, to, 1));
    // south (+Z): element doesn't reach z=1 → 0
    try std.testing.expectEqual(@as(u16, 0), elementFaceBitmap(from, to, 0));
}

test "elementFaceBitmap: combined stair bitmaps" {
    // Bottom slab [0,0,0]→[1,0.5,1] + upper back [0,0.5,0]→[1,1,0.5]
    // On north face (-Z): bottom gives 0x00FF, upper back gives 0xFF00 → OR = 0xFFFF
    const bottom = elementFaceBitmap(.{ 0, 0, 0 }, .{ 1, 0.5, 1 }, 1);
    const upper = elementFaceBitmap(.{ 0, 0.5, 0 }, .{ 1, 1, 0.5 }, 1);
    try std.testing.expectEqual(@as(u16, 0xFFFF), bottom | upper);

    // On south face (+Z): bottom gives 0x00FF, upper doesn't reach z=1 → 0x00FF
    const bottom_s = elementFaceBitmap(.{ 0, 0, 0 }, .{ 1, 0.5, 1 }, 0);
    const upper_s = elementFaceBitmap(.{ 0, 0.5, 0 }, .{ 1, 1, 0.5 }, 0);
    try std.testing.expectEqual(@as(u16, 0x00FF), bottom_s | upper_s);

    // On west face (-X): bottom gives 0x00FF (y 0→0.5), upper gives 0x3300 (z 0→0.5, y 0.5→1)
    // OR = 0x33FF
    const bottom_w = elementFaceBitmap(.{ 0, 0, 0 }, .{ 1, 0.5, 1 }, 2);
    const upper_w = elementFaceBitmap(.{ 0, 0.5, 0 }, .{ 1, 1, 0.5 }, 2);
    try std.testing.expectEqual(@as(u16, 0x33FF), bottom_w | upper_w);
}

test "transformBox: identity" {
    const result = transformBox(.{ 0, 0, 0 }, .{ 1, 0.5, 1 }, .none);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), result[1][1], 0.001);
}

test "transformBox: flip_y" {
    // [0,0,0]→[1,0.5,1] flip → [0,0.5,0]→[1,1,1]
    const result = transformBox(.{ 0, 0, 0 }, .{ 1, 0.5, 1 }, .flip_y);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), result[0][1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result[1][1], 0.001);
}

test "transformBox: rotate_90" {
    // [0,0,0]→[1,0.5,0.5] rot90 → (x,z)→(z,1-x) → [0,0,0]→[0.5,0.5,1]
    const result = transformBox(.{ 0, 0, 0 }, .{ 1, 0.5, 0.5 }, .rotate_90);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result[0][0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), result[1][0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result[0][2], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result[1][2], 0.001);
}

test "transformBucket: identity" {
    for (0..6) |f| {
        try std.testing.expectEqual(@as(u3, @intCast(f)), transformBucket(@intCast(f), .none));
    }
}

test "transformBucket: flip_y swaps up/down" {
    try std.testing.expectEqual(@as(u3, 5), transformBucket(4, .flip_y)); // up → down
    try std.testing.expectEqual(@as(u3, 4), transformBucket(5, .flip_y)); // down → up
    try std.testing.expectEqual(@as(u3, 0), transformBucket(0, .flip_y)); // south unchanged
    try std.testing.expectEqual(@as(u3, 1), transformBucket(1, .flip_y)); // north unchanged
}

test "transformBucket: rotate_90 CW" {
    try std.testing.expectEqual(@as(u3, 3), transformBucket(0, .rotate_90)); // south → east
    try std.testing.expectEqual(@as(u3, 2), transformBucket(1, .rotate_90)); // north → west
    try std.testing.expectEqual(@as(u3, 0), transformBucket(2, .rotate_90)); // west → south
    try std.testing.expectEqual(@as(u3, 1), transformBucket(3, .rotate_90)); // east → north
    try std.testing.expectEqual(@as(u3, 4), transformBucket(4, .rotate_90)); // up unchanged
    try std.testing.expectEqual(@as(u3, 5), transformBucket(5, .rotate_90)); // down unchanged
}

test "transformBucket: rotate_180" {
    try std.testing.expectEqual(@as(u3, 1), transformBucket(0, .rotate_180)); // south → north
    try std.testing.expectEqual(@as(u3, 0), transformBucket(1, .rotate_180)); // north → south
    try std.testing.expectEqual(@as(u3, 3), transformBucket(2, .rotate_180)); // west → east
    try std.testing.expectEqual(@as(u3, 2), transformBucket(3, .rotate_180)); // east → west
}

test "transformBucket: full rotation cycle" {
    // Rotating 4 times by 90° should return to original
    var b: u3 = 0; // south
    b = transformBucket(b, .rotate_90); // → east
    b = transformBucket(b, .rotate_90); // → north
    b = transformBucket(b, .rotate_90); // → west
    b = transformBucket(b, .rotate_90); // → south
    try std.testing.expectEqual(@as(u3, 0), b);
}

test "buildBoxFaceQuad: south face corners" {
    const from = [3]f32{ 0, 0, 0 };
    const to = [3]f32{ 1, 0.5, 1 };
    const uv = [4]f32{ 0, 0.5, 1, 1 };
    const q = buildBoxFaceQuad(from, to, 0, uv); // south (+Z)

    // South face at z=to[2]=1, corners CCW from bottom-left
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), q.corners[0][2], 0.001); // z = 1
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), q.corners[0][1], 0.001); // y = 0 (bottom)
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), q.corners[2][1], 0.001); // y = 0.5 (top)
    // Normal should be +Z
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), q.normal[2], 0.001);
}

test "buildBoxFaceQuad: up face corners" {
    const from = [3]f32{ 0, 0, 0 };
    const to = [3]f32{ 1, 1, 1 };
    const uv = [4]f32{ 0, 0, 1, 1 };
    const q = buildBoxFaceQuad(from, to, 4, uv); // up (+Y)

    // All 4 corners should be at y=1
    for (0..4) |i| {
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), q.corners[i][1], 0.001);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), q.normal[1], 0.001);
}

test "applyTransform: flip_y inverts Y coordinates" {
    const model = ExtraQuadModel{
        .corners = .{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 0.5, 0 }, .{ 0, 0.5, 0 } },
        .uvs = .{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0.5 }, .{ 0, 0.5 } },
        .normal = .{ 0, 0, -1 },
    };
    const flipped = applyTransform(model, .flip_y, 1);

    // Y coords should be 1-original, winding reversed
    // Original: 0, 0, 0.5, 0.5 → Flipped: 1, 1, 0.5, 0.5 → Reversed: 0.5, 0.5, 1, 1
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), flipped.corners[0][1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), flipped.corners[2][1], 0.001);
    // Normal Z should be unchanged (flip_y only affects Y)
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), flipped.normal[2], 0.001);
}

test "applyTransform: rotate_90 swaps X and Z" {
    const model = ExtraQuadModel{
        .corners = .{ .{ 0, 0, 1 }, .{ 1, 0, 1 }, .{ 1, 0.5, 1 }, .{ 0, 0.5, 1 } },
        .uvs = .{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0.5 }, .{ 0, 0.5 } },
        .normal = .{ 0, 0, 1 }, // +Z
    };
    const rotated = applyTransform(model, .rotate_90, 0);

    // 90° CW: (x,z) → (z, 1-x)
    // Corner 0: (0,0,1) → (1,0,1)
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), rotated.corners[0][0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), rotated.corners[0][2], 0.001);
    // Corner 1: (1,0,1) → (1,0,0)
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), rotated.corners[1][0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), rotated.corners[1][2], 0.001);
    // Normal: (0,0,1) → (1,0,0)
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), rotated.normal[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), rotated.normal[2], 0.001);
}
