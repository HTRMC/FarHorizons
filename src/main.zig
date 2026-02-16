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

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
