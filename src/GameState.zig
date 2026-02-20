const std = @import("std");
const Camera = @import("renderer/Camera.zig");
const WorldState = @import("world/WorldState.zig");
const Physics = @import("Physics.zig");

const GameState = @This();

allocator: std.mem.Allocator,
camera: Camera,
world: *WorldState.World,
entity_pos: [3]f32,
entity_vel: [3]f32,
entity_on_ground: bool,

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
    };
}

pub fn deinit(self: *GameState) void {
    self.allocator.destroy(self.world);
}

pub fn update(self: *GameState, dt: f32) void {
    Physics.updateEntity(self, dt);
}
