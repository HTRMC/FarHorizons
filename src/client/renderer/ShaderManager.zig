const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const shared = @import("Shared");
const ShaderCompiler = @import("ShaderCompiler.zig").ShaderCompiler;
const ShaderKind = @import("ShaderCompiler.zig").ShaderKind;
const CompiledShader = @import("ShaderCompiler.zig").CompiledShader;

const Logger = shared.Logger;

/// Manages runtime-compiled shaders loaded from assets
pub const ShaderManager = struct {
    const Self = @This();
    const logger = Logger.scoped(Self);

    allocator: std.mem.Allocator,
    io: Io,
    compiler: ?ShaderCompiler,
    /// Cache of runtime-compiled shaders
    shader_cache: std.StringHashMap(CachedShader),
    /// Active shader pack path (null = use defaults)
    active_pack: ?[]const u8,
    /// Cached default shaders (compiled at startup)
    default_vert_spv: ?[]u8,
    default_frag_spv: ?[]u8,
    /// Layer-specific fragment shaders
    solid_frag_spv: ?[]u8,
    cutout_frag_spv: ?[]u8,
    translucent_frag_spv: ?[]u8,
    /// Cached UI shaders
    ui_vert_spv: ?[]u8,
    ui_frag_spv: ?[]u8,
    /// Cached line shaders (for block outline)
    line_vert_spv: ?[]u8,
    line_frag_spv: ?[]u8,
    /// Cached entity shaders
    entity_vert_spv: ?[]u8,
    entity_frag_spv: ?[]u8,

    /// Base path for default shaders
    const default_shader_path = "assets/farhorizons/shaders/";
    const default_include_path = "assets/farhorizons/shaders/include/";

    const CachedShader = struct {
        data: []const u8,
        kind: ShaderKind,
    };

    /// Initialize shader manager
    /// Set enable_runtime_compilation to true to allow loading player shader packs
    pub fn init(allocator: std.mem.Allocator, io: Io, enable_runtime_compilation: bool) !ShaderManager {
        var compiler: ?ShaderCompiler = null;
        var default_vert: ?[]u8 = null;
        var default_frag: ?[]u8 = null;
        var solid_frag: ?[]u8 = null;
        var cutout_frag: ?[]u8 = null;
        var translucent_frag: ?[]u8 = null;
        var ui_vert: ?[]u8 = null;
        var ui_frag: ?[]u8 = null;
        var line_vert: ?[]u8 = null;
        var line_frag: ?[]u8 = null;
        var entity_vert: ?[]u8 = null;
        var entity_frag: ?[]u8 = null;

        if (enable_runtime_compilation) {
            var total_timer = std.time.Timer.start() catch unreachable;

            compiler = try ShaderCompiler.init(allocator, io);

            // Register default namespace for built-in includes
            try compiler.?.registerNamespace("farhorizons", default_include_path);

            // Compile default shaders at startup from assets directory
            logger.info("Compiling default vertex shader...", .{});
            var vert_timer = std.time.Timer.start() catch unreachable;
            var vert_compiled = try compiler.?.compileFile(default_shader_path ++ "triangle.vert");
            const vert_time_us = vert_timer.read() / std.time.ns_per_us;
            default_vert = try allocator.dupe(u8, vert_compiled.spv_data);
            vert_compiled.deinit();
            logger.info("Vertex shader compiled in {d}us ({d} bytes SPIR-V)", .{ vert_time_us, default_vert.?.len });

            logger.info("Compiling default fragment shader...", .{});
            var frag_timer = std.time.Timer.start() catch unreachable;
            var frag_compiled = try compiler.?.compileFile(default_shader_path ++ "triangle.frag");
            const frag_time_us = frag_timer.read() / std.time.ns_per_us;
            default_frag = try allocator.dupe(u8, frag_compiled.spv_data);
            frag_compiled.deinit();
            logger.info("Fragment shader compiled in {d}us ({d} bytes SPIR-V)", .{ frag_time_us, default_frag.?.len });

            // Compile layer-specific fragment shaders
            logger.info("Compiling layer-specific fragment shaders...", .{});
            var solid_compiled = try compiler.?.compileFile(default_shader_path ++ "triangle_solid.frag");
            solid_frag = try allocator.dupe(u8, solid_compiled.spv_data);
            solid_compiled.deinit();

            var cutout_compiled = try compiler.?.compileFile(default_shader_path ++ "triangle_cutout.frag");
            cutout_frag = try allocator.dupe(u8, cutout_compiled.spv_data);
            cutout_compiled.deinit();

            var translucent_compiled = try compiler.?.compileFile(default_shader_path ++ "triangle_translucent.frag");
            translucent_frag = try allocator.dupe(u8, translucent_compiled.spv_data);
            translucent_compiled.deinit();
            logger.info("Layer shaders compiled (solid: {d}, cutout: {d}, translucent: {d} bytes)", .{
                solid_frag.?.len,
                cutout_frag.?.len,
                translucent_frag.?.len,
            });

            // Compile UI shaders
            logger.info("Compiling UI shaders...", .{});
            var ui_vert_compiled = try compiler.?.compileFile(default_shader_path ++ "ui.vert");
            ui_vert = try allocator.dupe(u8, ui_vert_compiled.spv_data);
            ui_vert_compiled.deinit();

            var ui_frag_compiled = try compiler.?.compileFile(default_shader_path ++ "ui.frag");
            ui_frag = try allocator.dupe(u8, ui_frag_compiled.spv_data);
            ui_frag_compiled.deinit();
            logger.info("UI shaders compiled", .{});

            // Compile line shaders (for block outline)
            logger.info("Compiling line shaders...", .{});
            var line_vert_compiled = try compiler.?.compileFile(default_shader_path ++ "line.vert");
            line_vert = try allocator.dupe(u8, line_vert_compiled.spv_data);
            line_vert_compiled.deinit();

            var line_frag_compiled = try compiler.?.compileFile(default_shader_path ++ "line.frag");
            line_frag = try allocator.dupe(u8, line_frag_compiled.spv_data);
            line_frag_compiled.deinit();
            logger.info("Line shaders compiled", .{});

            // Compile entity shaders
            logger.info("Compiling entity shaders...", .{});
            var entity_vert_compiled = try compiler.?.compileFile(default_shader_path ++ "entity.vert");
            entity_vert = try allocator.dupe(u8, entity_vert_compiled.spv_data);
            entity_vert_compiled.deinit();

            var entity_frag_compiled = try compiler.?.compileFile(default_shader_path ++ "entity.frag");
            entity_frag = try allocator.dupe(u8, entity_frag_compiled.spv_data);
            entity_frag_compiled.deinit();
            logger.info("Entity shaders compiled", .{});

            const total_time_ms = @as(f64, @floatFromInt(total_timer.read())) / @as(f64, std.time.ns_per_ms);
            const cache_stats = compiler.?.getCacheStats();
            logger.info("Shader loading complete in {d:.2}ms (cache: {d} hits, {d} misses)", .{
                total_time_ms,
                cache_stats.hits,
                cache_stats.misses,
            });
        }

        return .{
            .allocator = allocator,
            .io = io,
            .compiler = compiler,
            .shader_cache = std.StringHashMap(CachedShader).init(allocator),
            .active_pack = null,
            .default_vert_spv = default_vert,
            .default_frag_spv = default_frag,
            .solid_frag_spv = solid_frag,
            .cutout_frag_spv = cutout_frag,
            .translucent_frag_spv = translucent_frag,
            .ui_vert_spv = ui_vert,
            .ui_frag_spv = ui_frag,
            .line_vert_spv = line_vert,
            .line_frag_spv = line_frag,
            .entity_vert_spv = entity_vert,
            .entity_frag_spv = entity_frag,
        };
    }

    pub fn deinit(self: *ShaderManager) void {
        var iter = self.shader_cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.data);
        }
        self.shader_cache.deinit();

        if (self.active_pack) |pack| {
            self.allocator.free(pack);
        }

        // Free compiled default shaders
        if (self.default_vert_spv) |spv| {
            self.allocator.free(spv);
        }
        if (self.default_frag_spv) |spv| {
            self.allocator.free(spv);
        }
        // Free layer-specific fragment shaders
        if (self.solid_frag_spv) |spv| {
            self.allocator.free(spv);
        }
        if (self.cutout_frag_spv) |spv| {
            self.allocator.free(spv);
        }
        if (self.translucent_frag_spv) |spv| {
            self.allocator.free(spv);
        }
        if (self.ui_vert_spv) |spv| {
            self.allocator.free(spv);
        }
        if (self.ui_frag_spv) |spv| {
            self.allocator.free(spv);
        }
        if (self.line_vert_spv) |spv| {
            self.allocator.free(spv);
        }
        if (self.line_frag_spv) |spv| {
            self.allocator.free(spv);
        }
        if (self.entity_vert_spv) |spv| {
            self.allocator.free(spv);
        }
        if (self.entity_frag_spv) |spv| {
            self.allocator.free(spv);
        }

        if (self.compiler) |*c| {
            c.deinit();
        }
    }

    /// Get the default vertex shader (compiled at runtime)
    pub fn getDefaultVertexShader(self: *ShaderManager) ?[]const u8 {
        return self.default_vert_spv;
    }

    /// Get the default fragment shader (compiled at runtime)
    pub fn getDefaultFragmentShader(self: *ShaderManager) ?[]const u8 {
        return self.default_frag_spv;
    }

    /// Get the solid layer fragment shader (no discard, max early-z performance)
    pub fn getSolidFragmentShader(self: *ShaderManager) ?[]const u8 {
        return self.solid_frag_spv;
    }

    /// Get the cutout layer fragment shader (alpha discard for leaves, etc.)
    pub fn getCutoutFragmentShader(self: *ShaderManager) ?[]const u8 {
        return self.cutout_frag_spv;
    }

    /// Get the translucent layer fragment shader (alpha blending)
    pub fn getTranslucentFragmentShader(self: *ShaderManager) ?[]const u8 {
        return self.translucent_frag_spv;
    }

    /// Get the UI vertex shader (compiled at runtime)
    pub fn getUIVertexShader(self: *ShaderManager) ?[]const u8 {
        return self.ui_vert_spv;
    }

    /// Get the UI fragment shader (compiled at runtime)
    pub fn getUIFragmentShader(self: *ShaderManager) ?[]const u8 {
        return self.ui_frag_spv;
    }

    /// Get the line vertex shader (compiled at runtime)
    pub fn getLineVertexShader(self: *ShaderManager) ?[]const u8 {
        return self.line_vert_spv;
    }

    /// Get the line fragment shader (compiled at runtime)
    pub fn getLineFragmentShader(self: *ShaderManager) ?[]const u8 {
        return self.line_frag_spv;
    }

    pub fn getEntityVertSpv(self: *const ShaderManager) ?[]const u8 {
        return self.entity_vert_spv;
    }

    pub fn getEntityFragSpv(self: *const ShaderManager) ?[]const u8 {
        return self.entity_frag_spv;
    }

    /// Load a shader pack from a directory
    /// Shader pack structure:
    ///   pack_path/
    ///     shaders/
    ///       include/     (optional custom includes)
    ///       terrain.vert
    ///       terrain.frag
    ///       ...
    ///     pack.json     (optional metadata)
    pub fn loadShaderPack(self: *ShaderManager, pack_path: []const u8) !void {
        if (self.compiler == null) {
            logger.err("Runtime shader compilation is disabled", .{});
            return error.RuntimeCompilationDisabled;
        }

        logger.info("Loading shader pack from: {s}", .{pack_path});
        // Clear existing cache
        self.clearCache();

        // Store active pack path
        if (self.active_pack) |old| {
            self.allocator.free(old);
        }
        self.active_pack = try self.allocator.dupe(u8, pack_path);

        const include_path = try Dir.path.join(self.allocator, &.{ pack_path, "shaders", "include" });
        defer self.allocator.free(include_path);

        if (Dir.cwd().openDir(self.io, include_path, .{})) |dir| {
            dir.close(self.io);
            try self.compiler.?.registerNamespace("pack", include_path);
            logger.info("Registered pack include path: {s}", .{include_path});
        } else |_| {
            logger.info("No custom include directory in shader pack", .{});
        }
    }

    /// Get a shader by name, compiling if necessary
    /// Returns SPIR-V bytes
    pub fn getShader(self: *ShaderManager, name: []const u8, kind: ShaderKind) ![]const u8 {
        if (self.shader_cache.get(name)) |cached| {
            return cached.data;
        }

        if (self.active_pack == null) {
            return switch (kind) {
                .vertex => self.getDefaultVertexShader(),
                .fragment => self.getDefaultFragmentShader(),
                else => error.NoShaderAvailable,
            };
        }

        if (self.compiler) |*compiler| {
            const ext = switch (kind) {
                .vertex => ".vert",
                .fragment => ".frag",
                .compute => ".comp",
                .geometry => ".geom",
                .tess_control => ".tesc",
                .tess_evaluation => ".tese",
            };

            const shader_path = try Dir.path.join(self.allocator, &.{
                self.active_pack.?,
                "shaders",
                try std.mem.concat(self.allocator, u8, &.{ name, ext }),
            });
            defer self.allocator.free(shader_path);

            var compiled = try compiler.compileFile(shader_path);
            defer compiled.deinit();

            const key = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(key);
            const data = try self.allocator.dupe(u8, compiled.spv_data);

            try self.shader_cache.put(key, .{ .data = data, .kind = kind });

            return data;
        }

        return error.RuntimeCompilationDisabled;
    }

    /// Compile a shader from source string (for hot-reloading or testing)
    pub fn compileSource(
        self: *ShaderManager,
        source: []const u8,
        kind: ShaderKind,
        name: []const u8,
    ) !CompiledShader {
        if (self.compiler) |*compiler| {
            return compiler.compile(source, kind, name);
        }
        return error.RuntimeCompilationDisabled;
    }

    /// Compile a shader file directly (for compute shaders, etc.)
    /// Returns owned SPIR-V data that must be freed by the caller
    pub fn compileShaderFile(self: *ShaderManager, path: []const u8) ![]u8 {
        if (self.compiler) |*compiler| {
            var compiled = try compiler.compileFile(path);
            defer compiled.deinit();
            return try self.allocator.dupe(u8, compiled.spv_data);
        }
        return error.RuntimeCompilationDisabled;
    }

    /// Clear the shader cache (call before reloading a pack)
    pub fn clearCache(self: *ShaderManager) void {
        var iter = self.shader_cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.data);
        }
        self.shader_cache.clearRetainingCapacity();
    }

    /// Unload the current shader pack and return to defaults
    pub fn unloadShaderPack(self: *ShaderManager) void {
        self.clearCache();
        if (self.active_pack) |pack| {
            self.allocator.free(pack);
            self.active_pack = null;
        }
        logger.info("Shader pack unloaded, using default shaders", .{});
    }

    /// Check if runtime compilation is enabled
    pub fn isRuntimeCompilationEnabled(self: *ShaderManager) bool {
        return self.compiler != null;
    }

    /// Check if a shader pack is currently loaded
    pub fn hasActiveShaderPack(self: *ShaderManager) bool {
        return self.active_pack != null;
    }
};
