const std = @import("std");
const Renderer = @import("../Renderer.zig").Renderer;
const vk = @import("../../platform/volk.zig");
const Window = @import("../../platform/Window.zig").Window;

const enable_validation_layers = @import("builtin").mode == .Debug;
const validation_layers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};

fn debugCallback(
    message_severity: vk.VkDebugUtilsMessageSeverityFlagBitsEXT,
    message_type: vk.VkDebugUtilsMessageTypeFlagsEXT,
    callback_data: ?*const vk.VkDebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque,
) callconv(.c) vk.VkBool32 {
    _ = message_type;
    _ = user_data;

    const data = callback_data orelse return vk.VK_FALSE;
    const message = std.mem.span(data.pMessage);

    if (message_severity >= vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) {
        std.log.err("[Vulkan] {s}", .{message});
    } else if (message_severity >= vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) {
        std.log.warn("[Vulkan] {s}", .{message});
    } else if (message_severity >= vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT) {
        std.log.info("[Vulkan] {s}", .{message});
    } else {
        std.log.debug("[Vulkan] {s}", .{message});
    }

    return vk.VK_FALSE;
}

pub const VulkanRenderer = struct {
    allocator: std.mem.Allocator,
    window: *const Window,
    instance: vk.VkInstance,
    debug_messenger: ?vk.VkDebugUtilsMessengerEXT,
    validation_enabled: bool,
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
    render_pass: vk.VkRenderPass,
    framebuffers: std.ArrayList(vk.VkFramebuffer),

    pub fn init(allocator: std.mem.Allocator, window: *const Window) !*VulkanRenderer {
        const self = try allocator.create(VulkanRenderer);
        errdefer allocator.destroy(self);

        try vk.initialize();

        const instance_result = try createInstance();
        const instance = instance_result.instance;
        const validation_enabled = instance_result.validation_enabled;
        errdefer vk.destroyInstance(instance, null);

        vk.loadInstance(instance);

        const debug_messenger = if (validation_enabled)
            try createDebugMessenger(instance)
        else
            null;
        errdefer if (validation_enabled) vk.destroyDebugUtilsMessengerEXT(instance, debug_messenger.?, null);

        const surface = try window.createSurface(instance, null);
        errdefer vk.destroySurfaceKHR(instance, surface, null);

        const device_info = try selectPhysicalDevice(allocator, instance, surface);
        const device = try createDevice(device_info.physical_device, device_info.queue_family_index);
        errdefer vk.destroyDevice(device, null);

        vk.loadDevice(device);

        var graphics_queue: vk.VkQueue = undefined;
        vk.getDeviceQueue(device, device_info.queue_family_index, 0, &graphics_queue);

        const swapchain_images: std.ArrayList(vk.VkImage) = .empty;
        const swapchain_image_views: std.ArrayList(vk.VkImageView) = .empty;
        const framebuffers: std.ArrayList(vk.VkFramebuffer) = .empty;

        self.* = .{
            .allocator = allocator,
            .window = window,
            .instance = instance,
            .debug_messenger = debug_messenger,
            .validation_enabled = validation_enabled,
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
            .render_pass = null,
            .framebuffers = framebuffers,
        };

        try self.createSwapchain();

        std.log.info("VulkanRenderer initialized", .{});
        return self;
    }

    pub fn deinit(self: *VulkanRenderer) void {
        vk.deviceWaitIdle(self.device) catch |err| {
            std.log.err("vkDeviceWaitIdle failed: {}", .{err});
        };

        self.cleanupSwapchain();
        self.swapchain_images.deinit(self.allocator);
        self.swapchain_image_views.deinit(self.allocator);
        self.framebuffers.deinit(self.allocator);

        vk.destroyRenderPass(self.device, self.render_pass, null);
        vk.destroySurfaceKHR(self.instance, self.surface, null);
        vk.destroyDevice(self.device, null);

        if (self.debug_messenger) |messenger| {
            vk.destroyDebugUtilsMessengerEXT(self.instance, messenger, null);
        }

        vk.destroyInstance(self.instance, null);
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

    const InstanceResult = struct {
        instance: vk.VkInstance,
        validation_enabled: bool,
    };

    fn createInstance() !InstanceResult {
        const app_info = vk.VkApplicationInfo{
            .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pNext = null,
            .pApplicationName = "FarHorizons",
            .applicationVersion = vk.VK_MAKE_VERSION(0, 0, 1),
            .pEngineName = "FarHorizons Engine",
            .engineVersion = vk.VK_MAKE_VERSION(0, 0, 1),
            .apiVersion = vk.VK_API_VERSION_1_2,
        };

        const window_extensions = Window.getRequiredExtensions();

        // Add debug utils extension in debug builds
        var extensions: [16][*:0]const u8 = undefined;
        var extension_count: u32 = 0;

        for (window_extensions.names[0..window_extensions.count]) |ext| {
            extensions[extension_count] = ext;
            extension_count += 1;
        }

        if (enable_validation_layers) {
            extensions[extension_count] = vk.VK_EXT_DEBUG_UTILS_EXTENSION_NAME;
            extension_count += 1;
        }

        const create_info = vk.VkInstanceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .pApplicationInfo = &app_info,
            .enabledLayerCount = if (enable_validation_layers) validation_layers.len else 0,
            .ppEnabledLayerNames = if (enable_validation_layers) &validation_layers else null,
            .enabledExtensionCount = extension_count,
            .ppEnabledExtensionNames = &extensions,
        };

        // Try to create instance with validation layers
        if (enable_validation_layers) {
            if (vk.createInstance(&create_info, null)) |instance| {
                return .{ .instance = instance, .validation_enabled = true };
            } else |err| {
                if (err == error.LayerNotPresent) {
                    std.log.warn("Validation layers requested but not available, continuing without them", .{});
                    // Retry without validation layers
                    const create_info_no_validation = vk.VkInstanceCreateInfo{
                        .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
                        .pNext = null,
                        .flags = 0,
                        .pApplicationInfo = &app_info,
                        .enabledLayerCount = 0,
                        .ppEnabledLayerNames = null,
                        .enabledExtensionCount = window_extensions.count,
                        .ppEnabledExtensionNames = window_extensions.names,
                    };
                    const instance = try vk.createInstance(&create_info_no_validation, null);
                    return .{ .instance = instance, .validation_enabled = false };
                }
                return err;
            }
        }

        const instance = try vk.createInstance(&create_info, null);
        return .{ .instance = instance, .validation_enabled = false };
    }

    const DeviceInfo = struct {
        physical_device: vk.VkPhysicalDevice,
        queue_family_index: u32,
    };

    fn selectPhysicalDevice(allocator: std.mem.Allocator, instance: vk.VkInstance, surface: vk.VkSurfaceKHR) !DeviceInfo {
        var device_count: u32 = 0;
        try vk.enumeratePhysicalDevices(instance, &device_count, null);

        if (device_count == 0) {
            return error.NoVulkanDevices;
        }

        var devices: [16]vk.VkPhysicalDevice = undefined;
        try vk.enumeratePhysicalDevices(instance, &device_count, &devices);

        for (devices[0..device_count]) |device| {
            var props: vk.VkPhysicalDeviceProperties = undefined;
            try vk.getPhysicalDeviceProperties(device, &props);
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
        try vk.getPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, null);

        var queue_families = try allocator.alloc(vk.VkQueueFamilyProperties, queue_family_count);
        defer allocator.free(queue_families);

        try vk.getPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, queue_families.ptr);

        for (queue_families, 0..) |family, i| {
            const supports_graphics = (family.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT) != 0;

            var present_support: vk.VkBool32 = vk.VK_FALSE;
            try vk.getPhysicalDeviceSurfaceSupportKHR(device, @intCast(i), surface, &present_support);

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

        return try vk.createDevice(physical_device, &create_info, null);
    }

    fn createRenderPass(self: *VulkanRenderer) !void {
        const color_attachment = vk.VkAttachmentDescription{
            .flags = 0,
            .format = self.swapchain_format,
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        };

        const color_attachment_ref = vk.VkAttachmentReference{
            .attachment = 0,
            .layout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };

        const subpass = vk.VkSubpassDescription{
            .flags = 0,
            .pipelineBindPoint = vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            .inputAttachmentCount = 0,
            .pInputAttachments = null,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_attachment_ref,
            .pResolveAttachments = null,
            .pDepthStencilAttachment = null,
            .preserveAttachmentCount = 0,
            .pPreserveAttachments = null,
        };

        const dependency = vk.VkSubpassDependency{
            .srcSubpass = vk.VK_SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .srcAccessMask = 0,
            .dstAccessMask = vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dependencyFlags = 0,
        };

        const render_pass_info = vk.VkRenderPassCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .attachmentCount = 1,
            .pAttachments = &color_attachment,
            .subpassCount = 1,
            .pSubpasses = &subpass,
            .dependencyCount = 1,
            .pDependencies = &dependency,
        };

        self.render_pass = try vk.createRenderPass(self.device, &render_pass_info, null);
        std.log.info("Render pass created", .{});
    }

    fn createSwapchain(self: *VulkanRenderer) !void {
        var capabilities: vk.VkSurfaceCapabilitiesKHR = undefined;
        try vk.getPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, self.surface, &capabilities);

        var format_count: u32 = 0;
        try vk.getPhysicalDeviceSurfaceFormatsKHR(self.physical_device, self.surface, &format_count, null);
        var formats = try self.allocator.alloc(vk.VkSurfaceFormatKHR, format_count);
        defer self.allocator.free(formats);
        try vk.getPhysicalDeviceSurfaceFormatsKHR(self.physical_device, self.surface, &format_count, formats.ptr);

        const format = formats[0];
        self.swapchain_format = format.format;

        // Create render pass first now that we know the format
        if (self.render_pass == null) {
            try self.createRenderPass();
        }

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

        self.swapchain = try vk.createSwapchainKHR(self.device, &create_info, null);

        var swapchain_image_count: u32 = 0;
        try vk.getSwapchainImagesKHR(self.device, self.swapchain, &swapchain_image_count, null);
        try self.swapchain_images.resize(self.allocator, swapchain_image_count);
        try vk.getSwapchainImagesKHR(self.device, self.swapchain, &swapchain_image_count, self.swapchain_images.items.ptr);

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

            self.swapchain_image_views.items[i] = try vk.createImageView(self.device, &view_info, null);
        }

        // Create framebuffers
        try self.framebuffers.resize(self.allocator, swapchain_image_count);
        for (self.swapchain_image_views.items, 0..) |image_view, i| {
            const attachments = [_]vk.VkImageView{image_view};

            const framebuffer_info = vk.VkFramebufferCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .renderPass = self.render_pass,
                .attachmentCount = attachments.len,
                .pAttachments = &attachments,
                .width = self.swapchain_extent.width,
                .height = self.swapchain_extent.height,
                .layers = 1,
            };

            self.framebuffers.items[i] = try vk.createFramebuffer(self.device, &framebuffer_info, null);
        }

        std.log.info("Swapchain created: {}x{} ({} images)", .{ self.swapchain_extent.width, self.swapchain_extent.height, swapchain_image_count });
    }

    fn cleanupSwapchain(self: *VulkanRenderer) void {
        for (self.framebuffers.items) |framebuffer| {
            vk.destroyFramebuffer(self.device, framebuffer, null);
        }
        self.framebuffers.clearRetainingCapacity();

        for (self.swapchain_image_views.items) |view| {
            vk.destroyImageView(self.device, view, null);
        }
        self.swapchain_image_views.clearRetainingCapacity();
        self.swapchain_images.clearRetainingCapacity();

        if (self.swapchain != null) {
            vk.destroySwapchainKHR(self.device, self.swapchain, null);
        }
    }

    fn createDebugMessenger(instance: vk.VkInstance) !vk.VkDebugUtilsMessengerEXT {
        const create_info = vk.VkDebugUtilsMessengerCreateInfoEXT{
            .sType = vk.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            .pNext = null,
            .flags = 0,
            .messageSeverity = vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT |
                vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT |
                vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
            .messageType = vk.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                vk.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                vk.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
            .pfnUserCallback = debugCallback,
            .pUserData = null,
        };

        return try vk.createDebugUtilsMessengerEXT(instance, &create_info, null);
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
