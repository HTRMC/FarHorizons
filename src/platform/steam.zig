const std = @import("std");
const build_options = @import("build_options");

pub const enabled = build_options.steam_enabled;

const log = std.log.scoped(.Steam);

// Opaque handle types (pointers to C++ objects)
const ISteamUserStats = opaque {};

// SteamErrMsg is char[1024]
const SteamErrMsg = [1024]u8;

const ESteamAPIInitResult = enum(c_int) {
    ok = 0,
    failed_generic = 1,
    no_steam_client = 2,
    version_mismatch = 3,
};

extern fn SteamAPI_InitFlat(out_err_msg: ?*SteamErrMsg) callconv(.c) ESteamAPIInitResult;
extern fn SteamAPI_Shutdown() callconv(.c) void;
extern fn SteamAPI_RunCallbacks() callconv(.c) void;
extern fn SteamAPI_RestartAppIfNecessary(app_id: u32) callconv(.c) bool;

extern fn SteamAPI_SteamUserStats_v013() callconv(.c) ?*ISteamUserStats;
extern fn SteamAPI_ISteamUserStats_SetAchievement(self: *ISteamUserStats, name: [*:0]const u8) callconv(.c) bool;
extern fn SteamAPI_ISteamUserStats_GetAchievement(self: *ISteamUserStats, name: [*:0]const u8, achieved: *bool) callconv(.c) bool;
extern fn SteamAPI_ISteamUserStats_ClearAchievement(self: *ISteamUserStats, name: [*:0]const u8) callconv(.c) bool;
extern fn SteamAPI_ISteamUserStats_StoreStats(self: *ISteamUserStats) callconv(.c) bool;
extern fn SteamAPI_ISteamUserStats_IndicateAchievementProgress(self: *ISteamUserStats, name: [*:0]const u8, cur: u32, max: u32) callconv(.c) bool;
extern fn SteamAPI_ISteamUserStats_GetNumAchievements(self: *ISteamUserStats) callconv(.c) u32;

const APP_ID: u32 = 3268420;

var user_stats: ?*ISteamUserStats = null;
var initialized = false;

pub fn init() bool {
    if (!enabled) return true;

    if (SteamAPI_RestartAppIfNecessary(APP_ID)) {
        // Steam is relaunching the game through the Steam client.
        // The current process should exit.
        log.info("Restarting through Steam client...", .{});
        std.process.exit(0);
    }

    var err_msg: SteamErrMsg = undefined;
    const result = SteamAPI_InitFlat(&err_msg);

    if (result != .ok) {
        const msg = std.mem.sliceTo(&err_msg, 0);
        log.err("Steam init failed: {s}", .{msg});
        return false;
    }

    user_stats = SteamAPI_SteamUserStats_v013();
    if (user_stats == null) {
        log.err("Failed to get ISteamUserStats interface", .{});
        shutdown();
        return false;
    }

    initialized = true;
    log.info("Steam initialized successfully", .{});
    return true;
}

pub fn shutdown() void {
    if (!enabled) return;
    if (!initialized) return;

    SteamAPI_Shutdown();
    user_stats = null;
    initialized = false;
    log.info("Steam shut down", .{});
}

pub fn runCallbacks() void {
    if (!enabled) return;
    if (!initialized) return;
    SteamAPI_RunCallbacks();
}

pub fn setAchievement(name: [*:0]const u8) bool {
    const stats = user_stats orelse return false;
    if (!SteamAPI_ISteamUserStats_SetAchievement(stats, name)) {
        log.warn("Failed to set achievement: {s}", .{name});
        return false;
    }
    if (!SteamAPI_ISteamUserStats_StoreStats(stats)) {
        log.warn("Failed to store stats after setting achievement: {s}", .{name});
        return false;
    }
    log.info("Achievement unlocked: {s}", .{name});
    return true;
}

pub fn getAchievement(name: [*:0]const u8) ?bool {
    const stats = user_stats orelse return null;
    var achieved: bool = false;
    if (!SteamAPI_ISteamUserStats_GetAchievement(stats, name, &achieved)) {
        return null;
    }
    return achieved;
}

pub fn clearAchievement(name: [*:0]const u8) bool {
    const stats = user_stats orelse return false;
    if (!SteamAPI_ISteamUserStats_ClearAchievement(stats, name)) return false;
    return SteamAPI_ISteamUserStats_StoreStats(stats);
}

pub fn indicateProgress(name: [*:0]const u8, current: u32, max: u32) bool {
    const stats = user_stats orelse return false;
    return SteamAPI_ISteamUserStats_IndicateAchievementProgress(stats, name, current, max);
}
