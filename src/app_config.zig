const std = @import("std");
const builtin = @import("builtin");
const tracy = @import("platform/tracy.zig");

const Io = std.Io;
const Dir = Io.Dir;

const sep = std.fs.path.sep_str;

pub fn getAppDataPath(allocator: std.mem.Allocator) ![]const u8 {
    const tz = tracy.zone(@src(), "getAppDataPath");
    defer tz.end();

    if (builtin.os.tag == .windows) {
        const appdata = std.c.getenv("APPDATA") orelse return error.AppDataNotSet;
        return std.fmt.allocPrint(allocator, "{s}" ++ sep ++ "FarHorizons", .{std.mem.span(appdata)});
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
