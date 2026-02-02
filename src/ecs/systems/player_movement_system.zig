// Player Movement System - applies input to velocity for player entities
// Handles flying vertical movement and travel logic from LocalPlayer.aiStep()

const std = @import("std");
const World = @import("../world.zig").World;
const PlayerInput = @import("../components/player_input.zig").PlayerInput;
const PlayerAbilities = @import("../components/player_abilities.zig").PlayerAbilities;
const Velocity = @import("../components/velocity.zig").Velocity;
const Transform = @import("../components/transform.zig").Transform;
const Tags = @import("../components/tags.zig").Tags;
const Vec3 = @import("Shared").Vec3;

// Constants from LocalPlayer/LivingEntity
const VERTICAL_FLYING_MULTIPLIER: f32 = 3.0;
const AIR_FRICTION: f64 = 0.91;
const FLYING_Y_DAMPENING: f64 = 0.6;

/// Player movement system - reads input and applies movement to velocity
/// For local player: Uses PlayerInput component
/// For remote players: Would use network state (future)
pub fn run(world: *World) void {
    var entity_iter = world.entities.iterator();
    while (entity_iter.next()) |id| {
        const tags = world.getComponent(Tags, id) orelse continue;
        if (!tags.is_player) continue;

        const abilities = world.getComponentMut(PlayerAbilities, id) orelse continue;
        const velocity = world.getComponentMut(Velocity, id) orelse continue;
        const transform = world.getComponent(Transform, id) orelse continue;

        // Get input based on whether this is a local player
        var input_forward: f32 = 0;
        var input_strafe: f32 = 0;
        var input_jump: bool = false;
        var input_shift: bool = false;
        var input_sprint: bool = false;

        if (tags.is_local_player) {
            // Local player uses PlayerInput component
            const input = world.getComponent(PlayerInput, id) orelse continue;
            input_forward = input.move_forward;
            input_strafe = input.move_strafe;
            input_jump = input.jump;
            input_shift = input.shift;
            input_sprint = input.sprint;
        } else {
            // Remote players would get input from network (future)
            continue;
        }

        // Update sprint state
        abilities.sprinting = input_sprint;

        // Handle vertical movement when flying (LocalPlayer.java:794-801)
        if (abilities.flying) {
            var input_ya: i32 = 0;
            if (input_shift) {
                input_ya -= 1;
            }
            if (input_jump) {
                input_ya += 1;
            }
            if (input_ya != 0) {
                // Add vertical velocity: inputYa * flyingSpeed * 3.0
                const vertical_speed = @as(f32, @floatFromInt(input_ya)) * abilities.getFlyingSpeed() * VERTICAL_FLYING_MULTIPLIER;
                velocity.linear.y += vertical_speed;
            }
        }

        // Create input Vec3 (x = strafe, y = 0, z = forward)
        const input_vec = Vec3{
            .x = input_strafe,
            .y = 0,
            .z = input_forward,
        };

        // Travel (flying movement)
        if (abilities.flying) {
            const original_y = velocity.linear.y;

            // travelFlying: moveRelative + air friction
            const air_speed = abilities.getEffectiveFlyingSpeed();
            const delta = getInputVector(input_vec, air_speed, transform.yaw);
            velocity.linear = velocity.linear.add(delta);

            // Apply air friction (we don't call move() here - physics system does that)
            velocity.linear.x = @floatCast(@as(f64, velocity.linear.x) * AIR_FRICTION);
            velocity.linear.y = @floatCast(@as(f64, velocity.linear.y) * AIR_FRICTION);
            velocity.linear.z = @floatCast(@as(f64, velocity.linear.z) * AIR_FRICTION);

            // Apply Y-axis dampening for flying (Player.java)
            velocity.linear.y = @floatCast(@as(f64, original_y) * FLYING_Y_DAMPENING);
        } else {
            // Non-flying travel (TODO: implement ground movement)
            const ground_speed = abilities.getEffectiveFlyingSpeed();
            const delta = getInputVector(input_vec, ground_speed, transform.yaw);
            velocity.linear = velocity.linear.add(delta);

            // Apply air friction
            velocity.linear.x = @floatCast(@as(f64, velocity.linear.x) * AIR_FRICTION);
            velocity.linear.y = @floatCast(@as(f64, velocity.linear.y) * AIR_FRICTION);
            velocity.linear.z = @floatCast(@as(f64, velocity.linear.z) * AIR_FRICTION);
        }
    }
}

/// Get movement vector from input, speed, and facing direction
fn getInputVector(input: Vec3, speed: f32, yaw: f32) Vec3 {
    const length_sq = input.lengthSquared();
    if (length_sq < 1.0e-7) {
        return Vec3.ZERO;
    }

    const movement = if (length_sq > 1.0)
        input.normalize().scale(speed)
    else
        input.scale(speed);

    const yaw_rad = yaw * std.math.pi / 180.0;
    const sin_yaw = @sin(yaw_rad);
    const cos_yaw = @cos(yaw_rad);

    return Vec3{
        .x = movement.x * cos_yaw - movement.z * sin_yaw,
        .y = movement.y,
        .z = movement.z * cos_yaw + movement.x * sin_yaw,
    };
}
