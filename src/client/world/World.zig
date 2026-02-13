/// World module - chunk management and async loading
pub const render_chunk = @import("RenderChunk.zig");
pub const RenderChunk = render_chunk.RenderChunk;
pub const ChunkMesh = render_chunk.ChunkMesh;
pub const ChunkState = render_chunk.ChunkState;
pub const CompletedMesh = render_chunk.CompletedMesh;

pub const thread_pool = @import("ThreadPool.zig");
pub const ThreadPool = thread_pool.ThreadPool;

pub const chunk_mesher = @import("ChunkMesher.zig");
pub const ChunkMesher = chunk_mesher.ChunkMesher;

pub const chunk_manager = @import("ChunkManager.zig");
pub const ChunkManager = chunk_manager.ChunkManager;

pub const mesh_scheduler_thread = @import("MeshSchedulerThread.zig");
pub const MeshSchedulerThread = mesh_scheduler_thread.MeshSchedulerThread;
