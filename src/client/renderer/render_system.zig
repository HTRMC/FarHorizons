// Render system - Vulkan state management

const std = @import("std");
const volk = @import("volk");
const vk = volk.c;
const shared = @import("shared");
const Logger = shared.Logger;
const platform = @import("platform");

pub const RenderSystem = struct {
    const Self = @This();
    const logger = Logger.init("RenderSystem");

    instance: vk.VkInstance = null,
    physical_device: vk.VkPhysicalDevice = null,
    device: vk.VkDevice = null,

    pub fn init() Self {
        return .{};
    }

    /// Initialize the Vulkan backend
    pub fn initBackend(self: *Self) !void {
        // Check Vulkan support
        if (!platform.isVulkanSupported()) {
            logger.err("Vulkan is not supported on this system", .{});
            return error.VulkanNotSupported;
        }

        // Initialize volk (Vulkan loader)
        volk.init() catch {
            logger.err("Failed to initialize Vulkan loader", .{});
            return error.VulkanLoaderFailed;
        };

        const vk_version = volk.getInstanceVersion();
        logger.info("Vulkan instance version: {}.{}.{}", .{
            (vk_version >> 22) & 0x7F,
            (vk_version >> 12) & 0x3FF,
            vk_version & 0xFFF,
        });

        // Create Vulkan instance
        try self.createInstance();
    }

    /// Shutdown the Vulkan backend
    pub fn shutdown(self: *Self) void {
        self.destroyInstance();
        logger.info("Render system shut down", .{});
    }

    fn createInstance(self: *Self) !void {
        // Get required extensions from GLFW
        const ext_info = platform.getRequiredVulkanExtensions() orelse {
            logger.err("Failed to get required Vulkan extensions", .{});
            return error.VulkanExtensionsFailed;
        };

        logger.info("Required instance extensions: {}", .{ext_info.count});

        const app_info = vk.VkApplicationInfo{
            .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pNext = null,
            .pApplicationName = "FarHorizons",
            .applicationVersion = vk.VK_MAKE_VERSION(0, 0, 1),
            .pEngineName = "FarHorizons Engine",
            .engineVersion = vk.VK_MAKE_VERSION(0, 0, 1),
            .apiVersion = vk.VK_API_VERSION_1_0,
        };

        const create_info = vk.VkInstanceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .pApplicationInfo = &app_info,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = ext_info.count,
            .ppEnabledExtensionNames = ext_info.extensions,
        };

        const vkCreateInstance = vk.vkCreateInstance orelse {
            logger.err("vkCreateInstance not loaded", .{});
            return error.VulkanFunctionNotLoaded;
        };

        const result = vkCreateInstance(&create_info, null, &self.instance);
        if (result != vk.VK_SUCCESS) {
            logger.err("Failed to create Vulkan instance: {}", .{result});
            return error.VulkanInstanceFailed;
        }

        // Load instance-level Vulkan functions
        volk.loadInstance(self.instance);

        logger.info("Vulkan instance created successfully", .{});
    }

    fn destroyInstance(self: *Self) void {
        if (self.instance) |instance| {
            if (vk.vkDestroyInstance) |destroy| {
                destroy(instance, null);
            }
            self.instance = null;
        }
    }

    pub fn getInstance(self: *const Self) vk.VkInstance {
        return self.instance;
    }
};
