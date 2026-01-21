const std = @import("std");
const World = @import("../world.zig").World;
const AIState = @import("../components/ai.zig").AIState;
const GoalType = @import("../components/ai.zig").GoalType;
const GoalEntry = @import("../components/ai.zig").GoalEntry;
const RandomStrollData = @import("../components/ai.zig").RandomStrollData;
const LookAtPlayerData = @import("../components/ai.zig").LookAtPlayerData;
const RandomLookAroundData = @import("../components/ai.zig").RandomLookAroundData;
const PanicData = @import("../components/ai.zig").PanicData;
const Transform = @import("../components/transform.zig").Transform;
const Velocity = @import("../components/velocity.zig").Velocity;
const Health = @import("../components/health.zig").Health;
const LookControlState = @import("../components/look_control.zig").LookControlState;
const HeadRotation = @import("../components/head_rotation.zig").HeadRotation;
const Jump = @import("../components/jump.zig").Jump;
const Vec3 = @import("Shared").Vec3;
const EntityId = @import("../entity.zig").EntityId;

/// AI system - handles goal selection and execution
/// Replaces GoalSelector with enum-based dispatch
pub fn run(world: *World) void {
    var entity_iter = world.entities.iterator();
    while (entity_iter.next()) |id| {
        const ai_state = world.getComponentMut(AIState, id) orelse continue;

        // Update player target position
        ai_state.player_target_pos = world.player_position;

        // Phase 1: Stop goals that can't continue
        for (ai_state.getGoals(), 0..) |*goal, idx| {
            if (goal.is_running) {
                if (!canContinueToUse(world, id, goal, ai_state)) {
                    stopGoal(world, id, goal, ai_state);
                    goal.is_running = false;
                    ai_state.unlockFlags(idx);
                }
            }
        }

        // Phase 2: Try to start new goals
        for (ai_state.getGoals(), 0..) |*goal, idx| {
            if (!goal.is_running) {
                if (ai_state.canAcquireFlags(idx) and canUse(world, id, goal, ai_state)) {
                    ai_state.acquireFlags(idx);
                    startGoal(world, id, goal, ai_state);
                    goal.is_running = true;
                }
            }
        }

        // Phase 3: Tick running goals
        for (ai_state.getGoals()) |*goal| {
            if (goal.is_running) {
                tickGoal(world, id, goal, ai_state);
            }
        }

        // Tick look control
        tickLookControl(world, id);

        // Update body rotation
        updateBodyRotation(world, id);
    }
}

// =====================
// Goal behavior functions (enum dispatch)
// =====================

fn canUse(world: *World, id: EntityId, goal: *GoalEntry, ai_state: *AIState) bool {
    return switch (goal.goal_type) {
        .random_stroll => canUseRandomStroll(&goal.data.random_stroll, ai_state),
        .look_at_player => canUseLookAtPlayer(world, id, &goal.data.look_at_player, ai_state),
        .random_look_around => canUseRandomLookAround(&goal.data.random_look_around, ai_state),
        .panic => canUsePanic(world, id, &goal.data.panic),
    };
}

fn canContinueToUse(world: *World, id: EntityId, goal: *GoalEntry, ai_state: *AIState) bool {
    return switch (goal.goal_type) {
        .random_stroll => canContinueRandomStroll(world, id, &goal.data.random_stroll),
        .look_at_player => canContinueLookAtPlayer(world, id, &goal.data.look_at_player, ai_state),
        .random_look_around => canContinueRandomLookAround(&goal.data.random_look_around),
        .panic => canContinuePanic(world, id, &goal.data.panic),
    };
}

fn startGoal(world: *World, id: EntityId, goal: *GoalEntry, ai_state: *AIState) void {
    switch (goal.goal_type) {
        .random_stroll => {},
        .look_at_player => startLookAtPlayer(&goal.data.look_at_player, ai_state),
        .random_look_around => startRandomLookAround(&goal.data.random_look_around, ai_state),
        .panic => startPanic(world, id, &goal.data.panic, ai_state),
    }
}

fn tickGoal(world: *World, id: EntityId, goal: *GoalEntry, _: *AIState) void {
    switch (goal.goal_type) {
        .random_stroll => tickRandomStroll(world, id, &goal.data.random_stroll),
        .look_at_player => tickLookAtPlayer(world, id, &goal.data.look_at_player),
        .random_look_around => tickRandomLookAround(world, id, &goal.data.random_look_around),
        .panic => tickPanic(world, id, &goal.data.panic),
    }
}

fn stopGoal(world: *World, id: EntityId, goal: *GoalEntry, ai_state: *AIState) void {
    _ = ai_state;
    switch (goal.goal_type) {
        .random_stroll => stopRandomStroll(world, id, &goal.data.random_stroll),
        .look_at_player => stopLookAtPlayer(&goal.data.look_at_player),
        .random_look_around => {},
        .panic => stopPanic(&goal.data.panic),
    }
}

// =====================
// RandomStroll implementation
// =====================

fn canUseRandomStroll(data: *RandomStrollData, ai_state: *AIState) bool {
    if (data.cooldown > 0) {
        data.cooldown -= 1;
        return false;
    }

    if (ai_state.nextRandom() % data.interval != 0) {
        return false;
    }

    // Pick random target
    const range: f32 = 10.0;
    const angle = ai_state.randomFloat() * std.math.pi * 2.0;
    const distance = ai_state.randomFloat() * range + 2.0;

    // Target will be relative to current position (set in tick)
    data.target_x = @cos(angle) * distance;
    data.target_z = @sin(angle) * distance;
    data.has_target = true;

    return true;
}

fn canContinueRandomStroll(world: *World, id: EntityId, data: *RandomStrollData) bool {
    if (!data.has_target) return false;

    const transform = world.getComponent(Transform, id) orelse return false;
    const dx = data.target_x - transform.position.x;
    const dz = data.target_z - transform.position.z;
    const dist_sq = dx * dx + dz * dz;

    return dist_sq >= 1.0;
}

fn tickRandomStroll(world: *World, id: EntityId, data: *RandomStrollData) void {
    if (!data.has_target) return;

    const transform = world.getComponentMut(Transform, id) orelse return;
    const velocity = world.getComponentMut(Velocity, id) orelse return;

    // On first tick, convert relative target to absolute
    if (data.target_x < -1000 or data.target_x > 1000) {
        data.target_x += transform.position.x;
        data.target_z += transform.position.z;
    }

    const dx = data.target_x - transform.position.x;
    const dz = data.target_z - transform.position.z;
    const dist = @sqrt(dx * dx + dz * dz);

    if (dist < 0.5) {
        data.has_target = false;
        return;
    }

    // Check if blocked and should jump
    if (velocity.horizontally_blocked and velocity.on_ground) {
        if (world.getComponentMut(Jump, id)) |jump| {
            if (jump.canJump(true)) {
                velocity.linear.y = jump.startJump();
                velocity.on_ground = false;
            }
        }
    }

    // Calculate target yaw
    const target_yaw = std.math.atan2(dx, -dz) * 180.0 / std.math.pi;

    // Smooth rotation
    var yaw_diff = target_yaw - transform.yaw;
    while (yaw_diff > 180.0) yaw_diff -= 360.0;
    while (yaw_diff < -180.0) yaw_diff += 360.0;

    const abs_yaw_diff = @abs(yaw_diff);
    const max_turn: f32 = 30.0;
    const clamped_diff = std.math.clamp(yaw_diff, -max_turn, max_turn);
    transform.yaw += clamped_diff;

    // Only walk when roughly facing target
    if (abs_yaw_diff < 45.0) {
        const facing_rad = transform.yaw * std.math.pi / 180.0;
        const forward_x = @sin(facing_rad);
        const forward_z = -@cos(facing_rad);

        const alignment = 1.0 - (abs_yaw_diff / 45.0) * 0.5;
        const distance_factor = std.math.clamp(dist / 3.0, 0.3, 1.0);
        const move_speed = data.speed * alignment * distance_factor;

        velocity.linear.x = forward_x * move_speed;
        velocity.linear.z = forward_z * move_speed;
    } else {
        velocity.linear.x = 0;
        velocity.linear.z = 0;
    }
}

fn stopRandomStroll(world: *World, id: EntityId, data: *RandomStrollData) void {
    _ = world;
    _ = id;
    data.has_target = false;
    data.cooldown = data.interval / 2;
}

// =====================
// LookAtPlayer implementation
// =====================

fn canUseLookAtPlayer(world: *World, id: EntityId, data: *LookAtPlayerData, ai_state: *AIState) bool {
    if (ai_state.randomFloat() >= data.probability) return false;

    if (ai_state.player_target_pos) |player_pos| {
        const transform = world.getComponent(Transform, id) orelse return false;
        const dx = player_pos.x - transform.position.x;
        const dy = player_pos.y - transform.position.y;
        const dz = player_pos.z - transform.position.z;
        const dist_sq = dx * dx + dy * dy + dz * dz;

        if (dist_sq <= data.look_distance * data.look_distance) {
            data.target_pos = player_pos;
            return true;
        }
    }

    return false;
}

fn canContinueLookAtPlayer(world: *World, id: EntityId, data: *LookAtPlayerData, ai_state: *AIState) bool {
    if (data.target_pos == null) return false;
    if (data.look_time <= 0) return false;

    if (ai_state.player_target_pos) |player_pos| {
        const transform = world.getComponent(Transform, id) orelse return false;
        const dx = player_pos.x - transform.position.x;
        const dy = player_pos.y - transform.position.y;
        const dz = player_pos.z - transform.position.z;
        const dist_sq = dx * dx + dy * dy + dz * dz;

        if (dist_sq > data.look_distance * data.look_distance) {
            return false;
        }

        data.target_pos = player_pos;
        return true;
    }

    return false;
}

fn startLookAtPlayer(data: *LookAtPlayerData, ai_state: *AIState) void {
    data.look_time = @intCast(40 + ai_state.nextRandom() % 40);
}

fn tickLookAtPlayer(world: *World, id: EntityId, data: *LookAtPlayerData) void {
    if (data.target_pos) |pos| {
        if (world.getComponentMut(LookControlState, id)) |look| {
            look.setLookAt(pos.x, pos.y, pos.z);
        }
        data.look_time -= 1;
    }
}

fn stopLookAtPlayer(data: *LookAtPlayerData) void {
    data.target_pos = null;
}

// =====================
// RandomLookAround implementation
// =====================

fn canUseRandomLookAround(data: *RandomLookAroundData, ai_state: *AIState) bool {
    _ = data;
    return ai_state.randomFloat() < 0.02;
}

fn canContinueRandomLookAround(data: *RandomLookAroundData) bool {
    return data.look_time >= 0;
}

fn startRandomLookAround(data: *RandomLookAroundData, ai_state: *AIState) void {
    const angle = ai_state.randomFloat() * std.math.pi * 2.0;
    data.rel_x = @cos(angle);
    data.rel_z = @sin(angle);
    data.look_time = @intCast(20 + ai_state.nextRandom() % 20);
}

fn tickRandomLookAround(world: *World, id: EntityId, data: *RandomLookAroundData) void {
    data.look_time -= 1;

    const transform = world.getComponent(Transform, id) orelse return;
    if (world.getComponentMut(LookControlState, id)) |look| {
        look.setLookAt(
            transform.position.x + data.rel_x,
            transform.position.y + 1.0,
            transform.position.z + data.rel_z,
        );
    }
}

// =====================
// Panic implementation
// =====================

fn canUsePanic(world: *World, id: EntityId, data: *PanicData) bool {
    _ = data;
    if (world.getComponent(Health, id)) |health| {
        return health.wasRecentlyHurt();
    }
    return false;
}

fn canContinuePanic(world: *World, id: EntityId, data: *PanicData) bool {
    if (!data.is_fleeing) return false;
    if (world.getComponent(Health, id)) |health| {
        return health.wasRecentlyHurt();
    }
    return false;
}

fn startPanic(world: *World, id: EntityId, data: *PanicData, ai_state: *AIState) void {
    const transform = world.getComponent(Transform, id) orelse return;
    const health = world.getComponent(Health, id) orelse return;

    if (health.last_hurt_by_pos) |attacker_pos| {
        // Flee away from attacker
        const dx = transform.position.x - attacker_pos.x;
        const dz = transform.position.z - attacker_pos.z;
        const dist = @sqrt(dx * dx + dz * dz);

        if (dist > 0.1) {
            data.target_x = transform.position.x + (dx / dist) * 10.0;
            data.target_z = transform.position.z + (dz / dist) * 10.0;
        } else {
            // Random direction if too close
            const angle = ai_state.randomFloat() * std.math.pi * 2.0;
            data.target_x = transform.position.x + @cos(angle) * 10.0;
            data.target_z = transform.position.z + @sin(angle) * 10.0;
        }
    }

    data.is_fleeing = true;
}

fn tickPanic(world: *World, id: EntityId, data: *PanicData) void {
    const transform = world.getComponentMut(Transform, id) orelse return;
    const velocity = world.getComponentMut(Velocity, id) orelse return;

    const dx = data.target_x - transform.position.x;
    const dz = data.target_z - transform.position.z;
    const dist = @sqrt(dx * dx + dz * dz);

    if (dist < 1.0) {
        data.is_fleeing = false;
        return;
    }

    // Face flee direction
    const target_yaw = std.math.atan2(dx, -dz) * 180.0 / std.math.pi;
    var yaw_diff = target_yaw - transform.yaw;
    while (yaw_diff > 180.0) yaw_diff -= 360.0;
    while (yaw_diff < -180.0) yaw_diff += 360.0;
    transform.yaw += std.math.clamp(yaw_diff, -45.0, 45.0);

    // Run away at panic speed
    const facing_rad = transform.yaw * std.math.pi / 180.0;
    velocity.linear.x = @sin(facing_rad) * data.speed;
    velocity.linear.z = -@cos(facing_rad) * data.speed;
}

fn stopPanic(data: *PanicData) void {
    data.is_fleeing = false;
}

// =====================
// Look control tick
// =====================

fn tickLookControl(world: *World, id: EntityId) void {
    const look = world.getComponentMut(LookControlState, id) orelse return;
    const transform = world.getComponent(Transform, id) orelse return;
    const head = world.getComponentMut(HeadRotation, id) orelse return;

    head.savePrevious();

    if (look.look_at_cooldown > 0) {
        look.look_at_cooldown -= 1;

        // Calculate target yaw
        if (look.getTargetYaw(transform.position)) |target_yaw| {
            const target_rad = target_yaw * std.math.pi / 180.0;
            const body_yaw_rad = transform.yaw * std.math.pi / 180.0;
            var rel_yaw = -(target_rad - body_yaw_rad);

            while (rel_yaw > std.math.pi) rel_yaw -= 2.0 * std.math.pi;
            while (rel_yaw < -std.math.pi) rel_yaw += 2.0 * std.math.pi;

            const max_head_yaw: f32 = 75.0 * std.math.pi / 180.0;
            rel_yaw = std.math.clamp(rel_yaw, -max_head_yaw, max_head_yaw);

            const max_rot = look.y_max_rot_speed * std.math.pi / 180.0;
            head.yaw = LookControlState.rotateTowards(head.yaw, rel_yaw, max_rot);
        }

        // Calculate target pitch
        if (look.getTargetPitch(transform.position)) |target_pitch| {
            const target_rad = -target_pitch * std.math.pi / 180.0;
            const max_pitch: f32 = 40.0 * std.math.pi / 180.0;
            const clamped = std.math.clamp(target_rad, -max_pitch, max_pitch);
            const max_rot = look.x_max_rot_angle * std.math.pi / 180.0;
            head.pitch = LookControlState.rotateTowards(head.pitch, clamped, max_rot);
        }
    } else {
        // Return head to center when not looking at anything
        const idle_speed: f32 = 5.0 * std.math.pi / 180.0;
        head.yaw = LookControlState.rotateTowards(head.yaw, 0, idle_speed);
        head.pitch = LookControlState.rotateTowards(head.pitch, 0, idle_speed);
    }
}

// =====================
// Body rotation control
// =====================

const MAX_HEAD_YAW: f32 = 75.0 * std.math.pi / 180.0;
const HEAD_STABLE_ANGLE: f32 = 15.0 * std.math.pi / 180.0;
const BODY_TURN_DELAY: u32 = 10;
const BODY_TURN_DURATION: u32 = 10;
const BODY_ROT_SPEED: f32 = 10.0 * std.math.pi / 180.0;

fn updateBodyRotation(world: *World, id: EntityId) void {
    const transform = world.getComponentMut(Transform, id) orelse return;
    const velocity = world.getComponent(Velocity, id) orelse return;
    const head = world.getComponentMut(HeadRotation, id) orelse return;

    const is_moving = velocity.isMoving();

    if (is_moving) {
        // When moving, clamp head to body
        head.yaw = std.math.clamp(head.yaw, -MAX_HEAD_YAW, MAX_HEAD_YAW);
        transform.last_stable_head_yaw = head.yaw;
        transform.head_stable_time = 0;
    } else {
        // When stationary, track head stability
        const head_moved = @abs(head.yaw - transform.last_stable_head_yaw) > HEAD_STABLE_ANGLE;

        if (head_moved) {
            transform.head_stable_time = 0;
            transform.last_stable_head_yaw = head.yaw;

            if (@abs(head.yaw) > MAX_HEAD_YAW * 0.5) {
                rotateBodyTowardHead(transform, head, MAX_HEAD_YAW);
            }
        } else {
            transform.head_stable_time += 1;

            if (transform.head_stable_time > BODY_TURN_DELAY) {
                const time_since_start = transform.head_stable_time - BODY_TURN_DELAY;
                const turn_progress = std.math.clamp(
                    @as(f32, @floatFromInt(time_since_start)) / @as(f32, @floatFromInt(BODY_TURN_DURATION)),
                    0.0,
                    1.0,
                );
                const max_angle = MAX_HEAD_YAW * (1.0 - turn_progress);
                rotateBodyTowardHead(transform, head, max_angle);
            }
        }
    }
}

fn rotateBodyTowardHead(transform: *Transform, head: *HeadRotation, max_angle: f32) void {
    if (@abs(head.yaw) > max_angle) {
        const excess = if (head.yaw > 0)
            head.yaw - max_angle
        else
            head.yaw + max_angle;

        const body_rotation = std.math.clamp(excess, -BODY_ROT_SPEED, BODY_ROT_SPEED);
        transform.yaw -= body_rotation * 180.0 / std.math.pi;
        head.yaw -= body_rotation;

        // Normalize body yaw
        while (transform.yaw > 360) transform.yaw -= 360;
        while (transform.yaw < 0) transform.yaw += 360;
    }
}
