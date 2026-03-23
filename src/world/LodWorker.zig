const std = @import("std");
const WorldState = @import("WorldState.zig");
const WorldGenApi = @import("WorldGenApi.zig");
const MeshWorker = @import("MeshWorker.zig").MeshWorker;
const Io = std.Io;
const tracy = @import("../platform/tracy.zig");

const ChunkKey = WorldState.ChunkKey;
const Chunk = WorldState.Chunk;
const CHUNK_SIZE = WorldState.CHUNK_SIZE;

pub const LOD_VOXEL_SIZE: u32 = 4;
const INNER_RADIUS: i32 = 4; // LOD1 chunks = 512 world blocks (LOD0 edge)
const OUTER_RADIUS: i32 = 8; // LOD1 chunks = 1024 world blocks
const MAX_LOD_CHUNKS = 2048;
const MAX_UNLOADS = 256;

pub const LodWorker = struct {
    allocator: std.mem.Allocator,
    seed: u64,
    player_cx: std.atomic.Value(i32),
    player_cy: std.atomic.Value(i32),
    player_cz: std.atomic.Value(i32),
    player_changed: std.atomic.Value(bool),

    // Active set of LOD chunk keys (LOD-space coordinates)
    active_keys: std.AutoHashMap(ChunkKey, void),

    // Output: inject into MeshWorker's output queue
    mesh_worker: *MeshWorker,

    // Unload queue (drained by main thread)
    unload_keys: [MAX_UNLOADS]ChunkKey,
    unload_len: u32,
    unload_mutex: Io.Mutex,

    // Thread control
    thread: ?std.Thread,
    shutdown: std.atomic.Value(bool),
    wake_cond: Io.Condition,
    wake_mutex: Io.Mutex,

    pub fn initInPlace(
        self: *LodWorker,
        allocator: std.mem.Allocator,
        seed: u64,
        mesh_worker: *MeshWorker,
    ) void {
        self.* = .{
            .allocator = allocator,
            .seed = seed,
            .player_cx = std.atomic.Value(i32).init(0),
            .player_cy = std.atomic.Value(i32).init(0),
            .player_cz = std.atomic.Value(i32).init(0),
            .player_changed = std.atomic.Value(bool).init(false),
            .active_keys = std.AutoHashMap(ChunkKey, void).init(allocator),
            .mesh_worker = mesh_worker,
            .unload_keys = undefined,
            .unload_len = 0,
            .unload_mutex = .init,
            .thread = null,
            .shutdown = std.atomic.Value(bool).init(false),
            .wake_cond = .init,
            .wake_mutex = .init,
        };
    }

    pub fn start(self: *LodWorker) void {
        self.shutdown.store(false, .release);
        self.thread = std.Thread.spawn(.{ .stack_size = 8 * 1024 * 1024 }, workerFn, .{self}) catch |err| {
            std.log.err("Failed to spawn LOD worker thread: {}", .{err});
            return;
        };
        std.log.info("LodWorker: started", .{});
    }

    pub fn stop(self: *LodWorker) void {
        self.shutdown.store(true, .release);
        // Wake the worker so it can exit
        const io = Io.Threaded.global_single_threaded.io();
        self.wake_mutex.lockUncancelable(io);
        self.wake_cond.broadcast(io);
        self.wake_mutex.unlock(io);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.active_keys.deinit();
    }

    /// Called from main thread (GameState.fixedUpdate) to update player position.
    pub fn syncPlayerChunk(self: *LodWorker, player_chunk: ChunkKey) void {
        const old_cx = self.player_cx.load(.monotonic);
        const old_cy = self.player_cy.load(.monotonic);
        const old_cz = self.player_cz.load(.monotonic);
        if (old_cx != player_chunk.cx or old_cy != player_chunk.cy or old_cz != player_chunk.cz) {
            self.player_cx.store(player_chunk.cx, .release);
            self.player_cy.store(player_chunk.cy, .release);
            self.player_cz.store(player_chunk.cz, .release);
            self.player_changed.store(true, .release);
            // Wake the worker
            const io = Io.Threaded.global_single_threaded.io();
            self.wake_mutex.lockUncancelable(io);
            self.wake_cond.signal(io);
            self.wake_mutex.unlock(io);
        }
    }

    /// Drain unload signals (called from main thread).
    pub fn drainUnloads(self: *LodWorker, out_buf: []ChunkKey) u32 {
        const io = Io.Threaded.global_single_threaded.io();
        self.unload_mutex.lockUncancelable(io);
        defer self.unload_mutex.unlock(io);

        const count = @min(self.unload_len, @as(u32, @intCast(out_buf.len)));
        if (count > 0) {
            @memcpy(out_buf[0..count], self.unload_keys[0..count]);
            if (count < self.unload_len) {
                const remaining = self.unload_len - count;
                std.mem.copyForwards(
                    ChunkKey,
                    self.unload_keys[0..remaining],
                    self.unload_keys[count..self.unload_len],
                );
            }
            self.unload_len -= count;
        }
        return count;
    }

    fn workerFn(self: *LodWorker) void {
        tracy.setThreadName("LodWorker");
        const io = Io.Threaded.global_single_threaded.io();

        // Initial generation pass
        self.player_changed.store(true, .release);

        while (!self.shutdown.load(.acquire)) {
            // Wait for player movement
            if (!self.player_changed.swap(false, .acquire)) {
                self.wake_mutex.lockUncancelable(io);
                if (!self.player_changed.load(.acquire) and !self.shutdown.load(.acquire)) {
                    self.wake_cond.waitUncancelable(io, &self.wake_mutex);
                }
                self.wake_mutex.unlock(io);
                continue;
            }

            if (self.shutdown.load(.acquire)) break;

            // Read player position in LOD-space coordinates
            const pcx = self.player_cx.load(.acquire);
            const pcy = self.player_cy.load(.acquire);
            const pcz = self.player_cz.load(.acquire);

            // Convert player chunk coords to LOD1 coords
            // Each LOD1 chunk covers 128 world blocks = 4 regular chunks
            const lod_px = @divFloor(pcx, @as(i32, LOD_VOXEL_SIZE));
            const lod_py = @divFloor(pcy, @as(i32, LOD_VOXEL_SIZE));
            const lod_pz = @divFloor(pcz, @as(i32, LOD_VOXEL_SIZE));

            const tz = tracy.zone(@src(), "lodWorker.generate");
            defer tz.end();

            // Build desired set of LOD keys (shell between INNER and OUTER radius)
            var desired = std.AutoHashMap(ChunkKey, void).init(self.allocator);
            defer desired.deinit();

            const inner_sq = INNER_RADIUS * INNER_RADIUS;
            const outer_sq = OUTER_RADIUS * OUTER_RADIUS;

            var dy: i32 = -OUTER_RADIUS;
            while (dy <= OUTER_RADIUS) : (dy += 1) {
                var dz: i32 = -OUTER_RADIUS;
                while (dz <= OUTER_RADIUS) : (dz += 1) {
                    var dx: i32 = -OUTER_RADIUS;
                    while (dx <= OUTER_RADIUS) : (dx += 1) {
                        const dist_sq = dx * dx + dy * dy + dz * dz;
                        if (dist_sq < inner_sq or dist_sq > outer_sq) continue;
                        const key = ChunkKey{
                            .cx = lod_px + dx,
                            .cy = lod_py + dy,
                            .cz = lod_pz + dz,
                        };
                        desired.put(key, {}) catch continue;
                    }
                }
            }

            // Determine keys to unload (in active but not in desired)
            {
                var unload_batch: [MAX_UNLOADS]ChunkKey = undefined;
                var unload_count: u32 = 0;
                var it = self.active_keys.iterator();
                while (it.next()) |entry| {
                    if (!desired.contains(entry.key_ptr.*)) {
                        if (unload_count < MAX_UNLOADS) {
                            unload_batch[unload_count] = entry.key_ptr.*;
                            unload_count += 1;
                        }
                    }
                }
                // Remove from active and push to unload queue
                for (unload_batch[0..unload_count]) |key| {
                    _ = self.active_keys.remove(key);
                }
                if (unload_count > 0) {
                    self.unload_mutex.lockUncancelable(io);
                    const space = MAX_UNLOADS - self.unload_len;
                    const to_push = @min(unload_count, space);
                    @memcpy(
                        self.unload_keys[self.unload_len..][0..to_push],
                        unload_batch[0..to_push],
                    );
                    self.unload_len += to_push;
                    self.unload_mutex.unlock(io);
                }
            }

            // Generate new LOD chunks (in desired but not in active)
            var desired_it = desired.iterator();
            while (desired_it.next()) |entry| {
                if (self.shutdown.load(.acquire)) break;
                const key = entry.key_ptr.*;
                if (self.active_keys.contains(key)) continue;

                // Generate terrain + mesh for this LOD chunk
                self.generateAndSubmit(key) catch |err| {
                    std.log.err("LOD chunk gen failed ({},{},{}): {}", .{ key.cx, key.cy, key.cz, err });
                    continue;
                };

                self.active_keys.put(key, {}) catch {};
            }
        }
    }

    fn generateAndSubmit(self: *LodWorker, key: ChunkKey) !void {
        const io = Io.Threaded.global_single_threaded.io();

        // Allocate chunks for center + 6 neighbors
        const center = try self.allocator.create(Chunk);
        defer self.allocator.destroy(center);

        var neighbor_chunks: [6]?*Chunk = .{null} ** 6;
        defer {
            for (&neighbor_chunks) |nc| {
                if (nc) |c| self.allocator.destroy(c);
            }
        }

        // Generate center chunk terrain
        WorldGenApi.generateLodChunk(center, key, self.seed, LOD_VOXEL_SIZE);

        // Generate 6 neighbor chunks for proper face culling at boundaries
        const offsets = WorldState.face_neighbor_offsets;
        for (0..6) |i| {
            const nk = ChunkKey{
                .cx = key.cx + offsets[i][0],
                .cy = key.cy + offsets[i][1],
                .cz = key.cz + offsets[i][2],
            };
            const nc = try self.allocator.create(Chunk);
            WorldGenApi.generateLodChunk(nc, nk, self.seed, LOD_VOXEL_SIZE);
            neighbor_chunks[i] = nc;
        }

        // Generate mesh
        const mesh = try WorldState.generateLodChunkMesh(
            self.allocator,
            center,
            neighbor_chunks,
        );

        // Push result to MeshWorker's output queue
        const mw = self.mesh_worker;
        mw.output_mutex.lockUncancelable(io);
        while (mw.output_len >= MeshWorker.MAX_OUTPUT and !self.shutdown.load(.acquire)) {
            mw.output_drained_cond.waitUncancelable(io, &mw.output_mutex);
        }
        if (self.shutdown.load(.acquire)) {
            mw.output_mutex.unlock(io);
            self.allocator.free(mesh.faces);
            self.allocator.free(mesh.lights);
            return;
        }
        mw.output_queue[mw.output_len] = .{
            .faces = mesh.faces,
            .layer_face_counts = mesh.layer_face_counts,
            .total_face_count = mesh.total_face_count,
            .lights = mesh.lights,
            .light_count = mesh.light_count,
            .key = key,
            .light_only = false,
            .voxel_size = LOD_VOXEL_SIZE,
        };
        mw.output_len += 1;
        mw.output_cond.signal(io);
        mw.output_mutex.unlock(io);
    }
};
