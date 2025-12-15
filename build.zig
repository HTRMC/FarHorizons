

const std = @import("std");

fn libName(b: *std.Build, name: []const u8) []const u8 {
    // All libraries use mingw-style naming (lib*.a)
    return b.fmt("lib{s}.a", .{name});
}

fn linkDependencies(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const target = exe.root_module.resolved_target.?;
    const t = target.result;

    exe.linkLibC();

    const deps_name = b.fmt("farhorizons_deps_{s}-{s}-{s}", .{
        @tagName(t.cpu.arch),
        @tagName(t.os.tag),
        @tagName(t.abi),
    });

    // Get headers dependency
    const headers_dep = b.lazyDependency("farhorizons_deps_headers", .{}) orelse {
        std.log.info("Downloading headers...", .{});
        return;
    };
    exe.addIncludePath(headers_dep.path(""));

    // Get platform-specific library dependency
    const lib_dep = b.lazyDependency(deps_name, .{}) orelse {
        std.log.info("Downloading {s}...", .{deps_name});
        return;
    };
    exe.addObjectFile(lib_dep.path(libName(b, "glfw")));
    exe.addObjectFile(lib_dep.path(libName(b, "volk")));
    exe.addObjectFile(lib_dep.path(libName(b, "stb_image")));
    exe.addObjectFile(lib_dep.path(libName(b, "shaderc_combined")));

    // shaderc requires C++ standard library
    exe.linkLibCpp();

    // Link system libraries (GLFW loads X11 dynamically on Linux)
    if (t.os.tag == .windows) {
        exe.linkSystemLibrary("gdi32");
        exe.linkSystemLibrary("user32");
        exe.linkSystemLibrary("shell32");
        exe.linkSystemLibrary("opengl32");
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Shared module used by both client and server
    const shared_module = b.createModule(.{
        .root_source_file = b.path("src/shared/Shared.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Get headers dependency for include path
    const headers_dep = b.lazyDependency("farhorizons_deps_headers", .{});

    // Create GLFW Zig bindings module
    const glfw_module = b.createModule(.{
        .root_source_file = b.path("src/client/GLFW.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (headers_dep) |d| {
        glfw_module.addIncludePath(d.path(""));
    }

    // Create Volk Zig bindings module
    const volk_module = b.createModule(.{
        .root_source_file = b.path("src/client/volk.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (headers_dep) |d| {
        volk_module.addIncludePath(d.path(""));
    }

    // Create stb_image Zig bindings module
    const stb_image_module = b.createModule(.{
        .root_source_file = b.path("src/client/stb_image.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (headers_dep) |d| {
        stb_image_module.addIncludePath(d.path(""));
    }

    // Create shaderc Zig bindings module
    const shaderc_module = b.createModule(.{
        .root_source_file = b.path("src/client/shaderc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (headers_dep) |d| {
        shaderc_module.addIncludePath(d.path(""));
    }

    // Create Platform module (window management)
    const platform_module = b.createModule(.{
        .root_source_file = b.path("src/client/platform/Platform.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "GLFW", .module = glfw_module },
            .{ .name = "Shared", .module = shared_module },
        },
    });

    // Create Renderer module (Vulkan rendering)
    const renderer_module = b.createModule(.{
        .root_source_file = b.path("src/client/renderer/Renderer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "volk", .module = volk_module },
            .{ .name = "Shared", .module = shared_module },
            .{ .name = "Platform", .module = platform_module },
            .{ .name = "stb_image", .module = stb_image_module },
            .{ .name = "shaderc", .module = shaderc_module },
        },
    });

    // Create World module (chunk management)
    const world_module = b.createModule(.{
        .root_source_file = b.path("src/client/world/world.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "Shared", .module = shared_module },
            .{ .name = "Renderer", .module = renderer_module },
            .{ .name = "volk", .module = volk_module },
        },
    });

    const exe = b.addExecutable(.{
        .name = "FarHorizons",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "Shared", .module = shared_module },
                .{ .name = "GLFW", .module = glfw_module },
                .{ .name = "volk", .module = volk_module },
                .{ .name = "Platform", .module = platform_module },
                .{ .name = "Renderer", .module = renderer_module },
                .{ .name = "World", .module = world_module },
                .{ .name = "stb_image", .module = stb_image_module },
            },
        }),
    });

    linkDependencies(b, exe);
    b.installArtifact(exe);

    // Server executable (no GLFW needed)
    const server_exe = b.addExecutable(.{
        .name = "FarHorizons-Server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/Main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "Shared", .module = shared_module },
            },
        }),
    });
    b.installArtifact(server_exe);

    // Run server step
    const run_server_step = b.step("server", "Run the chat server");
    const run_server_cmd = b.addRunArtifact(server_exe);
    run_server_step.dependOn(&run_server_cmd.step);
    run_server_cmd.step.dependOn(b.getInstallStep());

    // Run client step
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Tests
    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client/Main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
