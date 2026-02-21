const std = @import("std");
const zlm = @import("zlm");
const Camera = @import("renderer/Camera.zig");
const WorldState = @import("world/WorldState.zig");
const Physics = @import("Physics.zig");
const Raycast = @import("Raycast.zig");

const GameState = @This();

pub const MovementMode = enum { flying, walking };
pub const EYE_OFFSET: f32 = 1.62;

allocator: std.mem.Allocator,
camera: Camera,
world: *WorldState.World,
entity_pos: [3]f32,
entity_vel: [3]f32,
entity_on_ground: bool,
mode: MovementMode,
input_move: [3]f32,
hit_result: ?Raycast.BlockHitResult,
dirty_chunks: DirtyChunkSet,

pub const DirtyChunkSet = struct {
    chunks: [WorldState.TOTAL_WORLD_CHUNKS]WorldState.ChunkCoord,
    count: u8,

    pub fn empty() DirtyChunkSet {
        return .{ .chunks = undefined, .count = 0 };
    }

    pub fn add(self: *DirtyChunkSet, coord: WorldState.ChunkCoord) void {
        // Deduplicate
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

    return .{
        .allocator = allocator,
        .camera = Camera.init(width, height),
        .world = world,
        .entity_pos = .{ 0.0, 64.0, 0.0 },
        .entity_vel = .{ 0.0, 0.0, 0.0 },
        .entity_on_ground = false,
        .mode = .flying,
        .input_move = .{ 0.0, 0.0, 0.0 },
        .hit_result = null,
        .dirty_chunks = DirtyChunkSet.empty(),
    };
}

pub fn deinit(self: *GameState) void {
    self.allocator.destroy(self.world);
}

pub fn toggleMode(self: *GameState) void {
    switch (self.mode) {
        .flying => {
            // Sync entity to camera position minus eye offset
            self.entity_pos = .{
                self.camera.position.x,
                self.camera.position.y - EYE_OFFSET,
                self.camera.position.z,
            };
            self.entity_vel = .{ 0.0, 0.0, 0.0 };
            self.mode = .walking;
        },
        .walking => {
            // Sync camera to entity position plus eye offset
            self.camera.position = zlm.Vec3.init(
                self.entity_pos[0],
                self.entity_pos[1] + EYE_OFFSET,
                self.entity_pos[2],
            );
            self.mode = .flying;
        },
    }
}

pub fn update(self: *GameState, dt: f32) void {
    Physics.updateEntity(self, dt);

    if (self.mode == .walking) {
        self.camera.position = zlm.Vec3.init(
            self.entity_pos[0],
            self.entity_pos[1] + EYE_OFFSET,
            self.entity_pos[2],
        );
    }

    self.hit_result = Raycast.raycast(self.world, self.camera.position, self.camera.getForward());
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
