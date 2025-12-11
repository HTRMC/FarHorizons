const std = @import("std");

const c = @cImport({
    @cInclude("shaderc/shaderc.h");
});

/// Shader stage/kind for compilation
pub const ShaderKind = enum(c_uint) {
    vertex = c.shaderc_vertex_shader,
    fragment = c.shaderc_fragment_shader,
    compute = c.shaderc_compute_shader,
    geometry = c.shaderc_geometry_shader,
    tess_control = c.shaderc_tess_control_shader,
    tess_evaluation = c.shaderc_tess_evaluation_shader,
};

/// Target SPIR-V environment
pub const TargetEnv = enum(c_uint) {
    vulkan = c.shaderc_target_env_vulkan,
    opengl = c.shaderc_target_env_opengl,
    opengl_compat = c.shaderc_target_env_opengl_compat,
};

/// Optimization level
pub const OptimizationLevel = enum(c_uint) {
    zero = c.shaderc_optimization_level_zero,
    size = c.shaderc_optimization_level_size,
    performance = c.shaderc_optimization_level_performance,
};

/// Compilation status
pub const CompilationStatus = enum(c_uint) {
    success = c.shaderc_compilation_status_success,
    invalid_stage = c.shaderc_compilation_status_invalid_stage,
    compilation_error = c.shaderc_compilation_status_compilation_error,
    internal_error = c.shaderc_compilation_status_internal_error,
    null_result_object = c.shaderc_compilation_status_null_result_object,
    invalid_assembly = c.shaderc_compilation_status_invalid_assembly,
    validation_error = c.shaderc_compilation_status_validation_error,
    transformation_error = c.shaderc_compilation_status_transformation_error,
    configuration_error = c.shaderc_compilation_status_configuration_error,
};

/// Compilation error information
pub const CompilationError = error{
    InvalidStage,
    CompilationError,
    InternalError,
    NullResultObject,
    InvalidAssembly,
    ValidationError,
    TransformationError,
    ConfigurationError,
    Unknown,
};

/// Result of a shader compilation
pub const CompilationResult = struct {
    handle: c.shaderc_compilation_result_t,

    /// Get the SPIR-V binary data as a slice of u32
    pub fn getSpvData(self: CompilationResult) []const u32 {
        const bytes = c.shaderc_result_get_bytes(self.handle);
        const length = c.shaderc_result_get_length(self.handle);
        if (bytes == null or length == 0) {
            return &[_]u32{};
        }
        const ptr: [*]const u32 = @ptrCast(@alignCast(bytes));
        return ptr[0 .. length / 4];
    }

    /// Get the raw SPIR-V bytes
    pub fn getBytes(self: CompilationResult) []const u8 {
        const bytes = c.shaderc_result_get_bytes(self.handle);
        const length = c.shaderc_result_get_length(self.handle);
        if (bytes == null or length == 0) {
            return &[_]u8{};
        }
        return bytes[0..length];
    }

    /// Get the error message if compilation failed
    pub fn getErrorMessage(self: CompilationResult) ?[]const u8 {
        const msg = c.shaderc_result_get_error_message(self.handle);
        if (msg == null) return null;
        return std.mem.span(msg);
    }

    /// Get number of errors
    pub fn getNumErrors(self: CompilationResult) usize {
        return c.shaderc_result_get_num_errors(self.handle);
    }

    /// Get number of warnings
    pub fn getNumWarnings(self: CompilationResult) usize {
        return c.shaderc_result_get_num_warnings(self.handle);
    }

    /// Get the compilation status
    pub fn getStatus(self: CompilationResult) CompilationStatus {
        return @enumFromInt(c.shaderc_result_get_compilation_status(self.handle));
    }

    /// Release the compilation result
    pub fn release(self: *CompilationResult) void {
        if (self.handle != null) {
            c.shaderc_result_release(self.handle);
            self.handle = null;
        }
    }
};

/// Compilation options
pub const CompileOptions = struct {
    handle: c.shaderc_compile_options_t,

    pub fn init() !CompileOptions {
        const handle = c.shaderc_compile_options_initialize();
        if (handle == null) {
            return error.OptionsInitFailed;
        }
        return .{ .handle = handle };
    }

    pub fn deinit(self: *CompileOptions) void {
        if (self.handle != null) {
            c.shaderc_compile_options_release(self.handle);
            self.handle = null;
        }
    }

    /// Clone the options
    pub fn clone(self: CompileOptions) !CompileOptions {
        const handle = c.shaderc_compile_options_clone(self.handle);
        if (handle == null) {
            return error.OptionsCloneFailed;
        }
        return .{ .handle = handle };
    }

    /// Set target environment (Vulkan, OpenGL)
    pub fn setTargetEnv(self: CompileOptions, env: TargetEnv, version: u32) void {
        c.shaderc_compile_options_set_target_env(self.handle, @intFromEnum(env), version);
    }

    /// Set optimization level
    pub fn setOptimizationLevel(self: CompileOptions, level: OptimizationLevel) void {
        c.shaderc_compile_options_set_optimization_level(self.handle, @intFromEnum(level));
    }

    /// Add a preprocessor define
    pub fn addMacroDefinition(self: CompileOptions, name: []const u8, value: ?[]const u8) void {
        const value_ptr = if (value) |v| v.ptr else null;
        const value_len = if (value) |v| v.len else 0;
        c.shaderc_compile_options_add_macro_definition(
            self.handle,
            name.ptr,
            name.len,
            value_ptr,
            value_len,
        );
    }

    /// Generate debug info
    pub fn setGenerateDebugInfo(self: CompileOptions) void {
        c.shaderc_compile_options_set_generate_debug_info(self.handle);
    }

    /// Set source language (GLSL or HLSL)
    pub fn setSourceLanguage(self: CompileOptions, lang: SourceLanguage) void {
        c.shaderc_compile_options_set_source_language(self.handle, @intFromEnum(lang));
    }

    /// Set warnings as errors
    pub fn setWarningsAsErrors(self: CompileOptions) void {
        c.shaderc_compile_options_set_warnings_as_errors(self.handle);
    }
};

pub const SourceLanguage = enum(c_uint) {
    glsl = c.shaderc_source_language_glsl,
    hlsl = c.shaderc_source_language_hlsl,
};

/// Shaderc compiler instance
pub const Compiler = struct {
    handle: c.shaderc_compiler_t,

    /// Initialize a new compiler instance
    pub fn init() !Compiler {
        const handle = c.shaderc_compiler_initialize();
        if (handle == null) {
            return error.CompilerInitFailed;
        }
        return .{ .handle = handle };
    }

    /// Release the compiler
    pub fn deinit(self: *Compiler) void {
        if (self.handle != null) {
            c.shaderc_compiler_release(self.handle);
            self.handle = null;
        }
    }

    /// Compile GLSL/HLSL source to SPIR-V
    pub fn compile(
        self: Compiler,
        source: []const u8,
        kind: ShaderKind,
        input_file_name: [*:0]const u8,
        entry_point: [*:0]const u8,
        options: ?CompileOptions,
    ) !CompilationResult {
        const opt_handle = if (options) |o| o.handle else null;

        const result = c.shaderc_compile_into_spv(
            self.handle,
            source.ptr,
            source.len,
            @intFromEnum(kind),
            input_file_name,
            entry_point,
            opt_handle,
        );

        if (result == null) {
            return error.CompilationFailed;
        }

        const compilation_result = CompilationResult{ .handle = result };
        const status = compilation_result.getStatus();

        if (status != .success) {
            return statusToError(status);
        }

        return compilation_result;
    }

    /// Compile to SPIR-V assembly (text format) for debugging
    pub fn compileToAssembly(
        self: Compiler,
        source: []const u8,
        kind: ShaderKind,
        input_file_name: [*:0]const u8,
        entry_point: [*:0]const u8,
        options: ?CompileOptions,
    ) !CompilationResult {
        const opt_handle = if (options) |o| o.handle else null;

        const result = c.shaderc_compile_into_spv_assembly(
            self.handle,
            source.ptr,
            source.len,
            @intFromEnum(kind),
            input_file_name,
            entry_point,
            opt_handle,
        );

        if (result == null) {
            return error.CompilationFailed;
        }

        const compilation_result = CompilationResult{ .handle = result };
        const status = compilation_result.getStatus();

        if (status != .success) {
            return statusToError(status);
        }

        return compilation_result;
    }

    /// Preprocess source (expand macros, includes via callback)
    pub fn preprocess(
        self: Compiler,
        source: []const u8,
        kind: ShaderKind,
        input_file_name: [*:0]const u8,
        options: ?CompileOptions,
    ) !CompilationResult {
        const opt_handle = if (options) |o| o.handle else null;

        const result = c.shaderc_compile_into_preprocessed_text(
            self.handle,
            source.ptr,
            source.len,
            @intFromEnum(kind),
            input_file_name,
            "main",
            opt_handle,
        );

        if (result == null) {
            return error.CompilationFailed;
        }

        const compilation_result = CompilationResult{ .handle = result };
        const status = compilation_result.getStatus();

        if (status != .success) {
            return statusToError(status);
        }

        return compilation_result;
    }
};

fn statusToError(status: CompilationStatus) CompilationError {
    return switch (status) {
        .success => unreachable,
        .invalid_stage => error.InvalidStage,
        .compilation_error => error.CompilationError,
        .internal_error => error.InternalError,
        .null_result_object => error.NullResultObject,
        .invalid_assembly => error.InvalidAssembly,
        .validation_error => error.ValidationError,
        .transformation_error => error.TransformationError,
        .configuration_error => error.ConfigurationError,
    };
}
