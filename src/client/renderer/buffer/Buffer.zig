/// Buffer management module
/// Provides arena-based buffer allocation for GPU resources
pub const AllocationArena = @import("AllocationArena.zig").AllocationArena;
pub const Allocation = @import("AllocationArena.zig").Allocation;
pub const Region = @import("AllocationArena.zig").Region;

pub const BufferArena = @import("BufferArena.zig").BufferArena;
pub const BufferSlice = @import("BufferArena.zig").BufferSlice;

pub const StagingRing = @import("StagingRing.zig").StagingRing;
pub const PendingCopy = @import("StagingRing.zig").PendingCopy;

pub const ChunkBufferManager = @import("ChunkBufferManager.zig").ChunkBufferManager;
pub const ChunkBufferAllocation = @import("ChunkBufferManager.zig").ChunkBufferAllocation;
pub const ChunkBufferConfig = @import("ChunkBufferManager.zig").ChunkBufferConfig;
