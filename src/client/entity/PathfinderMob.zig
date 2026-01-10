const std = @import("std");
const shared = @import("Shared");
const Vec3 = shared.Vec3;
const Entity = @import("Entity.zig").Entity;
const Mob = @import("Mob.zig").Mob;

/// PathfinderMob - Base for mobs that can pathfind/navigate
///
/// Modeled after Minecraft's PathfinderMob class which extends Mob and adds:
/// - Path navigation system
/// - Movement control for following paths
/// - Target position tracking
/// - Walk target management
///
/// This is the base class for all mobs that wander or navigate to positions.
///
/// Inheritance: Entity -> LivingEntity -> Mob -> PathfinderMob
pub const PathfinderMob = struct {
    const Self = @This();

    /// Reference to the base entity
    entity: *Entity,

    /// Mob wrapper (AI, equipment, living)
    mob: Mob,

    /// Current walk target (where we're trying to go)
    walk_target: ?WalkTarget = null,

    /// Whether we're currently restricting to an area
    restricted_to_area: bool = false,

    /// Center of restricted area (if restricted)
    restrict_center: Vec3 = Vec3.ZERO,

    /// Radius of restricted area
    restrict_radius: f32 = 0,

    /// Walk target info
    pub const WalkTarget = struct {
        position: Vec3,
        speed_modifier: f32,
        close_enough_dist: f32,
    };

    /// Initialize a PathfinderMob wrapper for an entity
    pub fn init(entity: *Entity) Self {
        return .{
            .entity = entity,
            .mob = Mob.init(entity),
        };
    }

    /// Initialize with health
    pub fn initWithHealth(entity: *Entity, max_hp: f32) Self {
        return .{
            .entity = entity,
            .mob = Mob.initWithHealth(entity, max_hp),
        };
    }

    // ======================
    // Navigation
    // ======================

    /// Set the walk target (where to navigate to)
    pub fn setWalkTarget(self: *Self, position: Vec3, speed_modifier: f32, close_enough: f32) void {
        self.walk_target = .{
            .position = position,
            .speed_modifier = speed_modifier,
            .close_enough_dist = close_enough,
        };
    }

    /// Clear the walk target (stop navigating)
    pub fn clearWalkTarget(self: *Self) void {
        self.walk_target = null;
    }

    /// Check if we have a walk target
    pub fn hasWalkTarget(self: *const Self) bool {
        return self.walk_target != null;
    }

    /// Get distance to walk target
    pub fn getDistanceToWalkTarget(self: *const Self) ?f32 {
        if (self.walk_target) |target| {
            const dx = target.position.x - self.entity.position.x;
            const dy = target.position.y - self.entity.position.y;
            const dz = target.position.z - self.entity.position.z;
            return @sqrt(dx * dx + dy * dy + dz * dz);
        }
        return null;
    }

    /// Check if we've reached the walk target
    pub fn reachedWalkTarget(self: *const Self) bool {
        if (self.walk_target) |target| {
            if (self.getDistanceToWalkTarget()) |dist| {
                return dist <= target.close_enough_dist;
            }
        }
        return false;
    }

    // ======================
    // Area Restriction
    // ======================

    /// Restrict this mob to an area around a position
    pub fn restrictTo(self: *Self, center: Vec3, radius: f32) void {
        self.restricted_to_area = true;
        self.restrict_center = center;
        self.restrict_radius = radius;
    }

    /// Clear area restriction
    pub fn clearRestriction(self: *Self) void {
        self.restricted_to_area = false;
    }

    /// Check if a position is within restricted area
    pub fn isWithinRestriction(self: *const Self, pos: Vec3) bool {
        if (!self.restricted_to_area) return true;

        const dx = pos.x - self.restrict_center.x;
        const dy = pos.y - self.restrict_center.y;
        const dz = pos.z - self.restrict_center.z;
        const dist_sq = dx * dx + dy * dy + dz * dz;

        return dist_sq <= self.restrict_radius * self.restrict_radius;
    }

    /// Check if currently within restricted area
    pub fn isWithinRestrictionArea(self: *const Self) bool {
        return self.isWithinRestriction(self.entity.position);
    }

    // ======================
    // Mob Accessors
    // ======================

    /// Get the mob wrapper
    pub fn getMob(self: *Self) *Mob {
        return &self.mob;
    }

    /// Get the living entity wrapper
    pub fn getLiving(self: *Self) *@import("LivingEntity.zig").LivingEntity {
        return self.mob.getLiving();
    }

    /// Attempt to jump
    pub fn jump(self: *Self) void {
        self.mob.jump();
    }

    /// Try to jump over obstacle
    pub fn tryJumpOver(self: *Self, obstacle_height: f32) bool {
        return self.mob.tryJumpOver(obstacle_height);
    }

    /// Check if alive
    pub fn isAlive(self: *const Self) bool {
        return self.mob.isAlive();
    }

    // ======================
    // Tick Update
    // ======================

    /// Tick the pathfinder mob
    pub fn tick(self: *Self) void {
        // Tick the mob (living entity, etc.)
        self.mob.tick();

        // Check if we reached walk target
        if (self.reachedWalkTarget()) {
            self.clearWalkTarget();
        }
    }

    // ======================
    // Path Navigation (placeholder)
    // ======================

    /// Navigate to a position
    /// TODO: Implement actual A* pathfinding
    pub fn navigateTo(self: *Self, target: Vec3, speed: f32) bool {
        // For now, just set as walk target
        // Actual pathfinding would find a path avoiding obstacles
        self.setWalkTarget(target, speed, 1.0);
        return true;
    }

    /// Check if navigation is in progress
    pub fn isNavigating(self: *const Self) bool {
        return self.walk_target != null;
    }

    /// Stop navigating
    pub fn stopNavigation(self: *Self) void {
        self.clearWalkTarget();
    }
};
