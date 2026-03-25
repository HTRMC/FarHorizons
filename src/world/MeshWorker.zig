const std = @import("std");
const WorldState = @import("WorldState.zig");
const ChunkMap = @import("ChunkMap.zig").ChunkMap;
const ChunkStreamer = @import("ChunkStreamer.zig").ChunkStreamer;
const LightMapMod = @import("LightMap.zig");
const LightMap = LightMapMod.LightMap;
const LightEngine = @import("LightEngine.zig");
const SurfaceHeightMapMod = @import("SurfaceHeightMap.zig");
const SurfaceHeightMap = SurfaceHeightMapMod.SurfaceHeightMap;
const types = @import("../renderer/vulkan/types.zig");
const FaceData = types.FaceData;
const LightEntry = types.LightEntry;
const tracy = @import("../platform/tracy.zig");
const ThreadPool = @import("../ThreadPool.zig").ThreadPool;
const Io = std.Io;
const BlockState = WorldState.BlockState;

const LightMaps = std.AutoHashMap(WorldState.ChunkKey, *LightMap);

pub const MeshWorker = struct {
    pub const MAX_OUTPUT = 64;

    const ChunkKey = WorldState.ChunkKey;

    // Output queue (consumed by TransferPipeline thread)
    output_queue: [MAX_OUTPUT]ChunkResult,
    output_len: u32,
    output_mutex: Io.Mutex,
    output_cond: Io.Condition,

    // State (updated by syncChunkMap under mutex)
    allocator: std.mem.Allocator,
    chunk_map: *const ChunkMap,
    light_maps: *const LightMaps,
    surface_height_map: *const SurfaceHeightMap,
    state_mutex: Io.Mutex,
    pool: ?*ThreadPool,

    // Pipeline stats (atomically updated by workers)
    stats_meshed: std.atomic.Value(u64),
    stats_light_only: std.atomic.Value(u64),
    stats_hidden: std.atomic.Value(u64),
    stats_stale: std.atomic.Value(u64),
    stats_output_waits: std.atomic.Value(u64),

    pub const ChunkResult = struct {
        faces: []FaceData,
        layer_face_counts: [WorldState.LAYER_COUNT][6]u32,
        total_face_count: u32,
        lights: []LightEntry,
        light_count: u32,
        key: ChunkKey,
        light_only: bool,
    };

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
        light_maps: *const LightMaps,
        surface_height_map: *const SurfaceHeightMap,
    ) void {
        self.* = .{
            .output_queue = undefined,
            .output_len = 0,
            .output_mutex = .init,
            .output_cond = .init,
            .allocator = allocator,
            .chunk_map = chunk_map,
            .light_maps = light_maps,
            .surface_height_map = surface_height_map,
            .state_mutex = .init,
            .pool = null,
            .stats_meshed = std.atomic.Value(u64).init(0),
            .stats_light_only = std.atomic.Value(u64).init(0),
            .stats_hidden = std.atomic.Value(u64).init(0),
            .stats_stale = std.atomic.Value(u64).init(0),
            .stats_output_waits = std.atomic.Value(u64).init(0),
        };
    }

    pub fn stop(self: *MeshWorker) void {
        // Free any remaining output results
        for (self.output_queue[0..self.output_len]) |r| {
            if (!r.light_only) self.allocator.free(r.faces);
            self.allocator.free(r.lights);
        }
        self.output_len = 0;
    }

    pub fn syncChunkMap(self: *MeshWorker, chunk_map: *const ChunkMap, light_maps: *const LightMaps, surface_height_map: *const SurfaceHeightMap) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.state_mutex.lockUncancelable(io);
        self.chunk_map = chunk_map;
        self.light_maps = light_maps;
        self.surface_height_map = surface_height_map;
        self.state_mutex.unlock(io);
    }

    /// Compute lighting for a chunk and update the 27-chunk bitmask.
    /// When all existing neighbors of a chunk are lit, submits a mesh task for it.
    /// Returns true if processed, false if should be re-enqueued.
    pub fn processLightTask(self: *MeshWorker, key: ChunkKey) bool {
        const io = Io.Threaded.global_single_threaded.io();

        // Snapshot state pointers
        self.state_mutex.lockUncancelable(io);
        const local_chunk_map = self.chunk_map;
        const local_light_maps: *const LightMaps = self.light_maps;
        const local_shm: *const SurfaceHeightMap = self.surface_height_map;
        self.state_mutex.unlock(io);

        // Skip stale chunks
        const player_snapshot = if (self.pool) |p| p.player_chunk else ChunkKey{ .cx = 0, .cy = 0, .cz = 0 };
        const ud: i64 = ChunkStreamer.UNLOAD_DISTANCE;
        if (distSq(key, player_snapshot) > ud * ud) {
            _ = self.stats_stale.fetchAdd(1, .monotonic);
            return true;
        }

        const chunk = local_chunk_map.get(key) orelse return true;
        const neighbors = local_chunk_map.getNeighbors(key);
        const face_offsets = WorldState.face_neighbor_offsets;
        const light_map: ?*LightMap = local_light_maps.get(key);
        var neighbor_lights: [6]?*const LightMap = .{null} ** 6;
        for (0..6) |i| {
            const nk = ChunkKey{
                .cx = key.cx + face_offsets[i][0],
                .cy = key.cy + face_offsets[i][1],
                .cz = key.cz + face_offsets[i][2],
            };
            neighbor_lights[i] = local_light_maps.get(nk);
        }

        const neighbor_borders = LightMapMod.snapshotNeighborBorders(neighbor_lights);

        if (light_map) |lm| lm.mutex.lockUncancelable(io);
        defer {
            if (light_map) |lm| lm.mutex.unlock(io);
        }

        // Compute light if dirty
        if (light_map) |lm| {
            if (lm.dirty) {
                lm.incremental = null;
                const surface_heights = local_shm.getHeights(key.cx, key.cz);
                const boundary_mask = LightEngine.computeChunkLight(chunk, neighbors, neighbor_borders, lm, key.cy, surface_heights);

                // Cascade: submit light tasks for neighbors with changed borders
                if (boundary_mask != 0) {
                    var lo_keys: [6]ChunkKey = undefined;
                    var lo_count: usize = 0;
                    for (0..6) |i| {
                        if (boundary_mask & (@as(u6, 1) << @intCast(i)) != 0) {
                            lo_keys[lo_count] = .{
                                .cx = key.cx + face_offsets[i][0],
                                .cy = key.cy + face_offsets[i][1],
                                .cz = key.cz + face_offsets[i][2],
                            };
                            lo_count += 1;
                        }
                    }
                    if (lo_count > 0) {
                        if (self.pool) |p| p.submitMeshLightOnlyBatch(lo_keys[0..lo_count]);
                    }
                }
            }
        }

        // Update 27-chunk bitmask: notify all neighbors that we're lit,
        // and check if any chunk (including self) is ready to mesh.
        self.updateLitNeighborMasks(key, local_light_maps);

        return true;
    }

    /// After a chunk's lighting completes, set our bit in each neighbor's
    /// lit_neighbors mask. If any neighbor's mask becomes complete (all
    /// existing neighbors lit), submit a mesh task for it.
    fn updateLitNeighborMasks(self: *MeshWorker, key: ChunkKey, light_maps: *const LightMaps) void {
        const offsets_27 = WorldState.neighbor_offsets_27;

        for (offsets_27) |off| {
            const nk = ChunkKey{
                .cx = key.cx + off[0],
                .cy = key.cy + off[1],
                .cz = key.cz + off[2],
            };
            const neighbor_lm = light_maps.get(nk) orelse continue;

            // Our position relative to the neighbor is (-dx, -dy, -dz)
            const bit: u32 = @as(u32, 1) << WorldState.neighborBitIndex(-off[0], -off[1], -off[2]);

            // Atomically set our bit in the neighbor's lit_neighbors mask
            const old = neighbor_lm.lit_neighbors.fetchOr(bit, .acq_rel);
            const new = old | bit;
            const required = neighbor_lm.required_neighbors.load(.acquire);

            // If all required neighbors are now lit, submit mesh for that neighbor
            if (required != 0 and (new & required) == required) {
                // Only submit if this was the bit that completed the mask
                if ((old & required) != required) {
                    if (self.pool) |p| p.submitMesh(nk);
                }
            }
        }
    }

    /// Process one mesh task. Called by ThreadPool workers.
    /// Returns true if processed, false if output is full (caller should re-enqueue).
    pub fn processTask(self: *MeshWorker, key: ChunkKey, light_only: bool) bool {
        const io = Io.Threaded.global_single_threaded.io();

        // Check output capacity before doing expensive work
        self.output_mutex.lockUncancelable(io);
        const output_full = self.output_len >= MAX_OUTPUT;
        self.output_mutex.unlock(io);
        if (output_full) return false;

        // Snapshot state pointers
        self.state_mutex.lockUncancelable(io);
        const local_chunk_map = self.chunk_map;
        const local_light_maps: *const LightMaps = self.light_maps;
        const local_shm: *const SurfaceHeightMap = self.surface_height_map;
        self.state_mutex.unlock(io);

        // Skip stale chunks
        const player_snapshot = if (self.pool) |p| p.player_chunk else ChunkKey{ .cx = 0, .cy = 0, .cz = 0 };
        const ud: i64 = ChunkStreamer.UNLOAD_DISTANCE;
        if (distSq(key, player_snapshot) > ud * ud) {
            _ = self.stats_stale.fetchAdd(1, .monotonic);
            return true;
        }

        // Look up chunk and neighbors from the ChunkMap
        const chunk = local_chunk_map.get(key) orelse return true;

        // Skip all-air chunks immediately (no geometry possible)
        if (!light_only and chunk.blocks.get(0) == BlockState.defaultState(.air)) blk: {
            if (chunk.blocks.palette_len > 1) break :blk;
            _ = self.stats_hidden.fetchAdd(1, .monotonic);
            return true;
        }

        const neighbors = local_chunk_map.getNeighbors(key);

        // Skip fully hidden chunks (all opaque + all neighbor boundaries opaque)
        if (!light_only and WorldState.isFullyHidden(chunk, neighbors)) {
            _ = self.stats_hidden.fetchAdd(1, .monotonic);
            return true;
        }

        // Compute light for this chunk
        const offsets = WorldState.face_neighbor_offsets;
        const light_map: ?*LightMap = local_light_maps.get(key);
        var neighbor_lights: [6]?*const LightMap = .{null} ** 6;
        for (0..6) |i| {
            const nk = ChunkKey{
                .cx = key.cx + offsets[i][0],
                .cy = key.cy + offsets[i][1],
                .cz = key.cz + offsets[i][2],
            };
            neighbor_lights[i] = local_light_maps.get(nk);
        }

        const neighbor_borders = LightMapMod.snapshotNeighborBorders(neighbor_lights);

        if (light_map) |lm| lm.mutex.lockUncancelable(io);
        defer {
            if (light_map) |lm| lm.mutex.unlock(io);
        }

        if (light_map) |lm| {
            if (lm.dirty) {
                lm.incremental = null;
                const surface_heights = local_shm.getHeights(key.cx, key.cz);
                const boundary_mask = LightEngine.computeChunkLight(chunk, neighbors, neighbor_borders, lm, key.cy, surface_heights);

                // Light-only refresh for neighbors whose borders changed.
                // Neighbors recompute their lighting with updated border values,
                // propagating light inward via BFS (e.g. torches near chunk borders).
                if (boundary_mask != 0) {
                    var lo_keys: [6]ChunkKey = undefined;
                    var lo_count: usize = 0;
                    for (0..6) |i| {
                        if (boundary_mask & (@as(u6, 1) << @intCast(i)) != 0) {
                            lo_keys[lo_count] = .{
                                .cx = key.cx + offsets[i][0],
                                .cy = key.cy + offsets[i][1],
                                .cz = key.cz + offsets[i][2],
                            };
                            lo_count += 1;
                        }
                    }
                    if (lo_count > 0) {
                        if (self.pool) |p| p.submitMeshLightOnlyBatch(lo_keys[0..lo_count]);
                    }
                }
            } else if (lm.incremental) |update| {
                lm.incremental = null;
                if (LightEngine.applyBlockChange(chunk, lm, update.lx, update.ly, update.lz, update.old_block)) |boundary_mask| {
                    // Incremental succeeded — light-only refresh for affected neighbors
                    if (boundary_mask != 0) {
                        var lo_keys: [6]ChunkKey = undefined;
                        var lo_count: usize = 0;
                        for (0..6) |i| {
                            if (boundary_mask & (@as(u6, 1) << @intCast(i)) != 0) {
                                lo_keys[lo_count] = .{
                                    .cx = key.cx + offsets[i][0],
                                    .cy = key.cy + offsets[i][1],
                                    .cz = key.cz + offsets[i][2],
                                };
                                lo_count += 1;
                            }
                        }
                        if (lo_count > 0) {
                            if (self.pool) |p| p.submitMeshLightOnlyBatch(lo_keys[0..lo_count]);
                        }
                    }
                } else {
                    // Incremental declined (sky light affected) — fall back to full recompute
                    const surface_heights = local_shm.getHeights(key.cx, key.cz);
                    const boundary_mask = LightEngine.computeChunkLight(chunk, neighbors, neighbor_borders, lm, key.cy, surface_heights);
                    if (boundary_mask != 0) {
                        var lo_keys: [6]ChunkKey = undefined;
                        var lo_count: usize = 0;
                        for (0..6) |i| {
                            if (boundary_mask & (@as(u6, 1) << @intCast(i)) != 0) {
                                lo_keys[lo_count] = .{
                                    .cx = key.cx + offsets[i][0],
                                    .cy = key.cy + offsets[i][1],
                                    .cz = key.cz + offsets[i][2],
                                };
                                lo_count += 1;
                            }
                        }
                        if (lo_count > 0) {
                            if (self.pool) |p| p.submitMeshLightOnlyBatch(lo_keys[0..lo_count]);
                        }
                    }
                }
            }
        }

        if (light_only) {
            // Only run the expensive border BFS if neighbor light would actually
            // change values in this chunk's light map. During initial world load
            // most cascading light-only refreshes have no new light to propagate.
            if (light_map) |lm| {
                if (LightEngine.needsPropagation(chunk, neighbor_borders, lm)) {
                    LightEngine.propagateFromNeighbor(chunk, neighbor_borders, lm);
                }
            }

            const light_result = WorldState.generateChunkLightOnly(self.allocator, chunk, neighbors, light_map, neighbor_lights) catch |err| {
                std.log.err("Chunk light-only generation failed ({},{},{}): {}", .{ key.cx, key.cy, key.cz, err });
                return true;
            };

            self.output_mutex.lockUncancelable(io);
            if (self.output_len >= MAX_OUTPUT) {
                self.output_mutex.unlock(io);
                self.allocator.free(light_result.lights);
                _ = self.stats_output_waits.fetchAdd(1, .monotonic);
                return false;
            }
            self.output_queue[self.output_len] = .{
                .faces = &.{},
                .layer_face_counts = light_result.layer_face_counts,
                .total_face_count = light_result.total_face_count,
                .lights = light_result.lights,
                .light_count = light_result.light_count,
                .key = key,
                .light_only = true,
            };
            self.output_len += 1;
            self.output_cond.signal(io);
            self.output_mutex.unlock(io);
            _ = self.stats_light_only.fetchAdd(1, .monotonic);
        } else {
            const mesh = WorldState.generateChunkMesh(self.allocator, chunk, neighbors, light_map, neighbor_lights) catch |err| {
                std.log.err("Chunk mesh generation failed ({},{},{}): {}", .{ key.cx, key.cy, key.cz, err });
                return true;
            };

            self.output_mutex.lockUncancelable(io);
            if (self.output_len >= MAX_OUTPUT) {
                self.output_mutex.unlock(io);
                self.allocator.free(mesh.faces);
                self.allocator.free(mesh.lights);
                _ = self.stats_output_waits.fetchAdd(1, .monotonic);
                return false;
            }
            self.output_queue[self.output_len] = .{
                .faces = mesh.faces,
                .layer_face_counts = mesh.layer_face_counts,
                .total_face_count = mesh.total_face_count,
                .lights = mesh.lights,
                .light_count = mesh.light_count,
                .key = key,
                .light_only = false,
            };
            self.output_len += 1;
            self.output_cond.signal(io);
            self.output_mutex.unlock(io);
            _ = self.stats_meshed.fetchAdd(1, .monotonic);
        }

        return true;
    }
};
