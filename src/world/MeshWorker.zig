const std = @import("std");
const WorldState = @import("WorldState.zig");
const ChunkMap = @import("ChunkMap.zig").ChunkMap;
const types = @import("../renderer/vulkan/types.zig");
const FaceData = types.FaceData;
const LightEntry = types.LightEntry;
const tracy = @import("../platform/tracy.zig");
const Io = std.Io;

pub const MeshWorker = struct {
    const MAX_INPUT = 256;
    pub const MAX_OUTPUT = 64;

    pub const MeshRequest = struct {
        key: WorldState.ChunkKey,
        light_only: bool,
    };

    // Input queue
    input_queue: [MAX_INPUT]MeshRequest,
    input_len: u32,
    input_mutex: Io.Mutex,
    input_cond: Io.Condition,

    // Output queue (consumed by TransferPipeline thread)
    output_queue: [MAX_OUTPUT]ChunkResult,
    output_len: u32,
    output_mutex: Io.Mutex,
    output_cond: Io.Condition,
    output_drained_cond: Io.Condition,

    // State
    allocator: std.mem.Allocator,
    chunk_map: *const ChunkMap,

    thread: ?std.Thread,
    shutdown: std.atomic.Value(bool),

    pub const ChunkResult = struct {
        faces: []FaceData,
        face_counts: [6]u32,
        total_face_count: u32,
        lights: []LightEntry,
        light_count: u32,
        key: WorldState.ChunkKey,
        light_only: bool,
    };

    pub fn initInPlace(
        self: *MeshWorker,
        allocator: std.mem.Allocator,
        chunk_map: *const ChunkMap,
    ) void {
        self.* = .{
            .input_queue = undefined,
            .input_len = 0,
            .input_mutex = .init,
            .input_cond = .init,
            .output_queue = undefined,
            .output_len = 0,
            .output_mutex = .init,
            .output_cond = .init,
            .output_drained_cond = .init,
            .allocator = allocator,
            .chunk_map = chunk_map,
            .thread = null,
            .shutdown = std.atomic.Value(bool).init(false),
        };
    }

    pub fn start(self: *MeshWorker) void {
        self.thread = std.Thread.spawn(.{ .stack_size = 4 * 1024 * 1024 }, workerFn, .{self}) catch |err| {
            std.log.err("Failed to spawn mesh worker thread: {}", .{err});
            return;
        };
    }

    pub fn stop(self: *MeshWorker) void {
        self.shutdown.store(true, .release);
        const io = Io.Threaded.global_single_threaded.io();
        self.input_cond.broadcast(io);
        self.output_drained_cond.broadcast(io);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        // Free any remaining output results
        for (self.output_queue[0..self.output_len]) |r| {
            if (!r.light_only) self.allocator.free(r.faces);
            self.allocator.free(r.lights);
        }
        self.output_len = 0;
    }

    pub fn syncChunkMap(self: *MeshWorker, chunk_map: *const ChunkMap) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.input_mutex.lockUncancelable(io);
        self.chunk_map = chunk_map;
        self.input_mutex.unlock(io);
    }

    pub fn enqueue(self: *MeshWorker, key: WorldState.ChunkKey) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.input_mutex.lockUncancelable(io);
        defer self.input_mutex.unlock(io);

        // Dedup: full always wins
        for (self.input_queue[0..self.input_len]) |*r| {
            if (r.key.eql(key)) {
                r.light_only = false; // upgrade to full
                return;
            }
        }
        if (self.input_len < MAX_INPUT) {
            self.input_queue[self.input_len] = .{ .key = key, .light_only = false };
            self.input_len += 1;
        }
        self.input_cond.signal(io);
    }

    pub fn enqueueBatch(self: *MeshWorker, keys: []const WorldState.ChunkKey) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.input_mutex.lockUncancelable(io);
        defer self.input_mutex.unlock(io);

        for (keys) |key| {
            // Dedup: full always wins
            var found = false;
            for (self.input_queue[0..self.input_len]) |*r| {
                if (r.key.eql(key)) {
                    r.light_only = false; // upgrade to full
                    found = true;
                    break;
                }
            }
            if (!found and self.input_len < MAX_INPUT) {
                self.input_queue[self.input_len] = .{ .key = key, .light_only = false };
                self.input_len += 1;
            }
        }
        self.input_cond.signal(io);
    }

    pub fn enqueueLightOnlyBatch(self: *MeshWorker, keys: []const WorldState.ChunkKey) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.input_mutex.lockUncancelable(io);
        defer self.input_mutex.unlock(io);

        for (keys) |key| {
            // Dedup: full remesh wins over light-only
            var found = false;
            for (self.input_queue[0..self.input_len]) |r| {
                if (r.key.eql(key)) {
                    found = true;
                    break;
                }
            }
            if (!found and self.input_len < MAX_INPUT) {
                self.input_queue[self.input_len] = .{ .key = key, .light_only = true };
                self.input_len += 1;
            }
        }
        self.input_cond.signal(io);
    }

    fn workerFn(self: *MeshWorker) void {
        const io = Io.Threaded.global_single_threaded.io();

        while (!self.shutdown.load(.acquire)) {
            // 1. Wait for input
            var local_requests: [MAX_INPUT]MeshRequest = undefined;
            var local_count: u32 = 0;

            self.input_mutex.lockUncancelable(io);
            while (self.input_len == 0 and !self.shutdown.load(.acquire)) {
                self.input_cond.waitUncancelable(io, &self.input_mutex);
            }
            local_count = self.input_len;
            if (local_count > 0) {
                @memcpy(local_requests[0..local_count], self.input_queue[0..local_count]);
                self.input_len = 0;
            }
            // Snapshot chunk_map pointer under mutex
            const local_chunk_map = self.chunk_map;
            self.input_mutex.unlock(io);

            if (self.shutdown.load(.acquire)) break;

            // 2. Process each request
            for (local_requests[0..local_count]) |req| {
                if (self.shutdown.load(.acquire)) break;

                const key = req.key;

                // Look up chunk and neighbors from the ChunkMap
                const chunk = local_chunk_map.get(key) orelse continue;
                const neighbors = local_chunk_map.getNeighbors(key);

                if (req.light_only) {
                    // Light-only path: only regenerate light data
                    const light_result = WorldState.generateChunkLightOnly(self.allocator, chunk, neighbors) catch |err| {
                        std.log.err("Chunk light-only generation failed ({},{},{}): {}", .{ key.cx, key.cy, key.cz, err });
                        continue;
                    };

                    self.output_mutex.lockUncancelable(io);
                    while (self.output_len >= MAX_OUTPUT and !self.shutdown.load(.acquire)) {
                        self.output_drained_cond.waitUncancelable(io, &self.output_mutex);
                    }
                    if (self.shutdown.load(.acquire)) {
                        self.output_mutex.unlock(io);
                        self.allocator.free(light_result.lights);
                        break;
                    }
                    self.output_queue[self.output_len] = .{
                        .faces = &.{},
                        .face_counts = light_result.face_counts,
                        .total_face_count = light_result.total_face_count,
                        .lights = light_result.lights,
                        .light_count = light_result.light_count,
                        .key = key,
                        .light_only = true,
                    };
                    self.output_len += 1;
                    self.output_cond.signal(io);
                    self.output_mutex.unlock(io);
                } else {
                    // Full remesh path
                    const mesh = WorldState.generateChunkMesh(self.allocator, chunk, neighbors) catch |err| {
                        std.log.err("Chunk mesh generation failed ({},{},{}): {}", .{ key.cx, key.cy, key.cz, err });
                        continue;
                    };

                    self.output_mutex.lockUncancelable(io);
                    while (self.output_len >= MAX_OUTPUT and !self.shutdown.load(.acquire)) {
                        self.output_drained_cond.waitUncancelable(io, &self.output_mutex);
                    }
                    if (self.shutdown.load(.acquire)) {
                        self.output_mutex.unlock(io);
                        self.allocator.free(mesh.faces);
                        self.allocator.free(mesh.lights);
                        break;
                    }
                    self.output_queue[self.output_len] = .{
                        .faces = mesh.faces,
                        .face_counts = mesh.face_counts,
                        .total_face_count = mesh.total_face_count,
                        .lights = mesh.lights,
                        .light_count = mesh.light_count,
                        .key = key,
                        .light_only = false,
                    };
                    self.output_len += 1;
                    self.output_cond.signal(io);
                    self.output_mutex.unlock(io);
                }
            }
        }
    }
};
