pub const c = @cImport({
    // Disable mingw's fortified functions — they use __builtin_va_arg_pack
    // which Zig's C translator doesn't support (breaks ReleaseSafe/Fast builds).
    @cDefine("_FORTIFY_SOURCE", "0");
    @cDefine("VK_NO_PROTOTYPES", "1");
    @cDefine("GLFW_INCLUDE_NONE", "1");
    @cInclude("volk.h");
    @cInclude("GLFW/glfw3.h");
    @cInclude("shaderc/shaderc.h");
    @cInclude("stb_image.h");
    @cDefine("FASTNOISE_STATIC_LIB", "1");
    @cInclude("FastNoise/FastNoise_C.h");
});
