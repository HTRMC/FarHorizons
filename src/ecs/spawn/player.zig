const World = @import("../world.zig").World;
const EntityId = @import("../entity.zig").EntityId;
const Vec3 = @import("Shared").Vec3;

// Components
const Transform = @import("../components/transform.zig").Transform;
const Velocity = @import("../components/velocity.zig").Velocity;
const PhysicsBody = @import("../components/physics.zig").PhysicsBody;
const Health = @import("../components/health.zig").Health;
const Animation = @import("../components/animation.zig").Animation;
const HeadRotation = @import("../components/head_rotation.zig").HeadRotation;
const Jump = @import("../components/jump.zig").Jump;
const RenderData = @import("../components/render_data.zig").RenderData;
const Tags = @import("../components/tags.zig").Tags;

// Player constants
const PLAYER_MAX_HEALTH: f32 = 20.0;
const PLAYER_WIDTH: f32 = 0.6;
const PLAYER_HEIGHT: f32 = 1.8;

/// Spawn a player entity with all required components
/// Note: Players have no AI component - they are controlled by input
pub fn spawnPlayer(world: *World, position: Vec3) !EntityId {
    const id = try world.createEntity();
    errdefer world.destroyEntity(id);

    // Transform
    try world.addComponent(Transform, id, Transform.initVec(position));

    // Velocity
    try world.addComponent(Velocity, id, Velocity.init());

    // Physics body (player dimensions)
    try world.addComponent(PhysicsBody, id, PhysicsBody.initWithSize(PLAYER_WIDTH, PLAYER_HEIGHT));

    // Health
    try world.addComponent(Health, id, Health.initWith(PLAYER_MAX_HEALTH));

    // Animation
    try world.addComponent(Animation, id, Animation.init());

    // Head rotation
    try world.addComponent(HeadRotation, id, HeadRotation.init());

    // Jump
    try world.addComponent(Jump, id, Jump.init());

    // Render data
    try world.addComponent(RenderData, id, RenderData.init(.player));

    // Tags
    try world.addComponent(Tags, id, Tags.player());

    return id;
}

/// Move player by setting velocity based on input direction
pub fn movePlayer(world: *World, id: EntityId, forward: f32, strafe: f32, speed: f32) void {
    const transform = world.getComponent(Transform, id) orelse return;
    const velocity = world.getComponentMut(Velocity, id) orelse return;

    // Calculate movement direction based on facing angle
    const yaw_rad = transform.yaw * @import("std").math.pi / 180.0;

    const sin_yaw = @sin(yaw_rad);
    const cos_yaw = @cos(yaw_rad);

    // Forward is -Z in Minecraft coordinate system
    velocity.linear.x = (strafe * cos_yaw - forward * sin_yaw) * speed;
    velocity.linear.z = (strafe * sin_yaw + forward * cos_yaw) * speed;
}

/// Make player jump
pub fn jumpPlayer(world: *World, id: EntityId) void {
    const velocity = world.getComponentMut(Velocity, id) orelse return;
    const jump = world.getComponentMut(Jump, id) orelse return;

    if (jump.canJump(velocity.on_ground)) {
        velocity.linear.y = jump.startJump();
        velocity.on_ground = false;
    }
}

/// Set player look direction
pub fn setPlayerLook(world: *World, id: EntityId, yaw: f32, pitch: f32) void {
    const transform = world.getComponentMut(Transform, id) orelse return;
    const head = world.getComponentMut(HeadRotation, id) orelse return;

    transform.yaw = yaw;
    head.pitch = pitch;
}
