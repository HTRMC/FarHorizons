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
pub const BlockEntry = chunk.BlockEntry;
pub const CHUNK_SIZE = chunk.CHUNK_SIZE;

// VoxelShape system for face culling
pub const voxel_shape = @import("voxel_shape.zig");
pub const VoxelShape = voxel_shape.VoxelShape;
pub const Direction = voxel_shape.Direction;
pub const Axis = voxel_shape.Axis;
pub const CubeVoxelShape = voxel_shape.CubeVoxelShape;
pub const ArrayVoxelShape = voxel_shape.ArrayVoxelShape;
pub const BitSetDiscreteVoxelShape = voxel_shape.BitSetDiscreteVoxelShape;
pub const BitSetDiscreteVoxelShape2D = voxel_shape.BitSetDiscreteVoxelShape2D;
pub const SliceShape = voxel_shape.SliceShape;

pub const shapes = @import("shapes.zig");
pub const Shapes = shapes.Shapes;
pub const BooleanOp = shapes.BooleanOp;

pub const occlusion_cache = @import("occlusion_cache.zig");
pub const OcclusionCache = occlusion_cache.OcclusionCache;

pub const chunk_access = @import("chunk_access.zig");
pub const ChunkAccess = chunk_access.ChunkAccess;

// Block system
pub const block = @import("block/blocks.zig");
pub const block_mod = @import("block/block.zig");
pub const BlockState = block_mod.BlockState;
