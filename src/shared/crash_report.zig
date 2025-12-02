const std = @import("std");
const builtin = @import("builtin");
const Logger = @import("logger.zig").Logger;

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
/// Similar to Minecraft's CrashReport class.
pub const CrashReport = struct {
    const Self = @This();
    const logger = Logger.init("CrashReport");

    allocator: std.mem.Allocator,
    title: []const u8,
    error_msg: ?[]const u8,
    stack_trace: ?*std.builtin.StackTrace,
    categories: std.ArrayListUnmanaged(CrashReportCategory),
    system_report: SystemReport,
    save_file: ?[]const u8 = null,
    timestamp: i64,

    /// Create a new crash report with a title and optional error.
    pub fn init(allocator: std.mem.Allocator, title: []const u8, err: ?anyerror) Self {
        return Self{
            .allocator = allocator,
            .title = title,
            .error_msg = if (err) |e| @errorName(e) else null,
            .stack_trace = @errorReturnTrace(),
            .categories = .{},
            .system_report = SystemReport.init(allocator),
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
    pub fn forError(allocator: std.mem.Allocator, err: anyerror, title: []const u8) Self {
        return Self.init(allocator, title, err);
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
    pub fn saveToFile(self: *Self, dir_path: []const u8) ![]const u8 {
        const report = try self.getFriendlyReport();
        defer self.allocator.free(report);

        // Generate filename with timestamp
        var filename_buf: [64]u8 = undefined;
        const filename = try std.fmt.bufPrint(&filename_buf, "crash-{d}.txt", .{self.timestamp});

        const full_path = try std.fs.path.join(self.allocator, &.{ dir_path, filename });

        // Ensure directory exists
        std.fs.cwd().makePath(dir_path) catch |err| {
            logger.err("Failed to create crash report directory: {s}", .{@errorName(err)});
            return err;
        };

        // Write the file
        const file = try std.fs.cwd().createFile(full_path, .{});
        defer file.close();
        try file.writeAll(report);

        self.save_file = full_path;
        logger.info("Crash report saved to {s}", .{full_path});

        return full_path;
    }

    /// Pre-load crash reporting system (warm up allocations, etc.)
    pub fn preload(allocator: std.mem.Allocator) void {
        // Pre-allocate memory reserve for OOM situations
        MemoryReserve.allocate();

        // Create a dummy crash report to ensure all code paths are loaded
        var dummy = CrashReport.init(allocator, "Don't panic!", null);
        defer dummy.deinit();

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
/// Similar to Minecraft's CrashReportCategory.
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
        self.entries.append(self.allocator, .{ .key = key, .value = value }) catch {};
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
/// Similar to Minecraft's SystemReport.
pub const SystemReport = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    entries: std.StringHashMap([]const u8),
    allocated_values: std.ArrayListUnmanaged([]const u8),

    pub fn init(allocator: std.mem.Allocator) Self {
        var self = Self{
            .allocator = allocator,
            .entries = std.StringHashMap([]const u8).init(allocator),
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
        self.entries.deinit();
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

        // Storage info
        self.collectStorageInfo();

        // GPU info (Windows only via DXGI)
        if (builtin.os.tag == .windows) {
            self.collectGpuInfo();
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
        const cpu_count = std.Thread.getCpuCount() catch 0;
        self.setDetailFmt("CPUs", "{d}", .{cpu_count});

        // CPU info from builtin
        self.setDetail("CPU Architecture", @tagName(builtin.cpu.arch));

        // On x86_64, try to get more info via std library
        if (builtin.cpu.arch == .x86_64) {
            const cpu_model = builtin.cpu.model;
            self.setDetail("CPU Model", cpu_model.name);
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

    const IID_IDXGIFactory = GUID{
        .Data1 = 0x7b7166ec,
        .Data2 = 0x21c7,
        .Data3 = 0x44ae,
        .Data4 = .{ 0xb2, 0x1a, 0xc9, 0xae, 0x32, 0x1a, 0xe3, 0x69 },
    };

    const DXGI_ADAPTER_DESC = extern struct {
        Description: [128]u16,
        VendorId: u32,
        DeviceId: u32,
        SubSysId: u32,
        Revision: u32,
        DedicatedVideoMemory: usize,
        DedicatedSystemMemory: usize,
        SharedSystemMemory: usize,
        AdapterLuid: extern struct { LowPart: u32, HighPart: i32 },
    };

    const IDXGIAdapter = extern struct {
        vtable: *const VTable,

        const VTable = extern struct {
            // IUnknown
            QueryInterface: *const fn (*IDXGIAdapter, *const GUID, *?*anyopaque) callconv(.winapi) i32,
            AddRef: *const fn (*IDXGIAdapter) callconv(.winapi) u32,
            Release: *const fn (*IDXGIAdapter) callconv(.winapi) u32,
            // IDXGIObject
            SetPrivateData: *const anyopaque,
            SetPrivateDataInterface: *const anyopaque,
            GetPrivateData: *const anyopaque,
            GetParent: *const anyopaque,
            // IDXGIAdapter
            EnumOutputs: *const anyopaque,
            GetDesc: *const fn (*IDXGIAdapter, *DXGI_ADAPTER_DESC) callconv(.winapi) i32,
        };

        fn Release(self: *IDXGIAdapter) void {
            _ = self.vtable.Release(self);
        }

        fn GetDesc(self: *IDXGIAdapter, desc: *DXGI_ADAPTER_DESC) i32 {
            return self.vtable.GetDesc(self, desc);
        }
    };

    const IDXGIFactory = extern struct {
        vtable: *const VTable,

        const VTable = extern struct {
            // IUnknown
            QueryInterface: *const fn (*IDXGIFactory, *const GUID, *?*anyopaque) callconv(.winapi) i32,
            AddRef: *const fn (*IDXGIFactory) callconv(.winapi) u32,
            Release: *const fn (*IDXGIFactory) callconv(.winapi) u32,
            // IDXGIObject
            SetPrivateData: *const anyopaque,
            SetPrivateDataInterface: *const anyopaque,
            GetPrivateData: *const anyopaque,
            GetParent: *const anyopaque,
            // IDXGIFactory
            EnumAdapters: *const fn (*IDXGIFactory, u32, *?*IDXGIAdapter) callconv(.winapi) i32,
        };

        fn Release(self: *IDXGIFactory) void {
            _ = self.vtable.Release(self);
        }

        fn EnumAdapters(self: *IDXGIFactory, index: u32, adapter: *?*IDXGIAdapter) i32 {
            return self.vtable.EnumAdapters(self, index, adapter);
        }
    };

    extern "dxgi" fn CreateDXGIFactory(riid: *const GUID, ppFactory: *?*IDXGIFactory) callconv(.winapi) i32;

    fn collectGpuInfo(self: *Self) void {
        var factory: ?*IDXGIFactory = null;
        const hr = CreateDXGIFactory(&IID_IDXGIFactory, &factory);

        if (hr < 0 or factory == null) {
            self.setDetail("Graphics", "Failed to create DXGI factory");
            return;
        }
        defer factory.?.Release();

        var gpu_index: u32 = 0;
        while (gpu_index < 8) : (gpu_index += 1) { // Max 8 GPUs
            var adapter: ?*IDXGIAdapter = null;
            const enum_hr = factory.?.EnumAdapters(gpu_index, &adapter);

            if (enum_hr < 0 or adapter == null) break;
            defer adapter.?.Release();

            var desc: DXGI_ADAPTER_DESC = undefined;
            if (adapter.?.GetDesc(&desc) >= 0) {
                // Convert wide string (UTF-16) to UTF-8
                var name_buf: [256]u8 = undefined;
                var name_len: usize = 0;
                for (desc.Description) |c| {
                    if (c == 0) break;
                    if (c < 128) {
                        if (name_len < name_buf.len - 1) {
                            name_buf[name_len] = @truncate(c);
                            name_len += 1;
                        }
                    }
                }

                // Allocate GPU name on heap (stack buffer becomes invalid after loop)
                const gpu_name = std.fmt.allocPrint(self.allocator, "{s}", .{name_buf[0..name_len]}) catch continue;
                self.allocated_values.append(self.allocator, gpu_name) catch {
                    self.allocator.free(gpu_name);
                    continue;
                };

                const vram_mib = desc.DedicatedVideoMemory / (1024 * 1024);

                // Get vendor name from VendorId
                const vendor = switch (desc.VendorId) {
                    0x10DE => "NVIDIA",
                    0x1002 => "AMD",
                    0x8086 => "Intel",
                    0x1414 => "Microsoft",
                    else => "Unknown",
                };

                // Build key names with GPU index - must allocate to avoid stack issues
                const key_name_str = std.fmt.allocPrint(self.allocator, "Graphics card #{d} name", .{gpu_index}) catch continue;
                const key_vendor_str = std.fmt.allocPrint(self.allocator, "Graphics card #{d} vendor", .{gpu_index}) catch continue;
                const key_vram_str = std.fmt.allocPrint(self.allocator, "Graphics card #{d} VRAM (MiB)", .{gpu_index}) catch continue;
                const key_device_str = std.fmt.allocPrint(self.allocator, "Graphics card #{d} deviceId", .{gpu_index}) catch continue;

                // Track allocated keys for cleanup
                self.allocated_values.append(self.allocator, key_name_str) catch {};
                self.allocated_values.append(self.allocator, key_vendor_str) catch {};
                self.allocated_values.append(self.allocator, key_vram_str) catch {};
                self.allocated_values.append(self.allocator, key_device_str) catch {};

                self.setDetail(key_name_str, gpu_name);
                self.setDetail(key_vendor_str, vendor);
                self.setDetailFmt(key_vram_str, "{d}", .{vram_mib});
                self.setDetailFmt(key_device_str, "0x{X:0>4}", .{desc.DeviceId});
            }
        }
    }

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
            const file = std.fs.openFileAbsolute("/proc/meminfo", .{}) catch {
                self.setDetail("Memory", "Failed to read /proc/meminfo");
                return;
            };
            defer file.close();

            var buf: [4096]u8 = undefined;
            const bytes_read = file.readAll(&buf) catch {
                self.setDetail("Memory", "Failed to read /proc/meminfo");
                return;
            };

            self.setDetail("Memory", buf[0..bytes_read]);
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
        self.entries.put(key, value) catch {};
    }

    pub fn writeDetails(self: *Self, allocator: std.mem.Allocator, buffer: *std.ArrayListUnmanaged(u8)) !void {
        try buffer.appendSlice(allocator, "-- System Details --\n");
        try buffer.appendSlice(allocator, "Details:");

        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            try buffer.appendSlice(allocator, "\n\t");
            try buffer.appendSlice(allocator, entry.key_ptr.*);
            try buffer.appendSlice(allocator, ": ");
            try buffer.appendSlice(allocator, entry.value_ptr.*);
        }
    }
};

/// Pre-allocates memory that can be released during OOM to allow crash reporting.
/// Similar to Minecraft's MemoryReserve.
pub const MemoryReserve = struct {
    const RESERVE_SIZE = 10 * 1024 * 1024; // 10 MiB, same as Minecraft

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
