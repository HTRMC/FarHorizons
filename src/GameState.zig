const std = @import("std");
const zlm = @import("zlm");
const Camera = @import("renderer/Camera.zig");
const WorldState = @import("world/WorldState.zig");
const Physics = @import("Physics.zig");
const Raycast = @import("Raycast.zig");

const GameState = @This();

pub const MovementMode = enum { flying, walking };
pub const EYE_OFFSET: f32 = 1.62;
pub const TICK_RATE: f32 = 30.0;
pub const TICK_INTERVAL: f32 = 1.0 / TICK_RATE;

allocator: std.mem.Allocator,
camera: Camera,
world: *WorldState.World,
entity_pos: [3]f32,
entity_vel: [3]f32,
entity_on_ground: bool,
mode: MovementMode,
input_move: [3]f32,
jump_requested: bool,
hit_result: ?Raycast.BlockHitResult,
dirty_chunks: DirtyChunkSet,

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
    WorldState.generateSphereWorld(world);

    const cam = Camera.init(width, height);

    return .{
        .allocator = allocator,
        .camera = cam,
        .world = world,
        .entity_pos = .{ 0.0, 64.0, 0.0 },
        .entity_vel = .{ 0.0, 0.0, 0.0 },
        .entity_on_ground = false,
        .mode = .flying,
        .input_move = .{ 0.0, 0.0, 0.0 },
        .jump_requested = false,
        .hit_result = null,
        .dirty_chunks = DirtyChunkSet.empty(),
        .prev_entity_pos = .{ 0.0, 64.0, 0.0 },
        .prev_camera_pos = cam.position,
        .tick_camera_pos = cam.position,
        .render_entity_pos = .{ 0.0, 64.0, 0.0 },
    };
}

pub fn deinit(self: *GameState) void {
    self.allocator.destroy(self.world);
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

pub fn breakBlock(self: *GameState) void {
    const hit = self.hit_result orelse return;
    WorldState.setBlock(self.world, hit.block_pos[0], hit.block_pos[1], hit.block_pos[2], .air);
    self.markDirty(hit.block_pos[0], hit.block_pos[1], hit.block_pos[2]);
    self.hit_result = Raycast.raycast(self.world, self.camera.position, self.camera.getForward());
}

pub fn placeBlock(self: *GameState) void {
    const hit = self.hit_result orelse return;
    const n = hit.direction.normal();
    const px = hit.block_pos[0] + n[0];
    const py = hit.block_pos[1] + n[1];
    const pz = hit.block_pos[2] + n[2];
    if (WorldState.block_properties.isSolid(WorldState.getBlock(self.world, px, py, pz))) return;
    WorldState.setBlock(self.world, px, py, pz, .grass_block);
    self.markDirty(px, py, pz);
    self.hit_result = Raycast.raycast(self.world, self.camera.position, self.camera.getForward());
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
