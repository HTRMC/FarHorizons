const std = @import("std");

fn libName(b: *std.Build, name: []const u8) []const u8 {
    return b.fmt("lib{s}.a", .{name});
}

fn linkDependencies(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const target = exe.root_module.resolved_target.?;
    const t = target.result;

    exe.root_module.link_libc = true;
    exe.root_module.link_libcpp = true;

    const deps_name = b.fmt("farhorizons_deps_{s}-{s}-{s}", .{
        @tagName(t.cpu.arch),
        @tagName(t.os.tag),
        @tagName(t.abi),
    });

    const headers_dep = b.lazyDependency("farhorizons_deps_headers", .{}) orelse {
        std.log.info("Downloading headers...", .{});
        return;
    };
    exe.root_module.addIncludePath(headers_dep.path(""));

    const lib_dep = b.lazyDependency(deps_name, .{}) orelse {
        std.log.info("Downloading {s}...", .{deps_name});
        return;
    };
    exe.root_module.addObjectFile(lib_dep.path(libName(b, "glfw")));
    exe.root_module.addObjectFile(lib_dep.path(libName(b, "volk")));
    exe.root_module.addObjectFile(lib_dep.path(libName(b, "stb_image")));
    exe.root_module.addObjectFile(lib_dep.path(libName(b, "shaderc_combined")));
    exe.root_module.addObjectFile(lib_dep.path(libName(b, "FastNoise")));

    if (t.os.tag == .windows) {
        exe.root_module.linkSystemLibrary("gdi32", .{});
        exe.root_module.linkSystemLibrary("user32", .{});
        exe.root_module.linkSystemLibrary("shell32", .{});
        exe.root_module.linkSystemLibrary("opengl32", .{});
        exe.root_module.linkSystemLibrary("dwmapi", .{});
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "FarHorizons",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const zlm_dep = b.dependency("zlm", .{});
    exe.root_module.addImport("zlm", zlm_dep.module("zlm"));

    linkDependencies(b, exe);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
