// Shared module - exports common functionality for client and server
pub const Logger = @import("logger.zig").Logger;
pub const Level = @import("logger.zig").Level;

// Game configuration
pub const game_config = @import("game_config.zig");
pub const GameConfig = game_config.GameConfig;
pub const FolderData = game_config.FolderData;
pub const UserData = game_config.UserData;
pub const DisplayData = game_config.DisplayData;
pub const GameData = game_config.GameData;
pub const QuickPlayData = game_config.QuickPlayData;

// Crash reporting
pub const crash_report = @import("crash_report.zig");
pub const CrashReport = crash_report.CrashReport;
pub const CrashReportCategory = crash_report.CrashReportCategory;
pub const SystemReport = crash_report.SystemReport;
pub const MemoryReserve = crash_report.MemoryReserve;

// Math utilities
pub const math = @import("math.zig");
pub const Vec3 = math.Vec3;
pub const Mat4 = math.Mat4;

// Camera
pub const Camera = @import("camera.zig").Camera;

// Entity hierarchy (like Minecraft's)
pub const Entity = @import("entity.zig").Entity;
pub const LivingEntity = @import("living_entity.zig").LivingEntity;
pub const Player = @import("player.zig").Player;
pub const Abilities = @import("abilities.zig").Abilities;

// World data
pub const chunk = @import("chunk.zig");
pub const Chunk = chunk.Chunk;
pub const BlockType = chunk.BlockType;
pub const CHUNK_SIZE = chunk.CHUNK_SIZE;
