const std = @import("std");
const WorldState = @import("WorldState.zig");
const MeshWorker = @import("MeshWorker.zig").MeshWorker;
const Io = std.Io;

pub const LightWorker = struct {
    const MAX_REQUESTS = 64;
    const MAX_LOD_REQUESTS = 64;

    request_queue: [MAX_REQUESTS]LightRequest,
    request_len: u32,
    lod_request_queue: [MAX_LOD_REQUESTS]LodLightRequest,
    lod_request_len: u32,
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
        old_block: WorldState.BlockType,
    };

    pub const LodLightRequest = struct {
        wx: i32,
        wy: i32,
        wz: i32,
        world: *const WorldState.World,
        light_map: *WorldState.LightMap,
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
            .lod_request_queue = undefined,
            .lod_request_len = 0,
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

    pub fn enqueue(self: *LightWorker, wx: i32, wy: i32, wz: i32, old_block: WorldState.BlockType) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.queue_mutex.lockUncancelable(io);
        defer self.queue_mutex.unlock(io);

        if (self.request_len < MAX_REQUESTS) {
            self.request_queue[self.request_len] = .{ .wx = wx, .wy = wy, .wz = wz, .old_block = old_block };
            self.request_len += 1;
        }
        self.queue_cond.signal(io);
    }

    pub fn enqueueLod(self: *LightWorker, wx: i32, wy: i32, wz: i32, world: *const WorldState.World, light_map: *WorldState.LightMap) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.queue_mutex.lockUncancelable(io);
        defer self.queue_mutex.unlock(io);

        if (self.lod_request_len < MAX_LOD_REQUESTS) {
            self.lod_request_queue[self.lod_request_len] = .{ .wx = wx, .wy = wy, .wz = wz, .world = world, .light_map = light_map };
            self.lod_request_len += 1;
        }
        self.queue_cond.signal(io);
    }

    fn isGeometryDirty(coord: WorldState.ChunkCoord, geo_chunks: []const WorldState.ChunkCoord) bool {
        for (geo_chunks) |gc| {
            if (gc.eql(coord)) return true;
        }
        return false;
    }

    fn workerFn(self: *LightWorker) void {
        const io = Io.Threaded.global_single_threaded.io();

        while (!self.shutdown.load(.acquire)) {
            // 1. Wait for requests (either incremental or LOD)
            var local_requests: [MAX_REQUESTS]LightRequest = undefined;
            var local_count: u32 = 0;
            var local_lod_requests: [MAX_LOD_REQUESTS]LodLightRequest = undefined;
            var local_lod_count: u32 = 0;

            self.queue_mutex.lockUncancelable(io);
            while (self.request_len == 0 and self.lod_request_len == 0 and !self.shutdown.load(.acquire)) {
                self.queue_cond.waitUncancelable(io, &self.queue_mutex);
            }
            local_count = self.request_len;
            if (local_count > 0) {
                @memcpy(local_requests[0..local_count], self.request_queue[0..local_count]);
                self.request_len = 0;
            }
            local_lod_count = self.lod_request_len;
            if (local_lod_count > 0) {
                @memcpy(local_lod_requests[0..local_lod_count], self.lod_request_queue[0..local_lod_count]);
                self.lod_request_len = 0;
            }
            // Snapshot world/light_map under mutex (synced by main thread via syncWorld)
            const local_world = self.world;
            const local_light_map = self.light_map;
            self.queue_mutex.unlock(io);

            if (self.shutdown.load(.acquire)) break;

            // 2. Process incremental requests (current LOD)
            for (local_requests[0..local_count]) |req| {
                // Write-lock light map for incremental update
                self.light_map_rwlock.lockUncancelable(io);
                const light_result = WorldState.updateLightMapIncremental(local_world, local_light_map, req.wx, req.wy, req.wz, req.old_block);
                self.light_map_rwlock.unlock(io);

                if (!light_result.any_changed) continue;

                // Geometry-dirty chunks (from affectedChunks — max 7)
                // These are already enqueued as full remesh by dirty_chunks → enqueueBatch in beginFrame
                const geo = WorldState.affectedChunks(req.wx, req.wy, req.wz);

                // Convert light bounding box (voxel coords) to chunk coords with +1 padding
                const cs: i32 = WorldState.CHUNK_SIZE;
                const min_cx: i32 = @max(0, @divFloor(light_result.min_vx - 1, cs));
                const max_cx: i32 = @min(@as(i32, WorldState.WORLD_CHUNKS_X) - 1, @divFloor(light_result.max_vx + 1, cs));
                const min_cy: i32 = @max(0, @divFloor(light_result.min_vy - 1, cs));
                const max_cy: i32 = @min(@as(i32, WorldState.WORLD_CHUNKS_Y) - 1, @divFloor(light_result.max_vy + 1, cs));
                const min_cz: i32 = @max(0, @divFloor(light_result.min_vz - 1, cs));
                const max_cz: i32 = @min(@as(i32, WorldState.WORLD_CHUNKS_Z) - 1, @divFloor(light_result.max_vz + 1, cs));

                var light_only_coords: [WorldState.TOTAL_WORLD_CHUNKS]WorldState.ChunkCoord = undefined;
                var light_only_count: u32 = 0;

                var icy = min_cy;
                while (icy <= max_cy) : (icy += 1) {
                    var icz = min_cz;
                    while (icz <= max_cz) : (icz += 1) {
                        var icx = min_cx;
                        while (icx <= max_cx) : (icx += 1) {
                            const coord = WorldState.ChunkCoord{
                                .cx = @intCast(icx),
                                .cy = @intCast(icy),
                                .cz = @intCast(icz),
                            };
                            // Skip geometry-dirty chunks — they get full remesh from beginFrame
                            if (!isGeometryDirty(coord, geo.coords[0..geo.count])) {
                                if (light_only_count < WorldState.TOTAL_WORLD_CHUNKS) {
                                    light_only_coords[light_only_count] = coord;
                                    light_only_count += 1;
                                }
                            }
                        }
                    }
                }

                if (light_only_count > 0) {
                    self.mesh_worker.enqueueLightOnlyBatch(light_only_coords[0..light_only_count]);
                }
            }

            // 3. Process LOD light requests (full recalculation, no mesh updates needed)
            for (local_lod_requests[0..local_lod_count]) |req| {
                self.light_map_rwlock.lockUncancelable(io);
                WorldState.updateLightMapFull(req.world, req.light_map, req.wx, req.wy, req.wz);
                self.light_map_rwlock.unlock(io);
            }
        }
    }
};
