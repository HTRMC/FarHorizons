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
        var neighbor_lights: [6]?*LightMap = .{null} ** 6;
        for (0..6) |i| {
            const nk = ChunkKey{
                .cx = key.cx + face_offsets[i][0],
                .cy = key.cy + face_offsets[i][1],
                .cz = key.cz + face_offsets[i][2],
            };
            neighbor_lights[i] = self.light_maps.get(nk);
        }

        const neighbor_borders = LightMapMod.snapshotNeighborBorders(neighbor_lights);

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
        var neighbor_lights: [6]?*LightMap = .{null} ** 6;
        for (0..6) |i| {
            const nk = ChunkKey{
                .cx = key.cx + offsets[i][0],
                .cy = key.cy + offsets[i][1],
                .cz = key.cz + offsets[i][2],
            };
            neighbor_lights[i] = self.light_maps.get(nk);
        }

        const neighbor_borders = LightMapMod.snapshotNeighborBorders(neighbor_lights);

        if (light_map) |lm| lm.mutex.lockUncancelable(io);
        defer {
            if (light_map) |lm| lm.mutex.unlock(io);
        }

        if (light_map) |lm| {
            if (lm.dirty) {
                lm.incremental = null;
                const surface_heights = self.surface_height_map.getHeights(key.cx, key.cz);
                const boundary_mask = LightEngine.computeChunkLight(chunk, neighbors, neighbor_borders, lm, key.cy, surface_heights);

                // Initial load / full recompute: light-only refresh for neighbors.
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

                // Cross-chunk destructive BFS: collect border spill entries
                // during source chunk's destructive pass, then surgically
                // clear only the affected values in each neighbor (Cubyz-style).
                var spill = LightEngine.BorderSpill{};
                _ = LightEngine.applyBlockChange(chunk, lm, update.local, update.old_block, &spill);

                // UNLOCK source mutex before neighbor processing to avoid
                // AB/BA deadlock (neighbor border snapshot locks our mutex).
                lm.mutex.unlock(io);

                // Cubyz-style deferred batch reconstruction:
                // Phase 1: Run ALL destructive BFS across chunks, collecting
                // reseed positions. No reconstruction yet.
                // Phase 2: After all destruction, batch-reconstruct from
                // remaining sources in each affected chunk.
                const MAX_AFFECTED = 8; // source + up to 6 face + 1 hop
                var affected_lms: [MAX_AFFECTED]*LightMap = undefined;
                var affected_chunks: [MAX_AFFECTED]*const WorldState.Chunk = undefined;
                var affected_reseeds: [MAX_AFFECTED]LightEngine.ReseedBuffer = undefined;
                var affected_keys: [MAX_AFFECTED]ChunkKey = undefined;
                var affected_count: u32 = 0;

                // Source chunk reseeds (from applyBlockChange's destructiveBlockLight)
                // were already applied inline (null deferred_reseeds in applyBlockChange).
                // For neighbors, we defer.

                const MAX_HOPS = 4;
                var current_spill = spill;
                var hop: u32 = 0;

                while (hop < MAX_HOPS) : (hop += 1) {
                    var next_spill = LightEngine.BorderSpill{};
                    var any_work = false;

                    for (0..6) |face| {
                        if (current_spill.counts[face] == 0) continue;
                        const nk = ChunkKey{
                            .cx = key.cx + offsets[face][0],
                            .cy = key.cy + offsets[face][1],
                            .cz = key.cz + offsets[face][2],
                        };
                        const nlm = self.light_maps.get(nk) orelse continue;
                        const nchunk = self.chunk_map.get(nk) orelse continue;

                        // Destructive-only pass (reseeds deferred)
                        var reseeds = LightEngine.ReseedBuffer{};
                        nlm.mutex.lockUncancelable(io);
                        _ = LightEngine.destructiveBlockLightFromBorder(nlm, nchunk, current_spill.entries[face][0..current_spill.counts[face]], &next_spill, &reseeds);
                        nlm.mutex.unlock(io);

                        // Track for batch reconstruction
                        if (affected_count < MAX_AFFECTED and reseeds.count > 0) {
                            affected_lms[affected_count] = nlm;
                            affected_chunks[affected_count] = nchunk;
                            affected_reseeds[affected_count] = reseeds;
                            affected_keys[affected_count] = nk;
                            affected_count += 1;
                        }

                        if (self.pool) |p| p.submitMesh(nk);
                        any_work = true;
                    }

                    if (!any_work) break;
                    var has_next = false;
                    for (next_spill.counts) |c| {
                        if (c > 0) { has_next = true; break; }
                    }
                    if (!has_next) break;
                    current_spill = next_spill;
                }

                // Phase 2: Batch reconstruction — all stale values are now
                // cleared across all chunks, so reseeds read correct values.
                for (0..affected_count) |ai| {
                    affected_lms[ai].mutex.lockUncancelable(io);
                    _ = LightEngine.reseedBlockLight(affected_lms[ai], affected_chunks[ai], affected_reseeds[ai].positions[0..affected_reseeds[ai].count]);
                    affected_lms[ai].mutex.unlock(io);
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
