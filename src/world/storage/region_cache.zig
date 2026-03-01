const std = @import("std");
const storage_types = @import("types.zig");
const RegionFile = @import("region_file.zig").RegionFile;

const RegionCoord = storage_types.RegionCoord;
const Io = std.Io;

const log = std.log.scoped(.region_cache);

const MAX_OPEN_REGIONS = 64;

/// LRU cache of open RegionFile handles.
/// Thread-safe — protected by a mutex.
/// Entries are ref-counted; eviction only occurs when ref_count <= 1 (cache-only).
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

    /// Get an open RegionFile for the given coordinate, opening or creating one if needed.
    /// Increments the ref count — caller must call releaseRegion when done.
    pub fn getOrOpen(self: *RegionCache, coord: RegionCoord) !*RegionFile {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Look for existing entry
        for (&self.entries) |*slot| {
            if (slot.*) |*entry| {
                if (entry.coord.eql(coord)) {
                    entry.recently_used = true;
                    entry.region.ref();
                    return entry.region;
                }
            }
        }

        // Not found — need to open a new one
        // Build the directory path for this LOD level
        const sep = std.fs.path.sep_str;
        const dir_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}{s}lod{d}",
            .{ self.base_dir, sep, coord.lod },
        );
        defer self.allocator.free(dir_path);

        // Ensure LOD directory exists
        const io = Io.Threaded.global_single_threaded.io();
        Io.Dir.createDirAbsolute(io, dir_path, .default_file) catch {};

        // Open/create the region file
        const region = try RegionFile.open(self.allocator, dir_path, coord);
        errdefer region.close();

        // Find a slot (evict if necessary)
        const slot_idx = self.findSlot() orelse {
            log.err("Region cache full — all {d} entries are in use by workers", .{MAX_OPEN_REGIONS});
            return error.OutOfSpace;
        };

        // Evict if occupied (ref_count guaranteed <= 1 by findSlot)
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

        region.ref(); // Ref for the caller
        return region;
    }

    /// Release a reference to a RegionFile obtained via getOrOpen.
    pub fn releaseRegion(self: *RegionCache, region: *RegionFile) void {
        _ = self; // Cache doesn't need to do bookkeeping on release
        if (region.unref()) {
            // Last reference dropped outside the cache — shouldn't normally happen
            // since the cache holds one reference. This is a safety net.
            region.close();
        }
    }

    /// Find a free slot or evict using CLOCK algorithm.
    /// Returns null if all entries are actively referenced by workers.
    fn findSlot(self: *RegionCache) ?usize {
        // First pass: look for an empty slot
        for (self.entries, 0..) |entry, i| {
            if (entry == null) return i;
        }

        // CLOCK eviction: find an unreferenced entry that's not recently used
        var iterations: usize = 0;
        while (iterations < MAX_OPEN_REGIONS * 2) : (iterations += 1) {
            if (self.entries[self.clock_hand]) |*entry| {
                // Only evict entries with ref_count == 1 (only the cache holds a ref)
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

    /// Flush all dirty regions (write headers to disk).
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
