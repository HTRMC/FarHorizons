const std = @import("std");
const builtin = @import("builtin");
const tracy = @import("platform/tracy.zig");

const Io = std.Io;
const Dir = Io.Dir;

const sep = std.fs.path.sep_str;

const c_time = if (builtin.os.tag == .windows) struct {
    const Tm = extern struct {
        tm_sec: c_int,
        tm_min: c_int,
        tm_hour: c_int,
        tm_mday: c_int,
        tm_mon: c_int,
        tm_year: c_int,
        tm_wday: c_int,
        tm_yday: c_int,
        tm_isdst: c_int,
    };
    extern "c" fn time(timer: ?*i64) i64;
    extern "c" fn _localtime64_s(result: *Tm, timer: *const i64) c_int;

    fn localtime(timer: *const i64, result: *Tm) ?*const Tm {
        return if (_localtime64_s(result, timer) == 0) result else null;
    }
} else struct {
    const Tm = extern struct {
        tm_sec: c_int,
        tm_min: c_int,
        tm_hour: c_int,
        tm_mday: c_int,
        tm_mon: c_int,
        tm_year: c_int,
        tm_wday: c_int,
        tm_yday: c_int,
        tm_isdst: c_int,
    };
    extern "c" fn time(timer: ?*i64) i64;
    extern "c" fn localtime_r(timer: *const i64, result: *Tm) ?*Tm;

    fn localtime(timer: *const i64, result: *Tm) ?*const Tm {
        return localtime_r(timer, result);
    }
};

const win32 = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn GetEnvironmentVariableW(
        lpName: [*:0]const u16,
        lpBuffer: ?[*]u16,
        nSize: u32,
    ) callconv(.c) u32;
} else struct {};

pub fn getAssetsPath(allocator: std.mem.Allocator) ![]const u8 {
    const tz = tracy.zone(@src(), "getAssetsPath");
    defer tz.end();

    const io = Io.Threaded.global_single_threaded.io();
    const exe_dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(exe_dir);
    return std.fmt.allocPrint(allocator, "{s}" ++ sep ++ "assets" ++ sep ++ "farhorizons", .{exe_dir});
}

pub fn getAppDataPath(allocator: std.mem.Allocator) ![]const u8 {
    const tz = tracy.zone(@src(), "getAppDataPath");
    defer tz.end();

    if (builtin.os.tag == .windows) {
        const env_name = std.unicode.utf8ToUtf16LeStringLiteral("APPDATA");
        var buf: [512]u16 = undefined;
        const len = win32.GetEnvironmentVariableW(env_name, &buf, buf.len);
        if (len == 0 or len > buf.len) return error.AppDataNotSet;
        const appdata = try std.unicode.wtf16LeToWtf8Alloc(allocator, buf[0..len]);
        defer allocator.free(appdata);
        return std.fmt.allocPrint(allocator, "{s}" ++ sep ++ "FarHorizons", .{appdata});
    } else {
        const home = std.c.getenv("XDG_DATA_HOME") orelse blk: {
            const h = std.c.getenv("HOME") orelse return error.AppDataNotSet;
            break :blk h;
        };
        const home_span = std.mem.span(home);
        if (std.c.getenv("XDG_DATA_HOME")) |_| {
            return std.fmt.allocPrint(allocator, "{s}" ++ sep ++ "farhorizons", .{home_span});
        } else {
            return std.fmt.allocPrint(allocator, "{s}" ++ sep ++ ".local" ++ sep ++ "share" ++ sep ++ "farhorizons", .{home_span});
        }
    }
}

pub fn getWorldsDir(allocator: std.mem.Allocator) ![]const u8 {
    const base_path = try getAppDataPath(allocator);
    defer allocator.free(base_path);
    return std.fmt.allocPrint(allocator, "{s}" ++ sep ++ "worlds", .{base_path});
}

pub fn deleteWorld(allocator: std.mem.Allocator, name: []const u8) !void {
    const worlds_dir = try getWorldsDir(allocator);
    defer allocator.free(worlds_dir);

    const io = Io.Threaded.global_single_threaded.io();
    var dir = Dir.openDirAbsolute(io, worlds_dir, .{}) catch return error.AppDataNotSet;
    defer dir.close(io);

    dir.deleteTree(io, name) catch |err| {
        std.log.warn("Failed to delete world '{s}': {}", .{ name, err });
        return err;
    };
}

pub fn listWorlds(allocator: std.mem.Allocator, names: [][]const u8) !u8 {
    const worlds_dir = try getWorldsDir(allocator);
    defer allocator.free(worlds_dir);

    const io = Io.Threaded.global_single_threaded.io();
    var dir = Dir.openDirAbsolute(io, worlds_dir, .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    var iter = dir.iterate();
    var count: u8 = 0;
    while (count < names.len) {
        const entry = iter.next(io) catch break orelse break;
        if (entry.kind == .directory) {
            names[count] = try allocator.dupe(u8, entry.name);
            count += 1;
        }
    }
    return count;
}

pub fn backupWorld(allocator: std.mem.Allocator, name: []const u8) !void {
    const worlds_dir = try getWorldsDir(allocator);
    defer allocator.free(worlds_dir);

    const io = Io.Threaded.global_single_threaded.io();

    // Get current date for backup name
    var now = c_time.time(null);
    var tm: c_time.Tm = undefined;
    const lt = c_time.localtime(&now, &tm) orelse return error.TimeError;
    const year: u16 = @intCast(lt.tm_year + 1900);
    const month: u8 = @intCast(lt.tm_mon + 1);
    const day: u8 = @intCast(lt.tm_mday);

    // Find available backup name: Backup_YYYYMMDD_N_OriginalName
    var backup_name_buf: [128]u8 = undefined;
    var backup_name: []const u8 = undefined;
    var n: u16 = 1;
    while (n < 1000) : (n += 1) {
        backup_name = std.fmt.bufPrint(&backup_name_buf, "Backup_{d:0>4}{d:0>2}{d:0>2}_{d}_{s}", .{ year, month, day, n, name }) catch return error.NameTooLong;
        // Check if this directory already exists
        const check_path = std.fmt.allocPrint(allocator, "{s}" ++ sep ++ "{s}", .{ worlds_dir, backup_name }) catch return error.OutOfMemory;
        defer allocator.free(check_path);
        var check_dir = Dir.openDirAbsolute(io, check_path, .{}) catch break; // doesn't exist, use this name
        check_dir.close(io);
        // exists, try next number
    }

    const src_path = std.fmt.allocPrint(allocator, "{s}" ++ sep ++ "{s}", .{ worlds_dir, name }) catch return error.OutOfMemory;
    defer allocator.free(src_path);
    const dst_path = std.fmt.allocPrint(allocator, "{s}" ++ sep ++ "{s}", .{ worlds_dir, backup_name }) catch return error.OutOfMemory;
    defer allocator.free(dst_path);

    copyDir(allocator, io, src_path, dst_path) catch |err| {
        std.log.warn("Failed to backup world '{s}': {}", .{ name, err });
        return err;
    };
}

fn copyDir(allocator: std.mem.Allocator, io: anytype, src_path: []const u8, dst_path: []const u8) !void {
    Dir.createDirAbsolute(io, dst_path, .default_file) catch {};

    var src_dir = Dir.openDirAbsolute(io, src_path, .{ .iterate = true }) catch return error.OpenFailed;
    defer src_dir.close(io);

    var iter = src_dir.iterate();
    while (true) {
        const entry = iter.next(io) catch break orelse break;
        const child_src = std.fmt.allocPrint(allocator, "{s}" ++ sep ++ "{s}", .{ src_path, entry.name }) catch continue;
        defer allocator.free(child_src);
        const child_dst = std.fmt.allocPrint(allocator, "{s}" ++ sep ++ "{s}", .{ dst_path, entry.name }) catch continue;
        defer allocator.free(child_dst);

        switch (entry.kind) {
            .directory => {
                copyDir(allocator, io, child_src, child_dst) catch continue;
            },
            .file => {
                copyFile(allocator, io, child_src, child_dst) catch |err| {
                    std.log.warn("Failed to copy file '{s}': {}", .{ child_src, err });
                };
            },
            else => {},
        }
    }
}

fn copyFile(allocator: std.mem.Allocator, io: anytype, src_path: []const u8, dst_path: []const u8) !void {
    const data = Dir.readFileAlloc(.cwd(), io, src_path, allocator, .unlimited) catch return error.ReadFailed;
    defer allocator.free(data);

    const file = Dir.createFileAbsolute(io, dst_path, .{}) catch return error.CreateFailed;
    defer file.close(io);
    file.writePositionalAll(io, data, 0) catch return error.WriteFailed;
}
