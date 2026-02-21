const std = @import("std");
const WorldState = @import("WorldState.zig");
const types = @import("../renderer/vulkan/types.zig");
const GpuVertex = types.GpuVertex;
const DrawCommand = types.DrawCommand;
const tracy = @import("../platform/tracy.zig");

pub const MeshWorker = struct {
    state: std.atomic.Value(State),
    thread: ?std.Thread,
    allocator: std.mem.Allocator,
    world: *const WorldState.World,

    // Result storage (written by worker thread, consumed by poll)
    results: [WorldState.TOTAL_WORLD_CHUNKS]?ChunkResult,
    result_coords: [WorldState.TOTAL_WORLD_CHUNKS]WorldState.ChunkCoord,
    result_count: u32,
    is_initial: bool,

    // Input: which chunks to mesh (copied from dirty set before thread spawn)
    pending_coords: [WorldState.TOTAL_WORLD_CHUNKS]WorldState.ChunkCoord,
    pending_count: u8,
    pending_initial: bool,

    pub const State = enum(u8) { idle, working, ready };

    pub const ChunkResult = struct {
        vertices: []GpuVertex,
        indices: []u32,
        vertex_count: u32,
        index_count: u32,
        coord: WorldState.ChunkCoord,
    };

    pub const PollResult = struct {
        results: []const ?ChunkResult,
        coords: []const WorldState.ChunkCoord,
        count: u32,
        is_initial: bool,
    };

    pub fn init(allocator: std.mem.Allocator, world: *const WorldState.World) MeshWorker {
        return .{
            .state = std.atomic.Value(State).init(.idle),
            .thread = null,
            .allocator = allocator,
            .world = world,
            .results = .{null} ** WorldState.TOTAL_WORLD_CHUNKS,
            .result_coords = undefined,
            .result_count = 0,
            .is_initial = false,
            .pending_coords = undefined,
            .pending_count = 0,
            .pending_initial = false,
        };
    }

    /// Start meshing all chunks (initial world load).
    pub fn startAll(self: *MeshWorker) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.pending_initial = true;
        self.pending_count = 0;
        self.state.store(.working, .release);
        self.thread = std.Thread.spawn(.{}, workerFn, .{self}) catch |err| {
            std.log.err("Failed to spawn mesh worker thread: {}", .{err});
            self.state.store(.idle, .release);
            return;
        };
    }

    /// Start meshing specific dirty chunks.
    pub fn startDirty(self: *MeshWorker, coords: []const WorldState.ChunkCoord) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.pending_initial = false;
        self.pending_count = @intCast(coords.len);
        @memcpy(self.pending_coords[0..coords.len], coords);
        self.state.store(.working, .release);
        self.thread = std.Thread.spawn(.{}, workerFn, .{self}) catch |err| {
            std.log.err("Failed to spawn mesh worker thread: {}", .{err});
            self.state.store(.idle, .release);
            return;
        };
    }

    pub fn poll(self: *MeshWorker) ?PollResult {
        if (self.state.load(.acquire) != .ready) return null;

        const result = PollResult{
            .results = &self.results,
            .coords = &self.result_coords,
            .count = self.result_count,
            .is_initial = self.is_initial,
        };

        self.state.store(.idle, .release);
        return result;
    }

    /// Free mesh data for a specific result (caller invokes after uploading to GPU).
    pub fn freeResult(self: *MeshWorker, idx: usize) void {
        if (self.results[idx]) |r| {
            self.allocator.free(r.vertices);
            self.allocator.free(r.indices);
            self.results[idx] = null;
        }
    }

    pub fn deinit(self: *MeshWorker) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        for (&self.results) |*r| {
            if (r.*) |result| {
                self.allocator.free(result.vertices);
                self.allocator.free(result.indices);
                r.* = null;
            }
        }
    }

    fn workerFn(self: *MeshWorker) void {
        const tz = tracy.zone(@src(), "MeshWorker.workerFn");
        defer tz.end();

        self.result_count = 0;
        self.is_initial = self.pending_initial;

        if (self.pending_initial) {
            // Mesh all chunks
            for (0..WorldState.WORLD_CHUNKS_Y) |cy| {
                for (0..WorldState.WORLD_CHUNKS_Z) |cz| {
                    for (0..WorldState.WORLD_CHUNKS_X) |cx| {
                        const coord = WorldState.ChunkCoord{
                            .cx = @intCast(cx),
                            .cy = @intCast(cy),
                            .cz = @intCast(cz),
                        };
                        self.meshChunk(coord);
                    }
                }
            }
        } else {
            // Mesh only dirty chunks
            for (self.pending_coords[0..self.pending_count]) |coord| {
                self.meshChunk(coord);
            }
        }

        self.state.store(.ready, .release);
    }

    fn meshChunk(self: *MeshWorker, coord: WorldState.ChunkCoord) void {
        const mesh = WorldState.generateChunkMesh(self.allocator, self.world, coord) catch |err| {
            std.log.err("Chunk mesh generation failed ({},{},{}): {}", .{ coord.cx, coord.cy, coord.cz, err });
            return;
        };

        const idx = self.result_count;
        self.result_coords[idx] = coord;
        self.results[idx] = .{
            .vertices = mesh.vertices,
            .indices = mesh.indices,
            .vertex_count = mesh.vertex_count,
            .index_count = mesh.index_count,
            .coord = coord,
        };
        self.result_count += 1;
    }
};
