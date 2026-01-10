/// BlockstateLoader - Loads and caches blockstate definitions from JSON files
/// Loads blockstates from assets/namespace/blockstates/*.json
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const shared = @import("Shared");
const Logger = shared.Logger;
const BlockstateDefinition = @import("Blockstate.zig").BlockstateDefinition;
const ModelVariant = @import("Blockstate.zig").ModelVariant;

pub const BlockstateLoader = struct {
    const Self = @This();
    const logger = Logger.scoped(Self);

    allocator: Allocator,
    io: Io,
    assets_path: []const u8,
    /// Cache of loaded blockstate definitions: block name -> BlockstateDefinition
    cache: std.StringHashMap(BlockstateDefinition),

    pub fn init(allocator: Allocator, io: Io, assets_path: []const u8) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .assets_path = assets_path,
            .cache = std.StringHashMap(BlockstateDefinition).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var def = entry.value_ptr.*;
            def.deinit();
        }
        self.cache.deinit();
    }

    /// Load blockstate definition for a block name (e.g., "oak_slab")
    /// Returns cached definition if already loaded
    pub fn loadBlockstate(self: *Self, block_name: []const u8) !*const BlockstateDefinition {
        // Check cache first
        if (self.cache.getPtr(block_name)) |cached| {
            return cached;
        }

        // Build file path: assets/farhorizons/blockstates/{name}.json
        const file_path = try self.blockNameToPath(block_name);
        defer self.allocator.free(file_path);

        logger.info("Loading blockstate: {s}", .{block_name});
        logger.info("Reading blockstate file: {s}", .{file_path});

        // Read file
        const json_data = Dir.cwd().readFileAlloc(self.io, file_path, self.allocator, .limited(1024 * 64)) catch |err| {
            logger.err("Failed to read blockstate file: {s} - {any}", .{ file_path, err });
            return error.BlockstateFileNotFound;
        };
        defer self.allocator.free(json_data);

        // Parse JSON
        const definition = BlockstateDefinition.parseFromJson(self.allocator, json_data) catch |err| {
            logger.err("Failed to parse blockstate JSON: {s} - {}", .{ file_path, err });
            return error.BlockstateParseError;
        };

        // Cache it
        const cached_name = try self.allocator.dupe(u8, block_name);
        errdefer self.allocator.free(cached_name);

        try self.cache.put(cached_name, definition);

        return self.cache.getPtr(cached_name).?;
    }

    /// Get variant for a block name and state key
    /// Loads blockstate if not cached
    pub fn getVariant(self: *Self, block_name: []const u8, state_key: []const u8) !?ModelVariant {
        const definition = try self.loadBlockstate(block_name);
        return definition.getVariant(state_key);
    }

    /// Convert block name to file path
    /// "oak_slab" -> "assets/farhorizons/blockstates/oak_slab.json"
    fn blockNameToPath(self: *Self, block_name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(
            self.allocator,
            "{s}/farhorizons/blockstates/{s}.json",
            .{ self.assets_path, block_name },
        );
    }

    /// Check if a blockstate file exists for the given block name
    pub fn hasBlockstate(self: *Self, block_name: []const u8) bool {
        const file_path = self.blockNameToPath(block_name) catch return false;
        defer self.allocator.free(file_path);

        const file = Dir.cwd().openFile(self.io, file_path, .{}) catch return false;
        file.close(self.io);
        return true;
    }
};
