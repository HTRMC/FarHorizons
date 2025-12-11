const std = @import("std");

const log = std.log.scoped(.shader_cache);

/// Disk-based shader cache that stores compiled SPIR-V indexed by source hash.
/// This avoids recompiling shaders when the source hasn't changed.
pub const ShaderCache = struct {
    allocator: std.mem.Allocator,
    cache_dir: []const u8,

    const Self = @This();
    const default_cache_dir = "cache/shaders";

    pub fn init(allocator: std.mem.Allocator, cache_dir: ?[]const u8) !Self {
        const dir = cache_dir orelse default_cache_dir;

        // Ensure cache directory exists
        std.fs.cwd().makePath(dir) catch |err| {
            log.warn("Failed to create shader cache directory '{s}': {}", .{ dir, err });
        };

        return .{
            .allocator = allocator,
            .cache_dir = try allocator.dupe(u8, dir),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.cache_dir);
    }

    /// Compute hash of preprocessed shader source.
    /// Uses Wyhash for speed.
    pub fn hashSource(source: []const u8) u64 {
        return std.hash.Wyhash.hash(0, source);
    }

    /// Try to load cached SPIR-V for the given source hash.
    /// Returns null if not cached or cache is invalid.
    pub fn load(self: *Self, source_hash: u64) ?[]const u8 {
        const cache_path = self.getCachePath(source_hash) catch return null;
        defer self.allocator.free(cache_path);

        const file = std.fs.cwd().openFile(cache_path, .{}) catch return null;
        defer file.close();

        const stat = file.stat() catch return null;
        const size: usize = @intCast(stat.size);

        // SPIR-V must be 4-byte aligned and have valid header
        if (size < 20 or size % 4 != 0) {
            log.warn("Invalid cached SPIR-V size: {d}", .{size});
            return null;
        }

        const buffer = self.allocator.alloc(u8, size) catch return null;
        errdefer self.allocator.free(buffer);

        const bytes_read = file.preadAll(buffer, 0) catch {
            self.allocator.free(buffer);
            return null;
        };

        if (bytes_read != size) {
            self.allocator.free(buffer);
            return null;
        }

        // Validate SPIR-V magic number (0x07230203)
        const magic = std.mem.readInt(u32, buffer[0..4], .little);
        if (magic != 0x07230203) {
            log.warn("Invalid SPIR-V magic in cache: 0x{x}", .{magic});
            self.allocator.free(buffer);
            return null;
        }

        return buffer;
    }

    /// Store compiled SPIR-V in the cache.
    pub fn store(self: *Self, source_hash: u64, spv_data: []const u8) !void {
        const cache_path = try self.getCachePath(source_hash);
        defer self.allocator.free(cache_path);

        const file = std.fs.cwd().createFile(cache_path, .{}) catch |err| {
            log.warn("Failed to create cache file '{s}': {}", .{ cache_path, err });
            return err;
        };
        defer file.close();

        file.writeAll(spv_data) catch |err| {
            log.warn("Failed to write cache file: {}", .{err});
            return err;
        };

        log.debug("Cached SPIR-V: {s} ({d} bytes)", .{ cache_path, spv_data.len });
    }

    /// Get the cache file path for a given hash.
    fn getCachePath(self: *Self, hash: u64) ![]const u8 {
        var hash_str: [16]u8 = undefined;
        _ = std.fmt.bufPrint(&hash_str, "{x:0>16}", .{hash}) catch unreachable;
        return std.fs.path.join(self.allocator, &.{ self.cache_dir, &hash_str ++ ".spv" });
    }

    /// Clear all cached shaders.
    pub fn clearAll(self: *Self) void {
        var dir = std.fs.cwd().openDir(self.cache_dir, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".spv")) {
                dir.deleteFile(entry.name) catch {};
            }
        }

        log.info("Shader cache cleared", .{});
    }

    /// Get cache statistics.
    pub fn getStats(self: *const Self) CacheStats {
        var stats = CacheStats{};

        var dir = std.fs.cwd().openDir(self.cache_dir, .{ .iterate = true }) catch return stats;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".spv")) {
                stats.cached_shaders += 1;
                // Get file size
                const file = dir.openFile(entry.name, .{}) catch continue;
                defer file.close();
                const stat = file.stat() catch continue;
                stats.total_bytes += @intCast(stat.size);
            }
        }

        return stats;
    }

    pub const CacheStats = struct {
        cached_shaders: u32 = 0,
        total_bytes: u64 = 0,
    };
};
