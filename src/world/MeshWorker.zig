const std = @import("std");
const WorldState = @import("WorldState.zig");
const ChunkMap = @import("ChunkMap.zig").ChunkMap;
const ChunkStreamer = @import("ChunkStreamer.zig").ChunkStreamer;
const ChunkPool = @import("ChunkPool.zig").ChunkPool;
const LightMapMod = @import("LightMap.zig");
const LightMap = LightMapMod.LightMap;
const LightMapPool = LightMapMod.LightMapPool;
const LightEngine = @import("LightEngine.zig");
const SurfaceHeightMapMod = @import("SurfaceHeightMap.zig");
const SurfaceHeightMap = SurfaceHeightMapMod.SurfaceHeightMap;
const types = @import("../renderer/vulkan/types.zig");
const FaceData = types.FaceData;
const LightEntry = types.LightEntry;
const tracy = @import("../platform/tracy.zig");
const ThreadPool = @import("../platform/ThreadPool.zig").ThreadPool;
const Io = std.Io;
const BlockState = WorldState.BlockState;

const LightMaps = std.AutoHashMap(WorldState.ChunkKey, *LightMap);

pub const MeshWorker = struct {
    pub const MAX_OUTPUT = 128;

    const ChunkKey = WorldState.ChunkKey;

    // Output queue (consumed by TransferPipeline thread)
    output_queue: [MAX_OUTPUT]ChunkResult,
    output_len: u32,
    output_mutex: Io.Mutex,
    output_cond: Io.Condition,

    // State — these point to embedded GameState fields with stable addresses.
    // No mutex needed: ChunkMap/LightMaps are only mutated on the main thread,
    // and workers only read via .get() which is safe against concurrent reads
    // when no rehash occurs (guaranteed by pre-allocated capacity).
    allocator: std.mem.Allocator,
    chunk_map: *const ChunkMap,
    light_maps: *const LightMaps,
    surface_height_map: *const SurfaceHeightMap,
    chunk_pool: *ChunkPool,
    light_map_pool: *LightMapPool,
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
        chunk_pool: *ChunkPool,
        light_map_pool: *LightMapPool,
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
            .chunk_pool = chunk_pool,
            .light_map_pool = light_map_pool,
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

    /// Compute lighting for a chunk and update the 27-chunk bitmask.
    /// When all existing neighbors of a chunk are lit, submits a mesh task for it.
    /// Returns true if processed, false if should be re-enqueued.
    pub fn processLightTask(self: *MeshWorker, key: ChunkKey) bool {
        const io = Io.Threaded.global_single_threaded.io();

        // Skip stale chunks
        const player_snapshot = if (self.pool) |p| p.player_chunk else ChunkKey{ .cx = 0, .cy = 0, .cz = 0 };
        const ud: i64 = ChunkStreamer.UNLOAD_DISTANCE;
        if (distSq(key, player_snapshot) > ud * ud) {
            _ = self.stats_stale.fetchAdd(1, .monotonic);
            return true;
        }

        // Acquire center chunk reference (prevents free during our read)
        const chunk = self.chunk_map.get(key) orelse return true;
        _ = chunk.acquire();
        defer self.chunk_pool.release(chunk);

        const neighbors = self.chunk_map.getNeighbors(key);
        const face_offsets = WorldState.face_neighbor_offsets;

        // LightMap pointers are stable: light_maps hashmap is only mutated on
        // the main thread, and workers only read via .get(). Write access to
        // LightMap data is serialized by the per-LightMap mutex below.
        const light_map: ?*LightMap = self.light_maps.get(key);
        // Face neighbors for border snapshots (light propagation — 6 faces)
        var face_neighbor_lights: [6]?*LightMap = .{null} ** 6;
        for (0..6) |i| {
            const nk = ChunkKey{
                .cx = key.cx + face_offsets[i][0],
                .cy = key.cy + face_offsets[i][1],
                .cz = key.cz + face_offsets[i][2],
            };
            face_neighbor_lights[i] = self.light_maps.get(nk);
        }
        // All 27 neighbors for mesh light sampling (Cubyz: getMesh finds any chunk)
        const offsets_27 = WorldState.neighbor_offsets_27;
        var neighbor_lights: [27]?*LightMap = .{null} ** 27;
        for (0..27) |i| {
            if (offsets_27[i][0] == 0 and offsets_27[i][1] == 0 and offsets_27[i][2] == 0) continue; // self
            neighbor_lights[i] = self.light_maps.get(.{
                .cx = key.cx + offsets_27[i][0],
                .cy = key.cy + offsets_27[i][1],
                .cz = key.cz + offsets_27[i][2],
            });
        }

        const neighbor_borders = LightMapMod.snapshotNeighborBorders(face_neighbor_lights);

        // Compute light under mutex, then UNLOCK before bitmask iteration
        // to avoid AB/BA deadlock with concurrent neighbor light tasks.
        if (light_map) |lm| {
            lm.mutex.lockUncancelable(io);

            if (lm.dirty) {
                lm.incremental = null;
                const surface_heights = self.surface_height_map.getHeights(key.cx, key.cz);
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

            lm.mutex.unlock(io);
        }

        // Bitmask iteration with own mutex RELEASED — safe to lock neighbors.
        self.updateLitNeighborMasks(key, self.light_maps);

        return true;
    }

    /// Bidirectional 27-chunk bitmask update (matches Cubyz's generateLightingData).
    /// For each of the 27 neighbor positions:
    ///   1. Set OUR bit in the NEIGHBOR's mask → may trigger neighbor's mesh
    ///   2. If the neighbor has finished lighting, set NEIGHBOR's bit in OUR mask → may trigger our mesh
    /// Missing neighbors are skipped — their bit stays 0.
    ///
    /// Uses ALL_LIT (0x7FFFFFF) as the primary trigger for interior chunks.
    /// After the loop, a fallback check handles world-edge chunks by computing
    /// the actual required mask from currently loaded neighbors.
    fn updateLitNeighborMasks(self: *MeshWorker, key: ChunkKey, light_maps: *const LightMaps) void {
        const ALL_LIT: u32 = (1 << 27) - 1; // 0x7FFFFFF
        const offsets_27 = WorldState.neighbor_offsets_27;
        const io = Io.Threaded.global_single_threaded.io();

        const self_lm = light_maps.get(key) orelse return;

        for (offsets_27) |off| {
            const nk = ChunkKey{
                .cx = key.cx + off[0],
                .cy = key.cy + off[1],
                .cz = key.cz + off[2],
            };
            const neighbor_lm = light_maps.get(nk) orelse continue;

            const self_bit: u32 = @as(u32, 1) << WorldState.neighborBitIndex(-off[0], -off[1], -off[2]);
            const neighbor_bit: u32 = @as(u32, 1) << WorldState.neighborBitIndex(off[0], off[1], off[2]);

            // 1. Set our bit in the neighbor's mask
            const neighbor_old = neighbor_lm.lit_neighbors.fetchOr(self_bit, .acq_rel);
            if ((neighbor_old | self_bit) == ALL_LIT and neighbor_old != ALL_LIT) {
                if (self.pool) |p| p.submitMesh(nk);
            }

            // 2. If the neighbor has finished lighting, set its bit in our mask
            neighbor_lm.mutex.lockUncancelable(io);
            const neighbor_lit = !neighbor_lm.dirty;
            neighbor_lm.mutex.unlock(io);

            if (neighbor_lit) {
                const self_old = self_lm.lit_neighbors.fetchOr(neighbor_bit, .acq_rel);
                if ((self_old | neighbor_bit) == ALL_LIT and self_old != ALL_LIT) {
                    if (self.pool) |p| p.submitMesh(key);
                }
            }
        }

        // No fallback for edge chunks: the outermost ring of loaded chunks
        // (at RENDER_DISTANCE boundary) intentionally never reaches ALL_LIT
        // because their outward neighbors aren't loaded. This ring serves as
        // a "data ring" providing real neighbor lighting data to interior chunks.
        // Only chunks with all 27 neighbors loaded get meshed — no dark borders.
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

        // Skip stale chunks
        const player_snapshot = if (self.pool) |p| p.player_chunk else ChunkKey{ .cx = 0, .cy = 0, .cz = 0 };
        const ud: i64 = ChunkStreamer.UNLOAD_DISTANCE;
        if (distSq(key, player_snapshot) > ud * ud) {
            _ = self.stats_stale.fetchAdd(1, .monotonic);
            return true;
        }

        // Acquire center chunk reference
        const chunk = self.chunk_map.get(key) orelse return true;
        _ = chunk.acquire();
        defer self.chunk_pool.release(chunk);

        // Skip all-air chunks immediately (no geometry possible)
        if (!light_only and chunk.blocks.get(0) == BlockState.defaultState(.air)) blk: {
            if (chunk.blocks.palette_len > 1) break :blk;
            _ = self.stats_hidden.fetchAdd(1, .monotonic);
            return true;
        }

        const neighbors = self.chunk_map.getNeighbors(key);

        // Skip fully hidden chunks (all opaque + all neighbor boundaries opaque)
        if (!light_only and WorldState.isFullyHidden(chunk, neighbors)) {
            _ = self.stats_hidden.fetchAdd(1, .monotonic);
            return true;
        }

        // LightMap pointers: stable (main-thread-only mutation, worker read-only via .get()).
        // Write access serialized by per-LightMap mutex below.
        const offsets = WorldState.face_neighbor_offsets;
        const light_map: ?*LightMap = self.light_maps.get(key);
        var face_neighbor_lights: [6]?*LightMap = .{null} ** 6;
        for (0..6) |i| {
            const nk = ChunkKey{
                .cx = key.cx + offsets[i][0],
                .cy = key.cy + offsets[i][1],
                .cz = key.cz + offsets[i][2],
            };
            face_neighbor_lights[i] = self.light_maps.get(nk);
        }
        // All 27 neighbors for mesh light sampling (Cubyz: getMesh finds any chunk)
        const offsets_27 = WorldState.neighbor_offsets_27;
        var neighbor_lights: [27]?*LightMap = .{null} ** 27;
        for (0..27) |i| {
            if (offsets_27[i][0] == 0 and offsets_27[i][1] == 0 and offsets_27[i][2] == 0) continue;
            neighbor_lights[i] = self.light_maps.get(.{
                .cx = key.cx + offsets_27[i][0],
                .cy = key.cy + offsets_27[i][1],
                .cz = key.cz + offsets_27[i][2],
            });
        }

        const neighbor_borders = LightMapMod.snapshotNeighborBorders(face_neighbor_lights);

        if (light_map) |lm| lm.mutex.lockUncancelable(io);
        defer {
            if (light_map) |lm| lm.mutex.unlock(io);
        }

        if (light_map) |lm| {
            if (lm.dirty) {
                lm.incremental = null;
                const surface_heights = self.surface_height_map.getHeights(key.cx, key.cz);
                const boundary_mask = LightEngine.computeChunkLight(chunk, neighbors, neighbor_borders, lm, key.cy, surface_heights);

                // Synchronous cross-chunk propagation (Cubyz propagateDirect pattern).
                // Unlock source before cross-chunk work to avoid deadlock.
                // Two-hop cascade ensures diagonal chunks receive propagated light.
                if (boundary_mask != 0) {
                    lm.mutex.unlock(io);

                    var secondary_lo_keys: [6]ChunkKey = undefined;
                    var secondary_lo_count: usize = 0;

                    for (0..6) |i| {
                        if (boundary_mask & (@as(u6, 1) << @intCast(i)) == 0) continue;
                        const nk = ChunkKey{
                            .cx = key.cx + offsets[i][0],
                            .cy = key.cy + offsets[i][1],
                            .cz = key.cz + offsets[i][2],
                        };
                        const nlm = self.light_maps.get(nk) orelse continue;
                        if (nlm.dirty) continue; // neighbor not yet computed — async fallback
                        const nchunk = self.chunk_map.get(nk) orelse continue;

                        // Snapshot this neighbor's borders (source is unlocked, readable)
                        var n_neighbor_lights: [6]?*LightMap = .{null} ** 6;
                        for (0..6) |j| {
                            n_neighbor_lights[j] = self.light_maps.get(.{
                                .cx = nk.cx + offsets[j][0],
                                .cy = nk.cy + offsets[j][1],
                                .cz = nk.cz + offsets[j][2],
                            });
                        }
                        const n_borders = LightMapMod.snapshotNeighborBorders(n_neighbor_lights);

                        nlm.mutex.lockUncancelable(io);
                        if (LightEngine.needsPropagation(nchunk, n_borders, nlm)) {
                            LightEngine.propagateFromNeighbor(nchunk, n_borders, nlm);
                        }
                        nlm.mutex.unlock(io);

                        secondary_lo_keys[secondary_lo_count] = nk;
                        secondary_lo_count += 1;
                    }

                    // Second hop: cascade from each updated face neighbor to its
                    // face neighbors (diagonal chunks relative to source).
                    var secondary_lo_keys2: [36]ChunkKey = undefined;
                    var secondary_lo_count2: usize = 0;
                    for (secondary_lo_keys[0..secondary_lo_count]) |nk| {
                        const nlm = self.light_maps.get(nk) orelse continue;
                        nlm.mutex.lockUncancelable(io);
                        const nb_mask = LightEngine.computeBoundaryMask(nlm);
                        nlm.mutex.unlock(io);
                        if (nb_mask == 0) continue;

                        for (0..6) |j| {
                            if (nb_mask & (@as(u6, 1) << @intCast(j)) == 0) continue;
                            const nnk = ChunkKey{
                                .cx = nk.cx + offsets[j][0],
                                .cy = nk.cy + offsets[j][1],
                                .cz = nk.cz + offsets[j][2],
                            };
                            if (nnk.cx == key.cx and nnk.cy == key.cy and nnk.cz == key.cz) continue;
                            const nnlm = self.light_maps.get(nnk) orelse continue;
                            if (nnlm.dirty) continue;
                            const nnchunk = self.chunk_map.get(nnk) orelse continue;

                            var nn_nl: [6]?*LightMap = .{null} ** 6;
                            for (0..6) |k| {
                                nn_nl[k] = self.light_maps.get(.{
                                    .cx = nnk.cx + offsets[k][0],
                                    .cy = nnk.cy + offsets[k][1],
                                    .cz = nnk.cz + offsets[k][2],
                                });
                            }
                            const nn_borders = LightMapMod.snapshotNeighborBorders(nn_nl);

                            nnlm.mutex.lockUncancelable(io);
                            if (LightEngine.needsPropagation(nnchunk, nn_borders, nnlm)) {
                                LightEngine.propagateFromNeighbor(nnchunk, nn_borders, nnlm);
                                if (secondary_lo_count2 < secondary_lo_keys2.len) {
                                    secondary_lo_keys2[secondary_lo_count2] = nnk;
                                    secondary_lo_count2 += 1;
                                }
                            }
                            nnlm.mutex.unlock(io);
                        }
                    }

                    if (secondary_lo_count > 0) {
                        if (self.pool) |p| p.submitMeshLightOnlyBatch(secondary_lo_keys[0..secondary_lo_count]);
                    }
                    if (secondary_lo_count2 > 0) {
                        if (self.pool) |p| p.submitMeshLightOnlyBatch(secondary_lo_keys2[0..secondary_lo_count2]);
                    }

                    lm.mutex.lockUncancelable(io);
                }
            } else if (lm.incremental) |update| {
                lm.incremental = null;

                // Source chunk: incremental update with border spill collection
                var spill = LightEngine.BorderSpill{};
                var sky_spill = LightEngine.BorderSpill{};
                const boundary_mask = LightEngine.applyBlockChange(chunk, lm, update.local, update.old_block, &spill, &sky_spill, neighbor_borders);

                // UNLOCK source mutex before cross-chunk processing
                lm.mutex.unlock(io);

                // Cubyz-style: LightEngine handles recursive cross-chunk
                // destructive BFS + deferred batch reconstruction for both channels.
                var affected_keys: [24]ChunkKey = undefined;
                var affected_masks: [24]u6 = .{0} ** 24;
                const n_count = LightEngine.processNeighborSpill(
                    false, &spill, key, self.light_maps, self.chunk_map, &affected_keys, &affected_masks,
                );
                for (0..n_count) |ni| {
                    if (self.pool) |p| p.submitMesh(affected_keys[ni]);
                    // Synchronous cross-chunk propagation for reseed boundaries
                    // (Cubyz: propagateDirect crosses chunks recursively during
                    // reconstruction; we replicate by propagating immediately).
                    if (affected_masks[ni] != 0) {
                        var lo_keys2: [6]ChunkKey = undefined;
                        var lo_count2: usize = 0;
                        for (0..6) |i| {
                            if (affected_masks[ni] & (@as(u6, 1) << @intCast(i)) == 0) continue;
                            const rnk = ChunkKey{
                                .cx = affected_keys[ni].cx + offsets[i][0],
                                .cy = affected_keys[ni].cy + offsets[i][1],
                                .cz = affected_keys[ni].cz + offsets[i][2],
                            };
                            const rnlm = self.light_maps.get(rnk) orelse continue;
                            if (rnlm.dirty) continue;
                            const rnchunk = self.chunk_map.get(rnk) orelse continue;

                            var rn_neighbor_lights: [6]?*LightMap = .{null} ** 6;
                            for (0..6) |j| {
                                rn_neighbor_lights[j] = self.light_maps.get(.{
                                    .cx = rnk.cx + offsets[j][0],
                                    .cy = rnk.cy + offsets[j][1],
                                    .cz = rnk.cz + offsets[j][2],
                                });
                            }
                            const rn_borders = LightMapMod.snapshotNeighborBorders(rn_neighbor_lights);

                            rnlm.mutex.lockUncancelable(io);
                            if (LightEngine.needsPropagation(rnchunk, rn_borders, rnlm)) {
                                LightEngine.propagateFromNeighbor(rnchunk, rn_borders, rnlm);
                            }
                            rnlm.mutex.unlock(io);

                            lo_keys2[lo_count2] = rnk;
                            lo_count2 += 1;
                        }
                        if (lo_count2 > 0) {
                            if (self.pool) |p2| p2.submitMeshLightOnlyBatch(lo_keys2[0..lo_count2]);
                        }
                    }
                }

                // Sky light cross-chunk destructive
                var sky_affected_keys: [24]ChunkKey = undefined;
                var sky_affected_masks: [24]u6 = .{0} ** 24;
                const sky_n_count = LightEngine.processNeighborSpill(
                    true, &sky_spill, key, self.light_maps, self.chunk_map, &sky_affected_keys, &sky_affected_masks,
                );
                for (0..sky_n_count) |ni| {
                    if (self.pool) |p| p.submitMesh(sky_affected_keys[ni]);
                    // Synchronous cross-chunk propagation for sky reseed boundaries
                    if (sky_affected_masks[ni] != 0) {
                        var lo_keys2: [6]ChunkKey = undefined;
                        var lo_count2: usize = 0;
                        for (0..6) |i| {
                            if (sky_affected_masks[ni] & (@as(u6, 1) << @intCast(i)) == 0) continue;
                            const snk = ChunkKey{
                                .cx = sky_affected_keys[ni].cx + offsets[i][0],
                                .cy = sky_affected_keys[ni].cy + offsets[i][1],
                                .cz = sky_affected_keys[ni].cz + offsets[i][2],
                            };
                            const snlm = self.light_maps.get(snk) orelse continue;
                            if (snlm.dirty) continue;
                            const snchunk = self.chunk_map.get(snk) orelse continue;

                            var sn_neighbor_lights: [6]?*LightMap = .{null} ** 6;
                            for (0..6) |j| {
                                sn_neighbor_lights[j] = self.light_maps.get(.{
                                    .cx = snk.cx + offsets[j][0],
                                    .cy = snk.cy + offsets[j][1],
                                    .cz = snk.cz + offsets[j][2],
                                });
                            }
                            const sn_borders = LightMapMod.snapshotNeighborBorders(sn_neighbor_lights);

                            snlm.mutex.lockUncancelable(io);
                            if (LightEngine.needsPropagation(snchunk, sn_borders, snlm)) {
                                LightEngine.propagateFromNeighbor(snchunk, sn_borders, snlm);
                            }
                            snlm.mutex.unlock(io);

                            lo_keys2[lo_count2] = snk;
                            lo_count2 += 1;
                        }
                        if (lo_count2 > 0) {
                            if (self.pool) |p2| p2.submitMeshLightOnlyBatch(lo_keys2[0..lo_count2]);
                        }
                    }
                }

                // Synchronous cross-chunk additive propagation (Cubyz pattern).
                // Source is already unlocked — propagate directly into neighbors.
                // Two-hop cascade: after propagating to face neighbor B, also
                // propagate to B's face neighbors (diagonal to source A). This
                // matches Cubyz's inline propagateDirect which recursively crosses
                // chunk boundaries without depth limit.
                if (boundary_mask != 0) {
                    var lo_keys: [6]ChunkKey = undefined;
                    var lo_count: usize = 0;
                    for (0..6) |i| {
                        if (boundary_mask & (@as(u6, 1) << @intCast(i)) == 0) continue;
                        const nk = ChunkKey{
                            .cx = key.cx + offsets[i][0],
                            .cy = key.cy + offsets[i][1],
                            .cz = key.cz + offsets[i][2],
                        };
                        const nlm = self.light_maps.get(nk) orelse continue;
                        if (nlm.dirty) continue;
                        const nchunk = self.chunk_map.get(nk) orelse continue;

                        var n_neighbor_lights: [6]?*LightMap = .{null} ** 6;
                        for (0..6) |j| {
                            n_neighbor_lights[j] = self.light_maps.get(.{
                                .cx = nk.cx + offsets[j][0],
                                .cy = nk.cy + offsets[j][1],
                                .cz = nk.cz + offsets[j][2],
                            });
                        }
                        const n_borders = LightMapMod.snapshotNeighborBorders(n_neighbor_lights);

                        nlm.mutex.lockUncancelable(io);
                        if (LightEngine.needsPropagation(nchunk, n_borders, nlm)) {
                            LightEngine.propagateFromNeighbor(nchunk, n_borders, nlm);
                        }
                        nlm.mutex.unlock(io);

                        lo_keys[lo_count] = nk;
                        lo_count += 1;
                    }

                    // Second hop: cascade from each updated face neighbor B to B's
                    // face neighbors (which include diagonal chunks relative to A).
                    var lo_keys2: [36]ChunkKey = undefined;
                    var lo_count2: usize = 0;
                    for (lo_keys[0..lo_count]) |nk| {
                        const nlm = self.light_maps.get(nk) orelse continue;
                        nlm.mutex.lockUncancelable(io);
                        const nb_mask = LightEngine.computeBoundaryMask(nlm);
                        nlm.mutex.unlock(io);
                        if (nb_mask == 0) continue;

                        for (0..6) |j| {
                            if (nb_mask & (@as(u6, 1) << @intCast(j)) == 0) continue;
                            const nnk = ChunkKey{
                                .cx = nk.cx + offsets[j][0],
                                .cy = nk.cy + offsets[j][1],
                                .cz = nk.cz + offsets[j][2],
                            };
                            // Skip source chunk (avoid re-propagating back)
                            if (nnk.cx == key.cx and nnk.cy == key.cy and nnk.cz == key.cz) continue;
                            const nnlm = self.light_maps.get(nnk) orelse continue;
                            if (nnlm.dirty) continue;
                            const nnchunk = self.chunk_map.get(nnk) orelse continue;

                            var nn_neighbor_lights: [6]?*LightMap = .{null} ** 6;
                            for (0..6) |k| {
                                nn_neighbor_lights[k] = self.light_maps.get(.{
                                    .cx = nnk.cx + offsets[k][0],
                                    .cy = nnk.cy + offsets[k][1],
                                    .cz = nnk.cz + offsets[k][2],
                                });
                            }
                            const nn_borders = LightMapMod.snapshotNeighborBorders(nn_neighbor_lights);

                            nnlm.mutex.lockUncancelable(io);
                            if (LightEngine.needsPropagation(nnchunk, nn_borders, nnlm)) {
                                LightEngine.propagateFromNeighbor(nnchunk, nn_borders, nnlm);
                                if (lo_count2 < lo_keys2.len) {
                                    lo_keys2[lo_count2] = nnk;
                                    lo_count2 += 1;
                                }
                            }
                            nnlm.mutex.unlock(io);
                        }
                    }

                    // Submit mesh refresh for all affected neighbors
                    if (lo_count > 0) {
                        if (self.pool) |p| p.submitMeshLightOnlyBatch(lo_keys[0..lo_count]);
                    }
                    if (lo_count2 > 0) {
                        if (self.pool) |p| p.submitMeshLightOnlyBatch(lo_keys2[0..lo_count2]);
                    }
                }

                // Re-lock so the defer unlock at outer scope is balanced
                lm.mutex.lockUncancelable(io);
            }
        }

        if (light_only) {
            // Propagate neighbor border light into this chunk's light map.
            // Only for light-only tasks — full mesh tasks already handle border
            // propagation via computeChunkLight's BFS seeding (dirty path) or
            // applyBlockChange (incremental path). Running this after a dirty
            // recompute would re-add stale neighbor values that were just cleared.
            if (light_map) |lm| {
                if (LightEngine.needsPropagation(chunk, neighbor_borders, lm)) {
                    LightEngine.propagateFromNeighbor(chunk, neighbor_borders, lm);

                    // Cascade: if propagated light reaches our boundaries, synchronously
                    // push it into face neighbors (Cubyz propagateDirect pattern).
                    // Without this, light that needs 2+ face-hops (diagonal chunks)
                    // never receives propagated values.
                    const boundary_mask = LightEngine.computeBoundaryMask(lm);
                    if (boundary_mask != 0) {
                        lm.mutex.unlock(io);

                        var cascade_keys: [6]ChunkKey = undefined;
                        var cascade_count: usize = 0;
                        for (0..6) |i| {
                            if (boundary_mask & (@as(u6, 1) << @intCast(i)) == 0) continue;
                            const nk = ChunkKey{
                                .cx = key.cx + offsets[i][0],
                                .cy = key.cy + offsets[i][1],
                                .cz = key.cz + offsets[i][2],
                            };
                            const nlm = self.light_maps.get(nk) orelse continue;
                            if (nlm.dirty) continue;
                            const nchunk = self.chunk_map.get(nk) orelse continue;

                            var n_neighbor_lights2: [6]?*LightMap = .{null} ** 6;
                            for (0..6) |j| {
                                n_neighbor_lights2[j] = self.light_maps.get(.{
                                    .cx = nk.cx + offsets[j][0],
                                    .cy = nk.cy + offsets[j][1],
                                    .cz = nk.cz + offsets[j][2],
                                });
                            }
                            const n_borders2 = LightMapMod.snapshotNeighborBorders(n_neighbor_lights2);

                            nlm.mutex.lockUncancelable(io);
                            if (LightEngine.needsPropagation(nchunk, n_borders2, nlm)) {
                                LightEngine.propagateFromNeighbor(nchunk, n_borders2, nlm);
                                cascade_keys[cascade_count] = nk;
                                cascade_count += 1;
                            }
                            nlm.mutex.unlock(io);
                        }

                        if (cascade_count > 0) {
                            if (self.pool) |p| p.submitMeshLightOnlyBatch(cascade_keys[0..cascade_count]);
                        }

                        lm.mutex.lockUncancelable(io);
                    }
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
