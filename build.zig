const std = @import("std");

fn libName(b: *std.Build, name: []const u8) []const u8 {
    return b.fmt("lib{s}.a", .{name});
}

fn linkDependencies(b: *std.Build, exe: *std.Build.Step.Compile, tracy_enabled: bool) void {
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

    if (tracy_enabled) {
        exe.root_module.addObjectFile(lib_dep.path(libName(b, "tracy")));
    }

    if (t.os.tag == .windows) {
        exe.root_module.linkSystemLibrary("gdi32", .{});
        exe.root_module.linkSystemLibrary("user32", .{});
        exe.root_module.linkSystemLibrary("shell32", .{});
        exe.root_module.linkSystemLibrary("opengl32", .{});
        exe.root_module.linkSystemLibrary("dwmapi", .{});
        if (tracy_enabled) {
            exe.root_module.linkSystemLibrary("ws2_32", .{});
            exe.root_module.linkSystemLibrary("dbghelp", .{});
        }
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

    const tracy_enabled = b.option(bool, "tracy", "Enable Tracy profiling") orelse false;
    const zstd_enabled = b.option(bool, "zstd", "Enable ZSTD compression (requires lib/zstd/ source)") orelse false;

    const options = b.addOptions();
    options.addOption(bool, "tracy_enabled", tracy_enabled);
    options.addOption(bool, "zstd_enabled", zstd_enabled);
    exe.root_module.addOptions("build_options", options);

    linkDependencies(b, exe, tracy_enabled);

    // ZSTD: compile the amalgamation source if enabled
    if (zstd_enabled) {
        exe.root_module.addIncludePath(b.path("lib/zstd"));
        exe.root_module.addCSourceFile(.{
            .file = b.path("lib/zstd/zstd.c"),
            .flags = &.{ "-DZSTD_DISABLE_ASM", "-DXXH_NAMESPACE=ZSTD_" },
        });
    }

    b.installArtifact(exe);

    // Deploy assets to app data directory
    const deploy_assets = blk: {
        const host_os = @import("builtin").os.tag;
        if (host_os == .windows) {
            const appdata = b.graph.environ_map.get("APPDATA") orelse @panic("APPDATA not set");
            const deploy_dest = b.fmt("{s}\\FarHorizons\\assets", .{appdata});
            const robocopy_cmd = b.fmt("robocopy assets {s} /E /MIR /NJH /NJS /NP /NFL /NDL & if %errorlevel% leq 7 exit /b 0", .{deploy_dest});
            break :blk b.addSystemCommand(&.{ "cmd", "/c", robocopy_cmd });
        } else {
            const xdg = b.graph.environ_map.get("XDG_DATA_HOME");
            const home = b.graph.environ_map.get("HOME") orelse @panic("HOME not set");
            const deploy_dest = if (xdg) |x|
                b.fmt("{s}/farhorizons/assets/", .{x})
            else
                b.fmt("{s}/.local/share/farhorizons/assets/", .{home});
            const mkdir_cmd = b.fmt("mkdir -p {s}", .{deploy_dest});
            const rsync_cmd = b.fmt("{s} && rsync -a --delete assets/ {s}", .{ mkdir_cmd, deploy_dest });
            break :blk b.addSystemCommand(&.{ "sh", "-c", rsync_cmd });
        }
    };
    b.getInstallStep().dependOn(&deploy_assets.step);

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
