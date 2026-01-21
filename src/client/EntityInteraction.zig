/// EntityInteraction - Handles entity targeting and attacking
/// Port of Minecraft's entity interaction logic from MultiPlayerGameMode
const std = @import("std");
const shared = @import("Shared");
const ecs = @import("ecs");

const Logger = shared.Logger;
const Vec3 = shared.Vec3;
const Camera = shared.Camera;
const raycast = shared.Raycast;
const AABB = raycast.AABB;

pub const EntityInteraction = struct {
    const Self = @This();
    const logger = Logger.scoped(Self);

    /// Maximum reach distance for entity interaction (in blocks)
    /// MC uses 3.0 for survival, 6.0 for creative
    pub const ENTITY_REACH: f32 = 4.5;

    /// Base attack damage (would come from weapon in full implementation)
    pub const BASE_DAMAGE: f32 = 1.0;

    /// Attack cooldown in ticks
    pub const ATTACK_COOLDOWN: u32 = 10;

    /// Current targeted ECS entity ID
    target_ecs_id: ?ecs.EntityId = null,

    /// Hit location on the entity
    hit_location: ?Vec3 = null,

    /// Distance to the hit
    hit_distance: f32 = 0,

    /// Attack cooldown counter
    cooldown: u32 = 0,

    /// Reference to ECS world
    ecs_world: ?*ecs.World = null,

    /// Initialize with ECS World
    pub fn init(ecs_world: *ecs.World) Self {
        return .{
            .ecs_world = ecs_world,
        };
    }

    /// Tick - update cooldown
    pub fn tick(self: *Self) void {
        if (self.cooldown > 0) {
            self.cooldown -= 1;
        }
    }

    /// Get hit location (for rendering effects)
    pub fn getHitLocation(self: *const Self) ?Vec3 {
        return self.hit_location;
    }

    /// Get distance to target
    pub fn getTargetDistance(self: *const Self) f32 {
        return self.hit_distance;
    }

    /// Update the targeted entity based on camera position and direction
    /// Call this every frame for responsive targeting
    pub fn updateTarget(self: *Self, camera: *const Camera) void {
        const world = self.ecs_world orelse return;

        const eye_pos = camera.position;
        const forward = camera.forward;

        const to = Vec3{
            .x = eye_pos.x + forward.x * ENTITY_REACH,
            .y = eye_pos.y + forward.y * ENTITY_REACH,
            .z = eye_pos.z + forward.z * ENTITY_REACH,
        };

        self.target_ecs_id = null;
        self.hit_location = null;
        self.hit_distance = ENTITY_REACH + 1.0;

        var entity_iter = world.entities.iterator();
        while (entity_iter.next()) |id| {
            const transform = world.getComponent(ecs.Transform, id) orelse continue;
            const physics = world.getComponent(ecs.PhysicsBody, id) orelse continue;

            // Skip players
            if (world.getComponent(ecs.Tags, id)) |tags| {
                if (tags.is_player) continue;
            }

            const half_width = physics.halfWidth();
            const aabb = AABB.init(
                transform.position.x - half_width,
                transform.position.y,
                transform.position.z - half_width,
                transform.position.x + half_width,
                transform.position.y + physics.height,
                transform.position.z + half_width,
            );

            if (aabb.clip(eye_pos, to)) |hit_point| {
                const dx = hit_point.x - eye_pos.x;
                const dy = hit_point.y - eye_pos.y;
                const dz = hit_point.z - eye_pos.z;
                const dist = @sqrt(dx * dx + dy * dy + dz * dz);

                if (dist < self.hit_distance) {
                    self.target_ecs_id = id;
                    self.hit_location = hit_point;
                    self.hit_distance = @floatCast(dist);
                }
            }
        }
    }

    /// Handle attack (left click on entity)
    /// attacker_pos: Position of the player attacking
    /// Returns true if an entity was attacked
    pub fn handleAttack(self: *Self, attacker_pos: Vec3) bool {
        if (self.cooldown > 0) return false;

        const world = self.ecs_world orelse return false;
        const target_id = self.target_ecs_id orelse return false;

        if (!world.entityExists(target_id)) return false;

        // Get target components
        const transform = world.getComponent(ecs.Transform, target_id) orelse return false;
        const health = world.getComponentMut(ecs.Health, target_id) orelse return false;
        const velocity = world.getComponentMut(ecs.Velocity, target_id) orelse return false;

        // Check invulnerability
        if (health.isInvulnerable() or health.dead) return false;

        // Apply damage
        health.current -= BASE_DAMAGE;
        health.hurt_time = ecs.Health.HURT_DURATION;
        health.invulnerable_time = ecs.Health.INVULNERABLE_DURATION;
        health.last_hurt_by_pos = attacker_pos;
        health.last_hurt_timestamp = world.tick_count;

        // Apply knockback
        const dx = transform.position.x - attacker_pos.x;
        const dz = transform.position.z - attacker_pos.z;
        const dist = @sqrt(dx * dx + dz * dz);

        if (dist > 0.01) {
            const nx = dx / dist;
            const nz = dz / dist;
            velocity.linear.x = nx * ecs.Health.BASE_KNOCKBACK;
            velocity.linear.y = ecs.Health.BASE_KNOCKBACK;
            velocity.linear.z = nz * ecs.Health.BASE_KNOCKBACK;
        }

        // Check for death
        if (health.current <= 0) {
            health.die();
        }

        self.cooldown = ATTACK_COOLDOWN;

        logger.info("Attacked entity at ({d:.1}, {d:.1}, {d:.1})", .{
            transform.position.x,
            transform.position.y,
            transform.position.z,
        });

        return true;
    }

    /// Check if currently targeting an entity
    pub fn isTargetingEntity(self: *const Self) bool {
        return self.target_ecs_id != null;
    }

    /// Get targeted entity ID
    pub fn getTargetEntity(self: *const Self) ?ecs.EntityId {
        return self.target_ecs_id;
    }
};
