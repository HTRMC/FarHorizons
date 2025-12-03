const std = @import("std");
const shared = @import("shared");
const Logger = shared.Logger;
const GameConfig = shared.GameConfig;
const FolderData = shared.FolderData;
const UserData = shared.UserData;
const DisplayData = shared.DisplayData;
const GameData = shared.GameData;
const QuickPlayData = shared.QuickPlayData;
const CrashReport = shared.CrashReport;
const FarHorizonsClient = @import("farhorizonsclient.zig").FarHorizonsClient;

pub const Main = struct {
    const Self = @This();
    const logger = Logger.init("Main");

    pub fn init() Self {
        return Self{};
    }

    pub fn run() !void {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        // Use arena for strings that live for the program's lifetime
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        logger.info("Starting FarHorizons Client", .{});

        // Parse command line arguments
        const parsed_args = try parseArgs(arena_allocator);

        // Build game configuration
        const folder_data = FolderData{
            .game_directory = parsed_args.game_dir,
            .asset_directory = parsed_args.assets_dir orelse
                try std.fs.path.join(arena_allocator, &.{ parsed_args.game_dir, "assets" }),
            .resource_pack_directory = parsed_args.resource_pack_dir orelse
                try std.fs.path.join(arena_allocator, &.{ parsed_args.game_dir, "resourcepacks" }),
        };

        const config = GameConfig{
            .user = UserData.init("Player"),
            .display = DisplayData.init(),
            .location = folder_data,
            .game = GameData.init("1.0.0"),
            .quick_play = QuickPlayData.init(),
        };

        logger.info("Game directory: {s}", .{config.location.game_directory});
        logger.info("Assets directory: {s}", .{config.location.asset_directory});
        logger.info("Resource packs directory: {s}", .{config.location.resource_pack_directory});

        // Test crash if requested
        if (parsed_args.test_crash) {
            logger.info("Test crash requested!", .{});
            return error.TestCrash;
        }

        var client = FarHorizonsClient.init(allocator, config);
        try client.run();
    }

    const ParsedArgs = struct {
        game_dir: []const u8,
        assets_dir: ?[]const u8,
        resource_pack_dir: ?[]const u8,
        test_crash: bool = false,
    };

    fn parseArgs(allocator: std.mem.Allocator) !ParsedArgs {
        var args = try std.process.argsWithAllocator(allocator);
        defer args.deinit();

        // Skip executable name
        _ = args.skip();

        var game_dir: []const u8 = ".";
        var assets_dir: ?[]const u8 = null;
        var resource_pack_dir: ?[]const u8 = null;
        var test_crash: bool = false;

        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--gameDir")) {
                if (args.next()) |value| {
                    game_dir = try allocator.dupe(u8, value);
                } else {
                    logger.err("--gameDir requires a value", .{});
                    return error.MissingArgument;
                }
            } else if (std.mem.eql(u8, arg, "--assetsDir")) {
                if (args.next()) |value| {
                    assets_dir = try allocator.dupe(u8, value);
                } else {
                    logger.err("--assetsDir requires a value", .{});
                    return error.MissingArgument;
                }
            } else if (std.mem.eql(u8, arg, "--resourcePackDir")) {
                if (args.next()) |value| {
                    resource_pack_dir = try allocator.dupe(u8, value);
                } else {
                    logger.err("--resourcePackDir requires a value", .{});
                    return error.MissingArgument;
                }
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                printHelp();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--testCrash")) {
                test_crash = true;
            } else {
                logger.warn("Unknown argument: {s}", .{arg});
            }
        }

        return ParsedArgs{
            .game_dir = game_dir,
            .assets_dir = assets_dir,
            .resource_pack_dir = resource_pack_dir,
            .test_crash = test_crash,
        };
    }

    fn printHelp() void {
        const help_text =
            \\FarHorizons Client
            \\
            \\Usage: farhorizons-client [options]
            \\
            \\Options:
            \\  --gameDir <path>         Game directory (default: current directory)
            \\  --assetsDir <path>       Assets directory (default: <gameDir>/assets)
            \\  --resourcePackDir <path> Resource packs directory (default: <gameDir>/resourcepacks)
            \\  --testCrash              Trigger a test crash to verify crash reporting
            \\  --help, -h               Show this help message
            \\
        ;
        std.debug.print("{s}", .{help_text});
    }
};

pub fn main() void {
    // Use page allocator for crash reporting (most reliable)
    const crash_allocator = std.heap.page_allocator;

    // Preload crash reporting system
    CrashReport.preload(crash_allocator);

    // Run the client
    Main.run() catch |err| {
        Main.logger.err("Fatal error: {s}", .{@errorName(err)});

        // Generate crash report
        var report = CrashReport.forError(crash_allocator, err, "Running FarHorizons Client");

        // Add initialization category
        const init_cat = report.addCategory("Initialization");
        _ = init_cat.setDetail("Stage", "Client startup");

        // Try to save the crash report
        _ = report.saveToFile("crash-reports") catch |save_err| {
            Main.logger.err("Failed to save crash report: {s}", .{@errorName(save_err)});
        };

        // Print to console as well
        if (report.getFriendlyReport()) |friendly| {
            std.debug.print("\n{s}\n", .{friendly});
            crash_allocator.free(friendly);
        } else |_| {}

        report.deinit();
    };
}
