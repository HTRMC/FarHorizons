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

    // Body rotation following head (like MC's BodyRotationControl)
    last_stable_head_yaw: f32 = 0, // Last head yaw when stable
    head_stable_time: u32 = 0, // Ticks head has been stable

    // Body rotation offset from yaw
    body_yaw_offset: f32 = 0,

    // Whether entity is on ground (default false so entities fall when spawned)
    on_ground: bool = false,

    // Bounding box dimensions (set based on entity type)
    width: f32 = 0.9, // Cow default: 0.9 blocks wide
    height: f32 = 1.4, // Cow default: 1.4 blocks tall

    // Animation time (ticks)
    tick_count: u64 = 0,

    // Walk animation parameter
    walk_animation: f32 = 0,

    // Previous walk animation (for interpolation)
    prev_walk_animation: f32 = 0,

    // Walk animation speed (amplitude of leg swing)
    walk_speed: f32 = 0,

    // Previous walk speed (for interpolation)
    prev_walk_speed: f32 = 0,

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

    // Body rotation constants (from MC's BodyRotationControl)
    const HEAD_STABLE_ANGLE: f32 = 15.0 * std.math.pi / 180.0; // Head movement threshold to reset timer
    const BODY_TURN_DELAY: u32 = 10; // Ticks before body starts turning
    const BODY_TURN_DURATION: u32 = 10; // Ticks to complete the turn
    const BODY_ROT_SPEED: f32 = 10.0 * std.math.pi / 180.0; // Body rotation speed

    // Physics constants (matching Minecraft)
    const GRAVITY: f32 = 0.08; // Blocks per tick^2 (MC uses 0.08)
    const DRAG: f32 = 0.98; // Velocity multiplier per tick
    const GROUND_FRICTION: f32 = 0.91; // Horizontal friction when on ground

    /// Terrain query function type - returns true if block at position is solid
    pub const TerrainQuery = *const fn (x: i32, y: i32, z: i32) bool;

    /// Update entity state (call once per tick)
    /// player_pos: Position of the player (or null if no player tracking)
    /// terrain: Optional terrain query function for collision
    pub fn tick(self: *Self, player_pos: ?Vec3, terrain: ?TerrainQuery) void {
        self.prev_position = self.position;
        self.prev_yaw = self.yaw;
        self.prev_walk_animation = self.walk_animation;
        self.prev_walk_speed = self.walk_speed;
        self.prev_head_pitch = self.head_pitch;
        self.prev_head_yaw = self.head_yaw;
        self.tick_count += 1;

        // Apply physics if terrain is available
        if (terrain) |query_terrain| {
            self.applyPhysics(query_terrain);
        }

        // Update walk animation based on velocity (like MC's limb swing)
        const horizontal_speed = @sqrt(self.velocity.x * self.velocity.x + self.velocity.z * self.velocity.z);
        if (horizontal_speed > 0.01) {
            self.walk_speed = @min(1.0, horizontal_speed * 4.0);
            // Scale animation so legs move at reasonable speed
            // At speed 0.1, this gives ~0.6 per tick, completing a leg cycle in ~16 ticks
            self.walk_animation += horizontal_speed * 6.0;
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

        // Body rotation following head (like MC's BodyRotationControl)
        self.updateBodyRotation();
    }

    /// Update body rotation to follow head when stationary
    fn updateBodyRotation(self: *Self) void {
        const is_moving = (self.velocity.x * self.velocity.x + self.velocity.z * self.velocity.z) > 0.0001;

        if (is_moving) {
            // When moving, body faces movement direction
            // Head is clamped to stay within MAX_HEAD_YAW of body
            self.head_yaw = std.math.clamp(self.head_yaw, -MAX_HEAD_YAW, MAX_HEAD_YAW);
            self.last_stable_head_yaw = self.head_yaw;
            self.head_stable_time = 0;
        } else {
            // When stationary, track head stability
            const head_moved = @abs(self.head_yaw - self.last_stable_head_yaw) > HEAD_STABLE_ANGLE;

            if (head_moved) {
                // Head moved significantly - reset timer and update stable position
                self.head_stable_time = 0;
                self.last_stable_head_yaw = self.head_yaw;

                // Rotate body toward head if head is turned far
                if (@abs(self.head_yaw) > MAX_HEAD_YAW * 0.5) {
                    self.rotateBodyTowardHead(MAX_HEAD_YAW);
                }
            } else {
                // Head is stable
                self.head_stable_time += 1;

                if (self.head_stable_time > BODY_TURN_DELAY) {
                    // Body starts turning toward head direction
                    // Gradually reduce the max angle difference over BODY_TURN_DURATION ticks
                    const time_since_start = self.head_stable_time - BODY_TURN_DELAY;
                    const turn_progress = std.math.clamp(
                        @as(f32, @floatFromInt(time_since_start)) / @as(f32, @floatFromInt(BODY_TURN_DURATION)),
                        0.0,
                        1.0,
                    );
                    // As turn_progress goes 0->1, max_angle goes MAX_HEAD_YAW -> 0
                    const max_angle = MAX_HEAD_YAW * (1.0 - turn_progress);
                    self.rotateBodyTowardHead(max_angle);
                }
            }
        }
    }

    // Step height - entities can walk up this many blocks without jumping (like MC)
    const STEP_HEIGHT: f32 = 0.6;

    /// Apply physics: gravity, movement, and terrain collision
    fn applyPhysics(self: *Self, terrain: TerrainQuery) void {
        const half_width = self.width / 2.0;

        // Apply gravity if not on ground
        if (!self.on_ground) {
            self.velocity.y -= GRAVITY;
        }

        // Apply drag to Y velocity
        self.velocity.y *= DRAG;

        // Calculate new position (friction applied AFTER movement like MC)
        var new_x = self.position.x + self.velocity.x;
        var new_y = self.position.y + self.velocity.y;
        var new_z = self.position.z + self.velocity.z;

        // === Horizontal collision with step-up ===
        const is_moving_horizontally = self.velocity.x != 0 or self.velocity.z != 0;

        if (is_moving_horizontally) {
            // Try to move horizontally, with step-up if blocked
            const move_result = self.tryMoveHorizontal(terrain, new_x, new_y, new_z, half_width);
            new_x = move_result.x;
            new_y = move_result.y;
            new_z = move_result.z;
            if (move_result.blocked_x) self.velocity.x = 0;
            if (move_result.blocked_z) self.velocity.z = 0;
        }

        // === Vertical collision ===
        self.on_ground = false;

        if (self.velocity.y <= 0) {
            // Falling or stationary - check ground collision
            const feet_y: i32 = @intFromFloat(@floor(new_y));
            const check_positions = [_][2]f32{
                .{ new_x - half_width + 0.01, new_z - half_width + 0.01 },
                .{ new_x + half_width - 0.01, new_z - half_width + 0.01 },
                .{ new_x - half_width + 0.01, new_z + half_width - 0.01 },
                .{ new_x + half_width - 0.01, new_z + half_width - 0.01 },
            };

            for (check_positions) |pos| {
                const block_x: i32 = @intFromFloat(@floor(pos[0]));
                const block_z: i32 = @intFromFloat(@floor(pos[1]));

                if (terrain(block_x, feet_y, block_z)) {
                    // Hit ground - snap to top of block
                    new_y = @as(f32, @floatFromInt(feet_y + 1));
                    self.velocity.y = 0;
                    self.on_ground = true;
                    break;
                }
            }

            // If not falling but was on ground, check if still on ground (step-down)
            if (!self.on_ground and self.velocity.y >= -0.01) {
                // Check for ground slightly below (max step down distance)
                const step_down_y: i32 = @intFromFloat(@floor(new_y - STEP_HEIGHT));
                for (check_positions) |pos| {
                    const block_x: i32 = @intFromFloat(@floor(pos[0]));
                    const block_z: i32 = @intFromFloat(@floor(pos[1]));

                    if (terrain(block_x, step_down_y, block_z)) {
                        // Ground below - snap down to it
                        new_y = @as(f32, @floatFromInt(step_down_y + 1));
                        self.velocity.y = 0;
                        self.on_ground = true;
                        break;
                    }
                }
            }
        } else {
            // Rising - check ceiling collision
            const head_y: i32 = @intFromFloat(@floor(new_y + self.height));
            const check_positions = [_][2]f32{
                .{ new_x - half_width + 0.01, new_z - half_width + 0.01 },
                .{ new_x + half_width - 0.01, new_z + half_width - 0.01 },
            };

            for (check_positions) |pos| {
                const block_x: i32 = @intFromFloat(@floor(pos[0]));
                const block_z: i32 = @intFromFloat(@floor(pos[1]));

                if (terrain(block_x, head_y, block_z)) {
                    new_y = @as(f32, @floatFromInt(head_y)) - self.height;
                    self.velocity.y = 0;
                    break;
                }
            }
        }

        // Update position
        self.position.x = new_x;
        self.position.y = new_y;
        self.position.z = new_z;

        // Apply friction AFTER movement (like MC)
        if (self.on_ground) {
            self.velocity.x *= GROUND_FRICTION;
            self.velocity.z *= GROUND_FRICTION;
        }
    }

    /// Try to move horizontally with step-up capability
    fn tryMoveHorizontal(
        self: *Self,
        terrain: TerrainQuery,
        target_x: f32,
        target_y: f32,
        target_z: f32,
        half_width: f32,
    ) struct { x: f32, y: f32, z: f32, blocked_x: bool, blocked_z: bool } {
        var new_x = target_x;
        var new_y = target_y;
        var new_z = target_z;
        var blocked_x = false;
        var blocked_z = false;

        // Check X collision
        if (self.velocity.x != 0) {
            const check_x: i32 = if (self.velocity.x > 0)
                @intFromFloat(@floor(new_x + half_width))
            else
                @intFromFloat(@floor(new_x - half_width));

            if (self.isBlockedAtHeight(terrain, check_x, new_y, new_z, half_width)) {
                // Blocked - try stepping up
                const step_y = new_y + STEP_HEIGHT;
                if (!self.isBlockedAtHeight(terrain, check_x, step_y, new_z, half_width)) {
                    // Can step up - find exact step height
                    new_y = self.findStepHeight(terrain, new_x, new_y, new_z, half_width, check_x, true);
                } else {
                    // Can't step up - stop at wall
                    if (self.velocity.x > 0) {
                        new_x = @as(f32, @floatFromInt(check_x)) - half_width - 0.001;
                    } else {
                        new_x = @as(f32, @floatFromInt(check_x + 1)) + half_width + 0.001;
                    }
                    blocked_x = true;
                }
            }
        }

        // Check Z collision
        if (self.velocity.z != 0) {
            const check_z: i32 = if (self.velocity.z > 0)
                @intFromFloat(@floor(new_z + half_width))
            else
                @intFromFloat(@floor(new_z - half_width));

            if (self.isBlockedAtHeightZ(terrain, check_z, new_y, new_x, half_width)) {
                // Blocked - try stepping up
                const step_y = new_y + STEP_HEIGHT;
                if (!self.isBlockedAtHeightZ(terrain, check_z, step_y, new_x, half_width)) {
                    // Can step up
                    new_y = self.findStepHeightZ(terrain, new_x, new_y, new_z, half_width, check_z, true);
                } else {
                    // Can't step up - stop at wall
                    if (self.velocity.z > 0) {
                        new_z = @as(f32, @floatFromInt(check_z)) - half_width - 0.001;
                    } else {
                        new_z = @as(f32, @floatFromInt(check_z + 1)) + half_width + 0.001;
                    }
                    blocked_z = true;
                }
            }
        }

        return .{ .x = new_x, .y = new_y, .z = new_z, .blocked_x = blocked_x, .blocked_z = blocked_z };
    }

    /// Check if blocked at a given height for X movement
    fn isBlockedAtHeight(self: *Self, terrain: TerrainQuery, check_x: i32, y: f32, z: f32, half_width: f32) bool {
        const feet_y: i32 = @intFromFloat(@floor(y + 0.01));
        const mid_y: i32 = @intFromFloat(@floor(y + self.height * 0.5));
        const block_z1: i32 = @intFromFloat(@floor(z - half_width + 0.01));
        const block_z2: i32 = @intFromFloat(@floor(z + half_width - 0.01));

        for ([_]i32{ feet_y, mid_y }) |check_y| {
            if (terrain(check_x, check_y, block_z1) or terrain(check_x, check_y, block_z2)) {
                return true;
            }
        }
        return false;
    }

    /// Check if blocked at a given height for Z movement
    fn isBlockedAtHeightZ(self: *Self, terrain: TerrainQuery, check_z: i32, y: f32, x: f32, half_width: f32) bool {
        const feet_y: i32 = @intFromFloat(@floor(y + 0.01));
        const mid_y: i32 = @intFromFloat(@floor(y + self.height * 0.5));
        const block_x1: i32 = @intFromFloat(@floor(x - half_width + 0.01));
        const block_x2: i32 = @intFromFloat(@floor(x + half_width - 0.01));

        for ([_]i32{ feet_y, mid_y }) |check_y| {
            if (terrain(block_x1, check_y, check_z) or terrain(block_x2, check_y, check_z)) {
                return true;
            }
        }
        return false;
    }

    /// Find the exact step height needed for X movement
    fn findStepHeight(_: *Self, terrain: TerrainQuery, _: f32, y: f32, z: f32, half_width: f32, check_x: i32, _: bool) f32 {
        // Find the top of the blocking block
        const feet_y: i32 = @intFromFloat(@floor(y + 0.01));
        const block_z1: i32 = @intFromFloat(@floor(z - half_width + 0.01));
        const block_z2: i32 = @intFromFloat(@floor(z + half_width - 0.01));

        // Check if there's a block at feet level we need to step onto
        if (terrain(check_x, feet_y, block_z1) or terrain(check_x, feet_y, block_z2)) {
            return @as(f32, @floatFromInt(feet_y + 1));
        }
        return y;
    }

    /// Find the exact step height needed for Z movement
    fn findStepHeightZ(_: *Self, terrain: TerrainQuery, x: f32, y: f32, _: f32, half_width: f32, check_z: i32, _: bool) f32 {
        const feet_y: i32 = @intFromFloat(@floor(y + 0.01));
        const block_x1: i32 = @intFromFloat(@floor(x - half_width + 0.01));
        const block_x2: i32 = @intFromFloat(@floor(x + half_width - 0.01));

        if (terrain(block_x1, feet_y, check_z) or terrain(block_x2, feet_y, check_z)) {
            return @as(f32, @floatFromInt(feet_y + 1));
        }
        return y;
    }

    /// Rotate body toward head direction, keeping head within max_angle of body
    fn rotateBodyTowardHead(self: *Self, max_angle: f32) void {
        // If head is turned beyond max_angle, rotate body to compensate
        if (@abs(self.head_yaw) > max_angle) {
            // Calculate how much to rotate body
            const excess = if (self.head_yaw > 0)
                self.head_yaw - max_angle
            else
                self.head_yaw + max_angle;

            // Clamp rotation speed
            const body_rotation = std.math.clamp(excess, -BODY_ROT_SPEED, BODY_ROT_SPEED);

            // Rotate body (yaw is in degrees, body_rotation is in radians)
            // Negate because positive head_yaw = head right, need body to turn right (decrease yaw)
            self.yaw -= body_rotation * 180.0 / std.math.pi;

            // Reduce head_yaw since body now faces closer to where head was looking
            // Don't adjust head_target_yaw - it gets recalculated each tick
            self.head_yaw -= body_rotation;

            // Normalize body yaw to 0-360
            while (self.yaw > 360) self.yaw -= 360;
            while (self.yaw < 0) self.yaw += 360;
        }
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

    /// Get interpolated walk speed (leg swing amplitude) for rendering
    pub fn getWalkSpeed(self: *const Self, partial_tick: f32) f32 {
        return self.prev_walk_speed + (self.walk_speed - self.prev_walk_speed) * partial_tick;
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
    /// terrain: Optional terrain query function for collision
    pub fn tickAll(self: *Self, player_pos: ?Vec3, terrain: ?Entity.TerrainQuery) void {
        var iter = self.entities.valueIterator();
        while (iter.next()) |entity| {
            entity.tick(player_pos, terrain);
        }
    }

    /// Get iterator over all entities
    pub fn iterator(self: *Self) std.AutoHashMap(u64, Entity).ValueIterator {
        return self.entities.valueIterator();
    }
};