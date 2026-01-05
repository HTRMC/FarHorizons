const std = @import("std");
const shared = @import("Shared");
const Vec3 = shared.Vec3;
const Mat4 = shared.Mat4;

/// Entity type identifier
pub const EntityType = enum(u8) {
    cow= 0,
    pig= 1,
    sheep= 2,
    player = 3,
    // Add more as needed
};

/// Base entity data shared by all entity types
pub const Entity = struct {
    const Self = @This();

    // Unique entity ID
    id: u64,

    // Entity type
    entity_type: EntityType,

    // World position (center of the entity at feet level)
    position: Vec3,

    // Previous position (for interpolation)
    prev_position: Vec3,

    // Velocity
    velocity: Vec3 = Vec3.ZERO,

    // Rotation around the Y-axis (yaw) in degrees
    yaw: f32 = 0,

    // Previous yaw (for interpolation)
    prev_yaw: f32 = 0,

    // Head rotation (pitch and yaw) in radians
    head_pitch: f32 = 0,
    head_yaw: f32 = 0,

    // Previous head rotation (for interpolation)
    prev_head_pitch: f32 = 0,
    prev_head_yaw: f32 = 0,

    // Head animation targets for smooth idle movement
    head_target_pitch: f32 = 0,
    head_target_yaw: f32 = 0,
    head_idle_timer: u32 = 0,

    // Look-at target tracking
    is_looking_at_target: bool = false,

    // Body rotation offset from yaw
    body_yaw_offset: f32 = 0,

    // Whether entity is on ground
    on_ground: bool = true,

    // Animation time (ticks)
    tick_count: u64 = 0,

    // Walk animation parameter
    walk_animation: f32 = 0,

    // Previous walk animation (for interpolation)
    prev_walk_animation: f32 = 0,

    // Walk animation speed
    walk_speed: f32 = 0,

    /// Create a new entity
    pub fn init(id: u64, entity_type: EntityType, position: Vec3) Self {
        return Self{
            .id = id,
            .entity_type = entity_type,
            .position = position,
            .prev_position = position,
        };
    }

    // Constants for look-at behavior (matching Minecraft's Mob defaults)
    const LOOK_AT_DISTANCE: f32 = 8.0; // Blocks - how close player must be to trigger look-at
    const MAX_HEAD_YAW: f32 = 75.0 * std.math.pi / 180.0; // Max head turn from body (MC: 75 degrees)
    const MAX_HEAD_PITCH: f32 = 40.0 * std.math.pi / 180.0; // Max head pitch (radians)
    // Rotation speeds in radians per tick (MC uses degrees: yaw=10, pitch=40)
    const HEAD_YAW_SPEED: f32 = 10.0 * std.math.pi / 180.0; // 10 degrees/tick
    const HEAD_PITCH_SPEED: f32 = 40.0 * std.math.pi / 180.0; // 40 degrees/tick
    const IDLE_ROT_SPEED: f32 = 5.0 * std.math.pi / 180.0; // Slower for idle movement

    /// Update entity state (call once per tick)
    /// player_pos: Position of the player (or null if no player tracking)
    pub fn tick(self: *Self, player_pos: ?Vec3) void {
        self.prev_position = self.position;
        self.prev_yaw = self.yaw;
        self.prev_walk_animation = self.walk_animation;
        self.prev_head_pitch = self.head_pitch;
        self.prev_head_yaw = self.head_yaw;
        self.tick_count += 1;

        // Update walk animation based on velocity (like MC's limb swing)
        const horizontal_speed = @sqrt(self.velocity.x * self.velocity.x + self.velocity.z * self.velocity.z);
        if (horizontal_speed > 0.01) {
            self.walk_speed = @min(1.0, horizontal_speed * 4.0);
            // Just increment - cos() in the model handles periodicity naturally
            // The 0.6662 multiplier in the model creates the proper walk cycle
            self.walk_animation += horizontal_speed;
        } else {
            self.walk_speed *= 0.9; // Smoothly reduce animation speed when stopping
        }

        // Head look-at logic
        var yaw_speed: f32 = IDLE_ROT_SPEED;
        var pitch_speed: f32 = IDLE_ROT_SPEED;

        if (player_pos) |pp| {
            // Calculate distance to player
            const dx = pp.x - self.position.x;
            const dy = pp.y - (self.position.y + 1.0); // Approximate eye height
            const dz = pp.z - self.position.z;
            const horizontal_dist = @sqrt(dx * dx + dz * dz);
            const distance = @sqrt(dx * dx + dy * dy + dz * dz);

            if (distance < LOOK_AT_DISTANCE and distance > 0.1) {
                // Player is close enough - look at them
                self.is_looking_at_target = true;
                yaw_speed = HEAD_YAW_SPEED;
                pitch_speed = HEAD_PITCH_SPEED;

                // Calculate look-at angles using atan2 (like MC)
                // MC formula: atan2(zd, xd) * 180/PI - 90 gives world yaw in degrees
                // We need: angle from cow to player, relative to cow's body facing direction

                // World yaw to player (angle from +Z axis, since our model faces -Z by default)
                const target_world_yaw = std.math.atan2(dx, -dz);

                // Convert entity body yaw to radians (body yaw is in degrees)
                const body_yaw_rad = self.yaw * std.math.pi / 180.0;

                // Head yaw is relative to body - negate because model Y rotation is inverted
                var target_head_yaw = -(target_world_yaw - body_yaw_rad);

                // Normalize to -PI to PI
                while (target_head_yaw > std.math.pi) target_head_yaw -= 2.0 * std.math.pi;
                while (target_head_yaw < -std.math.pi) target_head_yaw += 2.0 * std.math.pi;

                // Clamp head yaw relative to body
                target_head_yaw = std.math.clamp(target_head_yaw, -MAX_HEAD_YAW, MAX_HEAD_YAW);

                // Pitch: vertical angle (negate because model X rotation is inverted)
                var target_head_pitch = -std.math.atan2(dy, horizontal_dist);
                target_head_pitch = std.math.clamp(target_head_pitch, -MAX_HEAD_PITCH, MAX_HEAD_PITCH);

                self.head_target_pitch = target_head_pitch;
                self.head_target_yaw = target_head_yaw;

                // Reset idle timer when looking at player
                self.head_idle_timer = 20; // Small delay before resuming idle
            } else {
                self.is_looking_at_target = false;
            }
        } else {
            self.is_looking_at_target = false;
        }

        // Idle head animation (when not looking at player)
        if (!self.is_looking_at_target) {
            if (self.head_idle_timer == 0) {
                // Pick new random target using simple hash of tick_count and id
                const hash = self.tick_count *% 2654435761 +% self.id *% 1597334677;
                const hash2 = hash *% 2654435761;

                // Random pitch: -20 to +30 degrees (looking down to up)
                const pitch_range: f32 = 50.0 * std.math.pi / 180.0;
                const pitch_offset: f32 = -20.0 * std.math.pi / 180.0;
                self.head_target_pitch = (@as(f32, @floatFromInt(hash % 1000)) / 1000.0) * pitch_range + pitch_offset;

                // Random yaw: -45 to +45 degrees (looking left to right)
                const yaw_range: f32 = 90.0 * std.math.pi / 180.0;
                self.head_target_yaw = (@as(f32, @floatFromInt(hash2 % 1000)) / 1000.0 - 0.5) * yaw_range;

                // Clamp idle yaw to max head rotation
                self.head_target_yaw = std.math.clamp(self.head_target_yaw, -MAX_HEAD_YAW, MAX_HEAD_YAW);

                // Random delay: 40-120 ticks (2-6 seconds at 20 tps)
                self.head_idle_timer = @intCast(40 + (hash >> 16) % 80);
            } else {
                self.head_idle_timer -= 1;
            }
        }

        // Rotate head toward target using MC's rotateTowards approach (fixed speed, not lerp)
        self.head_pitch = rotateTowards(self.head_pitch, self.head_target_pitch, pitch_speed);
        self.head_yaw = rotateTowards(self.head_yaw, self.head_target_yaw, yaw_speed);
    }

    /// Rotate from current angle toward target by at most maxRot (like MC's rotateTowards)
    fn rotateTowards(from: f32, to: f32, max_rot: f32) f32 {
        var diff = to - from;
        // Normalize difference to -PI to PI
        while (diff > std.math.pi) diff -= 2.0 * std.math.pi;
        while (diff < -std.math.pi) diff += 2.0 * std.math.pi;
        // Clamp to max rotation speed
        const clamped = std.math.clamp(diff, -max_rot, max_rot);
        return from + clamped;
    }

    /// Get interpolated position for rendering
    pub fn getPosition(self: *const Self, partial_tick: f32) Vec3 {
        return Vec3{
            .x = self.prev_position.x + (self.position.x - self.prev_position.x) * partial_tick,
            .y = self.prev_position.y + (self.position.y - self.prev_position.y) * partial_tick,
            .z = self.prev_position.z + (self.position.z - self.prev_position.z) * partial_tick,
        };
    }

    /// Get interpolated yaw for rendering
    pub fn getYaw(self: *const Self, partial_tick: f32) f32 {
        // Handle yaw wrap-around
        var delta = self.yaw - self.prev_yaw;
        while (delta > 180) delta -= 360;
        while (delta < -180) delta += 360;
        return self.prev_yaw + delta * partial_tick;
    }

    /// Get interpolated walk animation for rendering
    pub fn getWalkAnimation(self: *const Self, partial_tick: f32) f32 {
        return self.prev_walk_animation + (self.walk_animation - self.prev_walk_animation) * partial_tick;
    }

    /// Get interpolated head pitch for rendering
    pub fn getHeadPitch(self: *const Self, partial_tick: f32) f32 {
        return self.prev_head_pitch + (self.head_pitch - self.prev_head_pitch) * partial_tick;
    }

    /// Get interpolated head yaw for rendering
    pub fn getHeadYaw(self: *const Self, partial_tick: f32) f32 {
        return self.prev_head_yaw + (self.head_yaw - self.prev_head_yaw) * partial_tick;
    }

    /// Set position (also updates prev_position)
    pub fn setPosition(self: *Self, pos: Vec3) void {
        self.position = pos;
        self.prev_position = pos;
    }

    /// Move entity by delta
    pub fn move(self: *Self, delta: Vec3) void {
        self.position.x += delta.x;
        self.position.y += delta.y;
        self.position.z += delta.z;
    }

    /// Get model matrix for rendering
    pub fn getModelMatrix(self: *const Self, partial_tick: f32) Mat4 {
        const pos = self.getPosition(partial_tick);
        const yaw_rad = self.getYaw(partial_tick) * std.math.pi / 180.0;

        // Translate to position, then rotate around Y
        // Order: first rotate, then translate (in column-major order, multiply right to left)
        const rotation = Mat4.rotationY(yaw_rad);
        const translation = Mat4.translation(pos);
        return Mat4.multiply(translation, rotation);
    }
};

/// Manager for all entities in the world
pub const EntityManager = struct {
    const Self = @This();

    entities: std.AutoHashMap(u64, Entity),
    next_id: u64 = 1,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .entities = std.AutoHashMap(u64, Entity).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.entities.deinit();
    }

    /// Spawn a new entity
    pub fn spawn(self: *Self, entity_type: EntityType, position: Vec3) !u64 {
        const id = self.next_id;
        self.next_id += 1;

        try self.entities.put(id, Entity.init(id, entity_type, position));
        return id;
    }

    /// Get entity by ID
    pub fn get(self: *const Self, id: u64) ?*Entity {
        return self.entities.getPtr(id);
    }

    /// Remove entity by ID
    pub fn remove(self: *Self, id: u64) void {
        _ = self.entities.remove(id);
    }

    /// Tick all entities
    /// player_pos: Position of the player for look-at behavior
    pub fn tickAll(self: *Self, player_pos: ?Vec3) void {
        var iter = self.entities.valueIterator();
        while (iter.next()) |entity| {
            entity.tick(player_pos);
        }
    }

    /// Get iterator over all entities
    pub fn iterator(self: *Self) std.AutoHashMap(u64, Entity).ValueIterator {
        return self.entities.valueIterator();
    }
};