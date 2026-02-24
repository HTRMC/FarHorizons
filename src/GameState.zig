const std = @import("std");
const zlm = @import("zlm");
const Camera = @import("renderer/Camera.zig");
const WorldState = @import("world/WorldState.zig");
const Physics = @import("Physics.zig");
const Raycast = @import("Raycast.zig");
const Storage = @import("world/storage/Storage.zig");

const GameState = @This();

pub const MovementMode = enum { flying, walking };
pub const EYE_OFFSET: f32 = 1.62;
pub const TICK_RATE: f32 = 30.0;
pub const TICK_INTERVAL: f32 = 1.0 / TICK_RATE;

allocator: std.mem.Allocator,
camera: Camera,
world: *WorldState.World,
light_map: *WorldState.LightMap,
entity_pos: [3]f32,
entity_vel: [3]f32,
entity_on_ground: bool,
mode: MovementMode,
input_move: [3]f32,
jump_requested: bool,
hit_result: ?Raycast.BlockHitResult,
dirty_chunks: DirtyChunkSet,
debug_camera_active: bool,
overdraw_mode: bool,
saved_camera: Camera,

// LOD state
current_lod: u8,
lod_worlds: [3]*WorldState.World,
lod_light_maps: [3]*WorldState.LightMap,
lod_stale: [3]bool,

// World persistence
storage: ?*Storage,

// Previous-tick snapshots for interpolation
prev_entity_pos: [3]f32,
prev_camera_pos: zlm.Vec3,
tick_camera_pos: zlm.Vec3, // authoritative camera pos (saved before interpolation overwrites it)
render_entity_pos: [3]f32, // interpolated entity pos for rendering (debug AABB etc.)

pub const DirtyChunkSet = struct {
    chunks: [WorldState.TOTAL_WORLD_CHUNKS]WorldState.ChunkCoord,
    count: u8,

    pub fn empty() DirtyChunkSet {
        return .{ .chunks = undefined, .count = 0 };
    }

    pub fn add(self: *DirtyChunkSet, coord: WorldState.ChunkCoord) void {
        for (self.chunks[0..self.count]) |c| {
            if (c.eql(coord)) return;
        }
        if (self.count < WorldState.TOTAL_WORLD_CHUNKS) {
            self.chunks[self.count] = coord;
            self.count += 1;
        }
    }

    pub fn clear(self: *DirtyChunkSet) void {
        self.count = 0;
    }
};

pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !GameState {
    const world = try allocator.create(WorldState.World);
    // Initialize all blocks to air so unloaded chunks don't have garbage data
    @memset(std.mem.asBytes(world), 0);
    const light_map = try allocator.create(WorldState.LightMap);
    const cam = Camera.init(width, height);

    // Initialize storage (optional — game works without persistence)
    var storage = Storage.init(allocator, "default") catch |err| blk: {
        std.log.warn("Storage init failed: {}, world will not be saved", .{err});
        break :blk null;
    };

    // Try to load world from disk, generate missing chunks procedurally
    var any_loaded = false;
    if (storage != null) {
        for (0..WorldState.WORLD_CHUNKS_Y) |cy_u| {
            for (0..WorldState.WORLD_CHUNKS_Z) |cz_u| {
                for (0..WorldState.WORLD_CHUNKS_X) |cx_u| {
                    const cx: i32 = @as(i32, @intCast(cx_u)) - WorldState.WORLD_CHUNKS_X / 2;
                    const cy: i32 = @as(i32, @intCast(cy_u)) - WorldState.WORLD_CHUNKS_Y / 2;
                    const cz: i32 = @as(i32, @intCast(cz_u)) - WorldState.WORLD_CHUNKS_Z / 2;

                    if (storage.?.loadChunk(cx, cy, cz, 0)) |cached_chunk| {
                        world[cy_u][cz_u][cx_u] = cached_chunk.*;
                        any_loaded = true;
                    }
                }
            }
        }
    }

    if (!any_loaded) {
        // No saved data — generate fresh world
        WorldState.generateSphereWorld(world);

        // Persist generated world immediately
        if (storage != null) {
            for (0..WorldState.WORLD_CHUNKS_Y) |cy_u| {
                for (0..WorldState.WORLD_CHUNKS_Z) |cz_u| {
                    for (0..WorldState.WORLD_CHUNKS_X) |cx_u| {
                        const cx: i32 = @as(i32, @intCast(cx_u)) - WorldState.WORLD_CHUNKS_X / 2;
                        const cy: i32 = @as(i32, @intCast(cy_u)) - WorldState.WORLD_CHUNKS_Y / 2;
                        const cz: i32 = @as(i32, @intCast(cz_u)) - WorldState.WORLD_CHUNKS_Z / 2;
                        storage.?.saveChunk(cx, cy, cz, 0, &world[cy_u][cz_u][cx_u]) catch |err| {
                            std.log.warn("Failed to save generated chunk ({d},{d},{d}): {}", .{ cx, cy, cz, err });
                        };
                    }
                }
            }
            storage.?.flush();
        }
    }

    WorldState.computeLightMap(world, light_map);

    // Allocate LOD1 and LOD2 worlds and light maps
    const lod1_world = try allocator.create(WorldState.World);
    const lod1_light_map = try allocator.create(WorldState.LightMap);
    const lod2_world = try allocator.create(WorldState.World);
    const lod2_light_map = try allocator.create(WorldState.LightMap);

    // Generate LOD data
    WorldState.downsampleWorld(world, lod1_world, 1);
    WorldState.computeLightMap(lod1_world, lod1_light_map);
    WorldState.downsampleWorld(world, lod2_world, 2);
    WorldState.computeLightMap(lod2_world, lod2_light_map);

    return .{
        .allocator = allocator,
        .camera = cam,
        .world = world,
        .light_map = light_map,
        .entity_pos = .{ 0.0, 64.0, 0.0 },
        .entity_vel = .{ 0.0, 0.0, 0.0 },
        .entity_on_ground = false,
        .mode = .flying,
        .input_move = .{ 0.0, 0.0, 0.0 },
        .jump_requested = false,
        .hit_result = null,
        .dirty_chunks = DirtyChunkSet.empty(),
        .current_lod = 0,
        .lod_worlds = .{ world, lod1_world, lod2_world },
        .lod_light_maps = .{ light_map, lod1_light_map, lod2_light_map },
        .lod_stale = .{ false, false, false },
        .storage = storage,
        .debug_camera_active = false,
        .overdraw_mode = false,
        .saved_camera = cam,
        .prev_entity_pos = .{ 0.0, 64.0, 0.0 },
        .prev_camera_pos = cam.position,
        .tick_camera_pos = cam.position,
        .render_entity_pos = .{ 0.0, 64.0, 0.0 },
    };
}

/// Save all chunks to disk.
pub fn save(self: *GameState) void {
    const s = self.storage orelse return;
    for (0..WorldState.WORLD_CHUNKS_Y) |cy_u| {
        for (0..WorldState.WORLD_CHUNKS_Z) |cz_u| {
            for (0..WorldState.WORLD_CHUNKS_X) |cx_u| {
                const cx: i32 = @as(i32, @intCast(cx_u)) - WorldState.WORLD_CHUNKS_X / 2;
                const cy: i32 = @as(i32, @intCast(cy_u)) - WorldState.WORLD_CHUNKS_Y / 2;
                const cz: i32 = @as(i32, @intCast(cz_u)) - WorldState.WORLD_CHUNKS_Z / 2;
                s.saveChunk(cx, cy, cz, 0, &self.world[cy_u][cz_u][cx_u]) catch |err| {
                    std.log.warn("Failed to save chunk ({d},{d},{d}): {}", .{ cx, cy, cz, err });
                };
            }
        }
    }
    s.flush();
    std.log.info("World saved", .{});
}

pub fn deinit(self: *GameState) void {
    if (self.storage) |s| s.deinit();
    // Free LOD1 and LOD2 (LOD0 is the main world/light_map, freed below)
    self.allocator.destroy(self.lod_worlds[1]);
    self.allocator.destroy(self.lod_worlds[2]);
    self.allocator.destroy(self.lod_light_maps[1]);
    self.allocator.destroy(self.lod_light_maps[2]);
    self.allocator.destroy(self.lod_light_maps[0]);
    self.allocator.destroy(self.lod_worlds[0]);
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

pub fn switchLod(self: *GameState, lod: u8) void {
    if (lod >= 3 or lod == self.current_lod) return;

    // Re-downsample if LOD data is stale (block edits since last downsample)
    if (lod > 0 and self.lod_stale[lod]) {
        WorldState.downsampleWorld(self.lod_worlds[0], self.lod_worlds[lod], lod);
        WorldState.computeLightMap(self.lod_worlds[lod], self.lod_light_maps[lod]);
        self.lod_stale[lod] = false;
    }

    self.world = self.lod_worlds[lod];
    self.light_map = self.lod_light_maps[lod];
    self.current_lod = lod;
    self.dirtyAllChunks();
    std.log.info("Switched to LOD {d}", .{lod});
}

/// Run one fixed-timestep physics tick. Called with TICK_INTERVAL.
pub fn fixedUpdate(self: *GameState, move_speed: f32) void {
    // Snapshot previous positions before physics moves them
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
            // Consume buffered jump
            if (self.jump_requested and self.entity_on_ground) {
                self.entity_vel[1] = 7.5; // JUMP_VELOCITY
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

    self.hit_result = Raycast.raycast(self.world, self.camera.position, self.camera.getForward());
}

/// Lerp camera position between previous and current tick state for smooth rendering.
/// Call this after all ticks are drained, before rendering.
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

/// Restore camera to authoritative (non-interpolated) tick state.
/// Call after rendering so that the next tick starts from the real position.
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
    for (affected.coords[0..affected.count]) |coord| {
        self.dirty_chunks.add(coord);
    }
}

fn dirtyAllChunks(self: *GameState) void {
    for (0..WorldState.WORLD_CHUNKS_Y) |cy| {
        for (0..WorldState.WORLD_CHUNKS_Z) |cz| {
            for (0..WorldState.WORLD_CHUNKS_X) |cx| {
                self.dirty_chunks.add(.{
                    .cx = @intCast(cx),
                    .cy = @intCast(cy),
                    .cz = @intCast(cz),
                });
            }
        }
    }
}

fn recomputeLight(self: *GameState) void {
    WorldState.computeLightMap(self.world, self.light_map);
}

fn updateLight(self: *GameState, wx: i32, wy: i32, wz: i32) void {
    WorldState.updateLightMap(self.world, self.light_map, wx, wy, wz);
}

/// Dirty all chunks whose meshes could be affected by a light change at (wx, wy, wz).
/// The light propagation radius determines how far light can reach.
fn dirtyLightRadius(self: *GameState, wx: i32, wy: i32, wz: i32) void {
    const radius = WorldState.LIGHT_MAX_RADIUS + 2; // +2 for AO sampling across boundaries
    const cs: i32 = WorldState.CHUNK_SIZE;
    const half_x: i32 = WorldState.WORLD_SIZE_X / 2;
    const half_y: i32 = WorldState.WORLD_SIZE_Y / 2;
    const half_z: i32 = WorldState.WORLD_SIZE_Z / 2;

    // Convert world-space light radius to chunk range
    const min_cx = @max(0, @divFloor(wx - radius + half_x, cs));
    const max_cx = @min(@as(i32, WorldState.WORLD_CHUNKS_X) - 1, @divFloor(wx + radius + half_x, cs));
    const min_cy = @max(0, @divFloor(wy - radius + half_y, cs));
    const max_cy = @min(@as(i32, WorldState.WORLD_CHUNKS_Y) - 1, @divFloor(wy + radius + half_y, cs));
    const min_cz = @max(0, @divFloor(wz - radius + half_z, cs));
    const max_cz = @min(@as(i32, WorldState.WORLD_CHUNKS_Z) - 1, @divFloor(wz + radius + half_z, cs));

    var cy = min_cy;
    while (cy <= max_cy) : (cy += 1) {
        var cz = min_cz;
        while (cz <= max_cz) : (cz += 1) {
            var cx = min_cx;
            while (cx <= max_cx) : (cx += 1) {
                self.dirty_chunks.add(.{
                    .cx = @intCast(cx),
                    .cy = @intCast(cy),
                    .cz = @intCast(cz),
                });
            }
        }
    }
}

pub fn breakBlock(self: *GameState) void {
    const hit = self.hit_result orelse return;
    WorldState.setBlock(self.world, hit.block_pos[0], hit.block_pos[1], hit.block_pos[2], .air);
    self.updateLight(hit.block_pos[0], hit.block_pos[1], hit.block_pos[2]);
    self.dirtyLightRadius(hit.block_pos[0], hit.block_pos[1], hit.block_pos[2]);
    self.queueChunkSave(hit.block_pos[0], hit.block_pos[1], hit.block_pos[2]);
    self.hit_result = Raycast.raycast(self.world, self.camera.position, self.camera.getForward());
    self.lod_stale[1] = true;
    self.lod_stale[2] = true;
}

pub fn placeBlock(self: *GameState) void {
    const hit = self.hit_result orelse return;
    const n = hit.direction.normal();
    const px = hit.block_pos[0] + n[0];
    const py = hit.block_pos[1] + n[1];
    const pz = hit.block_pos[2] + n[2];
    if (WorldState.block_properties.isSolid(WorldState.getBlock(self.world, px, py, pz))) return;
    WorldState.setBlock(self.world, px, py, pz, .glowstone);
    self.updateLight(px, py, pz);
    self.dirtyLightRadius(px, py, pz);
    self.queueChunkSave(px, py, pz);
    self.hit_result = Raycast.raycast(self.world, self.camera.position, self.camera.getForward());
    self.lod_stale[1] = true;
    self.lod_stale[2] = true;
}

/// Queue an async save for the chunk containing world position (wx, wy, wz).
fn queueChunkSave(self: *GameState, wx: i32, wy: i32, wz: i32) void {
    if (self.storage == null) return;

    // Convert world position to voxel-space, then to local chunk index
    const half_x: i32 = WorldState.WORLD_SIZE_X / 2;
    const half_y: i32 = WorldState.WORLD_SIZE_Y / 2;
    const half_z: i32 = WorldState.WORLD_SIZE_Z / 2;

    const vx = wx + half_x;
    const vy = wy + half_y;
    const vz = wz + half_z;
    if (vx < 0 or vy < 0 or vz < 0) return;
    if (vx >= WorldState.WORLD_SIZE_X or vy >= WorldState.WORLD_SIZE_Y or vz >= WorldState.WORLD_SIZE_Z) return;

    const cs: i32 = WorldState.CHUNK_SIZE;
    const local_cx: usize = @intCast(@divFloor(vx, cs));
    const local_cy: usize = @intCast(@divFloor(vy, cs));
    const local_cz: usize = @intCast(@divFloor(vz, cs));

    // Storage uses signed chunk coordinates (centered at world origin)
    const storage_cx = @as(i32, @intCast(local_cx)) - WorldState.WORLD_CHUNKS_X / 2;
    const storage_cy = @as(i32, @intCast(local_cy)) - WorldState.WORLD_CHUNKS_Y / 2;
    const storage_cz = @as(i32, @intCast(local_cz)) - WorldState.WORLD_CHUNKS_Z / 2;

    self.storage.?.requestSaveAsync(
        storage_cx,
        storage_cy,
        storage_cz,
        0,
        &self.world[local_cy][local_cz][local_cx],
    );
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
