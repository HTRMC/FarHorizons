const std = @import("std");
const World = @import("../world.zig").World;
const Transform = @import("../components/transform.zig").Transform;
const Velocity = @import("../components/velocity.zig").Velocity;
const PhysicsBody = @import("../components/physics.zig").PhysicsBody;
const Jump = @import("../components/jump.zig").Jump;
const VoxelShape = @import("Shared").VoxelShape;
const VoxelShapeAABB = VoxelShape.AABB;
const Axis = @import("Shared").voxel_shape.Axis;

const EPSILON: f32 = 1.0e-7;

/// Physics system - applies velocity, gravity, and collision detection
/// Extracted from Entity.applyPhysics()
pub fn run(world: *World) void {
    const terrain = world.terrain_query orelse return;

    var entity_iter = world.entities.iterator();
    while (entity_iter.next()) |id| {
        const transform = world.getComponentMut(Transform, id) orelse continue;
        const velocity = world.getComponentMut(Velocity, id) orelse continue;
        const body = world.getComponent(PhysicsBody, id) orelse continue;

        // Save previous transform values
        transform.savePrevious();

        // Apply physics
        applyPhysics(transform, velocity, body, terrain);

        // Tick jump system if present
        if (world.getComponentMut(Jump, id)) |jump| {
            jump.tick(velocity.on_ground);
        }
    }
}

fn applyPhysics(
    transform: *Transform,
    velocity: *Velocity,
    body: *const PhysicsBody,
    terrain: World.TerrainQuery,
) void {
    const half_width = body.halfWidth();

    // Get desired movement
    const move_x = velocity.linear.x;
    const move_y = velocity.linear.y;
    const move_z = velocity.linear.z;

    var current_x = transform.position.x;
    var current_y = transform.position.y;
    var current_z = transform.position.z;

    // Determine axis order: Y first, then larger horizontal component
    const test_x_before_z = @abs(move_x) >= @abs(move_z);

    // 1. Test Y axis first
    velocity.on_ground = false;
    const resolved_y = collideY(body, terrain, current_x, current_y, current_z, half_width, move_y);
    if (@abs(resolved_y - move_y) > EPSILON) {
        if (move_y < 0) {
            velocity.on_ground = true;
        }
        velocity.linear.y = 0;
    }
    current_y += resolved_y;

    // 2. Test horizontal axes in order of magnitude
    if (test_x_before_z) {
        const resolved_x = collideX(body, terrain, current_x, current_y, current_z, half_width, move_x);
        if (@abs(resolved_x - move_x) > EPSILON) {
            velocity.linear.x = 0;
        }
        current_x += resolved_x;

        const resolved_z = collideZ(body, terrain, current_x, current_y, current_z, half_width, move_z);
        if (@abs(resolved_z - move_z) > EPSILON) {
            velocity.linear.z = 0;
        }
        current_z += resolved_z;
    } else {
        const resolved_z = collideZ(body, terrain, current_x, current_y, current_z, half_width, move_z);
        if (@abs(resolved_z - move_z) > EPSILON) {
            velocity.linear.z = 0;
        }
        current_z += resolved_z;

        const resolved_x = collideX(body, terrain, current_x, current_y, current_z, half_width, move_x);
        if (@abs(resolved_x - move_x) > EPSILON) {
            velocity.linear.x = 0;
        }
        current_x += resolved_x;
    }

    // Step-up mechanic
    const x_was_blocked = @abs(velocity.linear.x) < EPSILON and @abs(move_x) > EPSILON;
    const z_was_blocked = @abs(velocity.linear.z) < EPSILON and @abs(move_z) > EPSILON;
    velocity.horizontally_blocked = false;

    if (velocity.on_ground and (x_was_blocked or z_was_blocked)) {
        const step_y = transform.position.y + body.step_height;
        var step_x = transform.position.x;
        var step_z = transform.position.z;

        const step_move_x = collideX(body, terrain, step_x, step_y, step_z, half_width, move_x);
        step_x += step_move_x;
        const step_move_z = collideZ(body, terrain, step_x, step_y, step_z, half_width, move_z);
        step_z += step_move_z;

        const original_dist_sq = (current_x - transform.position.x) * (current_x - transform.position.x) +
            (current_z - transform.position.z) * (current_z - transform.position.z);
        const step_dist_sq = (step_x - transform.position.x) * (step_x - transform.position.x) +
            (step_z - transform.position.z) * (step_z - transform.position.z);

        if (step_dist_sq > original_dist_sq + EPSILON) {
            const step_down_y = collideY(body, terrain, step_x, step_y, step_z, half_width, -body.step_height - 0.01);
            current_x = step_x;
            current_y = step_y + step_down_y;
            current_z = step_z;

            if (@abs(step_move_x) > EPSILON) velocity.linear.x = move_x;
            if (@abs(step_move_z) > EPSILON) velocity.linear.z = move_z;
        } else {
            velocity.horizontally_blocked = true;
        }
    }

    // Step-down mechanic
    if (!velocity.on_ground and @abs(move_y) < EPSILON) {
        const step_down_y = collideY(body, terrain, current_x, current_y, current_z, half_width, -body.step_height - 0.01);
        if (@abs(step_down_y + body.step_height + 0.01) > EPSILON) {
            current_y += step_down_y;
            velocity.on_ground = true;
            velocity.linear.y = 0;
        }
    }

    // Update position
    transform.position.x = current_x;
    transform.position.y = current_y;
    transform.position.z = current_z;

    // Apply gravity and drag
    velocity.linear.y -= body.effectiveGravity();
    velocity.applyDrag(body.drag);

    // Apply ground friction
    if (velocity.on_ground) {
        velocity.applyFriction(body.ground_friction);
    }
}

fn collideY(body: *const PhysicsBody, terrain: World.TerrainQuery, x: f32, y: f32, z: f32, half_width: f32, move_y: f32) f32 {
    if (@abs(move_y) < EPSILON) return 0;

    const min_x = x - half_width;
    const max_x = x + half_width;
    const min_y = y;
    const max_y = y + body.height;
    const min_z = z - half_width;
    const max_z = z + half_width;

    const expanded_min_y = if (move_y < 0) min_y + move_y else min_y;
    const expanded_max_y = if (move_y > 0) max_y + move_y else max_y;

    const block_min_x: i32 = @intFromFloat(@floor(min_x));
    const block_max_x: i32 = @intFromFloat(@floor(max_x));
    const block_min_y: i32 = @intFromFloat(@floor(expanded_min_y));
    const block_max_y: i32 = @intFromFloat(@floor(expanded_max_y));
    const block_min_z: i32 = @intFromFloat(@floor(min_z));
    const block_max_z: i32 = @intFromFloat(@floor(max_z));

    var result: f64 = move_y;

    var by = block_min_y;
    while (by <= block_max_y) : (by += 1) {
        var bx = block_min_x;
        while (bx <= block_max_x) : (bx += 1) {
            var bz = block_min_z;
            while (bz <= block_max_z) : (bz += 1) {
                const shape = terrain(bx, by, bz);
                if (!shape.isEmpty()) {
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

                    result = shape.collide(.y, relative_aabb, result);
                }
            }
        }
    }

    return @floatCast(result);
}

fn collideX(body: *const PhysicsBody, terrain: World.TerrainQuery, x: f32, y: f32, z: f32, half_width: f32, distance: f32) f32 {
    return collideHorizontal(body, terrain, .x, x, y, z, half_width, distance);
}

fn collideZ(body: *const PhysicsBody, terrain: World.TerrainQuery, x: f32, y: f32, z: f32, half_width: f32, distance: f32) f32 {
    return collideHorizontal(body, terrain, .z, x, y, z, half_width, distance);
}

fn collideHorizontal(body: *const PhysicsBody, terrain: World.TerrainQuery, axis: Axis, x: f32, y: f32, z: f32, half_width: f32, distance: f32) f32 {
    if (@abs(distance) < EPSILON) return 0;

    const min_x = x - half_width;
    const max_x = x + half_width;
    const min_y = y;
    const max_y = y + body.height;
    const min_z = z - half_width;
    const max_z = z + half_width;

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

    var by = block_min_y;
    while (by <= block_max_y) : (by += 1) {
        var bx = block_min_x;
        while (bx <= block_max_x) : (bx += 1) {
            var bz = block_min_z;
            while (bz <= block_max_z) : (bz += 1) {
                const shape = terrain(bx, by, bz);
                if (!shape.isEmpty()) {
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

                    result = shape.collide(axis, relative_aabb, result);
                }
            }
        }
    }

    return @floatCast(result);
}
