const std = @import("std");
const Renderer = @import("../Renderer.zig").Renderer;
const vk = @import("../../platform/volk.zig").c;
const Window = @import("../../platform/Window.zig").Window;

pub const VulkanRenderer = struct {
    allocator: std.mem.Allocator,
    window: *const Window,
    instance: vk.VkInstance,
    physical_device: vk.VkPhysicalDevice,
    device: vk.VkDevice,
    graphics_queue: vk.VkQueue,
    queue_family_index: u32,
    surface: vk.VkSurfaceKHR,
    swapchain: vk.VkSwapchainKHR,
    swapchain_images: std.ArrayList(vk.VkImage),
    swapchain_image_views: std.ArrayList(vk.VkImageView),
    swapchain_format: vk.VkFormat,
    swapchain_extent: vk.VkExtent2D,

    pub fn init(allocator: std.mem.Allocator, window: *const Window) !*VulkanRenderer {
        const self = try allocator.create(VulkanRenderer);
        errdefer allocator.destroy(self);

        if (vk.volkInitialize() != vk.VK_SUCCESS) {
            return error.VulkanInitFailed;
        }

        const instance = try createInstance();
        errdefer vk.vkDestroyInstance.?(instance, null);

        vk.volkLoadInstance(instance);

        const surface = try window.createSurface(instance, null);
        errdefer vk.vkDestroySurfaceKHR.?(instance, surface, null);

        const device_info = try selectPhysicalDevice(allocator, instance, surface);
        const device = try createDevice(device_info.physical_device, device_info.queue_family_index);
        errdefer vk.vkDestroyDevice.?(device, null);

        vk.volkLoadDevice(device);

        var graphics_queue: vk.VkQueue = undefined;
        vk.vkGetDeviceQueue.?(device, device_info.queue_family_index, 0, &graphics_queue);

        var swapchain_images: std.ArrayList(vk.VkImage) = .empty;
        var swapchain_image_views: std.ArrayList(vk.VkImageView) = .empty;

        self.* = .{
            .allocator = allocator,
            .window = window,
            .instance = instance,
            .physical_device = device_info.physical_device,
            .device = device,
            .graphics_queue = graphics_queue,
            .queue_family_index = device_info.queue_family_index,
            .surface = surface,
            .swapchain = null,
            .swapchain_images = swapchain_images,
            .swapchain_image_views = swapchain_image_views,
            .swapchain_format = vk.VK_FORMAT_UNDEFINED,
            .swapchain_extent = .{ .width = 0, .height = 0 },
        };

        try self.createSwapchain();

        std.log.info("VulkanRenderer initialized", .{});
        return self;
    }

    pub fn deinit(self: *VulkanRenderer) void {
        const wait_result = vk.vkDeviceWaitIdle.?(self.device);
        if (wait_result != vk.VK_SUCCESS) {
            std.log.err("vkDeviceWaitIdle failed: {}", .{wait_result});
        }

        self.cleanupSwapchain();
        self.swapchain_images.deinit(self.allocator);
        self.swapchain_image_views.deinit(self.allocator);

        vk.vkDestroySurfaceKHR.?(self.instance, self.surface, null);
        vk.vkDestroyDevice.?(self.device, null);
        vk.vkDestroyInstance.?(self.instance, null);
        std.log.info("VulkanRenderer destroyed", .{});
        self.allocator.destroy(self);
    }

    pub fn beginFrame(self: *VulkanRenderer) !void {
        _ = self;
    }

    pub fn endFrame(self: *VulkanRenderer) !void {
        _ = self;
    }

    pub fn render(self: *VulkanRenderer) !void {
        _ = self;
    }

    fn createInstance() !vk.VkInstance {
        const app_info = vk.VkApplicationInfo{
            .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pNext = null,
            .pApplicationName = "FarHorizons",
            .applicationVersion = vk.VK_MAKE_VERSION(0, 0, 1),
            .pEngineName = "FarHorizons Engine",
            .engineVersion = vk.VK_MAKE_VERSION(0, 0, 1),
            .apiVersion = vk.VK_API_VERSION_1_2,
        };

        const extensions = Window.getRequiredExtensions();

        const create_info = vk.VkInstanceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .pApplicationInfo = &app_info,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = 2,
            .ppEnabledExtensionNames = extensions,
        };

        var instance: vk.VkInstance = undefined;
        const result = vk.vkCreateInstance.?(&create_info, null, &instance);
        if (result != vk.VK_SUCCESS) {
            return error.InstanceCreationFailed;
        }

        return instance;
    }

    const DeviceInfo = struct {
        physical_device: vk.VkPhysicalDevice,
        queue_family_index: u32,
    };

    fn selectPhysicalDevice(allocator: std.mem.Allocator, instance: vk.VkInstance, surface: vk.VkSurfaceKHR) !DeviceInfo {
        var device_count: u32 = 0;
        if (vk.vkEnumeratePhysicalDevices.?(instance, &device_count, null) != vk.VK_SUCCESS) {
            return error.EnumeratePhysicalDevicesFailed;
        }

        if (device_count == 0) {
            return error.NoVulkanDevices;
        }

        var devices: [16]vk.VkPhysicalDevice = undefined;
        if (vk.vkEnumeratePhysicalDevices.?(instance, &device_count, &devices) != vk.VK_SUCCESS) {
            return error.EnumeratePhysicalDevicesFailed;
        }

        for (devices[0..device_count]) |device| {
            var props: vk.VkPhysicalDeviceProperties = undefined;
            vk.vkGetPhysicalDeviceProperties.?(device, &props);
            std.log.info("Found GPU: {s}", .{props.deviceName});

            if (try findQueueFamily(allocator, device, surface)) |queue_family| {
                return .{
                    .physical_device = device,
                    .queue_family_index = queue_family,
                };
            }
        }

        return error.NoSuitableDevice;
    }

    fn findQueueFamily(allocator: std.mem.Allocator, device: vk.VkPhysicalDevice, surface: vk.VkSurfaceKHR) !?u32 {
        var queue_family_count: u32 = 0;
        vk.vkGetPhysicalDeviceQueueFamilyProperties.?(device, &queue_family_count, null);

        var queue_families = try allocator.alloc(vk.VkQueueFamilyProperties, queue_family_count);
        defer allocator.free(queue_families);

        vk.vkGetPhysicalDeviceQueueFamilyProperties.?(device, &queue_family_count, queue_families.ptr);

        for (queue_families, 0..) |family, i| {
            const supports_graphics = (family.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT) != 0;

            var present_support: vk.VkBool32 = vk.VK_FALSE;
            if (vk.vkGetPhysicalDeviceSurfaceSupportKHR.?(device, @intCast(i), surface, &present_support) != vk.VK_SUCCESS) {
                return error.GetSurfaceSupportFailed;
            }

            if (supports_graphics and present_support == vk.VK_TRUE) {
                return @intCast(i);
            }
        }

        return null;
    }

    fn createDevice(physical_device: vk.VkPhysicalDevice, queue_family_index: u32) !vk.VkDevice {
        const queue_priority: f32 = 1.0;
        const queue_create_info = vk.VkDeviceQueueCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = queue_family_index,
            .queueCount = 1,
            .pQueuePriorities = &queue_priority,
        };

        const device_extensions = [_][*:0]const u8{vk.VK_KHR_SWAPCHAIN_EXTENSION_NAME};

        const create_info = vk.VkDeviceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_create_info,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = device_extensions.len,
            .ppEnabledExtensionNames = &device_extensions,
            .pEnabledFeatures = null,
        };

        var device: vk.VkDevice = undefined;
        const result = vk.vkCreateDevice.?(physical_device, &create_info, null, &device);
        if (result != vk.VK_SUCCESS) {
            return error.DeviceCreationFailed;
        }

        return device;
    }

    fn createSwapchain(self: *VulkanRenderer) !void {
        var capabilities: vk.VkSurfaceCapabilitiesKHR = undefined;
        if (vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR.?(self.physical_device, self.surface, &capabilities) != vk.VK_SUCCESS) {
            return error.GetSurfaceCapabilitiesFailed;
        }

        var format_count: u32 = 0;
        if (vk.vkGetPhysicalDeviceSurfaceFormatsKHR.?(self.physical_device, self.surface, &format_count, null) != vk.VK_SUCCESS) {
            return error.GetSurfaceFormatsFailed;
        }
        var formats = try self.allocator.alloc(vk.VkSurfaceFormatKHR, format_count);
        defer self.allocator.free(formats);
        if (vk.vkGetPhysicalDeviceSurfaceFormatsKHR.?(self.physical_device, self.surface, &format_count, formats.ptr) != vk.VK_SUCCESS) {
            return error.GetSurfaceFormatsFailed;
        }

        const format = formats[0];
        self.swapchain_format = format.format;

        const fb_size = self.window.getFramebufferSize();
        self.swapchain_extent = .{
            .width = std.math.clamp(fb_size.width, capabilities.minImageExtent.width, capabilities.maxImageExtent.width),
            .height = std.math.clamp(fb_size.height, capabilities.minImageExtent.height, capabilities.maxImageExtent.height),
        };

        var image_count = capabilities.minImageCount + 1;
        if (capabilities.maxImageCount > 0 and image_count > capabilities.maxImageCount) {
            image_count = capabilities.maxImageCount;
        }

        const create_info = vk.VkSwapchainCreateInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .pNext = null,
            .flags = 0,
            .surface = self.surface,
            .minImageCount = image_count,
            .imageFormat = format.format,
            .imageColorSpace = format.colorSpace,
            .imageExtent = self.swapchain_extent,
            .imageArrayLayers = 1,
            .imageUsage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .imageSharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .preTransform = capabilities.currentTransform,
            .compositeAlpha = vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = vk.VK_PRESENT_MODE_FIFO_KHR,
            .clipped = vk.VK_TRUE,
            .oldSwapchain = null,
        };

        if (vk.vkCreateSwapchainKHR.?(self.device, &create_info, null, &self.swapchain) != vk.VK_SUCCESS) {
            return error.SwapchainCreationFailed;
        }

        var swapchain_image_count: u32 = 0;
        if (vk.vkGetSwapchainImagesKHR.?(self.device, self.swapchain, &swapchain_image_count, null) != vk.VK_SUCCESS) {
            return error.GetSwapchainImagesFailed;
        }
        try self.swapchain_images.resize(self.allocator, swapchain_image_count);
        if (vk.vkGetSwapchainImagesKHR.?(self.device, self.swapchain, &swapchain_image_count, self.swapchain_images.items.ptr) != vk.VK_SUCCESS) {
            return error.GetSwapchainImagesFailed;
        }

        try self.swapchain_image_views.resize(self.allocator, swapchain_image_count);
        for (self.swapchain_images.items, 0..) |image, i| {
            const view_info = vk.VkImageViewCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .image = image,
                .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
                .format = self.swapchain_format,
                .components = .{
                    .r = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .g = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .b = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .a = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                },
                .subresourceRange = .{
                    .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseMipLevel = 0,
                    .levelCount = 1,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                },
            };

            if (vk.vkCreateImageView.?(self.device, &view_info, null, &self.swapchain_image_views.items[i]) != vk.VK_SUCCESS) {
                return error.ImageViewCreationFailed;
            }
        }

        std.log.info("Swapchain created: {}x{} ({} images)", .{ self.swapchain_extent.width, self.swapchain_extent.height, swapchain_image_count });
    }

    fn cleanupSwapchain(self: *VulkanRenderer) void {
        for (self.swapchain_image_views.items) |view| {
            vk.vkDestroyImageView.?(self.device, view, null);
        }
        self.swapchain_image_views.clearRetainingCapacity();
        self.swapchain_images.clearRetainingCapacity();

        if (self.swapchain != null) {
            vk.vkDestroySwapchainKHR.?(self.device, self.swapchain, null);
        }
    }

    fn initVTable(allocator: std.mem.Allocator, window: *const Window) anyerror!*anyopaque {
        const self = try init(allocator, window);
        return @ptrCast(self);
    }

    fn deinitVTable(ptr: *anyopaque) void {
        const self: *VulkanRenderer = @ptrCast(@alignCast(ptr));
        deinit(self);
    }

    fn beginFrameVTable(ptr: *anyopaque) anyerror!void {
        const self: *VulkanRenderer = @ptrCast(@alignCast(ptr));
        return beginFrame(self);
    }

    fn endFrameVTable(ptr: *anyopaque) anyerror!void {
        const self: *VulkanRenderer = @ptrCast(@alignCast(ptr));
        return endFrame(self);
    }

    fn renderVTable(ptr: *anyopaque) anyerror!void {
        const self: *VulkanRenderer = @ptrCast(@alignCast(ptr));
        return render(self);
    }

    pub const vtable: Renderer.VTable = .{
        .init = initVTable,
        .deinit = deinitVTable,
        .begin_frame = beginFrameVTable,
        .end_frame = endFrameVTable,
        .render = renderVTable,
    };
};
