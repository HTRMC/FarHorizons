/// BlockModelShaper - Central model resolution system
/// Connects block entries to their resolved models via blockstate definitions
const std = @import("std");
const Allocator = std.mem.Allocator;
const shared = @import("Shared");
const Logger = shared.Logger;
const BlockEntry = shared.BlockEntry;
const BlockState = shared.BlockState;
const blocks = shared.block;

const ModelLoader = @import("model/ModelLoader.zig").ModelLoader;
const BlockModel = @import("model/BlockModel.zig").BlockModel;
const BlockstateLoader = @import("BlockstateLoader.zig").BlockstateLoader;
const BlockstateDefinition = @import("Blockstate.zig").BlockstateDefinition;
const ModelVariant = @import("Blockstate.zig").ModelVariant;
const StateMapper = @import("StateMapper.zig").StateMapper;
const TextureManager = @import("../TextureManager.zig").TextureManager;

pub const BlockModelShaper = struct {
    const Self = @This();
    const logger = Logger.scoped(Self);

    allocator: Allocator,
    model_loader: *ModelLoader,
    blockstate_loader: *BlockstateLoader,
    texture_manager: *const TextureManager,

    /// Cache key: (block_id << 8) | state
    /// This gives unique keys for each block+state combination
    model_cache: std.AutoHashMap(u16, CachedModel),

    const CachedModel = struct {
        model: BlockModel,
        variant: ModelVariant,
    };

    pub fn init(
        allocator: Allocator,
        model_loader: *ModelLoader,
        blockstate_loader: *BlockstateLoader,
        texture_manager: *const TextureManager,
    ) Self {
        return .{
            .allocator = allocator,
            .model_loader = model_loader,
            .blockstate_loader = blockstate_loader,
            .texture_manager = texture_manager,
            .model_cache = std.AutoHashMap(u16, CachedModel).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.model_cache.iterator();
        while (it.next()) |entry| {
            var cached = entry.value_ptr.*;
            cached.model.deinit();
            self.allocator.free(cached.variant.model);
        }
        self.model_cache.deinit();
    }

    /// Get the resolved and cached model for a BlockEntry
    /// This is the main entry point for mesh generation
    pub fn getModel(self: *Self, entry: BlockEntry) !*const BlockModel {
        const cache_key = makeCacheKey(entry);

        // Check cache
        if (self.model_cache.getPtr(cache_key)) |cached| {
            return &cached.model;
        }

        // Resolve and cache
        const cached = try self.resolveAndCache(entry, cache_key);
        return &cached.model;
    }

    /// Get the variant info (for rotation) for a BlockEntry
    pub fn getVariant(self: *Self, entry: BlockEntry) !ModelVariant {
        const cache_key = makeCacheKey(entry);

        // Check cache
        if (self.model_cache.get(cache_key)) |cached| {
            return cached.variant;
        }

        // Resolve and cache
        const cached = try self.resolveAndCache(entry, cache_key);
        return cached.variant;
    }

    /// Resolve a BlockEntry to its model and variant, then cache it
    fn resolveAndCache(self: *Self, entry: BlockEntry, cache_key: u16) !*CachedModel {
        // Get block name from ID
        const block_name = blocks.getBlockName(entry.id);

        // Get variant key from state
        const variant_key = StateMapper.toVariantKey(block_name, entry.state);

        logger.info("Resolving model for {s} with state key '{s}'", .{ block_name, variant_key });

        // Load blockstate definition
        const blockstate_def = self.blockstate_loader.loadBlockstate(block_name) catch |err| {
            logger.warn("No blockstate file for {s}, using default model: {}", .{ block_name, err });
            // Fall back to default model path
            return self.cacheDefaultModel(entry, cache_key, block_name);
        };

        // Get variant from blockstate
        const variant = blockstate_def.getVariant(variant_key) orelse
            blockstate_def.getDefaultVariant() orelse {
            logger.warn("No variant '{s}' in blockstate for {s}, using default", .{ variant_key, block_name });
            return self.cacheDefaultModel(entry, cache_key, block_name);
        };

        // Load the model
        var model = self.model_loader.loadModel(variant.model) catch |err| {
            logger.err("Failed to load model {s}: {}", .{ variant.model, err });
            return error.ModelLoadFailed;
        };

        // Resolve textures
        self.model_loader.resolveTextures(&model) catch |err| {
            logger.err("Failed to resolve textures for {s}: {}", .{ variant.model, err });
            model.deinit();
            return error.TextureResolveFailed;
        };

        // Copy variant model string since blockstate may be freed
        const variant_model_copy = try self.allocator.dupe(u8, variant.model);

        // Cache
        const cached = CachedModel{
            .model = model,
            .variant = .{
                .model = variant_model_copy,
                .x = variant.x,
                .y = variant.y,
                .uvlock = variant.uvlock,
                .weight = variant.weight,
            },
        };

        try self.model_cache.put(cache_key, cached);
        return self.model_cache.getPtr(cache_key).?;
    }

    /// Cache a default model when blockstate is not found
    fn cacheDefaultModel(self: *Self, _: BlockEntry, cache_key: u16, block_name: []const u8) !*CachedModel {
        // Construct default model path: farhorizons:block/{name}
        const model_id = try std.fmt.allocPrint(self.allocator, "farhorizons:block/{s}", .{block_name});
        defer self.allocator.free(model_id);

        var model = self.model_loader.loadModel(model_id) catch |err| {
            logger.err("Failed to load default model {s}: {}", .{ model_id, err });
            return error.ModelLoadFailed;
        };

        self.model_loader.resolveTextures(&model) catch |err| {
            logger.err("Failed to resolve textures for {s}: {}", .{ model_id, err });
            model.deinit();
            return error.TextureResolveFailed;
        };

        const variant_model_copy = try self.allocator.dupe(u8, model_id);

        const cached = CachedModel{
            .model = model,
            .variant = .{
                .model = variant_model_copy,
                .x = 0,
                .y = 0,
                .uvlock = false,
                .weight = 1,
            },
        };

        try self.model_cache.put(cache_key, cached);
        return self.model_cache.getPtr(cache_key).?;
    }

    /// Create cache key from BlockEntry
    /// Combines block ID and packed state into a single u16
    fn makeCacheKey(entry: BlockEntry) u16 {
        // BlockEntry is already packed as u16 (id: u8, state: u8)
        return @bitCast(entry);
    }

    /// Pre-bake models for common block states
    /// Call this at startup to warm the cache
    pub fn prebakeCommonModels(self: *Self) !void {
        logger.info("Pre-baking common block models...", .{});

        // Stone (simple block)
        _ = try self.getModel(BlockEntry.simple(1));

        // Oak slab variants
        _ = try self.getModel(BlockEntry.slab(2, .bottom));
        _ = try self.getModel(BlockEntry.slab(2, .top));
        _ = try self.getModel(BlockEntry.slab(2, .double));

        // Oak planks
        _ = try self.getModel(BlockEntry.simple(6));

        logger.info("Pre-baked {} models", .{self.model_cache.count()});
    }
};
