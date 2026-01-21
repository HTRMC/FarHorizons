// ECS Module - Entity Component System for FarHorizons
//
// This module provides a data-oriented architecture for game entities,
// replacing the deep inheritance hierarchy with composition.
//
// Usage:
//   const ecs = @import("ecs/ecs.zig");
//   var world = ecs.World.init(allocator);
//   defer world.deinit();
//
//   // Create an entity
//   const cow = try world.createEntity();
//
//   // Add components
//   try world.addComponent(ecs.Transform, cow, ecs.Transform.init(0, 64, 0));
//   try world.addComponent(ecs.Velocity, cow, ecs.Velocity.init());
//
//   // Or use spawn functions
//   const cow2 = try ecs.spawn.spawnCow(&world, pos);

// Core types
pub const EntityId = @import("entity.zig").EntityId;
pub const EntityStorage = @import("entity.zig").EntityStorage;

// Data structures
pub const SparseSet = @import("sparse_set.zig").SparseSet;

// World
pub const World = @import("world.zig").World;

// System scheduler
pub const SystemScheduler = @import("system.zig").SystemScheduler;
pub const Phase = @import("system.zig").Phase;

// Components
pub const components = @import("components/components.zig");
pub const Transform = components.Transform;
pub const Velocity = components.Velocity;
pub const PhysicsBody = components.PhysicsBody;
pub const Health = components.Health;
pub const Age = components.Age;
pub const Breeding = components.Breeding;
pub const Animation = components.Animation;
pub const HeadRotation = components.HeadRotation;
pub const Jump = components.Jump;
pub const AIState = components.AIState;
pub const GoalType = components.GoalType;
pub const GoalData = components.GoalData;
pub const GoalEntry = components.GoalEntry;
pub const Flag = components.Flag;
pub const LookControlState = components.LookControlState;
pub const RenderData = components.RenderData;
pub const CowData = components.CowData;
pub const Tags = components.Tags;

// Systems
pub const systems = @import("systems/systems.zig");

// Spawn functions
pub const spawn = @import("spawn/spawn.zig");

// Re-export shared types
pub const Vec3 = @import("Shared").Vec3;
pub const VoxelShape = @import("Shared").VoxelShape;

/// Initialize all systems in the world
/// Must be called after the World is stored in its final memory location.
pub fn initSystems(world: *World) !void {
    // Fix up the scheduler's context pointer now that World is in final location
    world.setup();

    // Pre-update phase
    // (none yet)

    // Update phase - order matters!
    try world.addSystem("aging", systems.aging_system.run, .update, 10);
    try world.addSystem("breeding", systems.breeding_system.run, .update, 20);
    try world.addSystem("health", systems.health_system.run, .update, 30);
    try world.addSystem("ai", systems.ai_system.run, .update, 40);
    try world.addSystem("physics", systems.physics_system.run, .update, 50);
    try world.addSystem("animation", systems.animation_system.run, .update, 60);

    // Render prep phase
    try world.addSystem("render_prep", systems.render_prep_system.run, .render_prep, 0);
}
