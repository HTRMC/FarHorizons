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
    const MAX_INPUT = 512;
    pub const MAX_OUTPUT = 64;

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

    // Output queue (consumed by TransferPipeline thread)
    output_queue: [MAX_OUTPUT]ChunkResult,
    output_len: u32,
    output_mutex: Io.Mutex,
    output_cond: Io.Condition,

    // State
    allocator: std.mem.Allocator,
    chunk_map: *const ChunkMap,
    light_maps: *const LightMaps,
    surface_height_map: *const SurfaceHeightMap,
    player_chunk: ChunkKey,
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
        light_maps: *const LightMaps,
        surface_height_map: *const SurfaceHeightMap,
    ) void {
        self.* = .{
            .input_heap = Heap.initContext(self),
            .input_set = DedupSet.init(allocator),
            .input_mutex = .init,
            .output_queue = undefined,
            .output_len = 0,
            .output_mutex = .init,
            .output_cond = .init,
            .allocator = allocator,
            .chunk_map = chunk_map,
            .light_maps = light_maps,
            .surface_height_map = surface_height_map,
            .player_chunk = .{ .cx = 0, .cy = 0, .cz = 0 },
            .pool = null,
            .stats_meshed = std.atomic.Value(u64).init(0),
            .stats_light_only = std.atomic.Value(u64).init(0),
            .stats_hidden = std.atomic.Value(u64).init(0),
            .stats_stale = std.atomic.Value(u64).init(0),
            .stats_output_waits = std.atomic.Value(u64).init(0),
        };
        self.input_heap.context = self;
        self.input_heap.ensureTotalCapacity(allocator, MAX_INPUT) catch {};
        self.input_set.ensureTotalCapacity(@intCast(MAX_INPUT)) catch {};
    }

    pub fn stop(self: *MeshWorker) void {
        // Free any remaining output results
        for (self.output_queue[0..self.output_len]) |r| {
            if (!r.light_only) self.allocator.free(r.faces);
            self.allocator.free(r.lights);
        }
        self.output_len = 0;
        self.input_heap.deinit(self.allocator);
        self.input_set.deinit();
    }

    pub fn syncChunkMap(self: *MeshWorker, chunk_map: *const ChunkMap, light_maps: *const LightMaps, surface_height_map: *const SurfaceHeightMap, player_chunk: ChunkKey) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.input_mutex.lockUncancelable(io);
        self.chunk_map = chunk_map;
        self.light_maps = light_maps;
        self.surface_height_map = surface_height_map;
        const old = self.player_chunk;
        self.player_chunk = player_chunk;
        if (!old.eql(player_chunk)) self.reheapify();
        self.input_mutex.unlock(io);
    }

    /// Floyd's bottom-up heapify — O(n), in-place. Caller must hold input_mutex.
    fn reheapify(self: *MeshWorker) void {
        const items = self.input_heap.items;
        if (items.len <= 1) return;
        var i = items.len >> 1;
        while (i > 0) {
            i -= 1;
            const target = items[i];
            var idx = i;
            while (true) {
                var child = (std.math.mul(usize, idx, 2) catch break) | 1;
                if (child >= items.len) break;
                const right = child + 1;
                if (right < items.len and meshDistCmp(self, items[right], items[child]) == .lt) {
                    child = right;
                }
                if (meshDistCmp(self, target, items[child]) == .lt) break;
                items[idx] = items[child];
                idx = child;
            }
            items[idx] = target;
        }
    }

    pub fn enqueue(self: *MeshWorker, key: ChunkKey) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.input_mutex.lockUncancelable(io);
        defer self.input_mutex.unlock(io);

        if (self.input_set.getPtr(key)) |existing| {
            if (existing.*) existing.* = false;
            return;
        }
        self.input_set.put(key, false) catch return;
        self.input_heap.push(self.allocator, key) catch return;
        if (self.pool) |p| p.notify();
    }

    pub fn enqueueBatch(self: *MeshWorker, keys: []const ChunkKey) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.input_mutex.lockUncancelable(io);
        defer self.input_mutex.unlock(io);

        var added: u32 = 0;
        for (keys) |key| {
            if (self.input_set.getPtr(key)) |existing| {
                if (existing.*) existing.* = false;
                continue;
            }
            self.input_set.put(key, false) catch continue;
            self.input_heap.push(self.allocator, key) catch continue;
            added += 1;
        }
        if (added > 0) {
            if (self.pool) |p| p.notifyAll();
        }
    }

    pub fn enqueueLightOnlyBatch(self: *MeshWorker, keys: []const ChunkKey) void {
        const io = Io.Threaded.global_single_threaded.io();
        self.input_mutex.lockUncancelable(io);
        defer self.input_mutex.unlock(io);

        var added: u32 = 0;
        for (keys) |key| {
            if (self.input_set.contains(key)) continue;
            self.input_set.put(key, true) catch continue;
            self.input_heap.push(self.allocator, key) catch continue;
            added += 1;
        }
        if (added > 0) {
            if (self.pool) |p| p.notifyAll();
        }
    }

    /// Process one mesh task. Called by ThreadPool workers.
    /// Returns true if work was consumed, false if nothing available.
    pub fn processOne(self: *MeshWorker) bool {
        const io = Io.Threaded.global_single_threaded.io();

        // Check output capacity before doing expensive work
        self.output_mutex.lockUncancelable(io);
        const output_full = self.output_len >= MAX_OUTPUT;
        self.output_mutex.unlock(io);
        if (output_full) return false;

        // Pop one key from the input heap
        self.input_mutex.lockUncancelable(io);
        const key = self.input_heap.pop() orelse {
            self.input_mutex.unlock(io);
            return false;
        };
        const light_only = self.input_set.get(key) orelse false;
        _ = self.input_set.remove(key);
        const local_chunk_map = self.chunk_map;
        const local_light_maps: *const LightMaps = self.light_maps;
        const local_shm: *const SurfaceHeightMap = self.surface_height_map;
        const player_snapshot = self.player_chunk;
        self.input_mutex.unlock(io);

        // Skip stale chunks the player has moved away from
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
                const old_mask = LightEngine.computeBoundaryMask(lm);
                const surface_heights = local_shm.getHeights(key.cx, key.cz);
                const new_mask = LightEngine.computeChunkLight(chunk, neighbors, neighbor_borders, lm, key.cy, surface_heights);

                const changed_mask = old_mask ^ new_mask;
                const stable_mask = old_mask & new_mask;

                if (changed_mask != 0) {
                    var dirty_keys: [6]ChunkKey = undefined;
                    var dirty_count: usize = 0;
                    for (0..6) |i| {
                        if (changed_mask & (@as(u6, 1) << @intCast(i)) != 0) {
                            const nk = ChunkKey{
                                .cx = key.cx + offsets[i][0],
                                .cy = key.cy + offsets[i][1],
                                .cz = key.cz + offsets[i][2],
                            };
                            if (local_light_maps.get(nk)) |nlm| {
                                nlm.dirty = true;
                            }
                            dirty_keys[dirty_count] = nk;
                            dirty_count += 1;
                        }
                    }
                    if (dirty_count > 0) {
                        self.enqueueBatch(dirty_keys[0..dirty_count]);
                    }
                }
                if (stable_mask != 0) {
                    var lo_keys: [6]ChunkKey = undefined;
                    var lo_count: usize = 0;
                    for (0..6) |i| {
                        if (stable_mask & (@as(u6, 1) << @intCast(i)) != 0) {
                            lo_keys[lo_count] = .{
                                .cx = key.cx + offsets[i][0],
                                .cy = key.cy + offsets[i][1],
                                .cz = key.cz + offsets[i][2],
                            };
                            lo_count += 1;
                        }
                    }
                    if (lo_count > 0) {
                        self.enqueueLightOnlyBatch(lo_keys[0..lo_count]);
                    }
                }
            } else if (lm.incremental) |update| {
                lm.incremental = null;
                if (LightEngine.applyBlockChange(chunk, lm, update.lx, update.ly, update.lz, update.old_block)) |boundary_mask| {
                    if (boundary_mask != 0) {
                        var cascade_keys: [6]ChunkKey = undefined;
                        var cascade_count: usize = 0;
                        for (0..6) |i| {
                            if (boundary_mask & (@as(u6, 1) << @intCast(i)) != 0) {
                                const nk = ChunkKey{
                                    .cx = key.cx + offsets[i][0],
                                    .cy = key.cy + offsets[i][1],
                                    .cz = key.cz + offsets[i][2],
                                };
                                if (local_light_maps.get(nk)) |nlm| {
                                    nlm.dirty = true;
                                }
                                cascade_keys[cascade_count] = nk;
                                cascade_count += 1;
                            }
                        }
                        if (cascade_count > 0) {
                            self.enqueueBatch(cascade_keys[0..cascade_count]);
                        }
                    }
                } else {
                    const surface_heights = local_shm.getHeights(key.cx, key.cz);
                    const boundary_mask = LightEngine.computeChunkLight(chunk, neighbors, neighbor_borders, lm, key.cy, surface_heights);
                    if (boundary_mask != 0) {
                        var cascade_keys: [6]ChunkKey = undefined;
                        var cascade_count: usize = 0;
                        for (0..6) |i| {
                            if (boundary_mask & (@as(u6, 1) << @intCast(i)) != 0) {
                                const nk = ChunkKey{
                                    .cx = key.cx + offsets[i][0],
                                    .cy = key.cy + offsets[i][1],
                                    .cz = key.cz + offsets[i][2],
                                };
                                if (local_light_maps.get(nk)) |nlm| {
                                    nlm.dirty = true;
                                }
                                cascade_keys[cascade_count] = nk;
                                cascade_count += 1;
                            }
                        }
                        if (cascade_count > 0) {
                            self.enqueueBatch(cascade_keys[0..cascade_count]);
                        }
                    }
                }
            }
        }

        if (light_only) {
            const light_result = WorldState.generateChunkLightOnly(self.allocator, chunk, neighbors, light_map, neighbor_borders) catch |err| {
                std.log.err("Chunk light-only generation failed ({},{},{}): {}", .{ key.cx, key.cy, key.cz, err });
                return true;
            };

            self.output_mutex.lockUncancelable(io);
            if (self.output_len >= MAX_OUTPUT) {
                self.output_mutex.unlock(io);
                self.allocator.free(light_result.lights);
                _ = self.stats_output_waits.fetchAdd(1, .monotonic);
                return true;
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
            const mesh = WorldState.generateChunkMesh(self.allocator, chunk, neighbors, light_map, neighbor_borders) catch |err| {
                std.log.err("Chunk mesh generation failed ({},{},{}): {}", .{ key.cx, key.cy, key.cz, err });
                return true;
            };

            self.output_mutex.lockUncancelable(io);
            if (self.output_len >= MAX_OUTPUT) {
                self.output_mutex.unlock(io);
                self.allocator.free(mesh.faces);
                self.allocator.free(mesh.lights);
                _ = self.stats_output_waits.fetchAdd(1, .monotonic);
                return true;
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

    fn processOneErased(ctx: *anyopaque) bool {
        const self: *MeshWorker = @ptrCast(@alignCast(ctx));
        return self.processOne();
    }

    pub fn workSource(self: *MeshWorker) ThreadPool.WorkSource {
        return .{
            .ctx = @ptrCast(self),
            .processOneFn = processOneErased,
        };
    }
};
