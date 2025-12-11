const std = @import("std");
const shared = @import("Shared");
const Allocator = std.mem.Allocator;
const BlockModel = @import("BlockModel.zig").BlockModel;
const BlockElement = @import("BlockElement.zig").BlockElement;
const Logger = shared.Logger;

/// Loads and resolves Minecraft block models with parent inheritance
/// Matches the functionality of net/minecraft/client/resources/model/ModelBakery.java
pub const ModelLoader = struct {
    const Self = @This();
    const logger = Logger.init("ModelLoader");

    allocator: Allocator,
    assets_path: []const u8,
    model_cache: std.StringHashMap(BlockModel),

    pub fn init(allocator: Allocator, assets_path: []const u8) Self {
        return .{
            .allocator = allocator,
            .assets_path = assets_path,
            .model_cache = std.StringHashMap(BlockModel).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.model_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var model = entry.value_ptr.*;
            model.deinit();
        }
        self.model_cache.deinit();
    }

    /// Load a model and resolve all parents, returning a fully resolved model
    /// Model ID format: "farhorizons:block/oak_slab" or "block/oak_slab"
    pub fn loadModel(self: *Self, model_id: []const u8) !BlockModel {
        logger.info("Loading model: {s}", .{model_id});

        // Load the model chain (child -> parent -> grandparent -> ...)
        var model_chain: std.ArrayList(BlockModel) = .empty;
        defer {
            // Don't deinit the models here, they'll be merged
            model_chain.deinit(self.allocator);
        }

        var current_id: ?[]const u8 = model_id;
        var depth: usize = 0;
        const max_depth = 32; // Prevent infinite loops

        while (current_id) |id| {
            if (depth >= max_depth) {
                logger.err("Model parent chain too deep (>{d}): {s}", .{ max_depth, model_id });
                return error.ModelParentChainTooDeep;
            }

            const model = try self.loadSingleModel(id);
            try model_chain.append(self.allocator, model);

            current_id = model.parent;
            depth += 1;
        }

        logger.info("Loaded {d} models in chain for {s}", .{ model_chain.items.len, model_id });

        // Merge models from parent to child (reverse order)
        return self.mergeModelChain(model_chain.items);
    }

    /// Load a single model file without resolving parents
    fn loadSingleModel(self: *Self, model_id: []const u8) !BlockModel {
        // Check cache first
        if (self.model_cache.get(model_id)) |cached| {
            return cached;
        }

        // Build file path from model ID
        const file_path = try self.modelIdToPath(model_id);
        defer self.allocator.free(file_path);

        logger.info("Reading model file: {s}", .{file_path});

        // Read the file
        const json_data = std.fs.cwd().readFileAlloc(file_path, self.allocator, .limited(1024 * 1024)) catch |err| {
            logger.err("Failed to read model file: {s} - {any}", .{ file_path, err });
            return error.ModelFileNotFound;
        };
        defer self.allocator.free(json_data);

        // Parse the model
        const model = try BlockModel.parseFromJson(self.allocator, json_data);

        // Cache it
        const cached_id = try self.allocator.dupe(u8, model_id);
        try self.model_cache.put(cached_id, model);

        return model;
    }

    /// Convert a model ID like "farhorizons:block/oak_slab" to a file path
    fn modelIdToPath(self: *Self, model_id: []const u8) ![]const u8 {
        var namespace: []const u8 = "farhorizons";
        var path: []const u8 = model_id;

        // Check for namespace prefix
        if (std.mem.indexOf(u8, model_id, ":")) |colon_idx| {
            namespace = model_id[0..colon_idx];
            path = model_id[colon_idx + 1 ..];
        }

        // Build full path: <assets_path>/<namespace>/models/<path>.json
        // assets_path already points to the assets folder (e.g., "./assets")
        return std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/models/{s}.json",
            .{ self.assets_path, namespace, path },
        );
    }

    /// Merge a chain of models, with child overriding parent
    fn mergeModelChain(self: *Self, chain: []BlockModel) !BlockModel {
        if (chain.len == 0) {
            return error.EmptyModelChain;
        }

        // Start with a new model
        var result = BlockModel.init(self.allocator);
        errdefer result.deinit();

        // Merge from parent (last) to child (first)
        var i: usize = chain.len;
        while (i > 0) {
            i -= 1;
            const model = &chain[i];

            // Merge textures (child overrides parent)
            var tex_it = model.textures.iterator();
            while (tex_it.next()) |entry| {
                // Remove old value if exists
                if (result.textures.fetchRemove(entry.key_ptr.*)) |old| {
                    self.allocator.free(old.key);
                    self.allocator.free(old.value);
                }

                const key = try self.allocator.dupe(u8, entry.key_ptr.*);
                errdefer self.allocator.free(key);
                const value = try self.allocator.dupe(u8, entry.value_ptr.*);
                try result.textures.put(key, value);
            }

            // Elements: child overrides parent (first non-null wins going from child to parent)
            if (result.elements == null and model.elements != null) {
                // Deep copy elements
                const elements = try self.allocator.alloc(BlockElement, model.elements.?.len);
                for (model.elements.?, 0..) |*src_elem, idx| {
                    elements[idx] = try copyElement(self.allocator, src_elem);
                }
                result.elements = elements;
            }

            // Ambient occlusion: first non-null wins
            if (result.ambient_occlusion == null and model.ambient_occlusion != null) {
                result.ambient_occlusion = model.ambient_occlusion;
            }

            // GUI light: first non-null wins
            if (result.gui_light == null and model.gui_light != null) {
                result.gui_light = try self.allocator.dupe(u8, model.gui_light.?);
            }
        }

        return result;
    }

    fn copyElement(allocator: Allocator, src: *const BlockElement) !BlockElement {
        const Direction = @import("BlockElement.zig").Direction;

        var elem = BlockElement.init(allocator);
        elem.from = src.from;
        elem.to = src.to;
        elem.shade = src.shade;
        elem.light_emission = src.light_emission;
        elem.rotation = src.rotation;

        // Copy faces - iterate over all directions and check which exist
        inline for (std.meta.fields(Direction)) |field| {
            const dir: Direction = @enumFromInt(field.value);
            if (src.faces.get(dir)) |src_face| {
                var face = src_face;
                face.texture = try allocator.dupe(u8, src_face.texture);
                elem.faces.put(dir, face);
            }
        }

        return elem;
    }

    /// Resolve all texture references in a model (replace #name with actual paths)
    pub fn resolveTextures(self: *Self, model: *BlockModel) !void {
        _ = self;
        const Direction = @import("BlockElement.zig").Direction;

        if (model.elements) |elements| {
            for (elements) |*elem| {
                // Iterate over all directions and resolve textures
                inline for (std.meta.fields(Direction)) |field| {
                    const dir: Direction = @enumFromInt(field.value);
                    if (elem.faces.get(dir)) |face| {
                        if (model.resolveTexture(face.texture)) |resolved| {
                            if (!std.mem.eql(u8, resolved, face.texture)) {
                                const old_tex = face.texture;
                                var new_face = face;
                                new_face.texture = try model.allocator.dupe(u8, resolved);
                                model.allocator.free(old_tex);
                                elem.faces.put(dir, new_face);
                            }
                        }
                    }
                }
            }
        }
    }
};
