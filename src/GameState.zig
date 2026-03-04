const std = @import("std");
const zlm = @import("zlm");
const Camera = @import("renderer/Camera.zig");
const WorldState = @import("world/WorldState.zig");
const ChunkMap = @import("world/ChunkMap.zig").ChunkMap;
const ChunkPool = @import("world/ChunkPool.zig").ChunkPool;
pub const ChunkStreamer = @import("world/ChunkStreamer.zig").ChunkStreamer;
const TerrainGen = @import("world/TerrainGen.zig");
const Physics = @import("Physics.zig");
const Raycast = @import("Raycast.zig");
const Storage = @import("world/storage/Storage.zig");
const WorldRenderer = @import("renderer/vulkan/WorldRenderer.zig").WorldRenderer;
const TlsfAllocator = @import("allocators/TlsfAllocator.zig").TlsfAllocator;
const MeshWorker = @import("world/MeshWorker.zig").MeshWorker;

const GameState = @This();

pub const MovementMode = enum { flying, walking };
pub const EYE_OFFSET: f32 = 1.62;
pub const TICK_RATE: f32 = 30.0;
pub const TICK_INTERVAL: f32 = 1.0 / TICK_RATE;
pub const HOTBAR_SIZE: u8 = 9;

// Initial load radius in chunks (per axis from center)
const LOAD_RADIUS_XZ: i32 = 2;
const LOAD_RADIUS_Y: i32 = 1;

pub fn blockName(block: WorldState.BlockType) []const u8 {
    return switch (block) {
        .air => "Air",
        .glass => "Glass",
        .grass_block => "Grass",
        .dirt => "Dirt",
        .stone => "Stone",
        .glowstone => "Glowstone",
        .sand => "Sand",
        .snow => "Snow",
        .water => "Water",
        .gravel => "Gravel",
    };
}

pub fn blockColor(block: WorldState.BlockType) [4]f32 {
    return switch (block) {
        .air => .{ 0.0, 0.0, 0.0, 0.0 },
        .glass => .{ 0.8, 0.9, 1.0, 0.4 },
        .grass_block => .{ 0.3, 0.7, 0.2, 1.0 },
        .dirt => .{ 0.6, 0.4, 0.2, 1.0 },
        .stone => .{ 0.5, 0.5, 0.5, 1.0 },
        .glowstone => .{ 1.0, 0.9, 0.5, 1.0 },
        .sand => .{ 0.82, 0.75, 0.51, 1.0 },
        .snow => .{ 0.95, 0.97, 1.0, 1.0 },
        .water => .{ 0.2, 0.4, 0.8, 0.6 },
        .gravel => .{ 0.5, 0.48, 0.47, 1.0 },
    };
}

allocator: std.mem.Allocator,
camera: Camera,
chunk_map: ChunkMap,
chunk_pool: ChunkPool,
entity_pos: [3]f32,
entity_vel: [3]f32,
entity_on_ground: bool,
mode: MovementMode,
input_move: [3]f32,
jump_requested: bool,
jump_cooldown: u8,
hit_result: ?Raycast.BlockHitResult,
dirty_chunks: DirtyChunkSet,
debug_camera_active: bool,
overdraw_mode: bool,
saved_camera: Camera,

selected_slot: u8 = 0,
hotbar: [HOTBAR_SIZE]WorldState.BlockType = .{ .grass_block, .dirt, .stone, .sand, .snow, .gravel, .glass, .glowstone, .water },
offhand: WorldState.BlockType = .air,

world_seed: u64,
storage: ?*Storage,
streamer: ChunkStreamer,
player_chunk: WorldState.ChunkKey,
streaming_initialized: bool,

debug_screens: u8 = 0,
delta_time: f32 = 0,
frame_timing: FrameTiming = .{},

prev_entity_pos: [3]f32,
prev_camera_pos: zlm.Vec3,
tick_camera_pos: zlm.Vec3,
render_entity_pos: [3]f32,

pub const FrameTiming = struct {
    update_ms: f32 = 0,
    render_ms: f32 = 0,
    frame_ms: f32 = 0,
};

pub const DirtyChunkSet = struct {
    const MAX_DIRTY = 64;
    keys: [MAX_DIRTY]WorldState.ChunkKey,
    count: u8,

    pub fn empty() DirtyChunkSet {
        return .{ .keys = undefined, .count = 0 };
    }

    pub fn add(self: *DirtyChunkSet, key: WorldState.ChunkKey) void {
        for (self.keys[0..self.count]) |k| {
            if (k.eql(key)) return;
        }
        if (self.count < MAX_DIRTY) {
            self.keys[self.count] = key;
            self.count += 1;
        }
    }

    pub fn clear(self: *DirtyChunkSet) void {
        self.count = 0;
    }
};

pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, world_name: []const u8) !GameState {
    var cam = Camera.init(width, height);
    var chunk_map = ChunkMap.init(allocator);
    var chunk_pool = ChunkPool.init(allocator);

    const storage_inst = Storage.init(allocator, world_name) catch |err| blk: {
        std.log.warn("Storage init failed: {}, world will not be saved", .{err});
        break :blk null;
    };

    const world_seed: u64 = if (storage_inst) |s| s.seed else 0;

    // Compute spawn height from terrain noise
    const spawn_x: i32 = 16;
    const spawn_z: i32 = 16;
    const surface_y = TerrainGen.sampleHeight(spawn_x, spawn_z, world_seed);
    const spawn_y: f32 = @as(f32, @floatFromInt(surface_y)) + 2.0;

    cam.position = zlm.Vec3.init(16.0, spawn_y + EYE_OFFSET, 16.0);

    const spawn_key = WorldState.ChunkKey.fromWorldPos(spawn_x, @intFromFloat(spawn_y), spawn_z);
    var any_loaded = false;

    var cy = spawn_key.cy - LOAD_RADIUS_Y;
    while (cy <= spawn_key.cy + LOAD_RADIUS_Y) : (cy += 1) {
        var cz = spawn_key.cz - LOAD_RADIUS_XZ;
        while (cz <= spawn_key.cz + LOAD_RADIUS_XZ) : (cz += 1) {
            var cx = spawn_key.cx - LOAD_RADIUS_XZ;
            while (cx <= spawn_key.cx + LOAD_RADIUS_XZ) : (cx += 1) {
                const key = WorldState.ChunkKey{ .cx = cx, .cy = cy, .cz = cz };
                const chunk = chunk_pool.acquire();

                var loaded = false;
                if (storage_inst) |s| {
                    if (s.loadChunk(cx, cy, cz, 0)) |cached_chunk| {
                        chunk.* = cached_chunk.*;
                        loaded = true;
                        any_loaded = true;
                    }
                }

                if (!loaded) {
                    TerrainGen.generateChunk(chunk, key, world_seed);
                }

                chunk_map.put(key, chunk);
            }
        }
    }

    // Save newly generated chunks if none were loaded from storage
    if (!any_loaded) {
        if (storage_inst) |s| {
            var it = chunk_map.iterator();
            while (it.next()) |entry| {
                s.saveChunk(entry.key_ptr.cx, entry.key_ptr.cy, entry.key_ptr.cz, 0, entry.value_ptr.*) catch |err| {
                    std.log.warn("Failed to save generated chunk ({d},{d},{d}): {}", .{ entry.key_ptr.cx, entry.key_ptr.cy, entry.key_ptr.cz, err });
                };
            }
            s.flush();
        }
    }

    // Mark all loaded chunks as dirty so they get meshed
    var dirty = DirtyChunkSet.empty();
    {
        var it = chunk_map.iterator();
        while (it.next()) |entry| {
            dirty.add(entry.key_ptr.*);
        }
    }

    return .{
        .allocator = allocator,
        .camera = cam,
        .chunk_map = chunk_map,
        .chunk_pool = chunk_pool,
        .entity_pos = .{ 16.0, spawn_y, 16.0 },
        .entity_vel = .{ 0.0, 0.0, 0.0 },
        .entity_on_ground = false,
        .mode = .flying,
        .input_move = .{ 0.0, 0.0, 0.0 },
        .jump_requested = false,
        .jump_cooldown = 0,
        .hit_result = null,
        .dirty_chunks = dirty,
        .world_seed = world_seed,
        .storage = storage_inst,
        .streamer = undefined,
        .player_chunk = spawn_key,
        .streaming_initialized = false,
        .debug_camera_active = false,
        .overdraw_mode = false,
        .saved_camera = cam,
        .prev_entity_pos = .{ 16.0, spawn_y, 16.0 },
        .prev_camera_pos = cam.position,
        .tick_camera_pos = cam.position,
        .render_entity_pos = .{ 16.0, spawn_y, 16.0 },
    };
}

pub fn save(self: *GameState) void {
    const s = self.storage orelse return;
    const io = std.Io.Threaded.global_single_threaded.io();
    const save_start = std.Io.Clock.now(.awake, io);

    const dirty_start = std.Io.Clock.now(.awake, io);
    s.saveAllDirty();
    const dirty_ns: i64 = @intCast(dirty_start.durationTo(std.Io.Clock.now(.awake, io)).nanoseconds);

    const flush_start = std.Io.Clock.now(.awake, io);
    s.flush();
    const flush_ns: i64 = @intCast(flush_start.durationTo(std.Io.Clock.now(.awake, io)).nanoseconds);

    const total_ns: i64 = @intCast(save_start.durationTo(std.Io.Clock.now(.awake, io)).nanoseconds);
    std.log.info("[save] dirty={d:.1}ms, flush={d:.1}ms, total={d:.1}ms", .{
        @as(f64, @floatFromInt(dirty_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(flush_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(total_ns)) / 1_000_000.0,
    });
}

pub fn deinit(self: *GameState) void {
    if (self.storage) |s| s.deinit();
    self.chunk_map.deinit();
    self.chunk_pool.deinit();
}

pub fn toggleDebugCamera(self: *GameState) void {
    if (self.debug_camera_active) {
        self.camera = self.saved_camera;
        self.prev_camera_pos = self.camera.position;
        self.tick_camera_pos = self.camera.position;
        self.debug_camera_active = false;
    } else {
        self.saved_camera = self.camera;
        self.debug_camera_active = true;
    }
}

pub fn toggleMode(self: *GameState) void {
    switch (self.mode) {
        .flying => {
            self.entity_pos = .{
                self.camera.position.x,
                self.camera.position.y - EYE_OFFSET,
                self.camera.position.z,
            };
            self.prev_entity_pos = self.entity_pos;
            self.entity_vel = .{ 0.0, 0.0, 0.0 };
            self.entity_on_ground = false;
            self.jump_requested = false;
            self.jump_cooldown = 5;
            self.mode = .walking;
        },
        .walking => {
            self.camera.position = zlm.Vec3.init(
                self.entity_pos[0],
                self.entity_pos[1] + EYE_OFFSET,
                self.entity_pos[2],
            );
            self.prev_camera_pos = self.camera.position;
            self.mode = .flying;
        },
    }
}

pub fn fixedUpdate(self: *GameState, move_speed: f32) void {
    self.prev_entity_pos = self.entity_pos;
    self.prev_camera_pos = self.camera.position;

    switch (self.mode) {
        .flying => {
            const forward_input = self.input_move[0];
            const right_input = self.input_move[2];
            const up_input = self.input_move[1];

            if (forward_input != 0.0 or right_input != 0.0 or up_input != 0.0) {
                const speed = move_speed * TICK_INTERVAL;
                self.camera.move(forward_input * speed, right_input * speed, up_input * speed);
            }
        },
        .walking => {
            if (self.jump_cooldown > 0) {
                self.jump_cooldown -= 1;
                self.jump_requested = false;
            } else if (self.jump_requested and self.entity_on_ground) {
                self.entity_vel[1] = 8.7;
                self.jump_requested = false;
            }

            Physics.updateEntity(self, TICK_INTERVAL);

            self.camera.position = zlm.Vec3.init(
                self.entity_pos[0],
                self.entity_pos[1] + EYE_OFFSET,
                self.entity_pos[2],
            );
        },
    }

    self.hit_result = Raycast.raycast(&self.chunk_map, self.camera.position, self.camera.getForward());

    // Request load for missing chunks within render distance (runs at tick rate).
    // Push all missing chunks — the dedup set rejects duplicates in O(1) and
    // the priority queue ensures closest chunks are loaded first.
    if (self.streaming_initialized) {
        const rd = ChunkStreamer.RENDER_DISTANCE;
        const rd_sq = rd * rd;
        const pc = self.player_chunk;
        const max_batch = 18000; // conservative upper bound for sphere volume at rd=16
        var batch: [max_batch]WorldState.ChunkKey = undefined;
        var batch_len: u32 = 0;

        var dy: i32 = -rd;
        while (dy <= rd) : (dy += 1) {
            var dz: i32 = -rd;
            while (dz <= rd) : (dz += 1) {
                var dx: i32 = -rd;
                while (dx <= rd) : (dx += 1) {
                    if (dx * dx + dy * dy + dz * dz > rd_sq) continue;
                    const key = WorldState.ChunkKey{
                        .cx = pc.cx + dx,
                        .cy = pc.cy + dy,
                        .cz = pc.cz + dz,
                    };
                    if (self.chunk_map.get(key) == null) {
                        batch[batch_len] = key;
                        batch_len += 1;
                    }
                }
            }
        }

        if (batch_len > 0) {
            self.streamer.requestLoadBatch(batch[0..batch_len]);
        }
    }
}

pub fn interpolateForRender(self: *GameState, alpha: f32) void {
    self.tick_camera_pos = self.camera.position;
    self.render_entity_pos = lerpArray3(self.prev_entity_pos, self.entity_pos, alpha);
    switch (self.mode) {
        .flying => {
            self.camera.position = lerpVec3(self.prev_camera_pos, self.tick_camera_pos, alpha);
        },
        .walking => {
            self.camera.position = zlm.Vec3.init(
                self.render_entity_pos[0],
                self.render_entity_pos[1] + EYE_OFFSET,
                self.render_entity_pos[2],
            );
        },
    }
}

pub fn restoreAfterRender(self: *GameState) void {
    switch (self.mode) {
        .flying => {
            self.camera.position = self.tick_camera_pos;
        },
        .walking => {
            self.camera.position = zlm.Vec3.init(
                self.entity_pos[0],
                self.entity_pos[1] + EYE_OFFSET,
                self.entity_pos[2],
            );
        },
    }
}

fn markDirty(self: *GameState, wx: i32, wy: i32, wz: i32) void {
    const affected = WorldState.affectedChunks(wx, wy, wz);
    for (affected.keys[0..affected.count]) |key| {
        self.dirty_chunks.add(key);
    }
}

pub fn breakBlock(self: *GameState) void {
    const hit = self.hit_result orelse return;
    const wx = hit.block_pos[0];
    const wy = hit.block_pos[1];
    const wz = hit.block_pos[2];
    self.chunk_map.setBlock(wx, wy, wz, .air);
    self.markDirty(wx, wy, wz);
    self.queueChunkSave(wx, wy, wz);
    self.hit_result = Raycast.raycast(&self.chunk_map, self.camera.position, self.camera.getForward());
}

pub fn placeBlock(self: *GameState) void {
    const block_type = self.hotbar[self.selected_slot];
    if (block_type == .air) return;
    const hit = self.hit_result orelse return;
    const n = hit.direction.normal();
    const px = hit.block_pos[0] + n[0];
    const py = hit.block_pos[1] + n[1];
    const pz = hit.block_pos[2] + n[2];
    if (WorldState.block_properties.isSolid(self.chunk_map.getBlock(px, py, pz))) return;
    self.chunk_map.setBlock(px, py, pz, block_type);
    self.markDirty(px, py, pz);
    self.queueChunkSave(px, py, pz);
    self.hit_result = Raycast.raycast(&self.chunk_map, self.camera.position, self.camera.getForward());
}

fn queueChunkSave(self: *GameState, wx: i32, wy: i32, wz: i32) void {
    const s = self.storage orelse return;
    const key = WorldState.ChunkKey.fromWorldPos(wx, wy, wz);
    const chunk = self.chunk_map.get(key) orelse return;
    s.markDirty(key.cx, key.cy, key.cz, 0, chunk);
}

pub fn updateStreaming(
    self: *GameState,
    wr: *WorldRenderer,
    deferred_face_frees: []TlsfAllocator.Handle,
    deferred_face_free_count: *u32,
    deferred_light_frees: []TlsfAllocator.Handle,
    deferred_light_free_count: *u32,
) void {
    const pos = self.camera.position;
    const current_chunk = WorldState.ChunkKey.fromWorldPos(
        @intFromFloat(@floor(pos.x)),
        @intFromFloat(@floor(pos.y)),
        @intFromFloat(@floor(pos.z)),
    );

    if (!current_chunk.eql(self.player_chunk) or !self.streaming_initialized) {
        self.player_chunk = current_chunk;
        self.streaming_initialized = true;
    }

    // Drain streamer output
    var results: [ChunkStreamer.MAX_OUTPUT]ChunkStreamer.LoadResult = undefined;
    const count = self.streamer.drainOutput(&results);
    for (results[0..count]) |result| {
        // Skip if chunk was already loaded (e.g. by sync init or double request)
        if (self.chunk_map.get(result.key) != null) {
            self.chunk_pool.release(result.chunk);
            continue;
        }
        self.chunk_map.put(result.key, result.chunk);
        self.dirty_chunks.add(result.key);
        // Mark neighbors dirty so they re-mesh with the new neighbor present
        const offsets = [6][3]i32{ .{ -1, 0, 0 }, .{ 1, 0, 0 }, .{ 0, -1, 0 }, .{ 0, 1, 0 }, .{ 0, 0, -1 }, .{ 0, 0, 1 } };
        for (offsets) |off| {
            const nk = WorldState.ChunkKey{
                .cx = result.key.cx + off[0],
                .cy = result.key.cy + off[1],
                .cz = result.key.cz + off[2],
            };
            if (self.chunk_map.get(nk) != null) {
                self.dirty_chunks.add(nk);
            }
        }
    }

    // Unload chunks beyond UNLOAD_DISTANCE (budget: max 16 per frame)
    const ud = ChunkStreamer.UNLOAD_DISTANCE;
    const ud_sq = ud * ud;
    var unload_count: u32 = 0;
    const MAX_UNLOADS: u32 = 256;

    // Collect keys to unload (can't modify map while iterating)
    var unload_keys: [MAX_UNLOADS]WorldState.ChunkKey = undefined;
    {
        var it = self.chunk_map.iterator();
        while (it.next()) |entry| {
            if (unload_count >= MAX_UNLOADS) break;
            const key = entry.key_ptr.*;
            const dx = key.cx - current_chunk.cx;
            const dy = key.cy - current_chunk.cy;
            const dz = key.cz - current_chunk.cz;
            if (dx * dx + dy * dy + dz * dz > ud_sq) {
                unload_keys[unload_count] = key;
                unload_count += 1;
            }
        }
    }

    // Actually unload
    for (unload_keys[0..unload_count]) |key| {
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

        if (self.chunk_map.remove(key)) |chunk| {
            self.chunk_pool.release(chunk);
        }
    }

    // Tick storage (periodic dirty saves)
    if (self.storage) |s| {
        s.tick();
    }
}

fn lerpVec3(a: zlm.Vec3, b: zlm.Vec3, t: f32) zlm.Vec3 {
    return zlm.Vec3.init(
        a.x + (b.x - a.x) * t,
        a.y + (b.y - a.y) * t,
        a.z + (b.z - a.z) * t,
    );
}

fn lerpArray3(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    return .{
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
    };
}
