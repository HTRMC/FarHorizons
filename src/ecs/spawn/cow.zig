const std = @import("std");
const World = @import("../world.zig").World;
const EntityId = @import("../entity.zig").EntityId;
const Vec3 = @import("Shared").Vec3;

// Components
const Transform = @import("../components/transform.zig").Transform;
const Velocity = @import("../components/velocity.zig").Velocity;
const PhysicsBody = @import("../components/physics.zig").PhysicsBody;
const Health = @import("../components/health.zig").Health;
const Age = @import("../components/age.zig").Age;
const Breeding = @import("../components/breeding.zig").Breeding;
const Animation = @import("../components/animation.zig").Animation;
const HeadRotation = @import("../components/head_rotation.zig").HeadRotation;
const Jump = @import("../components/jump.zig").Jump;
const AIState = @import("../components/ai.zig").AIState;
const Flag = @import("../components/ai.zig").Flag;
const LookControlState = @import("../components/look_control.zig").LookControlState;
const RenderData = @import("../components/render_data.zig").RenderData;
const CowData = @import("../components/cow_data.zig").CowData;
const Tags = @import("../components/tags.zig").Tags;

// Cow constants
const COW_MAX_HEALTH: f32 = 10.0;
const COW_ADULT_WIDTH: f32 = 0.9;
const COW_ADULT_HEIGHT: f32 = 1.4;
const COW_MOVEMENT_SPEED: f32 = 0.1;

/// Spawn a cow entity with all required components
pub fn spawnCow(world: *World, position: Vec3) !EntityId {
    return spawnCowInternal(world, position, false, .temperate, false);
}

/// Spawn a baby cow entity
pub fn spawnBabyCow(world: *World, position: Vec3) !EntityId {
    return spawnCowInternal(world, position, true, .temperate, false);
}

/// Spawn a cow with a specific variant
pub fn spawnCowWithVariant(world: *World, position: Vec3, variant: CowData.Variant) !EntityId {
    return spawnCowInternal(world, position, false, variant, false);
}

/// Spawn a mooshroom (red mushroom cow)
pub fn spawnMooshroom(world: *World, position: Vec3) !EntityId {
    return spawnCowInternal(world, position, false, .temperate, true);
}

/// Spawn a baby mooshroom
pub fn spawnBabyMooshroom(world: *World, position: Vec3) !EntityId {
    return spawnCowInternal(world, position, true, .temperate, true);
}

fn spawnCowInternal(
    world: *World,
    position: Vec3,
    is_baby: bool,
    variant: CowData.Variant,
    is_mooshroom: bool,
) !EntityId {
    const id = try world.createEntity();
    errdefer world.destroyEntity(id);

    // Generate random seed from entity id
    const seed = id.toU64() *% 2654435761;

    // Calculate dimensions based on baby state
    const scale = if (is_baby) Age.BABY_SCALE else 1.0;
    const width = COW_ADULT_WIDTH * scale;
    const height = COW_ADULT_HEIGHT * scale;

    // Transform
    try world.addComponent(Transform, id, Transform.initVec(position));

    // Velocity
    try world.addComponent(Velocity, id, Velocity.init());

    // Physics body
    try world.addComponent(PhysicsBody, id, PhysicsBody.initWithSize(width, height));

    // Health
    try world.addComponent(Health, id, Health.initWith(COW_MAX_HEALTH));

    // Age (baby or adult)
    try world.addComponent(Age, id, if (is_baby) Age.initBaby() else Age.init());

    // Breeding
    try world.addComponent(Breeding, id, Breeding.init());

    // Animation
    try world.addComponent(Animation, id, Animation.init());

    // Head rotation
    try world.addComponent(HeadRotation, id, HeadRotation.init());

    // Jump
    try world.addComponent(Jump, id, Jump.init());

    // AI state with cow goals
    var ai = AIState.initWithSeed(seed);
    registerCowGoals(&ai);
    try world.addComponent(AIState, id, ai);

    // Look control
    try world.addComponent(LookControlState, id, LookControlState.init());

    // Render data
    const render = RenderData{
        .entity_type = if (is_mooshroom) .mooshroom else .cow,
        .is_baby = is_baby,
        .model_type = if (variant == .cold) .cold else .normal,
    };
    try world.addComponent(RenderData, id, render);

    // Cow-specific data
    try world.addComponent(CowData, id, CowData.initWithVariant(variant));

    // Tags
    const tags = if (is_mooshroom) Tags.mooshroom() else Tags.cow();
    try world.addComponent(Tags, id, tags);

    return id;
}

/// Register standard cow AI goals
fn registerCowGoals(ai: *AIState) void {
    // Priority 1: Panic when hurt (flee from attacker)
    ai.addPanic(1, 0.2);

    // Priority 5: Random wandering
    ai.addRandomStroll(5, COW_MOVEMENT_SPEED, 120);

    // Priority 6: Look at nearby players
    ai.addLookAtPlayer(6, 6.0, 0.02);

    // Priority 7: Random looking around when idle
    ai.addRandomLookAround(7);
}

/// Apply damage to a cow entity
pub fn hurtCow(world: *World, id: EntityId, damage: f32, attacker_pos: Vec3) void {
    const health = world.getComponentMut(Health, id) orelse return;
    const velocity = world.getComponentMut(Velocity, id) orelse return;
    const transform = world.getComponent(Transform, id) orelse return;

    // Check invulnerability
    if (health.isInvulnerable()) return;
    if (health.dead) return;

    // Apply damage
    health.current -= damage;
    health.hurt_time = Health.HURT_DURATION;
    health.invulnerable_time = Health.INVULNERABLE_DURATION;
    health.last_hurt_by_pos = attacker_pos;
    health.last_hurt_timestamp = world.tick_count;

    // Apply knockback away from attacker
    const dx = transform.position.x - attacker_pos.x;
    const dz = transform.position.z - attacker_pos.z;
    const dist = @sqrt(dx * dx + dz * dz);

    if (dist > 0.01) {
        const nx = dx / dist;
        const nz = dz / dist;
        velocity.linear.x = nx * Health.BASE_KNOCKBACK;
        velocity.linear.y = Health.BASE_KNOCKBACK;
        velocity.linear.z = nz * Health.BASE_KNOCKBACK;
    }

    // Check for death
    if (health.current <= 0) {
        health.die();
    }
}

/// Check if two cows can mate
pub fn canCowsMate(world: *World, cow1: EntityId, cow2: EntityId) bool {
    if (cow1.eql(cow2)) return false;

    const age1 = world.getComponent(Age, cow1) orelse return false;
    const age2 = world.getComponent(Age, cow2) orelse return false;
    const breed1 = world.getComponent(Breeding, cow1) orelse return false;
    const breed2 = world.getComponent(Breeding, cow2) orelse return false;
    const tags1 = world.getComponent(Tags, cow1) orelse return false;
    const tags2 = world.getComponent(Tags, cow2) orelse return false;

    // Both must be cows (or mooshrooms)
    if (!tags1.is_cow and !tags1.is_mooshroom) return false;
    if (!tags2.is_cow and !tags2.is_mooshroom) return false;

    // Both must be adults
    if (age1.isBaby() or age2.isBaby()) return false;

    // Both must be in love
    if (!breed1.isInLove() or !breed2.isInLove()) return false;

    // Both must be able to breed (no cooldown)
    if (!age1.canBreed() or !age2.canBreed()) return false;

    return true;
}

/// Breed two cows and spawn a baby
pub fn breedCows(world: *World, cow1: EntityId, cow2: EntityId) !?EntityId {
    if (!canCowsMate(world, cow1, cow2)) return null;

    // Get positions for baby spawn location
    const transform1 = world.getComponent(Transform, cow1) orelse return null;
    const transform2 = world.getComponent(Transform, cow2) orelse return null;

    // Spawn baby at midpoint between parents
    const baby_pos = Vec3{
        .x = (transform1.position.x + transform2.position.x) / 2.0,
        .y = transform1.position.y,
        .z = (transform1.position.z + transform2.position.z) / 2.0,
    };

    // Determine baby variant (random from parents)
    const cow_data1 = world.getComponent(CowData, cow1);
    const cow_data2 = world.getComponent(CowData, cow2);
    const tags1 = world.getComponent(Tags, cow1) orelse return null;

    var variant = CowData.Variant.temperate;
    if (cow_data1 != null and cow_data2 != null) {
        // Simple random selection between parents
        const ai1 = world.getComponentMut(AIState, cow1);
        if (ai1) |ai| {
            variant = if (ai.nextRandom() % 2 == 0)
                cow_data1.?.variant
            else
                cow_data2.?.variant;
        }
    }

    // Check if mooshroom
    const is_mooshroom = tags1.is_mooshroom;

    // Set breeding cooldown on parents
    if (world.getComponentMut(Age, cow1)) |age| {
        age.setBreedingCooldown();
    }
    if (world.getComponentMut(Age, cow2)) |age| {
        age.setBreedingCooldown();
    }

    // Reset love mode
    if (world.getComponentMut(Breeding, cow1)) |breed| {
        breed.resetLove();
    }
    if (world.getComponentMut(Breeding, cow2)) |breed| {
        breed.resetLove();
    }

    // Spawn baby
    if (is_mooshroom) {
        return try spawnBabyMooshroom(world, baby_pos);
    } else {
        return try spawnCowInternal(world, baby_pos, true, variant, false);
    }
}
