const std = @import("std");
const WorldState = @import("WorldState.zig");
const MeshWorker = @import("MeshWorker.zig").MeshWorker;
const Io = std.Io;

pub const LightWorker = struct {
    const MAX_REQUESTS = 64;

    request_queue: [MAX_REQUESTS]LightRequest,
    request_len: u32,
    queue_mutex: Io.Mutex,
    queue_cond: Io.Condition,

    world: *const WorldState.World,
    light_map: *WorldState.LightMap,
    light_map_rwlock: Io.RwLock,
    mesh_worker: *MeshWorker,

    thread: ?std.Thread,
    shutdown: std.atomic.Value(bool),

    pub const LightRequest = struct {
        wx: i32,
        wy: i32,
        wz: i32,
    };

    pub fn initInPlace(
        self: *LightWorker,
        world: *const WorldState.World,
        light_map: *WorldState.LightMap,
        mesh_worker: *MeshWorker,
    ) void {
        self.* = .{
            .request_queue = undefined,
            .request_len = 0,
            .queue_mutex = .init,
            .queue_cond = .init,
            .world = world,
            .light_map = light_map,
            .light_map_rwlock = .init,
            .mesh_worker = mesh_worker,
            .thread = null,
            .shutdown = std.atomic.Value(bool).init(false),
        };
    }

    pub fn start(self: *LightWorker) void {
        self.thread = std.Thread.spawn(.{ .stack_size = 4 * 1024 * 1024 }, workerFn, .{self}) catch |err| {
            std.log.err("Failed to spawn light worker thread: {}", .{err});
            return;
        };
    }

    pub fn stop(self: *LightWorker) void {
        self.shutdown.store(true, .release);
        const io = Io.Threaded.global_single_threaded.io();
        self.queue_cond.broadcast(io);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn syncWorld(self: *LightWorker, world: *const WorldState.World, light_map: *WorldState.LightMap) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.queue_mutex.lockUncancelable(io);
        self.world = world;
        self.light_map = light_map;
        self.queue_mutex.unlock(io);
    }

    pub fn enqueue(self: *LightWorker, wx: i32, wy: i32, wz: i32) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.queue_mutex.lockUncancelable(io);
        defer self.queue_mutex.unlock(io);

        if (self.request_len < MAX_REQUESTS) {
            self.request_queue[self.request_len] = .{ .wx = wx, .wy = wy, .wz = wz };
            self.request_len += 1;
        }
        self.queue_cond.signal(io);
    }

    fn workerFn(self: *LightWorker) void {
        const io = Io.Threaded.global_single_threaded.io();

        while (!self.shutdown.load(.acquire)) {
            // 1. Wait for requests
            var local_requests: [MAX_REQUESTS]LightRequest = undefined;
            var local_count: u32 = 0;

            self.queue_mutex.lockUncancelable(io);
            while (self.request_len == 0 and !self.shutdown.load(.acquire)) {
                self.queue_cond.waitUncancelable(io, &self.queue_mutex);
            }
            local_count = self.request_len;
            if (local_count > 0) {
                @memcpy(local_requests[0..local_count], self.request_queue[0..local_count]);
                self.request_len = 0;
            }
            // Snapshot world/light_map under mutex (synced by main thread via syncWorld)
            const local_world = self.world;
            const local_light_map = self.light_map;
            self.queue_mutex.unlock(io);

            if (self.shutdown.load(.acquire)) break;

            // 2. Process each request
            for (local_requests[0..local_count]) |req| {
                // Write-lock light map for update
                self.light_map_rwlock.lockUncancelable(io);
                WorldState.updateLightMap(local_world, local_light_map, req.wx, req.wy, req.wz);
                self.light_map_rwlock.unlock(io);

                // Compute affected chunk coords (same logic as dirtyLightRadius)
                const radius = WorldState.LIGHT_MAX_RADIUS + 2;
                const cs: i32 = WorldState.CHUNK_SIZE;
                const half_x: i32 = WorldState.WORLD_SIZE_X / 2;
                const half_y: i32 = WorldState.WORLD_SIZE_Y / 2;
                const half_z: i32 = WorldState.WORLD_SIZE_Z / 2;

                const min_cx: i32 = @max(0, @divFloor(req.wx - radius + half_x, cs));
                const max_cx: i32 = @min(@as(i32, WorldState.WORLD_CHUNKS_X) - 1, @divFloor(req.wx + radius + half_x, cs));
                const min_cy: i32 = @max(0, @divFloor(req.wy - radius + half_y, cs));
                const max_cy: i32 = @min(@as(i32, WorldState.WORLD_CHUNKS_Y) - 1, @divFloor(req.wy + radius + half_y, cs));
                const min_cz: i32 = @max(0, @divFloor(req.wz - radius + half_z, cs));
                const max_cz: i32 = @min(@as(i32, WorldState.WORLD_CHUNKS_Z) - 1, @divFloor(req.wz + radius + half_z, cs));

                var coords: [WorldState.TOTAL_WORLD_CHUNKS]WorldState.ChunkCoord = undefined;
                var count: u32 = 0;

                var cy = min_cy;
                while (cy <= max_cy) : (cy += 1) {
                    var cz = min_cz;
                    while (cz <= max_cz) : (cz += 1) {
                        var cx = min_cx;
                        while (cx <= max_cx) : (cx += 1) {
                            if (count < WorldState.TOTAL_WORLD_CHUNKS) {
                                coords[count] = .{
                                    .cx = @intCast(cx),
                                    .cy = @intCast(cy),
                                    .cz = @intCast(cz),
                                };
                                count += 1;
                            }
                        }
                    }
                }

                if (count > 0) {
                    self.mesh_worker.enqueueBatch(coords[0..count]);
                }
            }
        }
    }
};
