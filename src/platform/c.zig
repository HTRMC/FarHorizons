pub const c = @cImport({
    @cDefine("VK_NO_PROTOTYPES", "1");
    @cInclude("volk.h");
    @cInclude("GLFW/glfw3.h");
    @cInclude("shaderc/shaderc.h");
    @cInclude("stb_image.h");
});
