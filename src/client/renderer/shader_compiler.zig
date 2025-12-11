const std = @import("std");
const shaderc = @import("shaderc");
const ShaderPreprocessor = @import("GlslPreprocessor.zig").ShaderPreprocessor;
const ShaderCache = @import("shader_cache.zig").ShaderCache;

const log = std.log.scoped(.shader_compiler);

/// Shader compiler that handles preprocessing (#fh_import) and GLSL->SPIR-V compilation
/// Includes disk-based caching to avoid recompiling unchanged shaders.
pub const ShaderCompiler = struct {
    allocator: std.mem.Allocator,
    preprocessor: ShaderPreprocessor,
    compiler: shaderc.Compiler,
    default_options: ?shaderc.CompileOptions,
    cache: ShaderCache,

    // Stats for profiling
    cache_hits: u32 = 0,
    cache_misses: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) !ShaderCompiler {
        var preprocessor = ShaderPreprocessor.init(allocator);
        errdefer preprocessor.deinit();

        var compiler = try shaderc.Compiler.init();
        errdefer compiler.deinit();

        var cache = try ShaderCache.init(allocator, null);
        errdefer cache.deinit();

        // Set up default compilation options
        var options = try shaderc.CompileOptions.init();
        options.setTargetEnv(.vulkan, 0); // Vulkan 1.0
        options.setOptimizationLevel(.performance);
        options.setSourceLanguage(.glsl);

        return .{
            .allocator = allocator,
            .preprocessor = preprocessor,
            .compiler = compiler,
            .default_options = options,
            .cache = cache,
        };
    }

    pub fn deinit(self: *ShaderCompiler) void {
        if (self.default_options) |*opts| {
            opts.deinit();
        }
        self.preprocessor.deinit();
        self.compiler.deinit();
        self.cache.deinit();
    }

    /// Register a namespace for import resolution
    /// e.g., registerNamespace("farhorizons", "assets/shaders/include/")
    pub fn registerNamespace(self: *ShaderCompiler, namespace: []const u8, base_path: []const u8) !void {
        try self.preprocessor.registerNamespace(namespace, base_path);
    }

    /// Compile GLSL source code to SPIR-V
    /// Handles #fh_import preprocessing automatically.
    /// Uses disk cache to avoid recompiling unchanged shaders.
    pub fn compile(
        self: *ShaderCompiler,
        source: []const u8,
        kind: ShaderKind,
        filename: []const u8,
    ) !CompiledShader {
        // Preprocess to resolve #fh_import directives
        const processed_source = try self.preprocessor.process(source);
        defer self.allocator.free(processed_source);

        // Hash the preprocessed source + shader kind for cache lookup
        // Include kind in hash so vertex/fragment shaders with same source are cached separately
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(processed_source);
        hasher.update(&[_]u8{@intFromEnum(kind)});
        const source_hash = hasher.final();

        // Check cache first
        if (self.cache.load(source_hash)) |cached_spv| {
            self.cache_hits += 1;
            log.info("Cache hit for '{s}' ({d} bytes SPIR-V)", .{ filename, cached_spv.len });
            return CompiledShader{
                .allocator = self.allocator,
                .spv_data = cached_spv,
                .kind = kind,
            };
        }

        self.cache_misses += 1;

        // Convert filename to null-terminated string
        const filename_z = try self.allocator.dupeZ(u8, filename);
        defer self.allocator.free(filename_z);

        // Compile to SPIR-V
        var result = try self.compiler.compile(
            processed_source,
            kind.toShaderc(),
            filename_z,
            "main",
            self.default_options,
        );
        errdefer result.release();

        // Copy SPIR-V data to owned memory
        const spv_data = result.getBytes();
        const owned_spv = try self.allocator.dupe(u8, spv_data);

        // Log any warnings
        if (result.getNumWarnings() > 0) {
            if (result.getErrorMessage()) |msg| {
                log.warn("Shader '{s}' compilation warnings:\n{s}", .{ filename, msg });
            }
        }

        log.info("Compiled shader '{s}' ({d} bytes SPIR-V)", .{ filename, owned_spv.len });

        result.release();

        // Store in cache for next time
        self.cache.store(source_hash, owned_spv) catch |err| {
            log.warn("Failed to cache shader '{s}': {}", .{ filename, err });
        };

        return CompiledShader{
            .allocator = self.allocator,
            .spv_data = owned_spv,
            .kind = kind,
        };
    }

    /// Compile a shader from a file path
    pub fn compileFile(self: *ShaderCompiler, path: []const u8) !CompiledShader {
        // Determine shader kind from extension
        const kind = ShaderKind.fromExtension(path) orelse {
            log.err("Unknown shader extension for file: {s}", .{path});
            return error.UnknownShaderType;
        };

        // Read source file
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            log.err("Failed to open shader file '{s}': {}", .{ path, err });
            return err;
        };
        defer file.close();

        const stat = try file.stat();
        const size: usize = @intCast(stat.size);
        if (size > 1024 * 1024) {
            return error.FileTooLarge;
        }

        const source = try self.allocator.alloc(u8, size);
        defer self.allocator.free(source);

        const bytes_read = try file.preadAll(source, 0);
        if (bytes_read != size) {
            return error.UnexpectedEOF;
        }

        return self.compile(source, kind, path);
    }

    /// Add a macro definition for all subsequent compilations
    pub fn addMacroDefinition(self: *ShaderCompiler, name: []const u8, value: ?[]const u8) void {
        if (self.default_options) |opts| {
            opts.addMacroDefinition(name, value);
        }
    }

    /// Get cache hit/miss statistics
    pub fn getCacheStats(self: *const ShaderCompiler) CacheStats {
        return .{
            .hits = self.cache_hits,
            .misses = self.cache_misses,
            .disk_stats = self.cache.getStats(),
        };
    }

    /// Clear the shader cache (forces recompilation)
    pub fn clearCache(self: *ShaderCompiler) void {
        self.cache.clearAll();
        self.cache_hits = 0;
        self.cache_misses = 0;
    }

    pub const CacheStats = struct {
        hits: u32,
        misses: u32,
        disk_stats: ShaderCache.CacheStats,
    };
};

/// Shader types/stages
pub const ShaderKind = enum {
    vertex,
    fragment,
    compute,
    geometry,
    tess_control,
    tess_evaluation,

    pub fn toShaderc(self: ShaderKind) shaderc.ShaderKind {
        return switch (self) {
            .vertex => .vertex,
            .fragment => .fragment,
            .compute => .compute,
            .geometry => .geometry,
            .tess_control => .tess_control,
            .tess_evaluation => .tess_evaluation,
        };
    }

    /// Determine shader kind from file extension
    pub fn fromExtension(path: []const u8) ?ShaderKind {
        const ext = std.fs.path.extension(path);
        if (std.mem.eql(u8, ext, ".vert")) return .vertex;
        if (std.mem.eql(u8, ext, ".frag")) return .fragment;
        if (std.mem.eql(u8, ext, ".comp")) return .compute;
        if (std.mem.eql(u8, ext, ".geom")) return .geometry;
        if (std.mem.eql(u8, ext, ".tesc")) return .tess_control;
        if (std.mem.eql(u8, ext, ".tese")) return .tess_evaluation;
        // Also support .vsh/.fsh (Minecraft-style)
        if (std.mem.eql(u8, ext, ".vsh")) return .vertex;
        if (std.mem.eql(u8, ext, ".fsh")) return .fragment;
        return null;
    }
};

/// Compiled shader result
pub const CompiledShader = struct {
    allocator: std.mem.Allocator,
    spv_data: []const u8,
    kind: ShaderKind,

    /// Get SPIR-V data as u32 slice (for Vulkan)
    pub fn getSpvWords(self: CompiledShader) []const u32 {
        const ptr: [*]const u32 = @ptrCast(@alignCast(self.spv_data.ptr));
        return ptr[0 .. self.spv_data.len / 4];
    }

    pub fn deinit(self: *CompiledShader) void {
        self.allocator.free(self.spv_data);
        self.* = undefined;
    }
};

// Tests
test "shader kind from extension" {
    try std.testing.expectEqual(ShaderKind.vertex, ShaderKind.fromExtension("test.vert").?);
    try std.testing.expectEqual(ShaderKind.fragment, ShaderKind.fromExtension("test.frag").?);
    try std.testing.expectEqual(ShaderKind.vertex, ShaderKind.fromExtension("test.vsh").?);
    try std.testing.expectEqual(ShaderKind.fragment, ShaderKind.fromExtension("test.fsh").?);
    try std.testing.expect(ShaderKind.fromExtension("test.txt") == null);
}
