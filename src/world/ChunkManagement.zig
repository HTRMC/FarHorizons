const std = @import("std");
const GameState = @import("GameState.zig");
const WorldState = @import("WorldState.zig");
const ChunkStreamer = @import("ChunkStreamer.zig").ChunkStreamer;
const WorldStreamingMod = @import("WorldStreaming.zig");
const SurfaceHeightMap = @import("SurfaceHeightMap.zig").SurfaceHeightMap;
const WorldRenderer = @import("../renderer/vulkan/WorldRenderer.zig").WorldRenderer;
const TlsfAllocator = @import("../allocators/TlsfAllocator.zig").TlsfAllocator;
const Io = std.Io;

const MAX_PENDING_UNLOADS = WorldStreamingMod.MAX_PENDING_UNLOADS;

/// Request load for missing chunks within render distance.
/// In singleplayer: submits to local ChunkStreamer via ThreadPool.
/// In multiplayer: chunks come from the server — no local loading.
pub fn requestMissingChunks(self: *GameState) void {
    if (!self.streaming.streaming_initialized) return;
    // In multiplayer, chunks are sent by the server — don't load/generate locally.
    if (self.multiplayer_client) return;

    const rd = ChunkStreamer.RENDER_DISTANCE;
    const rd_sq = rd * rd;
    const pc = self.streaming.player_chunk;
    var batch: [1024]WorldState.ChunkKey = undefined;
    var batch_len: u32 = 0;

    var shell: i32 = 0;
    outer: while (shell <= rd) : (shell += 1) {
        var dy: i32 = -shell;
        while (dy <= shell) : (dy += 1) {
            var dz: i32 = -shell;
            while (dz <= shell) : (dz += 1) {
                var dx: i32 = -shell;
                while (dx <= shell) : (dx += 1) {
                    if (@max(@abs(dx), @abs(dy), @abs(dz)) != shell) {
                        dx = shell - 1;
                        continue;
                    }
                    if (dx * dx + dy * dy + dz * dz > rd_sq) continue;
                    const key = WorldState.ChunkKey{
                        .cx = pc.cx + dx,
                        .cy = pc.cy + dy,
                        .cz = pc.cz + dz,
                    };
                    if (self.chunk_map.get(key) == null) {
                        batch[batch_len] = key;
                        batch_len += 1;
                        if (batch_len >= batch.len) break :outer;
                    }
                }
            }
        }
    }

    if (batch_len > 0) {
        if (self.streaming.pool) |pool| pool.submitChunkLoadBatch(batch[0..batch_len]);
    }
}

pub fn worldTick(self: *GameState) void {
    // Drain chunks received from server (multiplayer)
    self.drainNetworkChunks();

    // Update player chunk from camera position
    const pos = self.camera.position;
    const current_chunk = WorldState.WorldBlockPos.init(
        @intFromFloat(@floor(pos.x)),
        @intFromFloat(@floor(pos.y)),
        @intFromFloat(@floor(pos.z)),
    ).toChunkKey();

    if (!current_chunk.eql(self.streaming.player_chunk) or !self.streaming.streaming_initialized) {
        self.streaming.player_chunk = current_chunk;
        self.streaming.streaming_initialized = true;
    }

    // Drain streamer output
    var results: [ChunkStreamer.MAX_OUTPUT]ChunkStreamer.LoadResult = undefined;
    const count = self.streaming.streamer.drainOutput(&results);
    for (results[0..count]) |result| {
        // Skip if chunk was already loaded (e.g. by double request)
        if (self.chunk_map.get(result.key) != null) {
            self.chunk_pool.release(result.chunk);
            continue;
        }
        self.chunk_map.put(result.key, result.chunk);
        self.surface_height_map.updateFromChunk(result.key, result.chunk);
        const lm = self.light_map_pool.acquire();
        self.light_maps.put(result.key, lm) catch {
            std.log.err("Failed to register light map for chunk ({},{},{})", .{ result.key.cx, result.key.cy, result.key.cz });
            self.light_map_pool.release(lm);
            continue;
        };
        // Submit a light task — mesh will be triggered automatically by the
        // 27-chunk bitmask when all 27 neighbors have finished lighting.
        // Missing neighbors (outside render distance) are skipped, never blocking.
        if (self.streaming.pool) |pool| pool.submitLight(result.key);
    }

    // Scan for chunks to unload (incremental cursor)
    scanUnloads(self);

    // Sync streamer player position + tick storage
    if (self.streaming.pool) |pool| pool.syncPlayerChunk(self.streaming.player_chunk);
    if (self.streaming.storage) |s| {
        s.tick();
    }


    // Track initial load readiness
    if (!self.streaming.initial_load_ready) {
        const chunk_count = self.chunk_map.count();
        const player_loaded = self.chunk_map.get(self.streaming.player_chunk) != null;
        if (chunk_count >= self.streaming.initial_load_target and player_loaded) {
            self.streaming.initial_load_ready = true;
        }
    }
}

pub fn scanUnloads(self: *GameState) void {
    // Only scan when previous unloads have been applied
    if (self.streaming.pending_unload_count > 0) return;

    const ud = ChunkStreamer.UNLOAD_DISTANCE;
    const ud_sq = ud * ud;
    const pc = self.streaming.player_chunk;
    const SCAN_BUDGET: u32 = 512;

    const map_size: u32 = @intCast(self.chunk_map.count());
    if (map_size == 0) return;

    var scanned: u32 = 0;
    var skipped: u32 = 0;
    var it = self.chunk_map.iterator();

    // Skip cursor entries
    while (skipped < self.streaming.unload_scan_cursor) {
        if (it.next() == null) {
            // Wrapped around — reset cursor and restart
            self.streaming.unload_scan_cursor = 0;
            it = self.chunk_map.iterator();
            break;
        }
        skipped += 1;
    }

    while (scanned < SCAN_BUDGET) : (scanned += 1) {
        const entry = it.next() orelse {
            self.streaming.unload_scan_cursor = 0;
            break;
        };
        self.streaming.unload_scan_cursor += 1;

        const key = entry.key_ptr.*;
        const dx = key.cx - pc.cx;
        const dy = key.cy - pc.cy;
        const dz = key.cz - pc.cz;
        if (dx * dx + dy * dy + dz * dz > ud_sq) {
            if (self.streaming.pending_unload_count < MAX_PENDING_UNLOADS) {
                self.streaming.pending_unload_keys[self.streaming.pending_unload_count] = key;
                self.streaming.pending_unload_count += 1;
            }
        }
    }
}

pub fn applyUnloadsToGpu(
    self: *GameState,
    wr: *WorldRenderer,
    deferred_face_frees: []TlsfAllocator.Handle,
    deferred_face_free_count: *u32,
    deferred_light_frees: []TlsfAllocator.Handle,
    deferred_light_free_count: *u32,
) void {
    for (self.streaming.pending_unload_keys[0..self.streaming.pending_unload_count]) |key| {
        // Free GPU TLSF allocs via deferred mechanism
        if (wr.chunk_slot_map.get(key)) |slot| {
            if (wr.chunk_face_alloc[slot]) |fa| {
                if (fa.handle != TlsfAllocator.null_handle) {
                    const idx = deferred_face_free_count.*;
                    if (idx < deferred_face_frees.len) {
                        deferred_face_frees[idx] = fa.handle;
                        deferred_face_free_count.* = idx + 1;
                    }
                }
            }
            if (wr.chunk_light_alloc[slot]) |la| {
                if (la.handle != TlsfAllocator.null_handle) {
                    const idx = deferred_light_free_count.*;
                    if (idx < deferred_light_frees.len) {
                        deferred_light_frees[idx] = la.handle;
                        deferred_light_free_count.* = idx + 1;
                    }
                }
            }
        }
        wr.releaseSlot(key);

        // Clear this chunk's bit from all neighbors' lit_neighbors bitmasks
        {
            const offsets_27 = WorldState.neighbor_offsets_27;
            for (offsets_27) |off| {
                const nk = WorldState.ChunkKey{
                    .cx = key.cx + off[0],
                    .cy = key.cy + off[1],
                    .cz = key.cz + off[2],
                };
                const neighbor_lm = self.light_maps.get(nk) orelse continue;
                const bit: u32 = @as(u32, 1) << WorldState.neighborBitIndex(-off[0], -off[1], -off[2]);
                _ = neighbor_lm.lit_neighbors.fetchAnd(~bit, .release);
            }
        }
        if (self.light_maps.fetchRemove(key)) |lm_kv| {
            self.light_map_pool.release(lm_kv.value);
        }
        if (self.chunk_map.remove(key)) |chunk| {
            self.chunk_pool.release(chunk);
        }
        // Clean up surface height column if no chunks remain in this column
        if (!SurfaceHeightMap.hasChunksInColumn(key.cx, key.cz, &self.chunk_map)) {
            self.surface_height_map.removeColumn(key.cx, key.cz);
        }
    }
    self.streaming.pending_unload_count = 0;
}

pub fn reportPipelineStats(self: *GameState) void {
    const io = Io.Threaded.global_single_threaded.io();
    const now = Io.Clock.now(.awake, io);

    const last = self.streaming.stats_last_time orelse {
        self.streaming.stats_last_time = now;
        return;
    };

    const elapsed_ns: i64 = @intCast(last.durationTo(now).nanoseconds);
    if (elapsed_ns < 2_000_000_000) return;
    self.streaming.stats_last_time = now;

    // Read + reset mesh worker counters
    var m_meshed: u64 = 0;
    var m_light: u64 = 0;
    var m_hidden: u64 = 0;
    var m_stale: u64 = 0;
    var m_waits: u64 = 0;
    if (self.streaming.mesh_worker) |mw| {
        m_meshed = mw.stats_meshed.swap(0, .monotonic);
        m_light = mw.stats_light_only.swap(0, .monotonic);
        m_hidden = mw.stats_hidden.swap(0, .monotonic);
        m_stale = mw.stats_stale.swap(0, .monotonic);
        m_waits = mw.stats_output_waits.swap(0, .monotonic);
    }

    // Read + reset transfer pipeline counters
    var t_transferred: u64 = 0;
    var t_dropped: u64 = 0;
    if (self.streaming.transfer_pipeline) |tp| {
        t_transferred = tp.stats_transferred.swap(0, .monotonic);
        t_dropped = tp.stats_dropped.swap(0, .monotonic);
    }

    // Sample queue depths (non-atomic, diagnostic only)
    var si: usize = 0;
    var mi: usize = 0;
    var mo: u32 = 0;
    if (self.streaming.pool) |pool| {
        si = pool.loadQueueDepth();
        mi = pool.meshQueueDepth();
    }
    if (self.streaming.mesh_worker) |mw| {
        mo = mw.output_len;
    }
    var co: u32 = 0;
    if (self.streaming.transfer_pipeline) |tp| {
        co = tp.committed_len;
    }

    // Storage timing breakdown
    if (self.streaming.storage) |s| {
        const st_loads = s.stats_load_count.swap(0, .monotonic);
        const st_hits = s.stats_cache_hits.swap(0, .monotonic);
        const st_region_ns = s.stats_region_ns.swap(0, .monotonic);
        const st_read_ns = s.stats_read_ns.swap(0, .monotonic);
        const st_disk = st_loads - st_hits;
        if (st_disk > 0) {
            std.log.info("[Storage] loads:{} hits:{} disk:{} | avg region_open:{d:.0}us read+decomp:{d:.0}us total:{d:.0}us", .{
                st_loads,
                st_hits,
                st_disk,
                @as(f64, @floatFromInt(st_region_ns)) / @as(f64, @floatFromInt(st_disk)) / 1000.0,
                @as(f64, @floatFromInt(st_read_ns)) / @as(f64, @floatFromInt(st_disk)) / 1000.0,
                @as(f64, @floatFromInt(st_region_ns + st_read_ns)) / @as(f64, @floatFromInt(st_disk)) / 1000.0,
            });
        }
    }
}
