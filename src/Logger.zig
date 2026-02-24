const std = @import("std");
const app_config = @import("app_config.zig");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

const sep = std.fs.path.sep_str;

const c_time = struct {
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
    extern "c" fn localtime(timer: *const i64) ?*const Tm;
};

const BUFFER_SIZE = 256 * 1024; // 256KB per buffer
const RETENTION_DAYS = 7;
const SECONDS_PER_DAY = 86400;

pub const FileLogger = struct {
    // Double buffer system
    buffers: *[2][BUFFER_SIZE]u8,
    lens: [2]usize,
    active: u1,
    dropped_count: usize,

    // Synchronization
    mutex: Io.Mutex,
    cond: Io.Condition,
    shutdown: bool,

    // Writer thread
    thread: ?std.Thread,
    io: Io,
    log_file: File,

    // Ownership
    logs_dir_path: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*FileLogger {
        const io = Io.Threaded.global_single_threaded.io();

        const base_path = try app_config.getAppDataPath(allocator);
        defer allocator.free(base_path);

        const logs_dir_path = try std.fmt.allocPrint(allocator, "{s}" ++ sep ++ "logs", .{base_path});
        errdefer allocator.free(logs_dir_path);

        // Ensure logs directory exists
        Dir.createDirAbsolute(io, logs_dir_path, .default_file) catch {};

        // Rotate old latest.log and cleanup old logs
        rotateLatestLog(allocator, io, logs_dir_path);
        cleanupOldLogs(allocator, io, logs_dir_path);

        // Open new latest.log
        const latest_path = try std.fmt.allocPrint(allocator, "{s}" ++ sep ++ "latest.log", .{logs_dir_path});
        defer allocator.free(latest_path);

        const log_file = Dir.createFileAbsolute(io, latest_path, .{}) catch |err| {
            std.log.warn("Failed to create log file: {}", .{err});
            return err;
        };
        errdefer log_file.close(io);

        // Heap-allocate because the buffers are large
        const self = try allocator.create(FileLogger);
        errdefer allocator.destroy(self);

        const buffers = try allocator.create([2][BUFFER_SIZE]u8);
        errdefer allocator.destroy(buffers);

        self.* = .{
            .buffers = buffers,
            .lens = .{ 0, 0 },
            .active = 0,
            .dropped_count = 0,
            .mutex = .init,
            .cond = .init,
            .shutdown = false,
            .thread = null,
            .io = io,
            .log_file = log_file,
            .logs_dir_path = logs_dir_path,
            .allocator = allocator,
        };

        self.thread = std.Thread.spawn(.{}, writerThreadFn, .{self}) catch |err| {
            std.log.err("Failed to spawn log writer thread: {}", .{err});
            return err;
        };

        return self;
    }

    pub fn deinit(self: *FileLogger) void {
        // Signal shutdown
        {
            self.mutex.lockUncancelable(self.io);
            self.shutdown = true;
            self.cond.signal(self.io);
            self.mutex.unlock(self.io);
        }

        // Wait for writer thread
        if (self.thread) |t| {
            t.join();
        }

        if (self.dropped_count > 0) {
            std.log.warn("File logger dropped {} messages due to buffer overflow", .{self.dropped_count});
        }

        self.log_file.close(self.io);
        self.allocator.free(self.logs_dir_path);
        self.allocator.destroy(self.buffers);
        self.allocator.destroy(self);
    }

    pub fn push(self: *FileLogger, message: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const active = self.active;
        const remaining = BUFFER_SIZE - self.lens[active];

        if (message.len <= remaining) {
            @memcpy(self.buffers[active][self.lens[active]..][0..message.len], message);
            self.lens[active] += message.len;
        } else {
            self.dropped_count += 1;
        }

        self.cond.signal(self.io);
    }

    fn writerThreadFn(self: *FileLogger) void {
        var file_writer_buf: [8192]u8 = undefined;
        var file_writer = File.Writer.initStreaming(self.log_file, self.io, &file_writer_buf);

        while (true) {
            var drain_idx: u1 = undefined;
            var drain_len: usize = 0;
            var should_exit = false;

            {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);

                // Wait while active buffer is empty and not shutting down
                while (self.lens[self.active] == 0 and !self.shutdown) {
                    self.cond.waitUncancelable(self.io, &self.mutex);
                }

                if (self.shutdown and self.lens[self.active] == 0) {
                    should_exit = true;
                } else {
                    // Swap: take active buffer for draining
                    drain_idx = self.active;
                    drain_len = self.lens[drain_idx];
                    self.lens[drain_idx] = 0;
                    self.active ^= 1;
                }
            }

            if (drain_len > 0) {
                // Write outside of mutex - file I/O happens here
                file_writer.interface.writeAll(self.buffers[drain_idx][0..drain_len]) catch {};
                file_writer.interface.flush() catch {};
            }

            if (should_exit) break;
        }

        // Final flush
        file_writer.interface.flush() catch {};
    }

    fn rotateLatestLog(allocator: std.mem.Allocator, io: Io, logs_dir_path: []const u8) void {
        const latest_path = std.fmt.allocPrint(allocator, "{s}" ++ sep ++ "latest.log", .{logs_dir_path}) catch return;
        defer allocator.free(latest_path);

        // Check if latest.log exists
        const file = Dir.openFileAbsolute(io, latest_path, .{}) catch return;
        file.close(io);

        // Get current date for naming
        var t = c_time.time(null);
        const tm = c_time.localtime(&t) orelse return;
        const year = @as(u32, @intCast(tm.tm_year + 1900));
        const month = @as(u32, @intCast(tm.tm_mon + 1));
        const day = @as(u32, @intCast(tm.tm_mday));

        // Find next available sequence number
        var seq: u32 = 1;
        while (seq < 1000) : (seq += 1) {
            var name_buf: [64]u8 = undefined;
            const dated_name = std.fmt.bufPrint(&name_buf, "{d:0>4}-{d:0>2}-{d:0>2}-{d}.log", .{
                year, month, day, seq,
            }) catch break;

            const dated_path = std.fmt.allocPrint(allocator, "{s}" ++ sep ++ "{s}", .{
                logs_dir_path, dated_name,
            }) catch return;
            defer allocator.free(dated_path);

            // Check if this name is taken
            const check = Dir.openFileAbsolute(io, dated_path, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    // Available - rename latest.log to this
                    Dir.renameAbsolute(latest_path, dated_path, io) catch {
                        std.log.warn("Failed to rotate log file", .{});
                    };
                    return;
                },
                else => return,
            };
            check.close(io);
        }
    }

    fn cleanupOldLogs(allocator: std.mem.Allocator, io: Io, logs_dir_path: []const u8) void {
        const now = c_time.time(null);
        const tm_now = c_time.localtime(&now) orelse return;
        const today = dateToDays(
            tm_now.tm_year + 1900,
            tm_now.tm_mon + 1,
            tm_now.tm_mday,
        );

        const dir = Dir.openDirAbsolute(io, logs_dir_path, .{ .iterate = true }) catch return;
        defer dir.close(io);

        var iter = dir.iterate();
        while (iter.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;

            // Match pattern: YYYY-MM-DD-N.log
            const year, const month, const day = parseDateFromLogName(entry.name) orelse continue;
            const file_day = dateToDays(year, month, day);

            if (today - file_day > RETENTION_DAYS) {
                const path = std.fmt.allocPrint(allocator, "{s}" ++ sep ++ "{s}", .{
                    logs_dir_path, entry.name,
                }) catch continue;
                defer allocator.free(path);
                Dir.deleteFileAbsolute(io, path) catch {};
            }
        }
    }

    fn parseDateFromLogName(name: []const u8) ?struct { i32, i32, i32 } {
        // Expected: YYYY-MM-DD-N.log (min length: 4+1+2+1+2+1+1+4 = 16)
        if (name.len < 16) return null;
        if (!std.mem.endsWith(u8, name, ".log")) return null;
        if (name[4] != '-' or name[7] != '-' or name[10] != '-') return null;

        const year = std.fmt.parseInt(i32, name[0..4], 10) catch return null;
        const month = std.fmt.parseInt(i32, name[5..7], 10) catch return null;
        const day = std.fmt.parseInt(i32, name[8..10], 10) catch return null;

        if (month < 1 or month > 12 or day < 1 or day > 31) return null;
        return .{ year, month, day };
    }

    fn dateToDays(year: i32, month: i32, day: i32) i32 {
        // Convert date to a comparable day number (modified Julian day approximation)
        var y = year;
        var m = month;
        if (m <= 2) {
            y -= 1;
            m += 12;
        }
        return 365 * y + @divTrunc(y, 4) - @divTrunc(y, 100) + @divTrunc(y, 400) + @divTrunc(153 * (m - 3) + 2, 5) + day;
    }
};
