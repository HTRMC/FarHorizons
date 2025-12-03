

const std = @import("std");

fn libName(b: *std.Build, name: []const u8) []const u8 {
    // We always build with mingw-style naming (libXXX.a)
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
        .root_source_file = b.path("src/shared/shared.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Get headers dependency for include path
    const headers_dep = b.lazyDependency("farhorizons_deps_headers", .{});

    // Create GLFW Zig bindings module
    const glfw_module = b.createModule(.{
        .root_source_file = b.path("src/client/glfw.zig"),
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

    const exe = b.addExecutable(.{
        .name = "FarHorizons",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared_module },
                .{ .name = "glfw", .module = glfw_module },
                .{ .name = "volk", .module = volk_module },
            },
        }),
    });

    linkDependencies(b, exe);
    b.installArtifact(exe);

    // Server executable (no GLFW needed)
    const server_exe = b.addExecutable(.{
        .name = "FarHorizons-Server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared_module },
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
            .root_source_file = b.path("src/client/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
