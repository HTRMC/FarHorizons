// Volk - Vulkan meta-loader
// Wraps volk.h C interface for Zig

pub const c = @cImport({
    @cDefine("VK_NO_PROTOTYPES", "1");
    @cInclude("volk.h");
});

pub const VkResult = c.VkResult;
pub const VkInstance = c.VkInstance;
pub const VkPhysicalDevice = c.VkPhysicalDevice;
pub const VkDevice = c.VkDevice;

/// Initialize volk by loading the Vulkan loader
/// Must be called before any other Vulkan functions
pub fn init() !void {
    const result = c.volkInitialize();
    if (result != c.VK_SUCCESS) {
        return error.VulkanLoaderNotFound;
    }
}

/// Load instance-level Vulkan functions
/// Call this after creating a VkInstance
pub fn loadInstance(instance: VkInstance) void {
    c.volkLoadInstance(instance);
}

/// Load device-level Vulkan functions
/// Call this after creating a VkDevice for optimal performance
pub fn loadDevice(device: VkDevice) void {
    c.volkLoadDevice(device);
}

/// Get the Vulkan instance version
pub fn getInstanceVersion() u32 {
    return c.volkGetInstanceVersion();
}
