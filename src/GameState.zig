const std = @import("std");
const zlm = @import("zlm");
const Camera = @import("renderer/Camera.zig");
const WorldState = @import("world/WorldState.zig");
const Physics = @import("Physics.zig");

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
}
