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
        exe.root_module.linkSystemLibrary("ws2_32", .{}); // Networking (UDP sockets)
        if (tracy_enabled) {
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
    const zstd_enabled = b.option(bool, "zstd", "Enable ZSTD compression") orelse true;
    const steam_enabled = b.option(bool, "steam", "Enable Steam integration") orelse true;
    const console_enabled = b.option(bool, "console", "Show console window on Windows") orelse false;
    const gamepad_type = b.option([]const u8, "gamepad_type", "Force gamepad HUD type: xbox, playstation, nintendo") orelse null;

    const options = b.addOptions();
    options.addOption(bool, "tracy_enabled", tracy_enabled);
    options.addOption(bool, "zstd_enabled", zstd_enabled);
    options.addOption(bool, "steam_enabled", steam_enabled);
    options.addOption(?[]const u8, "gamepad_type", gamepad_type);
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

    const os_tag = exe.root_module.resolved_target.?.result.os.tag;

    // Steam: link import library and install runtime DLL/SO
    if (steam_enabled) {
        if (os_tag == .windows) {
            exe.root_module.addObjectFile(b.path("lib/steam/win64/steam_api64.lib"));
        } else if (os_tag == .linux) {
            exe.root_module.addLibraryPath(b.path("lib/steam/linux64"));
            exe.root_module.addRPath(.{ .src_path = .{ .owner = b, .sub_path = "lib/steam/linux64" } });
            exe.root_module.linkSystemLibrary("steam_api", .{});
        }
    }

    // Embed the application icon on Windows
    exe.root_module.addWin32ResourceFile(.{ .file = b.path("assets/icon.rc") });

    // Hide the console window on Windows unless -Dconsole=true
    if (os_tag == .windows and !console_enabled) {
        exe.subsystem = .windows;
    }

    b.installArtifact(exe);

    // Install assets next to the executable
    b.installDirectory(.{
        .source_dir = b.path("assets/farhorizons"),
        .install_dir = .{ .custom = "bin/assets/farhorizons" },
        .install_subdir = "",
    });

    // Install Steam runtime library next to the executable
    if (steam_enabled) {
        if (os_tag == .windows) {
            b.installFile("lib/steam/win64/steam_api64.dll", "bin/steam_api64.dll");
        } else if (os_tag == .linux) {
            b.installFile("lib/steam/linux64/libsteam_api.so", "bin/libsteam_api.so");
        }
        b.installFile("steam_appid.txt", "bin/steam_appid.txt");
    }

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
