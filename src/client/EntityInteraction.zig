/// EntityInteraction - Handles entity targeting and attacking
/// Port of Minecraft's entity interaction logic from MultiPlayerGameMode
const std = @import("std");
const shared = @import("Shared");

const Logger = shared.Logger;
const Vec3 = shared.Vec3;
const Camera = shared.Camera;
const raycast = shared.Raycast;
const AABB = raycast.AABB;

const entity_mod = @import("entity/Entity.zig");
const Entity = entity_mod.Entity;
const EntityManager = entity_mod.EntityManager;

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

    /// Current targeted entity ID (if any)
    target_entity_id: ?u64 = null,

    /// Hit location on the entity
    hit_location: ?Vec3 = null,

    /// Distance to the hit
    hit_distance: f32 = 0,

    /// Attack cooldown counter
    cooldown: u32 = 0,

    /// Reference to entity manager
    entity_manager: *EntityManager,

    pub fn init(entity_manager: *EntityManager) Self {
        return .{
            .entity_manager = entity_manager,
        };
    }

    /// Update the targeted entity based on camera position and direction
    /// Call this every frame for responsive targeting
    pub fn updateTarget(self: *Self, camera: *const Camera) void {
        const eye_pos = camera.position;
        const forward = camera.forward;

        // Calculate ray end point
        const to = Vec3{
            .x = eye_pos.x + forward.x * ENTITY_REACH,
            .y = eye_pos.y + forward.y * ENTITY_REACH,
            .z = eye_pos.z + forward.z * ENTITY_REACH,
        };

        // Find closest entity hit
        self.target_entity_id = null;
        self.hit_location = null;
        self.hit_distance = ENTITY_REACH + 1.0; // Start with max distance

        var iter = self.entity_manager.entities.valueIterator();
        while (iter.next()) |entity| {
            // Create AABB for entity
            const half_width = entity.width / 2.0;
            const aabb = AABB.init(
                entity.position.x - half_width,
                entity.position.y,
                entity.position.z - half_width,
                entity.position.x + half_width,
                entity.position.y + entity.height,
                entity.position.z + half_width,
            );

            // Check ray intersection
            if (aabb.clip(eye_pos, to)) |hit_point| {
                // Calculate distance to hit
                const dx = hit_point.x - eye_pos.x;
                const dy = hit_point.y - eye_pos.y;
                const dz = hit_point.z - eye_pos.z;
                const dist = @sqrt(dx * dx + dy * dy + dz * dz);

                // Check if this is closer than previous hit
                if (dist < self.hit_distance) {
                    self.target_entity_id = entity.id;
                    self.hit_location = hit_point;
                    self.hit_distance = @floatCast(dist);
                }
            }
        }
    }

    /// Tick - update cooldown
    pub fn tick(self: *Self) void {
        if (self.cooldown > 0) {
            self.cooldown -= 1;
        }
    }

    /// Handle attack (left click on entity)
    /// attacker_pos: Position of the player attacking
    /// Returns true if an entity was attacked
    pub fn handleAttack(self: *Self, attacker_pos: Vec3) bool {
        if (self.cooldown > 0) return false;

        const target_id = self.target_entity_id orelse return false;
        const target = self.entity_manager.get(target_id) orelse return false;

        // Apply damage with knockback
        // We need to access the LivingEntity through the entity hierarchy
        // For now, we'll add a hurt method to Entity that can be overridden
        self.attackEntity(target, attacker_pos);

        // Set cooldown
        self.cooldown = ATTACK_COOLDOWN;

        logger.info("Attacked entity {} at ({d:.1}, {d:.1}, {d:.1})", .{
            target_id,
            target.position.x,
            target.position.y,
            target.position.z,
        });

        return true;
    }

    /// Attack an entity
    fn attackEntity(self: *Self, target: *Entity, attacker_pos: Vec3) void {
        _ = self;

        // Calculate knockback direction (from attacker to target)
        const dx = target.position.x - attacker_pos.x;
        const dz = target.position.z - attacker_pos.z;
        const knockback_dir = std.math.atan2(dz, dx);

        // Apply damage through the entity's hurt callback
        // This will be handled by the entity's LivingEntity component
        target.hurtByPlayer(BASE_DAMAGE, knockback_dir, attacker_pos);
    }

    /// Check if currently targeting an entity
    pub fn isTargetingEntity(self: *const Self) bool {
        return self.target_entity_id != null;
    }

    /// Get the targeted entity (if any)
    pub fn getTargetEntity(self: *const Self) ?*Entity {
        const id = self.target_entity_id orelse return null;
        return self.entity_manager.get(id);
    }

    /// Get hit location (for rendering effects)
    pub fn getHitLocation(self: *const Self) ?Vec3 {
        return self.hit_location;
    }

    /// Get distance to target
    pub fn getTargetDistance(self: *const Self) f32 {
        return self.hit_distance;
    }
};
