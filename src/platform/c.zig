pub const c = @cImport({
    @cDefine("VK_NO_PROTOTYPES", "1");
    @cDefine("GLFW_INCLUDE_NONE", "1");
    @cInclude("volk.h");
    @cInclude("GLFW/glfw3.h");
    @cInclude("shaderc/shaderc.h");
    @cInclude("stb_image.h");
    @cDefine("FASTNOISE_STATIC_LIB", "1");
    @cInclude("FastNoise/FastNoise_C.h");
});
