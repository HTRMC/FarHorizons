const std = @import("std");
const WorldState = @import("WorldState.zig");
const ChunkMap = @import("ChunkMap.zig").ChunkMap;
const ChunkStreamer = @import("ChunkStreamer.zig").ChunkStreamer;
const types = @import("../renderer/vulkan/types.zig");
const FaceData = types.FaceData;
const LightEntry = types.LightEntry;
const tracy = @import("../platform/tracy.zig");
const Io = std.Io;

pub const MeshWorker = struct {
    const MAX_INPUT = 512;
    pub const MAX_OUTPUT = 64;
    const WORKER_BATCH = 32;

    const ChunkKey = WorldState.ChunkKey;

    pub const MeshRequest = struct {
        key: ChunkKey,
        light_only: bool,
    };

    const Heap = std.PriorityQueue(ChunkKey, *MeshWorker, meshDistCmp);
    // Dedup set: value is light_only flag (true = light-only, false = full mesh)
    const DedupSet = std.AutoHashMap(ChunkKey, bool);

    // Input queue — min-heap by distance² to player
    input_heap: Heap,
    input_set: DedupSet,
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
    player_chunk: ChunkKey,

    thread: ?std.Thread,
    shutdown: std.atomic.Value(bool),

    pub const ChunkResult = struct {
        faces: []FaceData,
        face_counts: [6]u32,
        total_face_count: u32,
        lights: []LightEntry,
        light_count: u32,
        key: ChunkKey,
        light_only: bool,
    };

    fn meshDistCmp(self: *MeshWorker, a: ChunkKey, b: ChunkKey) std.math.Order {
        const pc = self.player_chunk;
        const da = distSq(a, pc);
        const db = distSq(b, pc);
        return std.math.order(da, db);
    }

    fn distSq(a: ChunkKey, b: ChunkKey) i64 {
        const dx: i64 = a.cx - b.cx;
        const dy: i64 = a.cy - b.cy;
        const dz: i64 = a.cz - b.cz;
        return dx * dx + dy * dy + dz * dz;
    }

    pub fn initInPlace(
        self: *MeshWorker,
        allocator: std.mem.Allocator,
        chunk_map: *const ChunkMap,
    ) void {
        self.* = .{
            .input_heap = Heap.initContext(self),
            .input_set = DedupSet.init(allocator),
            .input_mutex = .init,
            .input_cond = .init,
            .output_queue = undefined,
            .output_len = 0,
            .output_mutex = .init,
            .output_cond = .init,
            .output_drained_cond = .init,
            .allocator = allocator,
            .chunk_map = chunk_map,
            .player_chunk = .{ .cx = 0, .cy = 0, .cz = 0 },
            .thread = null,
            .shutdown = std.atomic.Value(bool).init(false),
        };
        // Re-set context pointer after self.* assignment
        self.input_heap.context = self;
        // Pre-allocate to avoid runtime allocations on hot path
        self.input_heap.ensureTotalCapacity(allocator, MAX_INPUT) catch {};
        self.input_set.ensureTotalCapacity(@intCast(MAX_INPUT)) catch {};
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
        self.input_mutex.lockUncancelable(io);
        self.input_cond.broadcast(io);
        self.input_mutex.unlock(io);
        self.output_mutex.lockUncancelable(io);
        self.output_drained_cond.broadcast(io);
        self.output_mutex.unlock(io);
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
        // Free heap/set memory
        self.input_heap.deinit(self.allocator);
        self.input_set.deinit();
    }

    pub fn syncChunkMap(self: *MeshWorker, chunk_map: *const ChunkMap, player_chunk: ChunkKey) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.input_mutex.lockUncancelable(io);
        self.chunk_map = chunk_map;
        self.player_chunk = player_chunk;
        self.input_mutex.unlock(io);
    }

    pub fn enqueue(self: *MeshWorker, key: ChunkKey) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.input_mutex.lockUncancelable(io);
        defer self.input_mutex.unlock(io);

        if (self.input_set.getPtr(key)) |existing| {
            // Already queued — upgrade light-only to full if needed
            if (existing.*) existing.* = false;
            return;
        }
        self.input_set.put(key, false) catch return;
        self.input_heap.push(self.allocator, key) catch return;
        self.input_cond.signal(io);
    }

    pub fn enqueueBatch(self: *MeshWorker, keys: []const ChunkKey) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.input_mutex.lockUncancelable(io);
        defer self.input_mutex.unlock(io);

        for (keys) |key| {
            if (self.input_set.getPtr(key)) |existing| {
                if (existing.*) existing.* = false;
                continue;
            }
            self.input_set.put(key, false) catch continue;
            self.input_heap.push(self.allocator, key) catch continue;
        }
        self.input_cond.signal(io);
    }

    pub fn enqueueLightOnlyBatch(self: *MeshWorker, keys: []const ChunkKey) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.input_mutex.lockUncancelable(io);
        defer self.input_mutex.unlock(io);

        for (keys) |key| {
            // Don't upgrade existing entries — full mesh wins
            if (self.input_set.contains(key)) continue;
            self.input_set.put(key, true) catch continue;
            self.input_heap.push(self.allocator, key) catch continue;
        }
        self.input_cond.signal(io);
    }

    fn workerFn(self: *MeshWorker) void {
        const io = Io.Threaded.global_single_threaded.io();

        while (!self.shutdown.load(.acquire)) {
            // 1. Drain a batch from the heap (closest chunks first)
            var local_keys: [WORKER_BATCH]ChunkKey = undefined;
            var local_light_only: [WORKER_BATCH]bool = undefined;
            var local_count: u32 = 0;
            var local_chunk_map: *const ChunkMap = undefined;

            self.input_mutex.lockUncancelable(io);
            while (self.input_heap.count() == 0 and !self.shutdown.load(.acquire)) {
                self.input_cond.waitUncancelable(io, &self.input_mutex);
            }
            if (self.shutdown.load(.acquire)) {
                self.input_mutex.unlock(io);
                break;
            }
            while (local_count < WORKER_BATCH) {
                const k = self.input_heap.pop() orelse break;
                // Read authoritative light_only from set (may have been upgraded since push)
                local_light_only[local_count] = self.input_set.get(k) orelse false;
                _ = self.input_set.remove(k);
                local_keys[local_count] = k;
                local_count += 1;
            }
            // Snapshot chunk_map pointer and player position under mutex
            local_chunk_map = self.chunk_map;
            const player_snapshot = self.player_chunk;
            self.input_mutex.unlock(io);

            // 2. Process the batch
            const ud: i64 = ChunkStreamer.UNLOAD_DISTANCE;
            const ud_sq = ud * ud;
            for (local_keys[0..local_count], local_light_only[0..local_count]) |key, light_only| {
                if (self.shutdown.load(.acquire)) break;

                // Skip stale chunks the player has moved away from
                if (distSq(key, player_snapshot) > ud_sq) continue;

                // Look up chunk and neighbors from the ChunkMap
                const chunk = local_chunk_map.get(key) orelse continue;
                const neighbors = local_chunk_map.getNeighbors(key);

                if (light_only) {
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
