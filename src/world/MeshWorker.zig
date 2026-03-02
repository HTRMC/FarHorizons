const std = @import("std");
const WorldState = @import("WorldState.zig");
const types = @import("../renderer/vulkan/types.zig");
const FaceData = types.FaceData;
const LightEntry = types.LightEntry;
const tracy = @import("../platform/tracy.zig");
const Io = std.Io;

pub const MeshWorker = struct {
    const MAX_INPUT = @max(256, WorldState.TOTAL_WORLD_CHUNKS);
    pub const MAX_OUTPUT = 64;

    // Input queue
    input_queue: [MAX_INPUT]WorldState.ChunkCoord,
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
    world: *const WorldState.World,
    light_map: *const WorldState.LightMap,
    light_map_rwlock: *Io.RwLock,
    voxel_size: std.atomic.Value(u32),

    thread: ?std.Thread,
    shutdown: std.atomic.Value(bool),

    pub const ChunkResult = struct {
        faces: []FaceData,
        face_counts: [6]u32,
        total_face_count: u32,
        lights: []LightEntry,
        light_count: u32,
        coord: WorldState.ChunkCoord,
        voxel_size: u32,
    };

    pub fn initInPlace(
        self: *MeshWorker,
        allocator: std.mem.Allocator,
        world: *const WorldState.World,
        light_map: *const WorldState.LightMap,
        rwlock: *Io.RwLock,
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
            .world = world,
            .light_map = light_map,
            .light_map_rwlock = rwlock,
            .voxel_size = std.atomic.Value(u32).init(1),
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
            self.allocator.free(r.faces);
            self.allocator.free(r.lights);
        }
        self.output_len = 0;
    }

    pub fn syncWorld(self: *MeshWorker, world: *const WorldState.World, light_map: *const WorldState.LightMap, vs: u32) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.input_mutex.lockUncancelable(io);
        self.world = world;
        self.light_map = light_map;
        self.input_mutex.unlock(io);
        self.voxel_size.store(vs, .release);
    }

    pub fn enqueue(self: *MeshWorker, coord: WorldState.ChunkCoord) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.input_mutex.lockUncancelable(io);
        defer self.input_mutex.unlock(io);

        // Dedup
        for (self.input_queue[0..self.input_len]) |c| {
            if (c.eql(coord)) return;
        }
        if (self.input_len < MAX_INPUT) {
            self.input_queue[self.input_len] = coord;
            self.input_len += 1;
        }
        self.input_cond.signal(io);
    }

    pub fn enqueueBatch(self: *MeshWorker, coords: []const WorldState.ChunkCoord) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.input_mutex.lockUncancelable(io);
        defer self.input_mutex.unlock(io);

        for (coords) |coord| {
            // Dedup
            var found = false;
            for (self.input_queue[0..self.input_len]) |c| {
                if (c.eql(coord)) {
                    found = true;
                    break;
                }
            }
            if (!found and self.input_len < MAX_INPUT) {
                self.input_queue[self.input_len] = coord;
                self.input_len += 1;
            }
        }
        self.input_cond.signal(io);
    }

    pub fn enqueueAll(self: *MeshWorker) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.input_mutex.lockUncancelable(io);
        defer self.input_mutex.unlock(io);

        self.input_len = 0;
        for (0..WorldState.WORLD_CHUNKS_Y) |cy| {
            for (0..WorldState.WORLD_CHUNKS_Z) |cz| {
                for (0..WorldState.WORLD_CHUNKS_X) |cx| {
                    self.input_queue[self.input_len] = .{
                        .cx = @intCast(cx),
                        .cy = @intCast(cy),
                        .cz = @intCast(cz),
                    };
                    self.input_len += 1;
                }
            }
        }
        self.input_cond.signal(io);
    }

    fn workerFn(self: *MeshWorker) void {
        const io = Io.Threaded.global_single_threaded.io();

        while (!self.shutdown.load(.acquire)) {
            // 1. Wait for input
            var local_coords: [MAX_INPUT]WorldState.ChunkCoord = undefined;
            var local_count: u32 = 0;

            self.input_mutex.lockUncancelable(io);
            while (self.input_len == 0 and !self.shutdown.load(.acquire)) {
                self.input_cond.waitUncancelable(io, &self.input_mutex);
            }
            local_count = self.input_len;
            if (local_count > 0) {
                @memcpy(local_coords[0..local_count], self.input_queue[0..local_count]);
                self.input_len = 0;
            }
            // Snapshot world/light_map under mutex (synced by main thread via syncWorld)
            const local_world = self.world;
            const local_light_map = self.light_map;
            self.input_mutex.unlock(io);

            if (self.shutdown.load(.acquire)) break;

            const vs = self.voxel_size.load(.acquire);

            // 2. Process each coord
            for (local_coords[0..local_count]) |coord| {
                if (self.shutdown.load(.acquire)) break;

                // Read-lock light map
                self.light_map_rwlock.lockSharedUncancelable(io);
                const mesh = WorldState.generateChunkMesh(self.allocator, local_world, coord, local_light_map) catch |err| {
                    self.light_map_rwlock.unlockShared(io);
                    std.log.err("Chunk mesh generation failed ({},{},{}): {}", .{ coord.cx, coord.cy, coord.cz, err });
                    continue;
                };
                self.light_map_rwlock.unlockShared(io);

                // Push to output queue
                self.output_mutex.lockUncancelable(io);
                // If output full, wait for consumer to drain
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
                    .coord = coord,
                    .voxel_size = vs,
                };
                self.output_len += 1;
                self.output_cond.signal(io);
                self.output_mutex.unlock(io);
            }
        }
    }
};
