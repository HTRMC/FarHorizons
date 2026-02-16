const c = @import("c.zig").c;

pub const shaderc_compiler_t = c.shaderc_compiler_t;
pub const shaderc_compile_options_t = c.shaderc_compile_options_t;
pub const shaderc_compilation_result_t = c.shaderc_compilation_result_t;
pub const shaderc_shader_kind = c.shaderc_shader_kind;
pub const shaderc_compilation_status = c.shaderc_compilation_status;

pub const shaderc_vertex_shader = c.shaderc_vertex_shader;
pub const shaderc_fragment_shader = c.shaderc_fragment_shader;
pub const shaderc_compute_shader = c.shaderc_compute_shader;
pub const shaderc_compilation_status_success = c.shaderc_compilation_status_success;

pub fn compiler_initialize() shaderc_compiler_t {
    return c.shaderc_compiler_initialize();
}

pub fn compiler_release(compiler: shaderc_compiler_t) void {
    c.shaderc_compiler_release(compiler);
}

pub fn compile_options_initialize() shaderc_compile_options_t {
    return c.shaderc_compile_options_initialize();
}

pub fn compile_options_release(options: shaderc_compile_options_t) void {
    c.shaderc_compile_options_release(options);
}

pub fn compile_into_spv(
    compiler: shaderc_compiler_t,
    source_text: [*:0]const u8,
    source_size: usize,
    shader_kind: shaderc_shader_kind,
    input_file_name: [*:0]const u8,
    entry_point_name: [*:0]const u8,
    additional_options: shaderc_compile_options_t,
) shaderc_compilation_result_t {
    return c.shaderc_compile_into_spv(
        compiler,
        source_text,
        source_size,
        shader_kind,
        input_file_name,
        entry_point_name,
        additional_options,
    );
}

pub fn result_release(result: shaderc_compilation_result_t) void {
    c.shaderc_result_release(result);
}

pub fn result_get_compilation_status(result: shaderc_compilation_result_t) shaderc_compilation_status {
    return c.shaderc_result_get_compilation_status(result);
}

pub fn result_get_error_message(result: shaderc_compilation_result_t) [*:0]const u8 {
    return c.shaderc_result_get_error_message(result);
}

pub fn result_get_bytes(result: shaderc_compilation_result_t) [*]const u8 {
    return c.shaderc_result_get_bytes(result);
}

pub fn result_get_length(result: shaderc_compilation_result_t) usize {
    return c.shaderc_result_get_length(result);
}
