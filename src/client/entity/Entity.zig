const std = @import("std");
const shared = @import("Shared");
const Vec3 = shared.Vec3;
const Mat4 = shared.Mat4;
const Axis = shared.Axis;
const Logger = shared.Logger;

// AI imports
const ai = @import("ai/ai.zig");
const GoalSelector = ai.GoalSelector;
const LookControl = ai.LookControl;

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
    const logger = Logger.init("Entity");

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

    // Player position for AI goals (set each tick by EntityManager)
    player_target_pos: ?Vec3 = null,

    // AI system (optional - set up by registerGoals)
    goal_selector: ?*GoalSelector = null,
    look_control: ?*LookControl = null,

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

    // Baby flag (affects model selection in renderer)
    is_baby: bool = false,

    /// Create a new entity
    pub fn init(id: u64, entity_type: EntityType, position: Vec3) Self {
        return Self{
            .id = id,
            .entity_type = entity_type,
            .position = position,
            .prev_position = position,
        };
    }

    // Body rotation constants (from MC's BodyRotationControl)
    const MAX_HEAD_YAW: f32 = 75.0 * std.math.pi / 180.0; // Max head turn from body (MC: 75 degrees)
    const HEAD_STABLE_ANGLE: f32 = 15.0 * std.math.pi / 180.0; // Head movement threshold to reset timer
    const BODY_TURN_DELAY: u32 = 10; // Ticks before body starts turning
    const BODY_TURN_DURATION: u32 = 10; // Ticks to complete the turn
    const BODY_ROT_SPEED: f32 = 10.0 * std.math.pi / 180.0; // Body rotation speed

    // Physics constants (matching Minecraft)
    const GRAVITY: f32 = 0.08; // Blocks per tick^2 (MC uses 0.08)
    const DRAG: f32 = 0.98; // Velocity multiplier per tick
    const GROUND_FRICTION: f32 = 0.91; // Horizontal friction when on ground

    /// VoxelShape import for collision
    const VoxelShape = @import("Shared").VoxelShape;
    const VoxelShapeAABB = VoxelShape.AABB;
    const VoxelShapeAxis = @import("Shared").voxel_shape.Axis;

    /// Terrain query function type - returns VoxelShape for block at position
    /// Like Minecraft's BlockState.getCollisionShape()
    pub const TerrainQuery = *const fn (x: i32, y: i32, z: i32) VoxelShape;

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

        // Store player position for AI goals to access
        self.player_target_pos = player_pos;

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

        // Tick AI goal selector (handles movement goals, look goals, etc.)
        if (self.goal_selector) |gs| {
            gs.tick();
        }

        // Tick look control (smoothly rotates head toward target set by goals)
        if (self.look_control) |lc| {
            lc.tick();
        }

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

    // Small epsilon to prevent floating point issues at block boundaries
    const EPSILON: f32 = 1.0e-7;

    /// Apply physics: gravity, movement, and terrain collision
    /// Uses Minecraft's axis-independent collision resolution for smooth wall sliding
    fn applyPhysics(self: *Self, terrain: TerrainQuery) void {
        const half_width = self.width / 2.0;

        // Apply gravity if not on ground
        if (!self.on_ground) {
            self.velocity.y -= GRAVITY;
        }

        // Apply drag to Y velocity
        self.velocity.y *= DRAG;

        // Get desired movement
        const move_x = self.velocity.x;
        const move_y = self.velocity.y;
        const move_z = self.velocity.z;

        // Current AABB position (will be updated as we resolve each axis)
        var current_x = self.position.x;
        var current_y = self.position.y;
        var current_z = self.position.z;

        // === Axis-independent collision resolution (like Minecraft) ===
        // Test Y first (always), then X/Z based on which has larger movement
        // This produces smooth wall sliding behavior

        // Determine axis order: Y first, then larger horizontal component
        const test_x_before_z = @abs(move_x) >= @abs(move_z);

        // 1. Always test Y axis first
        // Don't blindly reset on_ground - only change it based on actual collision results
        const resolved_y = self.collideY(terrain, current_x, current_y, current_z, half_width, move_y);
        if (@abs(resolved_y - move_y) > EPSILON) {
            // Y movement was blocked
            if (move_y < 0) {
                self.on_ground = true;
            }
            self.velocity.y = 0;
        } else if (move_y > EPSILON) {
            // Moving up without collision means we're airborne
            self.on_ground = false;
        }
        // Note: If move_y ≈ 0 (standing still), keep previous on_ground value
        current_y += resolved_y;

        // 2. Test horizontal axes in order of magnitude
        if (test_x_before_z) {
            // Test X, then Z
            const resolved_x = self.collideX(terrain, current_x, current_y, current_z, half_width, move_x);
            if (@abs(resolved_x - move_x) > EPSILON) {
                self.velocity.x = 0;
            }
            current_x += resolved_x;

            const resolved_z = self.collideZ(terrain, current_x, current_y, current_z, half_width, move_z);
            if (@abs(resolved_z - move_z) > EPSILON) {
                self.velocity.z = 0;
            }
            current_z += resolved_z;
        } else {
            // Test Z, then X
            const resolved_z = self.collideZ(terrain, current_x, current_y, current_z, half_width, move_z);
            if (@abs(resolved_z - move_z) > EPSILON) {
                self.velocity.z = 0;
            }
            current_z += resolved_z;

            const resolved_x = self.collideX(terrain, current_x, current_y, current_z, half_width, move_x);
            if (@abs(resolved_x - move_x) > EPSILON) {
                self.velocity.x = 0;
            }
            current_x += resolved_x;
        }

        // === Step-up mechanic ===
        // If on ground and horizontal movement was blocked, try stepping up
        const x_was_blocked = @abs(self.velocity.x) < EPSILON and @abs(move_x) > EPSILON;
        const z_was_blocked = @abs(self.velocity.z) < EPSILON and @abs(move_z) > EPSILON;

        // Debug: Log values BEFORE the step-up check to understand why it might not trigger
        // Only log for cows to filter out player
        const moved_x = current_x - self.position.x;
        const moved_z = current_z - self.position.z;
        if (self.entity_type == .cow and (@abs(move_x) > 0.001 or @abs(move_z) > 0.001)) {
            logger.info("COW PHYSICS: pos=({d:.2},{d:.2},{d:.2}) on_ground={} vel=({d:.4},{d:.4}) move=({d:.4},{d:.4}) moved=({d:.4},{d:.4}) blocked=({},{})", .{
                self.position.x, self.position.y, self.position.z,
                self.on_ground,
                self.velocity.x, self.velocity.z,
                move_x, move_z,
                moved_x, moved_z,
                x_was_blocked, z_was_blocked,
            });
        }

        if (self.on_ground and (x_was_blocked or z_was_blocked)) {
            // Try movement from a stepped-up position
            const step_y = self.position.y + STEP_HEIGHT;
            var step_x = self.position.x;
            var step_z = self.position.z;

            // Test movement from stepped position
            const step_move_x = self.collideX(terrain, step_x, step_y, step_z, half_width, move_x);
            step_x += step_move_x;
            const step_move_z = self.collideZ(terrain, step_x, step_y, step_z, half_width, move_z);
            step_z += step_move_z;

            // Check if stepping up allows more horizontal progress
            const original_dist_sq = (current_x - self.position.x) * (current_x - self.position.x) +
                (current_z - self.position.z) * (current_z - self.position.z);
            const step_dist_sq = (step_x - self.position.x) * (step_x - self.position.x) +
                (step_z - self.position.z) * (step_z - self.position.z);

            // Debug: Log step-up attempt
            logger.info("STEP-UP: pos=({d:.2},{d:.2},{d:.2}) blocked=({},{}) step_move=({d:.4},{d:.4})", .{
                self.position.x, self.position.y, self.position.z,
                x_was_blocked, z_was_blocked, step_move_x, step_move_z,
            });

            if (step_dist_sq > original_dist_sq + EPSILON) {
                // Stepping up helped - find the ground at the stepped position
                const step_down_y = self.collideY(terrain, step_x, step_y, step_z, half_width, -STEP_HEIGHT - 0.01);
                logger.info("  STEP-UP SUCCESS! step_down_y={d:.4} new_y={d:.2}", .{ step_down_y, step_y + step_down_y });
                current_x = step_x;
                current_y = step_y + step_down_y;
                current_z = step_z;

                // Restore velocity if we made progress
                if (@abs(step_move_x) > EPSILON) self.velocity.x = move_x;
                if (@abs(step_move_z) > EPSILON) self.velocity.z = move_z;
            } else {
                logger.info("  STEP-UP FAILED: no progress (orig={d:.6} step={d:.6})", .{ original_dist_sq, step_dist_sq });
            }
        }

        // === Step-down mechanic ===
        // If not falling but was on ground and no ground under us, try to step down
        if (!self.on_ground and @abs(move_y) < EPSILON) {
            const step_down_y = self.collideY(terrain, current_x, current_y, current_z, half_width, -STEP_HEIGHT - 0.01);
            if (@abs(step_down_y + STEP_HEIGHT + 0.01) > EPSILON) {
                // Found ground below within step distance
                current_y += step_down_y;
                self.on_ground = true;
                self.velocity.y = 0;
            }
        }

        // === Ground contact check ===
        // Even if we didn't move in Y, check if we're actually on ground
        // This fixes the flickering on_ground issue when standing still
        if (!self.on_ground) {
            const GROUND_PROBE: f32 = 0.01; // Small probe distance
            const ground_check = self.collideY(terrain, current_x, current_y, current_z, half_width, -GROUND_PROBE);
            if (self.entity_type == .cow) {
                logger.info("GROUND PROBE: y={d:.3} probe={d:.6} result={}", .{ current_y, ground_check, @abs(ground_check) < GROUND_PROBE * 0.5 });
            }
            if (@abs(ground_check) < GROUND_PROBE * 0.5) {
                // Couldn't move down much - we're on ground
                self.on_ground = true;
            }
        }

        // Update position
        self.position.x = current_x;
        self.position.y = current_y;
        self.position.z = current_z;

        // Apply friction AFTER movement (like MC)
        if (self.on_ground) {
            self.velocity.x *= GROUND_FRICTION;
            self.velocity.z *= GROUND_FRICTION;
        }
    }

    /// Collide on Y axis - returns how far the entity can actually move
    /// Like Minecraft's VoxelShape.collide() for the Y axis
    fn collideY(self: *Self, terrain: TerrainQuery, x: f32, y: f32, z: f32, half_width: f32, move_y: f32) f32 {
        if (@abs(move_y) < EPSILON) return 0;

        // Entity AABB bounds
        const min_x = x - half_width;
        const max_x = x + half_width;
        const min_y = y;
        const max_y = y + self.height;
        const min_z = z - half_width;
        const max_z = z + half_width;

        // Expand AABB in movement direction to find all potentially colliding blocks
        const expanded_min_y = if (move_y < 0) min_y + move_y else min_y;
        const expanded_max_y = if (move_y > 0) max_y + move_y else max_y;

        const block_min_x: i32 = @intFromFloat(@floor(min_x));
        const block_max_x: i32 = @intFromFloat(@floor(max_x));
        const block_min_y: i32 = @intFromFloat(@floor(expanded_min_y));
        const block_max_y: i32 = @intFromFloat(@floor(expanded_max_y));
        const block_min_z: i32 = @intFromFloat(@floor(min_z));
        const block_max_z: i32 = @intFromFloat(@floor(max_z));

        var result: f64 = move_y;

        // Check all blocks in the expanded region
        var by = block_min_y;
        while (by <= block_max_y) : (by += 1) {
            var bx = block_min_x;
            while (bx <= block_max_x) : (bx += 1) {
                var bz = block_min_z;
                while (bz <= block_max_z) : (bz += 1) {
                    const shape = terrain(bx, by, bz);
                    if (!shape.isEmpty()) {
                        // Create AABB relative to block position
                        const block_x: f64 = @floatFromInt(bx);
                        const block_y: f64 = @floatFromInt(by);
                        const block_z: f64 = @floatFromInt(bz);

                        const relative_aabb = VoxelShapeAABB{
                            .min_x = min_x - block_x,
                            .min_y = min_y - block_y,
                            .min_z = min_z - block_z,
                            .max_x = max_x - block_x,
                            .max_y = max_y - block_y,
                            .max_z = max_z - block_z,
                        };

                        // Use VoxelShape.collide for accurate collision
                        result = shape.collide(.y, relative_aabb, result);
                    }
                }
            }
        }

        return @floatCast(result);
    }

    /// Collide on X axis - wrapper for collideHorizontal
    fn collideX(self: *Self, terrain: TerrainQuery, x: f32, y: f32, z: f32, half_width: f32, distance: f32) f32 {
        return self.collideHorizontal(terrain, .x, x, y, z, half_width, distance);
    }

    /// Collide on Z axis - wrapper for collideHorizontal
    fn collideZ(self: *Self, terrain: TerrainQuery, x: f32, y: f32, z: f32, half_width: f32, distance: f32) f32 {
        return self.collideHorizontal(terrain, .z, x, y, z, half_width, distance);
    }

    /// Collide on horizontal axis (X or Z) - returns how far the entity can actually move
    /// Unified collision code for both X and Z axes, using VoxelShape collision
    fn collideHorizontal(self: *Self, terrain: TerrainQuery, axis: Axis, x: f32, y: f32, z: f32, half_width: f32, distance: f32) f32 {
        if (@abs(distance) < EPSILON) return 0;

        // Entity AABB bounds
        const min_x = x - half_width;
        const max_x = x + half_width;
        const min_y = y;
        const max_y = y + self.height;
        const min_z = z - half_width;
        const max_z = z + half_width;

        // Expand AABB in movement direction
        const expanded_min_x = if (axis == .x and distance < 0) min_x + distance else min_x;
        const expanded_max_x = if (axis == .x and distance > 0) max_x + distance else max_x;
        const expanded_min_z = if (axis == .z and distance < 0) min_z + distance else min_z;
        const expanded_max_z = if (axis == .z and distance > 0) max_z + distance else max_z;

        const block_min_x: i32 = @intFromFloat(@floor(expanded_min_x));
        const block_max_x: i32 = @intFromFloat(@floor(expanded_max_x));
        const block_min_y: i32 = @intFromFloat(@floor(min_y));
        const block_max_y: i32 = @intFromFloat(@floor(max_y));
        const block_min_z: i32 = @intFromFloat(@floor(expanded_min_z));
        const block_max_z: i32 = @intFromFloat(@floor(expanded_max_z));

        var result: f64 = distance;

        // Convert local Axis to VoxelShape Axis
        const shape_axis: VoxelShapeAxis = switch (axis) {
            .x => .x,
            .y => .y,
            .z => .z,
        };

        // Check all blocks in the expanded region
        var by = block_min_y;
        while (by <= block_max_y) : (by += 1) {
            var bx = block_min_x;
            while (bx <= block_max_x) : (bx += 1) {
                var bz = block_min_z;
                while (bz <= block_max_z) : (bz += 1) {
                    const shape = terrain(bx, by, bz);
                    if (!shape.isEmpty()) {
                        // Create AABB relative to block position
                        const block_x: f64 = @floatFromInt(bx);
                        const block_y: f64 = @floatFromInt(by);
                        const block_z: f64 = @floatFromInt(bz);

                        const relative_aabb = VoxelShapeAABB{
                            .min_x = min_x - block_x,
                            .min_y = min_y - block_y,
                            .min_z = min_z - block_z,
                            .max_x = max_x - block_x,
                            .max_y = max_y - block_y,
                            .max_z = max_z - block_z,
                        };

                        // Use VoxelShape.collide for accurate collision
                        result = shape.collide(shape_axis, relative_aabb, result);
                    }
                }
            }
        }

        return @floatCast(result);
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