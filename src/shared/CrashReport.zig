const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const builtin = @import("builtin");
const Logger = @import("Logger.zig").Logger;

// Windows FILETIME to Unix timestamp conversion
const EPOCH_DIFF: u64 = 116444736000000000; // 100-ns intervals between 1601 and 1970

const FILETIME = extern struct {
    dwLowDateTime: u32,
    dwHighDateTime: u32,
};

extern "kernel32" fn GetSystemTimeAsFileTime(lpSystemTimeAsFileTime: *FILETIME) callconv(.winapi) void;

/// Get current Unix timestamp in seconds
fn getTimestamp() i64 {
    if (builtin.os.tag == .windows) {
        var ft: FILETIME = undefined;
        GetSystemTimeAsFileTime(&ft);
        const ft_u64: u64 = @as(u64, ft.dwHighDateTime) << 32 | ft.dwLowDateTime;
        return @intCast((ft_u64 - EPOCH_DIFF) / 10_000_000);
    } else {
        // POSIX: Use clock_gettime with REALTIME
        const ts = std.posix.clock_gettime(.REALTIME) catch return 0;
        return ts.sec;
    }
}

/// A crash report that collects information about an error and system state.
pub const CrashReport = struct {
    const Self = @This();
    const logger = Logger.scoped(Self);

    allocator: std.mem.Allocator,
    io: Io,
    title: []const u8,
    error_msg: ?[]const u8,
    stack_trace: ?*std.builtin.StackTrace,
    categories: std.ArrayListUnmanaged(CrashReportCategory),
    system_report: SystemReport,
    save_file: ?[]const u8 = null,
    timestamp: i64,

    /// Create a new crash report with a title and optional error.
    pub fn init(allocator: std.mem.Allocator, io: Io, title: []const u8, err: ?anyerror) Self {
        return Self{
            .allocator = allocator,
            .io = io,
            .title = title,
            .error_msg = if (err) |e| @errorName(e) else null,
            .stack_trace = @errorReturnTrace(),
            .categories = .{},
            .system_report = SystemReport.init(allocator, io),
            .timestamp = getTimestamp(),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.categories.items) |*cat| {
            cat.deinit();
        }
        self.categories.deinit(self.allocator);
        self.system_report.deinit();
    }

    /// Create a crash report from an error.
    pub fn forError(allocator: std.mem.Allocator, err: anyerror, title: []const u8, io: Io) Self {
        return Self.init(allocator, io, title, err);
    }

    /// Add a new category to the crash report.
    pub fn addCategory(self: *Self, name: []const u8) *CrashReportCategory {
        const category = CrashReportCategory.init(self.allocator, name);
        self.categories.append(self.allocator, category) catch {
            logger.err("Failed to add crash report category: {s}", .{name});
            // Return a dummy category that won't be stored
            return &self.categories.items[self.categories.items.len - 1];
        };
        return &self.categories.items[self.categories.items.len - 1];
    }

    /// Generate the full crash report as a string.
    pub fn getFriendlyReport(self: *Self) ![]const u8 {
        var buffer: std.ArrayListUnmanaged(u8) = .{};
        errdefer buffer.deinit(self.allocator);

        // Header
        try buffer.appendSlice(self.allocator, "---- FarHorizons Crash Report ----\n");
        try buffer.appendSlice(self.allocator, "// ");
        try buffer.appendSlice(self.allocator, getWittyComment());
        try buffer.appendSlice(self.allocator, "\n\n");

        // Timestamp
        try buffer.appendSlice(self.allocator, "Time: ");
        try self.writeTimestamp(&buffer);
        try buffer.appendSlice(self.allocator, "\n");

        // Description
        try buffer.appendSlice(self.allocator, "Description: ");
        try buffer.appendSlice(self.allocator, self.title);
        try buffer.appendSlice(self.allocator, "\n\n");

        // Error info
        if (self.error_msg) |err_msg| {
            try buffer.appendSlice(self.allocator, "Error: ");
            try buffer.appendSlice(self.allocator, err_msg);
            try buffer.appendSlice(self.allocator, "\n");
        }

        // Stack trace with thread info
        try buffer.appendSlice(self.allocator, "\n-- Head --\n");
        try buffer.appendSlice(self.allocator, "Thread: ");
        const tid = std.Thread.getCurrentId();
        var tid_buf: [32]u8 = undefined;
        const tid_str = std.fmt.bufPrint(&tid_buf, "Thread-{d}", .{tid}) catch "Main thread";
        try buffer.appendSlice(self.allocator, tid_str);
        try buffer.appendSlice(self.allocator, "\n");

        if (self.stack_trace) |trace| {
            try buffer.appendSlice(self.allocator, "Stacktrace:\n");
            try self.writeStackTrace(&buffer, trace.*);
        }

        try buffer.appendSlice(self.allocator, "\nA detailed walkthrough of the error, its code path and all known details is as follows:\n");
        try buffer.appendNTimes(self.allocator, '-', 87);
        try buffer.appendSlice(self.allocator, "\n\n");

        // Categories
        for (self.categories.items) |*category| {
            try category.writeDetails(self.allocator, &buffer);
            try buffer.appendSlice(self.allocator, "\n\n");
        }

        // System report
        try self.system_report.writeDetails(self.allocator, &buffer);

        return buffer.toOwnedSlice(self.allocator);
    }

    fn writeTimestamp(self: *Self, buffer: *std.ArrayListUnmanaged(u8)) !void {
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(self.timestamp) };
        const day_seconds = epoch_seconds.getDaySeconds();
        const epoch_day = epoch_seconds.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        var timestamp_buf: [32]u8 = undefined;
        const timestamp_str = std.fmt.bufPrint(&timestamp_buf, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
            year_day.year,
            @intFromEnum(month_day.month),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        }) catch "Unknown time";
        try buffer.appendSlice(self.allocator, timestamp_str);
    }

    fn writeStackTrace(self: *Self, buffer: *std.ArrayListUnmanaged(u8), trace: std.builtin.StackTrace) !void {
        var frame_index: usize = 0;
        var frames_left: usize = @min(trace.index, trace.instruction_addresses.len);

        while (frames_left > 0) : ({
            frame_index += 1;
            frames_left -= 1;
        }) {
            const addr = trace.instruction_addresses[frame_index];
            var addr_buf: [32]u8 = undefined;
            const addr_str = std.fmt.bufPrint(&addr_buf, "\tat 0x{x}\n", .{addr}) catch continue;
            try buffer.appendSlice(self.allocator, addr_str);
        }
    }

    /// Save the crash report to a file.
    pub fn saveToFile(self: *Self, io: Io, dir_path: []const u8) ![]const u8 {
        const report = try self.getFriendlyReport();
        defer self.allocator.free(report);

        // Generate filename with timestamp
        var filename_buf: [64]u8 = undefined;
        const filename = try std.fmt.bufPrint(&filename_buf, "crash-{d}.txt", .{self.timestamp});

        const full_path = try Dir.path.join(self.allocator, &.{ dir_path, filename });

        // Ensure directory exists
        Dir.cwd().createDirPath(io, dir_path) catch |err| {
            logger.err("Failed to create crash report directory: {s}", .{@errorName(err)});
            return err;
        };

        // Write the file
        const file = try Dir.cwd().createFile(io, full_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, report);

        self.save_file = full_path;
        logger.info("Crash report saved to {s}", .{full_path});

        return full_path;
    }

    /// Pre-load crash reporting system (warm up allocations, etc.)
    pub fn preload(allocator: std.mem.Allocator, io: Io) void {
        // Pre-allocate memory reserve for OOM situations
        MemoryReserve.allocate();

        // Create a dummy crash report to ensure all code paths are loaded
        var dummy = CrashReport.init(allocator, io, "Don't panic!", null);
        defer dummy.deinit();

        // Warm up code paths - result intentionally discarded
        _ = dummy.getFriendlyReport() catch {};

        logger.info("Crash report system preloaded", .{});
    }

    fn getWittyComment() []const u8 {
        const comments = [_][]const u8{
            "Who set us up the TNT?",
            "Everything's going to plan. No, really, that was supposed to happen.",
            "Uh... Did I do that?",
            "Oops.",
            "Why did you do that?",
            "I feel sad now :(",
            "My bad.",
            "I'm sorry, Dave.",
            "I let you down. Sorry :(",
            "On the bright side, I bought you a alarm clock!",
            "Surprise! Haha. Well, this is awkward.",
            "Hi. I'm FarHorizons, and I'm a crashaholic.",
            "This doesn't make any sense!",
            "Why is it breaking :(",
            "Don't be sad. I'll do better next time!",
            "Don't be sad, have a hug! <3",
            "But it works on my machine.",
        };

        // Use timestamp as seed for "random" selection
        const seed: u64 = @intCast(getTimestamp());
        const index = seed % comments.len;
        return comments[index];
    }
};

/// A category/section within a crash report.
pub const CrashReportCategory = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    name: []const u8,
    entries: std.ArrayListUnmanaged(Entry),

    const Entry = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, name: []const u8) Self {
        return Self{
            .allocator = allocator,
            .name = name,
            .entries = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.entries.deinit(self.allocator);
    }

    /// Add a detail to this category.
    pub fn setDetail(self: *Self, key: []const u8, value: []const u8) *Self {
        self.entries.append(self.allocator, .{ .key = key, .value = value }) catch {
            // During crash reporting, memory may be constrained - losing one entry is acceptable
            std.debug.print("[WARN] CrashReport: Failed to add detail '{s}' - out of memory\n", .{key});
        };
        return self;
    }

    /// Add a detail with a formatted value.
    pub fn setDetailFmt(self: *Self, key: []const u8, comptime fmt: []const u8, args: anytype) *Self {
        const value = std.fmt.allocPrint(self.allocator, fmt, args) catch "~~ERROR~~";
        return self.setDetail(key, value);
    }

    /// Write this category's details to a buffer.
    pub fn writeDetails(self: *Self, allocator: std.mem.Allocator, buffer: *std.ArrayListUnmanaged(u8)) !void {
        try buffer.appendSlice(allocator, "-- ");
        try buffer.appendSlice(allocator, self.name);
        try buffer.appendSlice(allocator, " --\n");
        try buffer.appendSlice(allocator, "Details:");

        for (self.entries.items) |entry| {
            try buffer.appendSlice(allocator, "\n\t");
            try buffer.appendSlice(allocator, entry.key);
            try buffer.appendSlice(allocator, ": ");
            try buffer.appendSlice(allocator, entry.value);
        }
    }
};

/// Collects system information for crash reports.
pub const SystemReport = struct {
    const Self = @This();

    const Entry = struct {
        key: []const u8,
        value: []const u8,
    };

    allocator: std.mem.Allocator,
    io: Io,
    entries: std.ArrayListUnmanaged(Entry),
    allocated_values: std.ArrayListUnmanaged([]const u8),

    pub fn init(allocator: std.mem.Allocator, io: Io) Self {
        var self = Self{
            .allocator = allocator,
            .io = io,
            .entries = .{},
            .allocated_values = .{},
        };
        self.collectSystemInfo();
        return self;
    }

    pub fn deinit(self: *Self) void {
        // Free all allocated format strings
        for (self.allocated_values.items) |value| {
            self.allocator.free(value);
        }
        self.allocated_values.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    fn collectSystemInfo(self: *Self) void {
        // Game version
        self.setDetail("FarHorizons Version", "0.1.0");

        // Operating system with version
        if (builtin.os.tag == .windows) {
            self.collectWindowsVersion();
        } else {
            self.setDetail("Operating System", @tagName(builtin.os.tag));
        }
        self.setDetail("Architecture", @tagName(builtin.cpu.arch));

        // Zig version
        self.setDetail("Zig Version", builtin.zig_version_string);

        // Build mode
        self.setDetail("Build Mode", @tagName(builtin.mode));

        // CPU info
        self.collectCpuInfo();

        // Memory info
        self.collectMemoryInfo();

        // Memory slot info (Windows WMI)
        if (builtin.os.tag == .windows) {
            self.collectMemorySlotInfo();
        }

        // Storage info
        self.collectStorageInfo();

        // GPU info (Windows only via Registry, like OSHI)
        if (builtin.os.tag == .windows) {
            self.collectGpuInfoFromRegistry();
        }
    }

    // Windows version info structures
    const OSVERSIONINFOEXW = extern struct {
        dwOSVersionInfoSize: u32,
        dwMajorVersion: u32,
        dwMinorVersion: u32,
        dwBuildNumber: u32,
        dwPlatformId: u32,
        szCSDVersion: [128]u16,
        wServicePackMajor: u16,
        wServicePackMinor: u16,
        wSuiteMask: u16,
        wProductType: u8,
        wReserved: u8,
    };

    extern "ntdll" fn RtlGetVersion(lpVersionInformation: *OSVERSIONINFOEXW) callconv(.winapi) i32;

    fn collectWindowsVersion(self: *Self) void {
        var osvi: OSVERSIONINFOEXW = undefined;
        osvi.dwOSVersionInfoSize = @sizeOf(OSVERSIONINFOEXW);

        if (RtlGetVersion(&osvi) == 0) {
            // Determine Windows version name
            const version_name: []const u8 = if (osvi.dwMajorVersion == 10 and osvi.dwBuildNumber >= 22000)
                "Windows 11"
            else if (osvi.dwMajorVersion == 10)
                "Windows 10"
            else if (osvi.dwMajorVersion == 6 and osvi.dwMinorVersion == 3)
                "Windows 8.1"
            else if (osvi.dwMajorVersion == 6 and osvi.dwMinorVersion == 2)
                "Windows 8"
            else if (osvi.dwMajorVersion == 6 and osvi.dwMinorVersion == 1)
                "Windows 7"
            else
                "Windows";

            self.setDetailFmt("Operating System", "{s} ({s}) version {d}.{d}.{d}", .{
                version_name,
                @tagName(builtin.cpu.arch),
                osvi.dwMajorVersion,
                osvi.dwMinorVersion,
                osvi.dwBuildNumber,
            });
        } else {
            self.setDetail("Operating System", "Windows (unknown version)");
        }
    }

    fn collectCpuInfo(self: *Self) void {
        // On x86/x86_64, use CPUID for detailed info
        if (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .x86) {
            self.collectCpuidInfo();
        } else {
            // Fallback for other architectures
            const cpu_count = std.Thread.getCpuCount() catch 0;
            self.setDetailFmt("CPUs", "{d}", .{cpu_count});
            self.setDetail("CPU Architecture", @tagName(builtin.cpu.arch));
        }
    }

    fn collectCpuidInfo(self: *Self) void {
        // CPUID function 0: Get vendor string
        const vendor_result = cpuid(0, 0);
        var vendor_buf: [12]u8 = undefined;
        @memcpy(vendor_buf[0..4], @as(*const [4]u8, @ptrCast(&vendor_result.ebx)));
        @memcpy(vendor_buf[4..8], @as(*const [4]u8, @ptrCast(&vendor_result.edx)));
        @memcpy(vendor_buf[8..12], @as(*const [4]u8, @ptrCast(&vendor_result.ecx)));

        const vendor_str = std.fmt.allocPrint(self.allocator, "{s}", .{vendor_buf[0..12]}) catch "Unknown";
        self.allocated_values.append(self.allocator, vendor_str) catch {
            self.allocator.free(vendor_str);
        };
        self.setDetail("Processor Vendor", vendor_str);

        // CPUID function 1: Get family, model, stepping
        const info_result = cpuid(1, 0);
        const stepping = info_result.eax & 0xF;
        const base_model = (info_result.eax >> 4) & 0xF;
        const base_family = (info_result.eax >> 8) & 0xF;
        const ext_model = (info_result.eax >> 16) & 0xF;
        const ext_family = (info_result.eax >> 20) & 0xFF;

        var family: u32 = base_family;
        var model: u32 = base_model;

        if (base_family == 0xF) {
            family = base_family + ext_family;
        }
        if (base_family == 0x6 or base_family == 0xF) {
            model = base_model + (ext_model << 4);
        }

        const identifier = std.fmt.allocPrint(
            self.allocator,
            "{s} Family {d} Model {d} Stepping {d}",
            .{ vendor_buf[0..12], family, model, stepping },
        ) catch "Unknown";
        self.allocated_values.append(self.allocator, identifier) catch {
            self.allocator.free(identifier);
        };
        self.setDetail("Identifier", identifier);

        // CPUID function 0x80000002-0x80000004: Get processor brand string
        const max_ext = cpuid(0x80000000, 0).eax;
        if (max_ext >= 0x80000004) {
            var brand_buf: [48]u8 = undefined;
            const brand2 = cpuid(0x80000002, 0);
            const brand3 = cpuid(0x80000003, 0);
            const brand4 = cpuid(0x80000004, 0);

            @memcpy(brand_buf[0..4], @as(*const [4]u8, @ptrCast(&brand2.eax)));
            @memcpy(brand_buf[4..8], @as(*const [4]u8, @ptrCast(&brand2.ebx)));
            @memcpy(brand_buf[8..12], @as(*const [4]u8, @ptrCast(&brand2.ecx)));
            @memcpy(brand_buf[12..16], @as(*const [4]u8, @ptrCast(&brand2.edx)));
            @memcpy(brand_buf[16..20], @as(*const [4]u8, @ptrCast(&brand3.eax)));
            @memcpy(brand_buf[20..24], @as(*const [4]u8, @ptrCast(&brand3.ebx)));
            @memcpy(brand_buf[24..28], @as(*const [4]u8, @ptrCast(&brand3.ecx)));
            @memcpy(brand_buf[28..32], @as(*const [4]u8, @ptrCast(&brand3.edx)));
            @memcpy(brand_buf[32..36], @as(*const [4]u8, @ptrCast(&brand4.eax)));
            @memcpy(brand_buf[36..40], @as(*const [4]u8, @ptrCast(&brand4.ebx)));
            @memcpy(brand_buf[40..44], @as(*const [4]u8, @ptrCast(&brand4.ecx)));
            @memcpy(brand_buf[44..48], @as(*const [4]u8, @ptrCast(&brand4.edx)));

            // Trim leading spaces and find null terminator
            var start: usize = 0;
            while (start < brand_buf.len and brand_buf[start] == ' ') : (start += 1) {}
            var end: usize = brand_buf.len;
            for (brand_buf, 0..) |c, i| {
                if (c == 0) {
                    end = i;
                    break;
                }
            }

            if (end > start) {
                const name = std.fmt.allocPrint(self.allocator, "{s}", .{brand_buf[start..end]}) catch "Unknown";
                self.allocated_values.append(self.allocator, name) catch {
                    self.allocator.free(name);
                };
                self.setDetail("Processor Name", name);
            }
        }

        // Get microarchitecture with pretty name
        self.setDetail("Microarchitecture", getPrettyMicroarchName(builtin.cpu.model.name));

        // Get CPU frequency
        self.collectCpuFrequency();

        // Logical CPU count
        const logical_cpus = std.Thread.getCpuCount() catch 0;
        self.setDetailFmt("Number of logical CPUs", "{d}", .{logical_cpus});

        // Try to get physical core count (Windows-specific)
        if (builtin.os.tag == .windows) {
            self.collectWindowsCpuTopology();
        }
    }

    fn collectCpuFrequency(self: *Self) void {
        // Method 1: Try CPUID leaf 0x16 (Intel Skylake+, some AMD)
        // This leaf returns base frequency, max frequency, and bus frequency in MHz
        const max_leaf = cpuid(0, 0).eax;

        if (max_leaf >= 0x16) {
            const freq_leaf = cpuid(0x16, 0);
            const base_freq_mhz = freq_leaf.eax & 0xFFFF; // Base frequency in MHz
            const max_freq_mhz = freq_leaf.ebx & 0xFFFF; // Max frequency in MHz

            if (base_freq_mhz > 0) {
                const freq_ghz = @as(f64, @floatFromInt(base_freq_mhz)) / 1000.0;
                self.setDetailFmt("Frequency (GHz)", "{d:.2}", .{freq_ghz});
                return;
            }

            // Some CPUs report max but not base
            if (max_freq_mhz > 0) {
                const freq_ghz = @as(f64, @floatFromInt(max_freq_mhz)) / 1000.0;
                self.setDetailFmt("Frequency (GHz)", "{d:.2}", .{freq_ghz});
                return;
            }
        }

        // Method 2: Parse frequency from brand string (like OSHI does)
        // Look for patterns like "@ 2.00GHz" or "2.39 GHz" in the processor name
        const max_ext = cpuid(0x80000000, 0).eax;
        if (max_ext >= 0x80000004) {
            var brand_buf: [48]u8 = undefined;
            const brand2 = cpuid(0x80000002, 0);
            const brand3 = cpuid(0x80000003, 0);
            const brand4 = cpuid(0x80000004, 0);

            @memcpy(brand_buf[0..4], @as(*const [4]u8, @ptrCast(&brand2.eax)));
            @memcpy(brand_buf[4..8], @as(*const [4]u8, @ptrCast(&brand2.ebx)));
            @memcpy(brand_buf[8..12], @as(*const [4]u8, @ptrCast(&brand2.ecx)));
            @memcpy(brand_buf[12..16], @as(*const [4]u8, @ptrCast(&brand2.edx)));
            @memcpy(brand_buf[16..20], @as(*const [4]u8, @ptrCast(&brand3.eax)));
            @memcpy(brand_buf[20..24], @as(*const [4]u8, @ptrCast(&brand3.ebx)));
            @memcpy(brand_buf[24..28], @as(*const [4]u8, @ptrCast(&brand3.ecx)));
            @memcpy(brand_buf[28..32], @as(*const [4]u8, @ptrCast(&brand3.edx)));
            @memcpy(brand_buf[32..36], @as(*const [4]u8, @ptrCast(&brand4.eax)));
            @memcpy(brand_buf[36..40], @as(*const [4]u8, @ptrCast(&brand4.ebx)));
            @memcpy(brand_buf[40..44], @as(*const [4]u8, @ptrCast(&brand4.ecx)));
            @memcpy(brand_buf[44..48], @as(*const [4]u8, @ptrCast(&brand4.edx)));

            // Find null terminator
            var brand_len: usize = brand_buf.len;
            for (brand_buf, 0..) |c, i| {
                if (c == 0) {
                    brand_len = i;
                    break;
                }
            }

            // Parse frequency from brand string
            if (parseFrequencyFromBrand(brand_buf[0..brand_len])) |freq_ghz| {
                self.setDetailFmt("Frequency (GHz)", "{d:.2}", .{freq_ghz});
                return;
            }
        }

        // Method 3: Windows Registry (fallback for AMD and others)
        // HKEY_LOCAL_MACHINE\HARDWARE\DESCRIPTION\System\CentralProcessor\0\~MHz
        if (builtin.os.tag == .windows) {
            if (getWindowsRegistryFrequency()) |freq_mhz| {
                const freq_ghz = @as(f64, @floatFromInt(freq_mhz)) / 1000.0;
                self.setDetailFmt("Frequency (GHz)", "{d:.2}", .{freq_ghz});
            }
        }
    }

    // Windows Registry API
    const HKEY = *opaque {};
    const HKEY_LOCAL_MACHINE: HKEY = @ptrFromInt(0x80000002);

    extern "advapi32" fn RegOpenKeyExA(
        hKey: HKEY,
        lpSubKey: [*:0]const u8,
        ulOptions: u32,
        samDesired: u32,
        phkResult: *HKEY,
    ) callconv(.winapi) i32;

    extern "advapi32" fn RegQueryValueExA(
        hKey: HKEY,
        lpValueName: [*:0]const u8,
        lpReserved: ?*u32,
        lpType: ?*u32,
        lpData: ?*u8,
        lpcbData: ?*u32,
    ) callconv(.winapi) i32;

    extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.winapi) i32;

    extern "advapi32" fn RegEnumKeyExA(
        hKey: HKEY,
        dwIndex: u32,
        lpName: [*]u8,
        lpcchName: *u32,
        lpReserved: ?*u32,
        lpClass: ?[*]u8,
        lpcchClass: ?*u32,
        lpftLastWriteTime: ?*anyopaque,
    ) callconv(.winapi) i32;

    fn getWindowsRegistryFrequency() ?u32 {
        const KEY_READ = 0x20019;
        var hKey: HKEY = undefined;

        // Open the CPU registry key
        if (RegOpenKeyExA(
            HKEY_LOCAL_MACHINE,
            "HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0",
            0,
            KEY_READ,
            &hKey,
        ) != 0) {
            return null;
        }
        defer _ = RegCloseKey(hKey);

        // Query the ~MHz value
        var freq_mhz: u32 = 0;
        var data_size: u32 = @sizeOf(u32);

        if (RegQueryValueExA(
            hKey,
            "~MHz",
            null,
            null,
            @ptrCast(&freq_mhz),
            &data_size,
        ) != 0) {
            return null;
        }

        return freq_mhz;
    }

    // ==================== Registry-based GPU Info (like OSHI) ====================
    fn collectGpuInfoFromRegistry(self: *Self) void {
        const KEY_READ = 0x20019;
        const GPU_CLASS_GUID = "SYSTEM\\CurrentControlSet\\Control\\Class\\{4d36e968-e325-11ce-bfc1-08002be10318}";

        var hClassKey: HKEY = undefined;
        if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, GPU_CLASS_GUID, 0, KEY_READ, &hClassKey) != 0) {
            return;
        }
        defer _ = RegCloseKey(hClassKey);

        var gpu_index: u32 = 0;
        var subkey_index: u32 = 0;

        while (subkey_index < 32) : (subkey_index += 1) { // Max 32 subkeys to check
            var subkey_name: [16]u8 = undefined;
            var name_len: u32 = subkey_name.len;

            if (RegEnumKeyExA(hClassKey, subkey_index, &subkey_name, &name_len, null, null, null, null) != 0) {
                break;
            }

            // Build full subkey path
            var full_path: [256]u8 = undefined;
            const path_len = std.fmt.bufPrint(&full_path, "{s}\\{s}", .{ GPU_CLASS_GUID, subkey_name[0..name_len] }) catch continue;
            full_path[path_len.len] = 0;

            var hDevKey: HKEY = undefined;
            if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, @ptrCast(full_path[0..path_len.len :0]), 0, KEY_READ, &hDevKey) != 0) {
                continue;
            }
            defer _ = RegCloseKey(hDevKey);

            // Read DriverDesc (GPU name)
            var name_buf: [256]u8 = undefined;
            var name_size: u32 = name_buf.len;
            var reg_type: u32 = 0;

            if (RegQueryValueExA(hDevKey, "DriverDesc", null, &reg_type, @ptrCast(&name_buf), &name_size) != 0) {
                continue; // Skip entries without DriverDesc (not a real GPU)
            }

            // We found a GPU
            const gpu_name = std.fmt.allocPrint(self.allocator, "{s}", .{name_buf[0 .. name_size - 1]}) catch continue;
            self.allocated_values.append(self.allocator, gpu_name) catch {
                self.allocator.free(gpu_name);
                continue;
            };

            // Build keys for this GPU
            const key_name = std.fmt.allocPrint(self.allocator, "Graphics card #{d} name", .{gpu_index}) catch continue;
            const key_vendor = std.fmt.allocPrint(self.allocator, "Graphics card #{d} vendor", .{gpu_index}) catch continue;
            const key_vram = std.fmt.allocPrint(self.allocator, "Graphics card #{d} VRAM (MiB)", .{gpu_index}) catch continue;
            const key_driver = std.fmt.allocPrint(self.allocator, "Graphics card #{d} versionInfo", .{gpu_index}) catch continue;

            self.allocated_values.append(self.allocator, key_name) catch {
                self.allocator.free(key_name);
            };
            self.allocated_values.append(self.allocator, key_vendor) catch {
                self.allocator.free(key_vendor);
            };
            self.allocated_values.append(self.allocator, key_vram) catch {
                self.allocator.free(key_vram);
            };
            self.allocated_values.append(self.allocator, key_driver) catch {
                self.allocator.free(key_driver);
            };

            self.setDetail(key_name, gpu_name);

            // Read ProviderName (Vendor)
            var vendor_buf: [128]u8 = undefined;
            var vendor_size: u32 = vendor_buf.len;
            if (RegQueryValueExA(hDevKey, "ProviderName", null, null, @ptrCast(&vendor_buf), &vendor_size) == 0 and vendor_size > 1) {
                const vendor = std.fmt.allocPrint(self.allocator, "{s}", .{vendor_buf[0 .. vendor_size - 1]}) catch "Unknown";
                self.allocated_values.append(self.allocator, vendor) catch {
                    self.allocator.free(vendor);
                };
                self.setDetail(key_vendor, vendor);
            } else {
                self.setDetail(key_vendor, "Unknown");
            }

            // Read DriverVersion
            var driver_buf: [64]u8 = undefined;
            var driver_size: u32 = driver_buf.len;
            if (RegQueryValueExA(hDevKey, "DriverVersion", null, null, @ptrCast(&driver_buf), &driver_size) == 0 and driver_size > 1) {
                const driver = std.fmt.allocPrint(self.allocator, "{s}", .{driver_buf[0 .. driver_size - 1]}) catch "Unknown";
                self.allocated_values.append(self.allocator, driver) catch {
                    self.allocator.free(driver);
                };
                self.setDetail(key_driver, driver);
            }

            // Read VRAM - try qwMemorySize (QWORD) first, then HardwareInformation.MemorySize (DWORD)
            var vram_bytes: u64 = 0;
            var vram_size: u32 = @sizeOf(u64);
            var vram_type: u32 = 0;

            if (RegQueryValueExA(hDevKey, "HardwareInformation.qwMemorySize", null, &vram_type, @ptrCast(&vram_bytes), &vram_size) == 0) {
                const vram_mib = vram_bytes / (1024 * 1024);
                self.setDetailFmt(key_vram, "{d:.2}", .{@as(f64, @floatFromInt(vram_mib))});
            } else {
                // Try 32-bit value
                var vram_dword: u32 = 0;
                vram_size = @sizeOf(u32);
                if (RegQueryValueExA(hDevKey, "HardwareInformation.MemorySize", null, null, @ptrCast(&vram_dword), &vram_size) == 0) {
                    const vram_mib = vram_dword / (1024 * 1024);
                    self.setDetailFmt(key_vram, "{d:.2}", .{@as(f64, @floatFromInt(vram_mib))});
                }
            }

            gpu_index += 1;
        }
    }

    // ==================== WMI for Memory Slot Info ====================
    // COM GUIDs
    const CLSID_WbemLocator = GUID{
        .Data1 = 0x4590f811,
        .Data2 = 0x1d3a,
        .Data3 = 0x11d0,
        .Data4 = .{ 0x89, 0x1f, 0x00, 0xaa, 0x00, 0x4b, 0x2e, 0x24 },
    };

    const IID_IWbemLocator = GUID{
        .Data1 = 0xdc12a687,
        .Data2 = 0x737f,
        .Data3 = 0x11cf,
        .Data4 = .{ 0x88, 0x4d, 0x00, 0xaa, 0x00, 0x4b, 0x2e, 0x24 },
    };

    // BSTR type (wide string with length prefix)
    const BSTR = [*:0]u16;

    // COM interfaces
    const IUnknown = extern struct {
        vtable: *const VTable,

        const VTable = extern struct {
            QueryInterface: *const fn (*IUnknown, *const GUID, *?*anyopaque) callconv(.winapi) i32,
            AddRef: *const fn (*IUnknown) callconv(.winapi) u32,
            Release: *const fn (*IUnknown) callconv(.winapi) u32,
        };
    };

    const IWbemLocator = extern struct {
        vtable: *const VTable,

        const VTable = extern struct {
            // IUnknown
            QueryInterface: *const anyopaque,
            AddRef: *const anyopaque,
            Release: *const fn (*IWbemLocator) callconv(.winapi) u32,
            // IWbemLocator
            ConnectServer: *const fn (
                *IWbemLocator,
                ?BSTR, // strNetworkResource
                ?BSTR, // strUser
                ?BSTR, // strPassword
                ?BSTR, // strLocale
                i32, // lSecurityFlags
                ?BSTR, // strAuthority
                ?*anyopaque, // pCtx
                *?*IWbemServices, // ppNamespace
            ) callconv(.winapi) i32,
        };

        fn Release(self: *IWbemLocator) void {
            _ = self.vtable.Release(self);
        }

        fn ConnectServer(self: *IWbemLocator, resource: BSTR, services: *?*IWbemServices) i32 {
            return self.vtable.ConnectServer(self, resource, null, null, null, 0, null, null, services);
        }
    };

    const IWbemServices = extern struct {
        vtable: *const VTable,

        const VTable = extern struct {
            // IUnknown (3)
            QueryInterface: *const anyopaque,
            AddRef: *const anyopaque,
            Release: *const fn (*IWbemServices) callconv(.winapi) u32,
            // IWbemServices - many methods, we only need ExecQuery at index 20
            _padding: [17]*const anyopaque,
            ExecQuery: *const fn (
                *IWbemServices,
                BSTR, // strQueryLanguage
                BSTR, // strQuery
                i32, // lFlags
                ?*anyopaque, // pCtx
                *?*IEnumWbemClassObject, // ppEnum
            ) callconv(.winapi) i32,
        };

        fn Release(self: *IWbemServices) void {
            _ = self.vtable.Release(self);
        }

        fn ExecQuery(self: *IWbemServices, lang: BSTR, query: BSTR, enumerator: *?*IEnumWbemClassObject) i32 {
            const WBEM_FLAG_FORWARD_ONLY = 0x20;
            const WBEM_FLAG_RETURN_IMMEDIATELY = 0x10;
            return self.vtable.ExecQuery(self, lang, query, WBEM_FLAG_FORWARD_ONLY | WBEM_FLAG_RETURN_IMMEDIATELY, null, enumerator);
        }
    };

    const IEnumWbemClassObject = extern struct {
        vtable: *const VTable,

        const VTable = extern struct {
            // IUnknown (3)
            QueryInterface: *const anyopaque,
            AddRef: *const anyopaque,
            Release: *const fn (*IEnumWbemClassObject) callconv(.winapi) u32,
            // IEnumWbemClassObject
            Reset: *const anyopaque,
            Next: *const fn (
                *IEnumWbemClassObject,
                i32, // lTimeout
                u32, // uCount
                *?*IWbemClassObject, // apObjects
                *u32, // puReturned
            ) callconv(.winapi) i32,
        };

        fn Release(self: *IEnumWbemClassObject) void {
            _ = self.vtable.Release(self);
        }

        fn Next(self: *IEnumWbemClassObject, obj: *?*IWbemClassObject, returned: *u32) i32 {
            const WBEM_INFINITE: i32 = -1;
            return self.vtable.Next(self, WBEM_INFINITE, 1, obj, returned);
        }
    };

    const IWbemClassObject = extern struct {
        vtable: *const VTable,

        const VTable = extern struct {
            // IUnknown (3)
            QueryInterface: *const anyopaque,
            AddRef: *const anyopaque,
            Release: *const fn (*IWbemClassObject) callconv(.winapi) u32,
            // IWbemClassObject - Get is at index 4
            GetQualifierSet: *const anyopaque,
            Get: *const fn (
                *IWbemClassObject,
                BSTR, // wszName
                i32, // lFlags
                *VARIANT, // pVal
                ?*i32, // pType
                ?*i32, // plFlavor
            ) callconv(.winapi) i32,
        };

        fn Release(self: *IWbemClassObject) void {
            _ = self.vtable.Release(self);
        }

        fn Get(self: *IWbemClassObject, name: BSTR, val: *VARIANT) i32 {
            return self.vtable.Get(self, name, 0, val, null, null);
        }
    };

    // VARIANT structure (simplified)
    const VARIANT = extern struct {
        vt: u16,
        wReserved1: u16,
        wReserved2: u16,
        wReserved3: u16,
        data: extern union {
            llVal: i64,
            ullVal: u64,
            intVal: i32,
            uintVal: u32,
            bstrVal: BSTR,
        },
    };

    const VT_NULL = 1;
    const VT_I4 = 3;
    const VT_BSTR = 8;
    const VT_UI4 = 19;
    const VT_I8 = 20;
    const VT_UI8 = 21;

    // COM functions
    extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: u32) callconv(.winapi) i32;
    extern "ole32" fn CoUninitialize() callconv(.winapi) void;
    extern "ole32" fn CoCreateInstance(
        rclsid: *const GUID,
        pUnkOuter: ?*anyopaque,
        dwClsContext: u32,
        riid: *const GUID,
        ppv: *?*anyopaque,
    ) callconv(.winapi) i32;
    extern "ole32" fn CoSetProxyBlanket(
        pProxy: *anyopaque,
        dwAuthnSvc: u32,
        dwAuthzSvc: u32,
        pServerPrincName: ?*anyopaque,
        dwAuthnLevel: u32,
        dwImpLevel: u32,
        pAuthInfo: ?*anyopaque,
        dwCapabilities: u32,
    ) callconv(.winapi) i32;
    extern "oleaut32" fn SysFreeString(bstr: BSTR) callconv(.winapi) void;
    extern "oleaut32" fn VariantClear(pvarg: *VARIANT) callconv(.winapi) i32;

    fn collectMemorySlotInfo(self: *Self) void {
        const COINIT_MULTITHREADED = 0;
        const CLSCTX_INPROC_SERVER = 1;

        // Initialize COM
        const hr_init = CoInitializeEx(null, COINIT_MULTITHREADED);
        if (hr_init < 0 and hr_init != -2147417850) { // S_OK or RPC_E_CHANGED_MODE
            return;
        }
        defer CoUninitialize();

        // Create WbemLocator
        var locator: ?*IWbemLocator = null;
        if (CoCreateInstance(&CLSID_WbemLocator, null, CLSCTX_INPROC_SERVER, &IID_IWbemLocator, @ptrCast(&locator)) < 0) {
            return;
        }
        defer if (locator) |l| l.Release();

        // Connect to WMI
        var services: ?*IWbemServices = null;
        const root_cimv2 = std.unicode.utf8ToUtf16LeStringLiteral("ROOT\\CIMV2");
        if (locator.?.ConnectServer(@constCast(@ptrCast(root_cimv2.ptr)), &services) < 0) {
            return;
        }
        defer if (services) |s| s.Release();

        // Set security on the proxy - required for WMI access
        const RPC_C_AUTHN_WINNT = 10;
        const RPC_C_AUTHZ_NONE = 0;
        const RPC_C_AUTHN_LEVEL_CALL = 3;
        const RPC_C_IMP_LEVEL_IMPERSONATE = 3;
        const EOAC_NONE = 0;
        _ = CoSetProxyBlanket(
            @ptrCast(services.?),
            RPC_C_AUTHN_WINNT,
            RPC_C_AUTHZ_NONE,
            null,
            RPC_C_AUTHN_LEVEL_CALL,
            RPC_C_IMP_LEVEL_IMPERSONATE,
            null,
            EOAC_NONE,
        );

        // Execute query
        var enumerator: ?*IEnumWbemClassObject = null;
        const wql = std.unicode.utf8ToUtf16LeStringLiteral("WQL");
        const query = std.unicode.utf8ToUtf16LeStringLiteral("SELECT Capacity, Speed, SMBIOSMemoryType FROM Win32_PhysicalMemory");
        if (services.?.ExecQuery(@constCast(@ptrCast(wql.ptr)), @constCast(@ptrCast(query.ptr)), &enumerator) < 0) {
            return;
        }
        defer if (enumerator) |e| e.Release();

        // Iterate results
        var slot_index: u32 = 0;
        while (slot_index < 16) : (slot_index += 1) { // Max 16 slots
            var obj: ?*IWbemClassObject = null;
            var returned: u32 = 0;

            if (enumerator.?.Next(&obj, &returned) < 0 or returned == 0) break;
            defer if (obj) |o| o.Release();

            // Get Capacity
            var var_capacity: VARIANT = undefined;
            if (obj.?.Get(@constCast(@ptrCast(std.unicode.utf8ToUtf16LeStringLiteral("Capacity").ptr)), &var_capacity) >= 0) {
                defer _ = VariantClear(&var_capacity);

                var capacity_bytes: ?u64 = null;

                if (var_capacity.vt == VT_UI8 or var_capacity.vt == VT_I8) {
                    capacity_bytes = @bitCast(var_capacity.data.ullVal);
                } else if (var_capacity.vt == VT_BSTR and @intFromPtr(var_capacity.data.bstrVal) != 0) {
                    // Parse string value
                    var buf: [32]u8 = undefined;
                    var len: usize = 0;
                    var i: usize = 0;
                    while (var_capacity.data.bstrVal[i] != 0 and len < buf.len) : (i += 1) {
                        buf[len] = @truncate(var_capacity.data.bstrVal[i]);
                        len += 1;
                    }
                    capacity_bytes = std.fmt.parseInt(u64, buf[0..len], 10) catch null;
                }

                if (capacity_bytes) |bytes| {
                    const capacity_mib = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
                    const key = std.fmt.allocPrint(self.allocator, "Memory slot #{d} capacity (MiB)", .{slot_index}) catch continue;
                    self.allocated_values.append(self.allocator, key) catch {
                        self.allocator.free(key);
                    };
                    self.setDetailFmt(key, "{d:.2}", .{capacity_mib});
                }
            }

            // Get Speed
            var var_speed: VARIANT = undefined;
            if (obj.?.Get(@constCast(@ptrCast(std.unicode.utf8ToUtf16LeStringLiteral("Speed").ptr)), &var_speed) >= 0) {
                defer _ = VariantClear(&var_speed);
                if (var_speed.vt == VT_UI4 or var_speed.vt == VT_I4) {
                    const speed_mhz: u32 = @bitCast(var_speed.data.uintVal);
                    const speed_ghz = @as(f64, @floatFromInt(speed_mhz)) / 1000.0;

                    const key = std.fmt.allocPrint(self.allocator, "Memory slot #{d} clockSpeed (GHz)", .{slot_index}) catch continue;
                    self.allocated_values.append(self.allocator, key) catch {
                        self.allocator.free(key);
                    };
                    self.setDetailFmt(key, "{d:.2}", .{speed_ghz});
                }
            }

            // Get Memory Type (SMBIOSMemoryType)
            var var_type: VARIANT = undefined;
            if (obj.?.Get(@constCast(@ptrCast(std.unicode.utf8ToUtf16LeStringLiteral("SMBIOSMemoryType").ptr)), &var_type) >= 0) {
                defer _ = VariantClear(&var_type);
                if (var_type.vt == VT_UI4 or var_type.vt == VT_I4) {
                    const mem_type: u32 = @bitCast(var_type.data.uintVal);
                    const type_name = getMemoryTypeName(mem_type);

                    const key = std.fmt.allocPrint(self.allocator, "Memory slot #{d} type", .{slot_index}) catch continue;
                    self.allocated_values.append(self.allocator, key) catch {
                        self.allocator.free(key);
                    };
                    self.setDetail(key, type_name);
                }
            }
        }
    }

    fn getMemoryTypeName(smbios_type: u32) []const u8 {
        // SMBIOS Memory Type codes (from DMTF SMBIOS spec)
        return switch (smbios_type) {
            0x01 => "Other",
            0x02 => "Unknown",
            0x03 => "DRAM",
            0x04 => "EDRAM",
            0x05 => "VRAM",
            0x06 => "SRAM",
            0x07 => "RAM",
            0x08 => "ROM",
            0x09 => "Flash",
            0x0A => "EEPROM",
            0x0B => "FEPROM",
            0x0C => "EPROM",
            0x0D => "CDRAM",
            0x0E => "3DRAM",
            0x0F => "SDRAM",
            0x10 => "SGRAM",
            0x11 => "RDRAM",
            0x12 => "DDR",
            0x13 => "DDR2",
            0x14 => "DDR2 FB-DIMM",
            0x18 => "DDR3",
            0x19 => "FBD2",
            0x1A => "DDR4",
            0x1B => "LPDDR",
            0x1C => "LPDDR2",
            0x1D => "LPDDR3",
            0x1E => "LPDDR4",
            0x1F => "Logical non-volatile device",
            0x20 => "HBM",
            0x21 => "HBM2",
            0x22 => "DDR5",
            0x23 => "LPDDR5",
            else => "Unknown",
        };
    }

    fn parseFrequencyFromBrand(brand: []const u8) ?f64 {
        // Look for patterns like "@ 2.00GHz", "2.39 GHz", "2.39GHz"
        var i: usize = 0;
        while (i < brand.len) : (i += 1) {
            // Look for @ symbol (Intel style: "@ 2.00GHz")
            if (brand[i] == '@') {
                i += 1;
                // Skip spaces
                while (i < brand.len and brand[i] == ' ') : (i += 1) {}
                if (parseGhzValue(brand[i..])) |freq| {
                    return freq;
                }
            }
            // Look for digit followed by . and more digits then GHz/MHz
            if (i + 4 < brand.len and isDigit(brand[i])) {
                if (parseGhzValue(brand[i..])) |freq| {
                    // Verify it's followed by GHz or MHz
                    var j = i;
                    while (j < brand.len and (isDigit(brand[j]) or brand[j] == '.')) : (j += 1) {}
                    if (j + 3 <= brand.len) {
                        const suffix = brand[j .. j + 3];
                        if (std.ascii.eqlIgnoreCase(suffix, "GHz") or std.ascii.eqlIgnoreCase(suffix, "MHz")) {
                            return freq;
                        }
                    }
                }
            }
        }
        return null;
    }

    fn parseGhzValue(s: []const u8) ?f64 {
        var value: f64 = 0;
        var decimal_place: f64 = 0;
        var i: usize = 0;

        // Parse integer part
        while (i < s.len and isDigit(s[i])) : (i += 1) {
            value = value * 10 + @as(f64, @floatFromInt(s[i] - '0'));
        }

        // Parse decimal part
        if (i < s.len and s[i] == '.') {
            i += 1;
            decimal_place = 0.1;
            while (i < s.len and isDigit(s[i])) : (i += 1) {
                value += @as(f64, @floatFromInt(s[i] - '0')) * decimal_place;
                decimal_place *= 0.1;
            }
        }

        if (value == 0) return null;

        // Check for MHz suffix (convert to GHz)
        if (i + 3 <= s.len and std.ascii.eqlIgnoreCase(s[i .. i + 3], "MHz")) {
            value /= 1000.0;
        }

        return value;
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn getPrettyMicroarchName(name: []const u8) []const u8 {
        // AMD microarchitectures
        if (std.mem.eql(u8, name, "znver5")) return "Zen 5";
        if (std.mem.eql(u8, name, "znver4")) return "Zen 4";
        if (std.mem.eql(u8, name, "znver3")) return "Zen 3";
        if (std.mem.eql(u8, name, "znver2")) return "Zen 2";
        if (std.mem.eql(u8, name, "znver1")) return "Zen";
        if (std.mem.eql(u8, name, "bdver4")) return "Excavator";
        if (std.mem.eql(u8, name, "bdver3")) return "Steamroller";
        if (std.mem.eql(u8, name, "bdver2")) return "Piledriver";
        if (std.mem.eql(u8, name, "bdver1")) return "Bulldozer";

        // Intel microarchitectures
        if (std.mem.eql(u8, name, "arrowlake")) return "Arrow Lake";
        if (std.mem.eql(u8, name, "arrowlake_s")) return "Arrow Lake-S";
        if (std.mem.eql(u8, name, "lunarlake")) return "Lunar Lake";
        if (std.mem.eql(u8, name, "meteorlake")) return "Meteor Lake";
        if (std.mem.eql(u8, name, "raptorlake")) return "Raptor Lake";
        if (std.mem.eql(u8, name, "alderlake")) return "Alder Lake";
        if (std.mem.eql(u8, name, "rocketlake")) return "Rocket Lake";
        if (std.mem.eql(u8, name, "tigerlake")) return "Tiger Lake";
        if (std.mem.eql(u8, name, "icelake_client")) return "Ice Lake";
        if (std.mem.eql(u8, name, "icelake_server")) return "Ice Lake (Server)";
        if (std.mem.eql(u8, name, "cascadelake")) return "Cascade Lake";
        if (std.mem.eql(u8, name, "cannonlake")) return "Cannon Lake";
        if (std.mem.eql(u8, name, "skylake")) return "Skylake";
        if (std.mem.eql(u8, name, "skylake_avx512")) return "Skylake-X";
        if (std.mem.eql(u8, name, "broadwell")) return "Broadwell";
        if (std.mem.eql(u8, name, "haswell")) return "Haswell";
        if (std.mem.eql(u8, name, "ivybridge")) return "Ivy Bridge";
        if (std.mem.eql(u8, name, "sandybridge")) return "Sandy Bridge";
        if (std.mem.eql(u8, name, "westmere")) return "Westmere";
        if (std.mem.eql(u8, name, "nehalem")) return "Nehalem";
        if (std.mem.eql(u8, name, "core2")) return "Core 2";

        // Fallback to original name
        return name;
    }

    const CpuidResult = struct {
        eax: u32,
        ebx: u32,
        ecx: u32,
        edx: u32,
    };

    fn cpuid(leaf: u32, subleaf: u32) CpuidResult {
        var eax: u32 = undefined;
        var ebx: u32 = undefined;
        var ecx: u32 = undefined;
        var edx: u32 = undefined;

        asm volatile ("cpuid"
            : [_] "={eax}" (eax),
              [_] "={ebx}" (ebx),
              [_] "={ecx}" (ecx),
              [_] "={edx}" (edx),
            : [_] "{eax}" (leaf),
              [_] "{ecx}" (subleaf),
        );

        return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
    }

    // Windows CPU topology
    const SYSTEM_LOGICAL_PROCESSOR_INFORMATION = extern struct {
        ProcessorMask: usize,
        Relationship: u32,
        Data: extern union {
            ProcessorCore: extern struct {
                Flags: u8,
            },
            NumaNode: extern struct {
                NodeNumber: u32,
            },
            Cache: extern struct {
                Level: u8,
                Associativity: u8,
                LineSize: u16,
                Size: u32,
                Type: u32,
            },
            Reserved: [2]u64,
        },
    };

    extern "kernel32" fn GetLogicalProcessorInformation(
        buffer: ?[*]SYSTEM_LOGICAL_PROCESSOR_INFORMATION,
        returnedLength: *u32,
    ) callconv(.winapi) c_int;

    fn collectWindowsCpuTopology(self: *Self) void {
        var buffer_size: u32 = 0;

        // First call to get required buffer size
        _ = GetLogicalProcessorInformation(null, &buffer_size);

        if (buffer_size == 0) return;

        const count = buffer_size / @sizeOf(SYSTEM_LOGICAL_PROCESSOR_INFORMATION);
        const buffer = self.allocator.alloc(SYSTEM_LOGICAL_PROCESSOR_INFORMATION, count) catch return;
        defer self.allocator.free(buffer);

        if (GetLogicalProcessorInformation(buffer.ptr, &buffer_size) == 0) return;

        var physical_cores: u32 = 0;
        var packages: u32 = 0;
        const RelationProcessorCore = 0;
        const RelationProcessorPackage = 3;

        for (buffer[0..count]) |info| {
            if (info.Relationship == RelationProcessorCore) {
                physical_cores += 1;
            } else if (info.Relationship == RelationProcessorPackage) {
                packages += 1;
            }
        }

        if (packages > 0) {
            self.setDetailFmt("Number of physical packages", "{d}", .{packages});
        }
        if (physical_cores > 0) {
            self.setDetailFmt("Number of physical CPUs", "{d}", .{physical_cores});
        }
    }

    const ULARGE_INTEGER = extern struct { QuadPart: u64 };

    extern "kernel32" fn GetDiskFreeSpaceExA(
        lpDirectoryName: ?[*:0]const u8,
        lpFreeBytesAvailableToCaller: ?*ULARGE_INTEGER,
        lpTotalNumberOfBytes: ?*ULARGE_INTEGER,
        lpTotalNumberOfFreeBytes: ?*ULARGE_INTEGER,
    ) callconv(.winapi) c_int;

    fn collectStorageInfo(self: *Self) void {
        if (builtin.os.tag == .windows) {
            // Get free disk space for current directory
            var free_bytes: ULARGE_INTEGER = undefined;
            var total_bytes: ULARGE_INTEGER = undefined;

            if (GetDiskFreeSpaceExA(null, &free_bytes, &total_bytes, null) != 0) {
                const free_mib = free_bytes.QuadPart / (1024 * 1024);
                const total_mib = total_bytes.QuadPart / (1024 * 1024);
                self.setDetailFmt("Storage (workdir)", "available: {d} MiB, total: {d} MiB", .{ free_mib, total_mib });
            }
        }
    }

    // DXGI structures for GPU enumeration
    const GUID = extern struct {
        Data1: u32,
        Data2: u16,
        Data3: u16,
        Data4: [8]u8,
    };

    // Windows MEMORYSTATUSEX structure
    const MEMORYSTATUSEX = extern struct {
        dwLength: u32,
        dwMemoryLoad: u32,
        ullTotalPhys: u64,
        ullAvailPhys: u64,
        ullTotalPageFile: u64,
        ullAvailPageFile: u64,
        ullTotalVirtual: u64,
        ullAvailVirtual: u64,
        ullAvailExtendedVirtual: u64,
    };

    extern "kernel32" fn GlobalMemoryStatusEx(lpBuffer: *MEMORYSTATUSEX) callconv(.winapi) c_int;

    fn collectMemoryInfo(self: *Self) void {
        if (builtin.os.tag == .windows) {
            // Windows: Use GlobalMemoryStatusEx
            var mem_info: MEMORYSTATUSEX = .{
                .dwLength = @sizeOf(MEMORYSTATUSEX),
                .dwMemoryLoad = 0,
                .ullTotalPhys = 0,
                .ullAvailPhys = 0,
                .ullTotalPageFile = 0,
                .ullAvailPageFile = 0,
                .ullTotalVirtual = 0,
                .ullAvailVirtual = 0,
                .ullAvailExtendedVirtual = 0,
            };

            if (GlobalMemoryStatusEx(&mem_info) != 0) {
                const total_mb = mem_info.ullTotalPhys / (1024 * 1024);
                const avail_mb = mem_info.ullAvailPhys / (1024 * 1024);
                const used_mb = total_mb - avail_mb;

                self.setDetailFmt("Memory", "{d} MiB / {d} MiB ({d}% used)", .{
                    used_mb,
                    total_mb,
                    mem_info.dwMemoryLoad,
                });
                self.setDetailFmt("Total Physical Memory", "{d} MiB", .{total_mb});
                self.setDetailFmt("Available Physical Memory", "{d} MiB", .{avail_mb});
                self.setDetailFmt("Virtual memory max", "{d} MiB", .{mem_info.ullTotalVirtual / (1024 * 1024)});
                self.setDetailFmt("Virtual memory used", "{d} MiB", .{(mem_info.ullTotalVirtual - mem_info.ullAvailVirtual) / (1024 * 1024)});

                // Page file is Windows' swap
                const swap_total = mem_info.ullTotalPageFile / (1024 * 1024);
                const swap_avail = mem_info.ullAvailPageFile / (1024 * 1024);
                self.setDetailFmt("Swap memory total", "{d} MiB", .{swap_total});
                self.setDetailFmt("Swap memory used", "{d} MiB", .{swap_total - swap_avail});
            } else {
                self.setDetail("Memory", "Failed to query memory status");
            }
        } else if (builtin.os.tag == .linux) {
            // Linux: Read /proc/meminfo
            const meminfo = Dir.cwd().readFileAlloc(self.io, "/proc/meminfo", self.allocator, .limited(4096)) catch {
                self.setDetail("Memory", "Failed to read /proc/meminfo");
                return;
            };
            // Track allocation so it gets freed in deinit
            self.allocated_values.append(self.allocator, meminfo) catch {
                self.allocator.free(meminfo);
                self.setDetail("Memory", "Failed to read /proc/meminfo");
                return;
            };

            self.setDetail("Memory", meminfo);
        } else {
            self.setDetail("Memory", "Not available on this platform");
        }
    }

    fn setDetailFmt(self: *Self, key: []const u8, comptime fmt: []const u8, args: anytype) void {
        const value = std.fmt.allocPrint(self.allocator, fmt, args) catch {
            self.setDetail(key, "~~ERROR~~");
            return;
        };
        // Track the allocated string so we can free it later
        self.allocated_values.append(self.allocator, value) catch {
            self.allocator.free(value);
            self.setDetail(key, "~~ERROR~~");
            return;
        };
        self.setDetail(key, value);
    }

    pub fn setDetail(self: *Self, key: []const u8, value: []const u8) void {
        self.entries.append(self.allocator, .{ .key = key, .value = value }) catch {
            // During crash reporting, memory may be constrained - losing one entry is acceptable
            std.debug.print("[WARN] CrashReport: Failed to add system detail '{s}' - out of memory\n", .{key});
        };
    }

    pub fn writeDetails(self: *Self, allocator: std.mem.Allocator, buffer: *std.ArrayListUnmanaged(u8)) !void {
        try buffer.appendSlice(allocator, "-- System Details --\n");
        try buffer.appendSlice(allocator, "Details:");

        for (self.entries.items) |entry| {
            try buffer.appendSlice(allocator, "\n\t");
            try buffer.appendSlice(allocator, entry.key);
            try buffer.appendSlice(allocator, ": ");
            try buffer.appendSlice(allocator, entry.value);
        }
    }
};

/// Pre-allocates memory that can be released during OOM to allow crash reporting.
pub const MemoryReserve = struct {
    const RESERVE_SIZE = 10 * 1024 * 1024; // 10 MiB

    var reserve: ?[]u8 = null;
    var backing_allocator: ?std.mem.Allocator = null;

    /// Allocate the memory reserve.
    pub fn allocate() void {
        if (reserve != null) return;

        // Use page allocator for the reserve - it's the most reliable
        backing_allocator = std.heap.page_allocator;
        reserve = backing_allocator.?.alloc(u8, RESERVE_SIZE) catch {
            Logger.init("MemoryReserve").warn("Failed to allocate memory reserve", .{});
            return;
        };

        // Fill with zeros (forces actual allocation on some systems)
        @memset(reserve.?, 0);
    }

    /// Release the memory reserve (call this when OOM occurs).
    pub fn release() void {
        if (reserve) |r| {
            if (backing_allocator) |alloc| {
                alloc.free(r);
            }
            reserve = null;
            backing_allocator = null;
        }
    }

    /// Check if the reserve is allocated.
    pub fn isAllocated() bool {
        return reserve != null;
    }
};

// Tests
test "CrashReport basic" {
    const allocator = std.testing.allocator;

    var report = CrashReport.init(allocator, "Test crash", error.TestError);
    defer report.deinit();

    const category = report.addCategory("Test Category");
    _ = category.setDetail("Key1", "Value1");
    _ = category.setDetail("Key2", "Value2");

    const output = try report.getFriendlyReport();
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "Test crash") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Test Category") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Key1: Value1") != null);
}

test "MemoryReserve" {
    MemoryReserve.allocate();
    try std.testing.expect(MemoryReserve.isAllocated());

    MemoryReserve.release();
    try std.testing.expect(!MemoryReserve.isAllocated());
}
