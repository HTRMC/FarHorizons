const std = @import("std");
const storage_types = @import("types.zig");
const RegionFile = @import("region_file.zig").RegionFile;

const RegionCoord = storage_types.RegionCoord;
const Io = std.Io;

const log = std.log.scoped(.region_cache);

const MAX_OPEN_REGIONS = 64;

pub const RegionCache = struct {
    mutex: Io.Mutex,
    io: Io,
    entries: [MAX_OPEN_REGIONS]?Entry,
    count: usize,
    clock_hand: usize,
    allocator: std.mem.Allocator,
    base_dir: []const u8,

    const Entry = struct {
        region: *RegionFile,
        coord: RegionCoord,
        recently_used: bool,
    };

    pub fn init(allocator: std.mem.Allocator, base_dir: []const u8) RegionCache {
        return .{
            .mutex = .init,
            .io = Io.Threaded.global_single_threaded.io(),
            .entries = [_]?Entry{null} ** MAX_OPEN_REGIONS,
            .count = 0,
            .clock_hand = 0,
            .allocator = allocator,
            .base_dir = base_dir,
        };
    }

    pub fn deinit(self: *RegionCache) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        for (&self.entries) |*slot| {
            if (slot.*) |entry| {
                entry.region.close();
                slot.* = null;
            }
        }
        self.count = 0;
    }

    pub fn getOrOpen(self: *RegionCache, coord: RegionCoord) !*RegionFile {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        for (&self.entries) |*slot| {
            if (slot.*) |*entry| {
                if (entry.coord.eql(coord)) {
                    entry.recently_used = true;
                    entry.region.ref();
                    return entry.region;
                }
            }
        }

        const sep = std.fs.path.sep_str;
        const dir_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}{s}lod{d}",
            .{ self.base_dir, sep, coord.lod },
        );
        defer self.allocator.free(dir_path);

        const io = Io.Threaded.global_single_threaded.io();
        Io.Dir.createDirAbsolute(io, dir_path, .default_file) catch {};

        const region = try RegionFile.open(self.allocator, dir_path, coord);
        errdefer region.close();

        const slot_idx = self.findSlot() orelse {
            log.err("Region cache full — all {d} entries are in use by workers", .{MAX_OPEN_REGIONS});
            return error.OutOfSpace;
        };

        if (self.entries[slot_idx]) |old| {
            log.debug("Evicting region ({d},{d},{d}) lod{d}", .{
                old.coord.rx, old.coord.ry, old.coord.rz, old.coord.lod,
            });
            if (old.region.unref()) {
                old.region.close();
            }
            self.count -= 1;
        }

        self.entries[slot_idx] = .{
            .region = region,
            .coord = coord,
            .recently_used = true,
        };
        self.count += 1;

        region.ref();
        return region;
    }

    pub fn releaseRegion(self: *RegionCache, region: *RegionFile) void {
        _ = self;
        if (region.unref()) {
            region.close();
        }
    }

    fn findSlot(self: *RegionCache) ?usize {
        for (self.entries, 0..) |entry, i| {
            if (entry == null) return i;
        }

        var iterations: usize = 0;
        while (iterations < MAX_OPEN_REGIONS * 2) : (iterations += 1) {
            if (self.entries[self.clock_hand]) |*entry| {
                if (entry.region.ref_count.load(.acquire) <= 1) {
                    if (!entry.recently_used) {
                        const idx = self.clock_hand;
                        self.clock_hand = (self.clock_hand + 1) % MAX_OPEN_REGIONS;
                        return idx;
                    }
                    entry.recently_used = false;
                }
            }
            self.clock_hand = (self.clock_hand + 1) % MAX_OPEN_REGIONS;
        }

        return null;
    }

    pub fn flushAll(self: *RegionCache) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        for (self.entries) |entry_opt| {
            if (entry_opt) |entry| {
                entry.region.fsync() catch {};
            }
        }
    }
};
