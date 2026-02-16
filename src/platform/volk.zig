const std = @import("std");
pub const c = @import("c.zig").c;

// Re-export types
pub const VkInstance = c.VkInstance;
pub const VkPhysicalDevice = c.VkPhysicalDevice;
pub const VkDevice = c.VkDevice;
pub const VkQueue = c.VkQueue;
pub const VkSurfaceKHR = c.VkSurfaceKHR;
pub const VkSwapchainKHR = c.VkSwapchainKHR;
pub const VkImage = c.VkImage;
pub const VkImageView = c.VkImageView;
pub const VkFormat = c.VkFormat;
pub const VkExtent2D = c.VkExtent2D;
pub const VkResult = c.VkResult;
pub const VkBool32 = c.VkBool32;

pub const VkInstanceCreateInfo = c.VkInstanceCreateInfo;
pub const VkApplicationInfo = c.VkApplicationInfo;
pub const VkPhysicalDeviceProperties = c.VkPhysicalDeviceProperties;
pub const VkQueueFamilyProperties = c.VkQueueFamilyProperties;
pub const VkDeviceCreateInfo = c.VkDeviceCreateInfo;
pub const VkDeviceQueueCreateInfo = c.VkDeviceQueueCreateInfo;
pub const VkSurfaceCapabilitiesKHR = c.VkSurfaceCapabilitiesKHR;
pub const VkSurfaceFormatKHR = c.VkSurfaceFormatKHR;
pub const VkSwapchainCreateInfoKHR = c.VkSwapchainCreateInfoKHR;
pub const VkImageViewCreateInfo = c.VkImageViewCreateInfo;
pub const VkAllocationCallbacks = c.VkAllocationCallbacks;
pub const VkRenderPass = c.VkRenderPass;
pub const VkFramebuffer = c.VkFramebuffer;
pub const VkRenderPassCreateInfo = c.VkRenderPassCreateInfo;
pub const VkFramebufferCreateInfo = c.VkFramebufferCreateInfo;
pub const VkAttachmentDescription = c.VkAttachmentDescription;
pub const VkAttachmentReference = c.VkAttachmentReference;
pub const VkSubpassDescription = c.VkSubpassDescription;
pub const VkSubpassDependency = c.VkSubpassDependency;

// Re-export constants
pub const VK_SUCCESS = c.VK_SUCCESS;
pub const VK_TRUE = c.VK_TRUE;
pub const VK_FALSE = c.VK_FALSE;
pub const VK_FORMAT_UNDEFINED = c.VK_FORMAT_UNDEFINED;
pub const VK_STRUCTURE_TYPE_APPLICATION_INFO = c.VK_STRUCTURE_TYPE_APPLICATION_INFO;
pub const VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
pub const VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
pub const VK_QUEUE_GRAPHICS_BIT = c.VK_QUEUE_GRAPHICS_BIT;
pub const VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
pub const VK_SHARING_MODE_EXCLUSIVE = c.VK_SHARING_MODE_EXCLUSIVE;
pub const VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
pub const VK_PRESENT_MODE_FIFO_KHR = c.VK_PRESENT_MODE_FIFO_KHR;
pub const VK_IMAGE_VIEW_TYPE_2D = c.VK_IMAGE_VIEW_TYPE_2D;
pub const VK_COMPONENT_SWIZZLE_IDENTITY = c.VK_COMPONENT_SWIZZLE_IDENTITY;
pub const VK_IMAGE_ASPECT_COLOR_BIT = c.VK_IMAGE_ASPECT_COLOR_BIT;
pub const VK_KHR_SWAPCHAIN_EXTENSION_NAME = c.VK_KHR_SWAPCHAIN_EXTENSION_NAME;
pub const VK_EXT_DEBUG_UTILS_EXTENSION_NAME = c.VK_EXT_DEBUG_UTILS_EXTENSION_NAME;
pub const VK_MAKE_VERSION = c.VK_MAKE_VERSION;
pub const VK_API_VERSION_1_2 = c.VK_API_VERSION_1_2;
pub const VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
pub const VK_ATTACHMENT_LOAD_OP_CLEAR = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
pub const VK_ATTACHMENT_LOAD_OP_DONT_CARE = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
pub const VK_ATTACHMENT_STORE_OP_STORE = c.VK_ATTACHMENT_STORE_OP_STORE;
pub const VK_ATTACHMENT_STORE_OP_DONT_CARE = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
pub const VK_IMAGE_LAYOUT_UNDEFINED = c.VK_IMAGE_LAYOUT_UNDEFINED;
pub const VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
pub const VK_IMAGE_LAYOUT_PRESENT_SRC_KHR = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
pub const VK_PIPELINE_BIND_POINT_GRAPHICS = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
pub const VK_SUBPASS_EXTERNAL = c.VK_SUBPASS_EXTERNAL;
pub const VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
pub const VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
pub const VK_SAMPLE_COUNT_1_BIT = c.VK_SAMPLE_COUNT_1_BIT;

// Debug utils types
pub const VkDebugUtilsMessengerEXT = c.VkDebugUtilsMessengerEXT;
pub const VkDebugUtilsMessengerCreateInfoEXT = c.VkDebugUtilsMessengerCreateInfoEXT;
pub const VkDebugUtilsMessageSeverityFlagBitsEXT = c.VkDebugUtilsMessageSeverityFlagBitsEXT;
pub const VkDebugUtilsMessageTypeFlagsEXT = c.VkDebugUtilsMessageTypeFlagsEXT;
pub const VkDebugUtilsMessengerCallbackDataEXT = c.VkDebugUtilsMessengerCallbackDataEXT;

// Debug utils constants
pub const VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT = c.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT;
pub const VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT;
pub const VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT;
pub const VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT;
pub const VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
pub const VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT = c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT;
pub const VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT = c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT;
pub const VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT = c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;

// Error types
pub const VulkanError = error{
    FunctionNotLoaded,
    // Core errors
    OutOfHostMemory,
    OutOfDeviceMemory,
    InitializationFailed,
    DeviceLost,
    MemoryMapFailed,
    LayerNotPresent,
    ExtensionNotPresent,
    FeatureNotPresent,
    IncompatibleDriver,
    TooManyObjects,
    FormatNotSupported,
    FragmentedPool,
    OutOfPoolMemory,
    InvalidExternalHandle,
    Fragmentation,
    InvalidOpaqueCaptureAddress,
    // Surface/Swapchain errors (KHR)
    SurfaceLostKHR,
    NativeWindowInUseKHR,
    OutOfDateKHR,
    IncompatibleDisplayKHR,
    FullScreenExclusiveModeLostEXT,
    // Validation and shader errors
    ValidationFailedEXT,
    InvalidShaderNV,
    IncompatibleShaderBinaryEXT,
    // Pipeline and rendering errors
    PipelineCompileRequiredEXT,
    InvalidDrmFormatModifierPlaneLayoutEXT,
    NotPermittedEXT,
    // Compression errors
    CompressionExhaustedEXT,
    // Video errors
    ImageUsageNotSupportedKHR,
    VideoPictureLayoutNotSupportedKHR,
    VideoProfileOperationNotSupportedKHR,
    VideoProfileFormatNotSupportedKHR,
    VideoProfileCodecNotSupportedKHR,
    VideoStdVersionNotSupportedKHR,
    // Unknown fallback
    Unknown,
};

fn vkResultToError(result: VkResult) VulkanError!void {
    return switch (result) {
        c.VK_SUCCESS => {},
        // Core errors
        c.VK_ERROR_OUT_OF_HOST_MEMORY => error.OutOfHostMemory,
        c.VK_ERROR_OUT_OF_DEVICE_MEMORY => error.OutOfDeviceMemory,
        c.VK_ERROR_INITIALIZATION_FAILED => error.InitializationFailed,
        c.VK_ERROR_DEVICE_LOST => error.DeviceLost,
        c.VK_ERROR_MEMORY_MAP_FAILED => error.MemoryMapFailed,
        c.VK_ERROR_LAYER_NOT_PRESENT => error.LayerNotPresent,
        c.VK_ERROR_EXTENSION_NOT_PRESENT => error.ExtensionNotPresent,
        c.VK_ERROR_FEATURE_NOT_PRESENT => error.FeatureNotPresent,
        c.VK_ERROR_INCOMPATIBLE_DRIVER => error.IncompatibleDriver,
        c.VK_ERROR_TOO_MANY_OBJECTS => error.TooManyObjects,
        c.VK_ERROR_FORMAT_NOT_SUPPORTED => error.FormatNotSupported,
        c.VK_ERROR_FRAGMENTED_POOL => error.FragmentedPool,
        c.VK_ERROR_OUT_OF_POOL_MEMORY => error.OutOfPoolMemory,
        c.VK_ERROR_INVALID_EXTERNAL_HANDLE => error.InvalidExternalHandle,
        c.VK_ERROR_FRAGMENTATION => error.Fragmentation,
        c.VK_ERROR_INVALID_OPAQUE_CAPTURE_ADDRESS => error.InvalidOpaqueCaptureAddress,
        // Surface/Swapchain errors
        c.VK_ERROR_SURFACE_LOST_KHR => error.SurfaceLostKHR,
        c.VK_ERROR_NATIVE_WINDOW_IN_USE_KHR => error.NativeWindowInUseKHR,
        c.VK_ERROR_OUT_OF_DATE_KHR => error.OutOfDateKHR,
        c.VK_ERROR_INCOMPATIBLE_DISPLAY_KHR => error.IncompatibleDisplayKHR,
        c.VK_ERROR_VALIDATION_FAILED_EXT => error.ValidationFailedEXT,
        c.VK_ERROR_INVALID_SHADER_NV => error.InvalidShaderNV,
        c.VK_ERROR_INVALID_DRM_FORMAT_MODIFIER_PLANE_LAYOUT_EXT => error.InvalidDrmFormatModifierPlaneLayoutEXT,
        c.VK_ERROR_NOT_PERMITTED_KHR => error.NotPermittedEXT,
        c.VK_ERROR_FULL_SCREEN_EXCLUSIVE_MODE_LOST_EXT => error.FullScreenExclusiveModeLostEXT,
        c.VK_ERROR_COMPRESSION_EXHAUSTED_EXT => error.CompressionExhaustedEXT,
        c.VK_ERROR_INCOMPATIBLE_SHADER_BINARY_EXT => error.IncompatibleShaderBinaryEXT,
        else => {
            std.log.err("Unhandled VkResult: {} (0x{x})", .{ result, @as(u32, @bitCast(result)) });
            return error.Unknown;
        },
    };
}

// Safe Volk initialization
pub fn initialize() VulkanError!void {
    const result = c.volkInitialize();
    try vkResultToError(result);
}

pub fn loadInstance(instance: VkInstance) void {
    c.volkLoadInstance(instance);
}

pub fn loadDevice(device: VkDevice) void {
    c.volkLoadDevice(device);
}

// Safe Vulkan function wrappers
pub fn createInstance(
    create_info: *const VkInstanceCreateInfo,
    allocator: ?*const VkAllocationCallbacks,
) VulkanError!VkInstance {
    const fn_ptr = c.vkCreateInstance orelse return error.FunctionNotLoaded;
    var instance: VkInstance = undefined;
    const result = fn_ptr(create_info, allocator, &instance);
    try vkResultToError(result);
    return instance;
}

pub fn destroyInstance(instance: VkInstance, allocator: ?*const VkAllocationCallbacks) void {
    if (c.vkDestroyInstance) |fn_ptr| {
        fn_ptr(instance, allocator);
    }
}

pub fn enumeratePhysicalDevices(
    instance: VkInstance,
    device_count: *u32,
    devices: ?[*]VkPhysicalDevice,
) VulkanError!void {
    const fn_ptr = c.vkEnumeratePhysicalDevices orelse return error.FunctionNotLoaded;
    const result = fn_ptr(instance, device_count, devices);
    try vkResultToError(result);
}

pub fn getPhysicalDeviceProperties(
    physical_device: VkPhysicalDevice,
    properties: *VkPhysicalDeviceProperties,
) VulkanError!void {
    const fn_ptr = c.vkGetPhysicalDeviceProperties orelse return error.FunctionNotLoaded;
    fn_ptr(physical_device, properties);
}

pub fn getPhysicalDeviceQueueFamilyProperties(
    physical_device: VkPhysicalDevice,
    queue_family_count: *u32,
    queue_families: ?[*]VkQueueFamilyProperties,
) VulkanError!void {
    const fn_ptr = c.vkGetPhysicalDeviceQueueFamilyProperties orelse return error.FunctionNotLoaded;
    fn_ptr(physical_device, queue_family_count, queue_families);
}

pub fn getPhysicalDeviceSurfaceSupportKHR(
    physical_device: VkPhysicalDevice,
    queue_family_index: u32,
    surface: VkSurfaceKHR,
    supported: *VkBool32,
) VulkanError!void {
    const fn_ptr = c.vkGetPhysicalDeviceSurfaceSupportKHR orelse return error.FunctionNotLoaded;
    const result = fn_ptr(physical_device, queue_family_index, surface, supported);
    try vkResultToError(result);
}

pub fn createDevice(
    physical_device: VkPhysicalDevice,
    create_info: *const VkDeviceCreateInfo,
    allocator: ?*const VkAllocationCallbacks,
) VulkanError!VkDevice {
    const fn_ptr = c.vkCreateDevice orelse return error.FunctionNotLoaded;
    var device: VkDevice = undefined;
    const result = fn_ptr(physical_device, create_info, allocator, &device);
    try vkResultToError(result);
    return device;
}

pub fn destroyDevice(device: VkDevice, allocator: ?*const VkAllocationCallbacks) void {
    if (c.vkDestroyDevice) |fn_ptr| {
        fn_ptr(device, allocator);
    }
}

pub fn getDeviceQueue(
    device: VkDevice,
    queue_family_index: u32,
    queue_index: u32,
    queue: *VkQueue,
) void {
    if (c.vkGetDeviceQueue) |fn_ptr| {
        fn_ptr(device, queue_family_index, queue_index, queue);
    }
}

pub fn deviceWaitIdle(device: VkDevice) VulkanError!void {
    const fn_ptr = c.vkDeviceWaitIdle orelse return error.FunctionNotLoaded;
    const result = fn_ptr(device);
    try vkResultToError(result);
}

pub fn destroySurfaceKHR(
    instance: VkInstance,
    surface: VkSurfaceKHR,
    allocator: ?*const VkAllocationCallbacks,
) void {
    if (c.vkDestroySurfaceKHR) |fn_ptr| {
        fn_ptr(instance, surface, allocator);
    }
}

pub fn getPhysicalDeviceSurfaceCapabilitiesKHR(
    physical_device: VkPhysicalDevice,
    surface: VkSurfaceKHR,
    capabilities: *VkSurfaceCapabilitiesKHR,
) VulkanError!void {
    const fn_ptr = c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR orelse return error.FunctionNotLoaded;
    const result = fn_ptr(physical_device, surface, capabilities);
    try vkResultToError(result);
}

pub fn getPhysicalDeviceSurfaceFormatsKHR(
    physical_device: VkPhysicalDevice,
    surface: VkSurfaceKHR,
    format_count: *u32,
    formats: ?[*]VkSurfaceFormatKHR,
) VulkanError!void {
    const fn_ptr = c.vkGetPhysicalDeviceSurfaceFormatsKHR orelse return error.FunctionNotLoaded;
    const result = fn_ptr(physical_device, surface, format_count, formats);
    try vkResultToError(result);
}

pub fn createSwapchainKHR(
    device: VkDevice,
    create_info: *const VkSwapchainCreateInfoKHR,
    allocator: ?*const VkAllocationCallbacks,
) VulkanError!VkSwapchainKHR {
    const fn_ptr = c.vkCreateSwapchainKHR orelse return error.FunctionNotLoaded;
    var swapchain: VkSwapchainKHR = undefined;
    const result = fn_ptr(device, create_info, allocator, &swapchain);
    try vkResultToError(result);
    return swapchain;
}

pub fn destroySwapchainKHR(
    device: VkDevice,
    swapchain: VkSwapchainKHR,
    allocator: ?*const VkAllocationCallbacks,
) void {
    if (c.vkDestroySwapchainKHR) |fn_ptr| {
        fn_ptr(device, swapchain, allocator);
    }
}

pub fn getSwapchainImagesKHR(
    device: VkDevice,
    swapchain: VkSwapchainKHR,
    image_count: *u32,
    images: ?[*]VkImage,
) VulkanError!void {
    const fn_ptr = c.vkGetSwapchainImagesKHR orelse return error.FunctionNotLoaded;
    const result = fn_ptr(device, swapchain, image_count, images);
    try vkResultToError(result);
}

pub fn createImageView(
    device: VkDevice,
    create_info: *const VkImageViewCreateInfo,
    allocator: ?*const VkAllocationCallbacks,
) VulkanError!VkImageView {
    const fn_ptr = c.vkCreateImageView orelse return error.FunctionNotLoaded;
    var image_view: VkImageView = undefined;
    const result = fn_ptr(device, create_info, allocator, &image_view);
    try vkResultToError(result);
    return image_view;
}

pub fn destroyImageView(
    device: VkDevice,
    image_view: VkImageView,
    allocator: ?*const VkAllocationCallbacks,
) void {
    if (c.vkDestroyImageView) |fn_ptr| {
        fn_ptr(device, image_view, allocator);
    }
}

// Debug utils functions
pub fn createDebugUtilsMessengerEXT(
    instance: VkInstance,
    create_info: *const VkDebugUtilsMessengerCreateInfoEXT,
    allocator: ?*const VkAllocationCallbacks,
) VulkanError!VkDebugUtilsMessengerEXT {
    const fn_ptr = c.vkCreateDebugUtilsMessengerEXT orelse return error.FunctionNotLoaded;
    var messenger: VkDebugUtilsMessengerEXT = undefined;
    const result = fn_ptr(instance, create_info, allocator, &messenger);
    try vkResultToError(result);
    return messenger;
}

pub fn destroyDebugUtilsMessengerEXT(
    instance: VkInstance,
    messenger: VkDebugUtilsMessengerEXT,
    allocator: ?*const VkAllocationCallbacks,
) void {
    if (c.vkDestroyDebugUtilsMessengerEXT) |fn_ptr| {
        fn_ptr(instance, messenger, allocator);
    }
}

pub fn createRenderPass(
    device: VkDevice,
    create_info: *const VkRenderPassCreateInfo,
    allocator: ?*const VkAllocationCallbacks,
) VulkanError!VkRenderPass {
    const fn_ptr = c.vkCreateRenderPass orelse return error.FunctionNotLoaded;
    var render_pass: VkRenderPass = undefined;
    const result = fn_ptr(device, create_info, allocator, &render_pass);
    try vkResultToError(result);
    return render_pass;
}

pub fn destroyRenderPass(
    device: VkDevice,
    render_pass: VkRenderPass,
    allocator: ?*const VkAllocationCallbacks,
) void {
    if (c.vkDestroyRenderPass) |fn_ptr| {
        fn_ptr(device, render_pass, allocator);
    }
}

pub fn createFramebuffer(
    device: VkDevice,
    create_info: *const VkFramebufferCreateInfo,
    allocator: ?*const VkAllocationCallbacks,
) VulkanError!VkFramebuffer {
    const fn_ptr = c.vkCreateFramebuffer orelse return error.FunctionNotLoaded;
    var framebuffer: VkFramebuffer = undefined;
    const result = fn_ptr(device, create_info, allocator, &framebuffer);
    try vkResultToError(result);
    return framebuffer;
}

pub fn destroyFramebuffer(
    device: VkDevice,
    framebuffer: VkFramebuffer,
    allocator: ?*const VkAllocationCallbacks,
) void {
    if (c.vkDestroyFramebuffer) |fn_ptr| {
        fn_ptr(device, framebuffer, allocator);
    }
}
