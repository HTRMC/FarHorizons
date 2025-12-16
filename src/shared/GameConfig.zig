    const std = @import("std");

/// Game configuration - passed from Main to the client/server
pub const GameConfig = struct {
    user: UserData,
    display: DisplayData,
    location: FolderData,
    game: GameData,
    quick_play: QuickPlayData,

    pub fn init(
        user: UserData,
        display: DisplayData,
        location: FolderData,
        game: GameData,
        quick_play: QuickPlayData,
    ) GameConfig {
        return .{
            .user = user,
            .display = display,
            .location = location,
            .game = game,
            .quick_play = quick_play,
        };
    }
};

/// User authentication and network proxy data
pub const UserData = struct {
    username: []const u8,
    uuid: ?[36]u8 = null, // UUID string format
    access_token: ?[]const u8 = null,
    proxy: ?ProxyConfig = null,

    pub fn init(username: []const u8) UserData {
        return .{ .username = username };
    }
};

/// Network proxy configuration
pub const ProxyConfig = struct {
    proxy_type: ProxyType,
    address: []const u8,
    port: u16,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,

    pub const ProxyType = enum {
        direct,
        http,
        socks,
    };
};

/// Display/window configuration
pub const DisplayData = struct {
    width: u32 = 854,
    height: u32 = 480,
    fullscreen: bool = false,
    fullscreen_width: ?u32 = null,
    fullscreen_height: ?u32 = null,

    pub fn init() DisplayData {
        return .{};
    }

    pub fn withSize(width: u32, height: u32) DisplayData {
        return .{ .width = width, .height = height };
    }
};

/// Game directory locations
pub const FolderData = struct {
    game_directory: []const u8,
    resource_pack_directory: []const u8,
    asset_directory: []const u8,
    asset_index: ?[]const u8 = null,

    pub fn init(game_dir: []const u8) FolderData {
        return .{
            .game_directory = game_dir,
            .resource_pack_directory = game_dir, // TODO: append /resourcepacks
            .asset_directory = game_dir, // TODO: append /assets
        };
    }
};

/// Game launch settings
pub const GameData = struct {
    demo: bool = false,
    launch_version: []const u8,
    version_type: []const u8 = "release",
    disable_multiplayer: bool = false,
    disable_chat: bool = false,

    pub fn init(version: []const u8) GameData {
        return .{ .launch_version = version };
    }
};

/// Quick play options for fast game joining
pub const QuickPlayData = struct {
    variant: QuickPlayVariant = .disabled,
    log_path: ?[]const u8 = null,

    pub fn init() QuickPlayData {
        return .{};
    }

    pub fn isEnabled(self: QuickPlayData) bool {
        return switch (self.variant) {
            .disabled => false,
            .singleplayer => |data| data.world_id != null,
            .multiplayer => |data| data.server_address.len > 0,
            .realms => |data| data.realm_id.len > 0,
        };
    }
};

pub const QuickPlayVariant = union(enum) {
    disabled: void,
    singleplayer: SingleplayerData,
    multiplayer: MultiplayerData,
    realms: RealmsData,

    pub const SingleplayerData = struct {
        world_id: ?[]const u8 = null,
    };

    pub const MultiplayerData = struct {
        server_address: []const u8,
    };

    pub const RealmsData = struct {
        realm_id: []const u8,
    };
};
