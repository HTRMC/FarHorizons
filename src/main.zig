const std = @import("std");
const Window = @import("platform/Window.zig").Window;
const Renderer = @import("renderer/Renderer.zig").Renderer;
const VulkanRenderer = @import("renderer/vulkan/VulkanRenderer.zig").VulkanRenderer;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var window = try Window.init(.{
        .width = 1280,
        .height = 720,
        .title = "FarHorizons 0.0.0",
    });
    defer window.deinit();

    var renderer = try Renderer.init(allocator, &window, &VulkanRenderer.vtable);
    defer renderer.deinit();

    std.log.info("Entering main loop...", .{});

    while (!window.shouldClose()) {
        window.pollEvents();

        try renderer.beginFrame();
        try renderer.render();
        try renderer.endFrame();
    }

    std.log.info("Shutting down...", .{});
}
