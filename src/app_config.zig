const std = @import("std");
const builtin = @import("builtin");

const sep = std.fs.path.sep_str;

pub fn getAppDataPath(allocator: std.mem.Allocator) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const appdata = std.c.getenv("APPDATA") orelse return error.AppDataNotSet;
        return std.fmt.allocPrint(allocator, "{s}" ++ sep ++ "FarHorizons", .{std.mem.span(appdata)});
    } else {
        // XDG_DATA_HOME or ~/.local/share
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
