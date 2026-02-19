const std = @import("std");
const shaderc = @import("../../platform/shaderc.zig");
const app_config = @import("../../app_config.zig");
const Io = std.Io;
const Dir = Io.Dir;

const sep = std.fs.path.sep_str;

pub const ShaderKind = enum {
    vertex,
    fragment,
    compute,

    fn toShaderc(self: ShaderKind) shaderc.shaderc_shader_kind {
        return switch (self) {
            .vertex => shaderc.shaderc_vertex_shader,
            .fragment => shaderc.shaderc_fragment_shader,
            .compute => shaderc.shaderc_compute_shader,
        };
    }
};

pub const CompileError = error{
    CompilationFailed,
    ShaderSourceNotFound,
};

allocator: std.mem.Allocator,
io: Io,
compiler: shaderc.shaderc_compiler_t,
options: shaderc.shaderc_compile_options_t,
cache_dir_path: []const u8,
shader_base_path: []const u8,

const Self = @This();

pub fn init(allocator: std.mem.Allocator) !Self {
    const base_path = try app_config.getAppDataPath(allocator);
    defer allocator.free(base_path);

    const shader_base_path = try std.fmt.allocPrint(allocator, "{s}" ++ sep ++ "assets" ++ sep ++ "farhorizons" ++ sep ++ "shaders", .{base_path});
    const cache_dir_path = try std.fmt.allocPrint(allocator, "{s}" ++ sep ++ ".shader_cache", .{base_path});

    const io = Io.Threaded.global_single_threaded.io();

    // Ensure cache directory exists
    Dir.createDirAbsolute(io, cache_dir_path, .default_file) catch {};

    return .{
        .allocator = allocator,
        .io = io,
        .compiler = shaderc.compiler_initialize(),
        .options = shaderc.compile_options_initialize(),
        .cache_dir_path = cache_dir_path,
        .shader_base_path = shader_base_path,
    };
}

pub fn deinit(self: *Self) void {
    shaderc.compile_options_release(self.options);
    shaderc.compiler_release(self.compiler);
    self.allocator.free(self.cache_dir_path);
    self.allocator.free(self.shader_base_path);
}

pub fn compile(self: *Self, filename: []const u8, kind: ShaderKind) ![]const u8 {
    // Read shader source from disk
    const shader_path = try std.fmt.allocPrint(self.allocator, "{s}" ++ sep ++ "{s}", .{ self.shader_base_path, filename });
    defer self.allocator.free(shader_path);

    const source = Dir.readFileAlloc(.cwd(), self.io, shader_path, self.allocator, .unlimited) catch {
        std.log.err("Failed to read shader source '{s}'", .{shader_path});
        return error.ShaderSourceNotFound;
    };
    defer self.allocator.free(source);

    // Hash the source
    const hash = std.hash.XxHash3.hash(0, source);
    var hash_hex: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&hash_hex, "{x:0>16}", .{hash}) catch unreachable;

    // Build cache filename path
    const cache_file_path = try std.fmt.allocPrint(self.allocator, "{s}" ++ sep ++ "{s}.{s}.spv", .{ self.cache_dir_path, filename, hash_hex });
    defer self.allocator.free(cache_file_path);

    // Try cache hit
    if (Dir.readFileAlloc(.cwd(), self.io, cache_file_path, self.allocator, .unlimited)) |cached| {
        std.log.info("Shader cache hit: {s}", .{filename});
        return cached;
    } else |_| {}

    // Cache miss — compile
    std.log.info("Shader cache miss, compiling: {s}", .{filename});

    const filename_z = try self.allocator.dupeZ(u8, filename);
    defer self.allocator.free(filename_z);

    const source_z = try self.allocator.dupeZ(u8, source);
    defer self.allocator.free(source_z);

    const result = shaderc.compile_into_spv(
        self.compiler,
        source_z.ptr,
        source.len,
        kind.toShaderc(),
        filename_z.ptr,
        "main",
        self.options,
    );
    defer shaderc.result_release(result);

    const status = shaderc.result_get_compilation_status(result);
    if (status != shaderc.shaderc_compilation_status_success) {
        const error_msg = shaderc.result_get_error_message(result);
        std.log.err("Shader compilation failed for {s}:\n{s}", .{ filename, std.mem.span(error_msg) });
        return error.CompilationFailed;
    }

    const bytes = shaderc.result_get_bytes(result);
    const length = shaderc.result_get_length(result);

    const spirv = try self.allocator.alloc(u8, length);
    @memcpy(spirv, bytes[0..length]);

    // Write to cache
    Dir.writeFile(.cwd(), self.io, .{ .sub_path = cache_file_path, .data = spirv }) catch {};

    return spirv;
}
