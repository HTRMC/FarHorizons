const std = @import("std");
const Renderer = @import("../Renderer.zig").Renderer;
const vk = @import("volk").c;

pub const VulkanRenderer = struct {
    allocator: std.mem.Allocator,
    instance: vk.VkInstance,
    physical_device: vk.VkPhysicalDevice,
    device: vk.VkDevice,
    graphics_queue: vk.VkQueue,

    pub fn init(allocator: std.mem.Allocator) !*VulkanRenderer {
        const self = try allocator.create(VulkanRenderer);
        errdefer allocator.destroy(self);

        if (vk.volkInitialize() != vk.VK_SUCCESS) {
            return error.VulkanInitFailed;
        }

        const instance = try createInstance();
        errdefer vk.vkDestroyInstance.?(instance, null);

        vk.volkLoadInstance(instance);

        const physical_device = try selectPhysicalDevice(instance);
        const device = try createDevice(physical_device);
        errdefer vk.vkDestroyDevice.?(device, null);

        vk.volkLoadDevice(device);

        var graphics_queue: vk.VkQueue = undefined;
        vk.vkGetDeviceQueue.?(device, 0, 0, &graphics_queue);

        self.* = .{
            .allocator = allocator,
            .instance = instance,
            .physical_device = physical_device,
            .device = device,
            .graphics_queue = graphics_queue,
        };

        std.log.info("VulkanRenderer initialized", .{});
        return self;
    }

    pub fn deinit(self: *VulkanRenderer) void {
        _ = vk.vkDeviceWaitIdle.?(self.device);
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

        const create_info = vk.VkInstanceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .pApplicationInfo = &app_info,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = 0,
            .ppEnabledExtensionNames = null,
        };

        var instance: vk.VkInstance = undefined;
        const result = vk.vkCreateInstance.?(&create_info, null, &instance);
        if (result != vk.VK_SUCCESS) {
            return error.InstanceCreationFailed;
        }

        return instance;
    }

    fn selectPhysicalDevice(instance: vk.VkInstance) !vk.VkPhysicalDevice {
        var device_count: u32 = 0;
        _ = vk.vkEnumeratePhysicalDevices.?(instance, &device_count, null);

        if (device_count == 0) {
            return error.NoVulkanDevices;
        }

        var devices: [16]vk.VkPhysicalDevice = undefined;
        _ = vk.vkEnumeratePhysicalDevices.?(instance, &device_count, &devices);

        for (devices[0..device_count]) |device| {
            var props: vk.VkPhysicalDeviceProperties = undefined;
            vk.vkGetPhysicalDeviceProperties.?(device, &props);
            std.log.info("Found GPU: {s}", .{props.deviceName});
            return device;
        }

        return error.NoSuitableDevice;
    }

    fn createDevice(physical_device: vk.VkPhysicalDevice) !vk.VkDevice {
        const queue_priority: f32 = 1.0;
        const queue_create_info = vk.VkDeviceQueueCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = 0,
            .queueCount = 1,
            .pQueuePriorities = &queue_priority,
        };

        const create_info = vk.VkDeviceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_create_info,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = 0,
            .ppEnabledExtensionNames = null,
            .pEnabledFeatures = null,
        };

        var device: vk.VkDevice = undefined;
        const result = vk.vkCreateDevice.?(physical_device, &create_info, null, &device);
        if (result != vk.VK_SUCCESS) {
            return error.DeviceCreationFailed;
        }

        return device;
    }

    fn initVTable(allocator: std.mem.Allocator) anyerror!*anyopaque {
        const self = try init(allocator);
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
