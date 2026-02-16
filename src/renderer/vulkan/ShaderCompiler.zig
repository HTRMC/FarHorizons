const std = @import("std");
const shaderc = @import("../../platform/shaderc.zig");

pub const ShaderKind = enum {
    vertex,
    fragment,
    compute,

    fn toShaderc(self: ShaderKind) c_uint {
        return switch (self) {
            .vertex => shaderc.shaderc_vertex_shader,
            .fragment => shaderc.shaderc_fragment_shader,
            .compute => @panic("Compute shaders not yet supported"),
        };
    }
};

pub const CompileError = error{
    CompilationFailed,
    OutOfMemory,
};

pub fn compile(
    allocator: std.mem.Allocator,
    source: []const u8,
    filename: []const u8,
    kind: ShaderKind,
) CompileError![]const u8 {
    const compiler = shaderc.compiler_initialize();
    defer shaderc.compiler_release(compiler);

    const options = shaderc.compile_options_initialize();
    defer shaderc.compile_options_release(options);

    const filename_z = try allocator.dupeZ(u8, filename);
    defer allocator.free(filename_z);

    const result = shaderc.compile_into_spv(
        compiler,
        source.ptr,
        source.len,
        kind.toShaderc(),
        filename_z.ptr,
        "main",
        options,
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

    const spirv = try allocator.alloc(u8, length);
    @memcpy(spirv, bytes[0..length]);

    return spirv;
}
