const std = @import("std");
const vk = @import("../../platform/volk.zig");
const ShaderCompiler = @import("ShaderCompiler.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const tracy = @import("../../platform/tracy.zig");
pub const WorldRenderer = @import("WorldRenderer.zig").WorldRenderer;
pub const DebugRenderer = @import("DebugRenderer.zig").DebugRenderer;

pub const MAX_FRAMES_IN_FLIGHT = 2;

pub const RenderState = struct {
    world_renderer: WorldRenderer,
    debug_renderer: DebugRenderer,
    // Command buffers and sync
    command_buffers: [MAX_FRAMES_IN_FLIGHT]vk.VkCommandBuffer,
    image_available_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.VkSemaphore,
    in_flight_fences: [MAX_FRAMES_IN_FLIGHT]vk.VkFence,
    current_frame: u32,

    pub fn create(allocator: std.mem.Allocator, ctx: *const VulkanContext, swapchain_format: vk.VkFormat) !RenderState {
        const create_zone = tracy.zone(@src(), "RenderState.create");
        defer create_zone.end();

        var shader_compiler = try ShaderCompiler.init(allocator);
        defer shader_compiler.deinit();

        var world_renderer = try WorldRenderer.init(allocator, &shader_compiler, ctx, swapchain_format);
        errdefer world_renderer.deinit(ctx.device);

        var debug_renderer = try DebugRenderer.init(&shader_compiler, ctx, swapchain_format);
        errdefer debug_renderer.deinit(ctx.device);

        var self = RenderState{
            .world_renderer = world_renderer,
            .debug_renderer = debug_renderer,
            .command_buffers = [_]vk.VkCommandBuffer{null} ** MAX_FRAMES_IN_FLIGHT,
            .image_available_semaphores = [_]vk.VkSemaphore{null} ** MAX_FRAMES_IN_FLIGHT,
            .in_flight_fences = [_]vk.VkFence{null} ** MAX_FRAMES_IN_FLIGHT,
            .current_frame = 0,
        };

        try self.createCommandBuffers(ctx);
        try self.createSyncObjects(ctx.device);

        return self;
    }

    pub fn deinit(self: *RenderState, device: vk.VkDevice) void {
        const tz = tracy.zone(@src(), "RenderState.deinit");
        defer tz.end();

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            vk.destroySemaphore(device, self.image_available_semaphores[i], null);
            vk.destroyFence(device, self.in_flight_fences[i], null);
        }

        self.world_renderer.deinit(device);
        self.debug_renderer.deinit(device);
    }

    fn createCommandBuffers(self: *RenderState, ctx: *const VulkanContext) !void {
        const tz = tracy.zone(@src(), "createCommandBuffers");
        defer tz.end();

        const alloc_info = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = ctx.command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = MAX_FRAMES_IN_FLIGHT,
        };

        try vk.allocateCommandBuffers(ctx.device, &alloc_info, &self.command_buffers);
        std.log.info("Command buffers allocated ({} frames in flight)", .{MAX_FRAMES_IN_FLIGHT});
    }

    fn createSyncObjects(self: *RenderState, device: vk.VkDevice) !void {
        const tz = tracy.zone(@src(), "createSyncObjects");
        defer tz.end();

        const semaphore_info = vk.VkSemaphoreCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
        };

        const fence_info = vk.VkFenceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .pNext = null,
            .flags = vk.VK_FENCE_CREATE_SIGNALED_BIT,
        };

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            self.image_available_semaphores[i] = try vk.createSemaphore(device, &semaphore_info, null);
            self.in_flight_fences[i] = try vk.createFence(device, &fence_info, null);
        }

        std.log.info("Synchronization objects created", .{});
    }
};
