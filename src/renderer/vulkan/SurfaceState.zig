const std = @import("std");
const vk = @import("../../platform/volk.zig");
const Window = @import("../../platform/Window.zig").Window;
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const vk_utils = @import("vk_utils.zig");
const tracy = @import("../../platform/tracy.zig");

pub const SurfaceState = struct {
    swapchain: vk.VkSwapchainKHR,
    swapchain_images: std.ArrayList(vk.VkImage),
    swapchain_image_views: std.ArrayList(vk.VkImageView),
    swapchain_format: vk.VkFormat,
    swapchain_extent: vk.VkExtent2D,
    depth_image: vk.VkImage,
    depth_image_memory: vk.VkDeviceMemory,
    depth_image_view: vk.VkImageView,
    render_finished_semaphores: std.ArrayList(vk.VkSemaphore),
    images_in_flight: std.ArrayList(?vk.VkFence),

    pub fn create(allocator: std.mem.Allocator, ctx: *const VulkanContext, surface: vk.VkSurfaceKHR, window: *const Window) !SurfaceState {
        const tz = tracy.zone(@src(), "SurfaceState.create");
        defer tz.end();

        var self = SurfaceState{
            .swapchain = null,
            .swapchain_images = .empty,
            .swapchain_image_views = .empty,
            .swapchain_format = vk.VK_FORMAT_UNDEFINED,
            .swapchain_extent = .{ .width = 0, .height = 0 },
            .depth_image = null,
            .depth_image_memory = null,
            .depth_image_view = null,
            .render_finished_semaphores = .empty,
            .images_in_flight = .empty,
        };

        try self.createSwapchain(allocator, ctx, surface, window);
        try self.createDepthBuffer(ctx);

        return self;
    }

    pub fn deinit(self: *SurfaceState, allocator: std.mem.Allocator, device: vk.VkDevice) void {
        const tz = tracy.zone(@src(), "SurfaceState.deinit");
        defer tz.end();

        for (self.render_finished_semaphores.items) |semaphore| {
            vk.destroySemaphore(device, semaphore, null);
        }
        self.render_finished_semaphores.deinit(allocator);

        self.cleanupSwapchain(device);
        self.swapchain_images.deinit(allocator);
        self.swapchain_image_views.deinit(allocator);
        self.images_in_flight.deinit(allocator);

        vk.destroyImageView(device, self.depth_image_view, null);
        vk.destroyImage(device, self.depth_image, null);
        vk.freeMemory(device, self.depth_image_memory, null);
    }

    pub fn createSwapchain(self: *SurfaceState, allocator: std.mem.Allocator, ctx: *const VulkanContext, surface: vk.VkSurfaceKHR, window: *const Window) !void {
        const tz = tracy.zone(@src(), "createSwapchain");
        defer tz.end();

        var capabilities: vk.VkSurfaceCapabilitiesKHR = undefined;
        try vk.getPhysicalDeviceSurfaceCapabilitiesKHR(ctx.physical_device, surface, &capabilities);

        var format_count: u32 = 0;
        try vk.getPhysicalDeviceSurfaceFormatsKHR(ctx.physical_device, surface, &format_count, null);
        var formats = try allocator.alloc(vk.VkSurfaceFormatKHR, format_count);
        defer allocator.free(formats);
        try vk.getPhysicalDeviceSurfaceFormatsKHR(ctx.physical_device, surface, &format_count, formats.ptr);

        const format = formats[0];
        self.swapchain_format = format.format;

        const fb_size = window.getFramebufferSize();
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
            .surface = surface,
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

        self.swapchain = try vk.createSwapchainKHR(ctx.device, &create_info, null);

        var swapchain_image_count: u32 = 0;
        try vk.getSwapchainImagesKHR(ctx.device, self.swapchain, &swapchain_image_count, null);
        try self.swapchain_images.resize(allocator, swapchain_image_count);
        try vk.getSwapchainImagesKHR(ctx.device, self.swapchain, &swapchain_image_count, self.swapchain_images.items.ptr);

        try self.swapchain_image_views.resize(allocator, swapchain_image_count);
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

            self.swapchain_image_views.items[i] = try vk.createImageView(ctx.device, &view_info, null);
        }

        try self.images_in_flight.resize(allocator, swapchain_image_count);
        for (0..swapchain_image_count) |i| {
            self.images_in_flight.items[i] = null;
        }

        const semaphore_info = vk.VkSemaphoreCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
        };

        const old_semaphore_count = self.render_finished_semaphores.items.len;
        if (swapchain_image_count < old_semaphore_count) {
            for (self.render_finished_semaphores.items[swapchain_image_count..]) |sem| {
                vk.destroySemaphore(ctx.device, sem, null);
            }
        }
        try self.render_finished_semaphores.resize(allocator, swapchain_image_count);
        for (old_semaphore_count..swapchain_image_count) |i| {
            self.render_finished_semaphores.items[i] = try vk.createSemaphore(ctx.device, &semaphore_info, null);
        }

        std.log.info("Swapchain created: {}x{} ({} images)", .{ self.swapchain_extent.width, self.swapchain_extent.height, swapchain_image_count });
    }

    pub fn cleanupSwapchain(self: *SurfaceState, device: vk.VkDevice) void {
        const tz = tracy.zone(@src(), "cleanupSwapchain");
        defer tz.end();

        for (self.swapchain_image_views.items) |view| {
            vk.destroyImageView(device, view, null);
        }
        self.swapchain_image_views.clearRetainingCapacity();
        self.swapchain_images.clearRetainingCapacity();
        self.images_in_flight.clearRetainingCapacity();

        if (self.swapchain != null) {
            vk.destroySwapchainKHR(device, self.swapchain, null);
        }
    }

    pub fn createDepthBuffer(self: *SurfaceState, ctx: *const VulkanContext) !void {
        const tz = tracy.zone(@src(), "createDepthBuffer");
        defer tz.end();

        const image_info = vk.VkImageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = vk.VK_IMAGE_TYPE_2D,
            .format = vk.VK_FORMAT_D32_SFLOAT,
            .extent = .{
                .width = self.swapchain_extent.width,
                .height = self.swapchain_extent.height,
                .depth = 1,
            },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
            .usage = vk.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | vk.VK_IMAGE_USAGE_SAMPLED_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        };

        self.depth_image = try vk.createImage(ctx.device, &image_info, null);
        errdefer vk.destroyImage(ctx.device, self.depth_image, null);

        var mem_requirements: vk.VkMemoryRequirements = undefined;
        vk.getImageMemoryRequirements(ctx.device, self.depth_image, &mem_requirements);

        const memory_type_index = try vk_utils.findMemoryType(
            ctx.physical_device,
            mem_requirements.memoryTypeBits,
            vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        );

        const alloc_info = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = mem_requirements.size,
            .memoryTypeIndex = memory_type_index,
        };

        self.depth_image_memory = try vk.allocateMemory(ctx.device, &alloc_info, null);
        errdefer vk.freeMemory(ctx.device, self.depth_image_memory, null);
        try vk.bindImageMemory(ctx.device, self.depth_image, self.depth_image_memory, 0);

        const view_info = vk.VkImageViewCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = self.depth_image,
            .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
            .format = vk.VK_FORMAT_D32_SFLOAT,
            .components = .{
                .r = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_DEPTH_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        self.depth_image_view = try vk.createImageView(ctx.device, &view_info, null);
    }
};
