const std = @import("std");
const EntityId = @import("entity.zig").EntityId;
const EntityStorage = @import("entity.zig").EntityStorage;
const SparseSet = @import("sparse_set.zig").SparseSet;
const SystemScheduler = @import("system.zig").SystemScheduler;
const Phase = @import("system.zig").Phase;

// Import all components
const components = @import("components/components.zig");
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
pub const LookControlState = components.LookControlState;
pub const RenderData = components.RenderData;
pub const CowData = components.CowData;
pub const Tags = components.Tags;

/// The ECS World - manages all entities, components, and systems
pub const World = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    /// Entity ID management
    entities: EntityStorage,

    /// Component storage (sparse sets for each component type)
    transforms: SparseSet(Transform),
    velocities: SparseSet(Velocity),
    physics_bodies: SparseSet(PhysicsBody),
    healths: SparseSet(Health),
    ages: SparseSet(Age),
    breeding: SparseSet(Breeding),
    animations: SparseSet(Animation),
    head_rotations: SparseSet(HeadRotation),
    jumps: SparseSet(Jump),
    ai_states: SparseSet(AIState),
    look_controls: SparseSet(LookControlState),
    render_data: SparseSet(RenderData),
    cow_data: SparseSet(CowData),
    tags: SparseSet(Tags),

    /// System scheduler
    scheduler: SystemScheduler,

    /// Current tick count
    tick_count: u64,

    /// Player position (for AI targeting)
    player_position: ?@import("Shared").Vec3,

    /// Terrain query callback (for physics)
    terrain_query: ?TerrainQuery,

    /// Terrain query function type
    pub const TerrainQuery = *const fn (x: i32, y: i32, z: i32) @import("Shared").VoxelShape;

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .entities = EntityStorage.init(allocator),
            .transforms = SparseSet(Transform).init(allocator),
            .velocities = SparseSet(Velocity).init(allocator),
            .physics_bodies = SparseSet(PhysicsBody).init(allocator),
            .healths = SparseSet(Health).init(allocator),
            .ages = SparseSet(Age).init(allocator),
            .breeding = SparseSet(Breeding).init(allocator),
            .animations = SparseSet(Animation).init(allocator),
            .head_rotations = SparseSet(HeadRotation).init(allocator),
            .jumps = SparseSet(Jump).init(allocator),
            .ai_states = SparseSet(AIState).init(allocator),
            .look_controls = SparseSet(LookControlState).init(allocator),
            .render_data = SparseSet(RenderData).init(allocator),
            .cow_data = SparseSet(CowData).init(allocator),
            .tags = SparseSet(Tags).init(allocator),
            // Scheduler context will be set in setup() after World is in final location
            .scheduler = SystemScheduler.init(undefined),
            .tick_count = 0,
            .player_position = null,
            .terrain_query = null,
        };
    }

    /// Must be called after the World is stored in its final memory location.
    /// This fixes up the scheduler's context pointer to point to the actual World.
    pub fn setup(self: *Self) void {
        self.scheduler.context = @ptrCast(self);
    }

    pub fn deinit(self: *Self) void {
        self.entities.deinit();
        self.transforms.deinit();
        self.velocities.deinit();
        self.physics_bodies.deinit();
        self.healths.deinit();
        self.ages.deinit();
        self.breeding.deinit();
        self.animations.deinit();
        self.head_rotations.deinit();
        self.jumps.deinit();
        self.ai_states.deinit();
        self.look_controls.deinit();
        self.render_data.deinit();
        self.cow_data.deinit();
        self.tags.deinit();
    }

    // =========================================
    // Entity Management
    // =========================================

    /// Create a new entity
    pub fn createEntity(self: *Self) !EntityId {
        return self.entities.create();
    }

    /// Destroy an entity and all its components
    pub fn destroyEntity(self: *Self, id: EntityId) void {
        if (!self.entities.isValid(id)) return;

        // Remove all components
        _ = self.transforms.remove(id);
        _ = self.velocities.remove(id);
        _ = self.physics_bodies.remove(id);
        _ = self.healths.remove(id);
        _ = self.ages.remove(id);
        _ = self.breeding.remove(id);
        _ = self.animations.remove(id);
        _ = self.head_rotations.remove(id);
        _ = self.jumps.remove(id);
        _ = self.ai_states.remove(id);
        _ = self.look_controls.remove(id);
        _ = self.render_data.remove(id);
        _ = self.cow_data.remove(id);
        _ = self.tags.remove(id);

        _ = self.entities.destroy(id);
    }

    /// Check if an entity exists
    pub fn entityExists(self: *const Self, id: EntityId) bool {
        return self.entities.isValid(id);
    }

    /// Get entity count
    pub fn entityCount(self: *const Self) u32 {
        return self.entities.count();
    }

    /// Iterate over all alive entities
    pub fn entityIterator(self: *const Self) EntityStorage.Iterator {
        return self.entities.iterator();
    }

    // =========================================
    // Component Access
    // =========================================

    /// Add a component to an entity
    pub fn addComponent(self: *Self, comptime T: type, id: EntityId, component: T) !void {
        const storage = self.getStorage(T);
        try storage.set(id, component);
    }

    /// Get a component (const)
    pub fn getComponent(self: *const Self, comptime T: type, id: EntityId) ?*const T {
        const storage = self.getStorageConst(T);
        return storage.get(id);
    }

    /// Get a component (mutable)
    pub fn getComponentMut(self: *Self, comptime T: type, id: EntityId) ?*T {
        const storage = self.getStorage(T);
        return storage.getMut(id);
    }

    /// Remove a component from an entity
    pub fn removeComponent(self: *Self, comptime T: type, id: EntityId) bool {
        const storage = self.getStorage(T);
        return storage.remove(id);
    }

    /// Check if entity has a component
    pub fn hasComponent(self: *const Self, comptime T: type, id: EntityId) bool {
        const storage = self.getStorageConst(T);
        return storage.contains(id);
    }

    /// Get the storage for a component type
    fn getStorage(self: *Self, comptime T: type) *SparseSet(T) {
        return switch (T) {
            Transform => &self.transforms,
            Velocity => &self.velocities,
            PhysicsBody => &self.physics_bodies,
            Health => &self.healths,
            Age => &self.ages,
            Breeding => &self.breeding,
            Animation => &self.animations,
            HeadRotation => &self.head_rotations,
            Jump => &self.jumps,
            AIState => &self.ai_states,
            LookControlState => &self.look_controls,
            RenderData => &self.render_data,
            CowData => &self.cow_data,
            Tags => &self.tags,
            else => @compileError("Unknown component type: " ++ @typeName(T)),
        };
    }

    /// Get the storage for a component type (const)
    fn getStorageConst(self: *const Self, comptime T: type) *const SparseSet(T) {
        return switch (T) {
            Transform => &self.transforms,
            Velocity => &self.velocities,
            PhysicsBody => &self.physics_bodies,
            Health => &self.healths,
            Age => &self.ages,
            Breeding => &self.breeding,
            Animation => &self.animations,
            HeadRotation => &self.head_rotations,
            Jump => &self.jumps,
            AIState => &self.ai_states,
            LookControlState => &self.look_controls,
            RenderData => &self.render_data,
            CowData => &self.cow_data,
            Tags => &self.tags,
            else => @compileError("Unknown component type: " ++ @typeName(T)),
        };
    }

    // =========================================
    // Queries
    // =========================================

    /// Query for entities with specific components
    /// Returns an iterator that yields entities matching all required components
    pub fn query(self: *Self, comptime Components: type) QueryIterator(Components) {
        return QueryIterator(Components).init(self);
    }

    /// Query iterator that filters entities by required components
    pub fn QueryIterator(comptime Components: type) type {
        return struct {
            const QuerySelf = @This();

            world: *Self,
            entity_iter: EntityStorage.Iterator,

            fn init(world: *Self) QuerySelf {
                return .{
                    .world = world,
                    .entity_iter = world.entities.iterator(),
                };
            }

            pub fn next(self: *QuerySelf) ?EntityId {
                while (self.entity_iter.next()) |id| {
                    if (self.matches(id)) {
                        return id;
                    }
                }
                return null;
            }

            fn matches(self: *QuerySelf, id: EntityId) bool {
                // Check each field in Components tuple
                inline for (std.meta.fields(Components)) |field| {
                    const T = field.type;
                    if (!self.world.hasComponent(T, id)) {
                        return false;
                    }
                }
                return true;
            }
        };
    }

    // =========================================
    // System Management
    // =========================================

    /// System function signature - takes World pointer directly
    pub const SystemFn = *const fn (*Self) void;

    /// Register a system using comptime wrapper generation
    pub fn addSystem(
        self: *Self,
        name: []const u8,
        comptime func: SystemFn,
        phase: Phase,
        priority: i32,
    ) !void {
        // Generate wrapper at comptime - no runtime closure needed
        const wrapper = struct {
            fn call(ctx: *anyopaque) void {
                const world: *Self = @ptrCast(@alignCast(ctx));
                func(world);
            }
        }.call;

        try self.scheduler.addSystem(name, wrapper, phase, priority);
    }

    /// Run a single tick (all update phases)
    pub fn tick(self: *Self) void {
        self.scheduler.runUpdate();
        self.tick_count += 1;
    }

    /// Run render preparation phase
    pub fn prepareRender(self: *Self) void {
        self.scheduler.runPhase(.render_prep);
    }

    /// Set the player position (for AI targeting)
    pub fn setPlayerPosition(self: *Self, pos: @import("Shared").Vec3) void {
        self.player_position = pos;
    }

    /// Set the terrain query function (for physics)
    pub fn setTerrainQuery(self: *Self, terrain_fn: TerrainQuery) void {
        self.terrain_query = terrain_fn;
    }
};

test "World basic operations" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    // Create entity
    const e1 = try world.createEntity();
    try std.testing.expect(world.entityExists(e1));

    // Add components
    try world.addComponent(Transform, e1, Transform.init(1.0, 2.0, 3.0));
    try world.addComponent(Velocity, e1, Velocity{});

    try std.testing.expect(world.hasComponent(Transform, e1));
    try std.testing.expect(world.hasComponent(Velocity, e1));
    try std.testing.expect(!world.hasComponent(Health, e1));

    // Get component
    const transform = world.getComponent(Transform, e1).?;
    try std.testing.expectEqual(@as(f32, 1.0), transform.position.x);

    // Destroy entity
    world.destroyEntity(e1);
    try std.testing.expect(!world.entityExists(e1));
}
