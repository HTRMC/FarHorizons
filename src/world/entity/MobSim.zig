const std = @import("std");
const GameState = @import("../GameState.zig");
const InventoryOps = GameState.InventoryOps;
const Entity = GameState.Entity;
const Item = GameState.Item;
const Physics = @import("Physics.zig");
const BlockState = @import("../WorldState.zig").BlockState;
const Radians = @import("../../math/Angle.zig").Radians;

const TICK_INTERVAL = GameState.TICK_INTERVAL;

pub fn updateEntities(state: *GameState) void {
    updateItemDrops(state);
    updateMobs(state);
    updateMobCombat(state);
}

pub fn updateItemDrops(state: *GameState) void {
    const P = Entity.PLAYER;
    const player_pos = state.entities.pos[P];
    const MERGE_RADIUS: f32 = 1.0;

    // Advance pickup ghost animations
    for (&state.inv.pickup_ghosts) |*ghost| {
        if (ghost.active) {
            ghost.tick += 1;
            if (ghost.tick >= 3) ghost.active = false;
        }
    }

    // Iterate backwards so swap-remove is safe
    var i: u32 = state.entities.count;
    while (i > 1) {
        i -= 1;
        if (state.entities.kind[i] != .item_drop) continue;

        // Age and despawn
        state.entities.age_ticks[i] += 1;
        if (state.entities.age_ticks[i] >= Entity.DESPAWN_TICKS) {
            state.entities.despawn(i);
            continue;
        }

        // Cooldown
        if (state.entities.pickup_cooldown[i] > 0) {
            state.entities.pickup_cooldown[i] -= 1;
        }

        // Physics
        state.entities.prev_pos[i] = state.entities.pos[i];
        Physics.updateEntity(&state.entities, i, &state.chunk_map, .{ 0, 0, 0 }, Radians{ .value = 0 }, TICK_INTERVAL);

        // AABB-based pickup (1.0 block horizontal, 0.5 block vertical from player feet to head)
        if (state.entities.pickup_cooldown[i] == 0) {
            const dp = state.entities.pos[i];
            const dx = @abs(dp[0] - player_pos[0]);
            const dz = @abs(dp[2] - player_pos[2]);
            const dy_min = dp[1] - (player_pos[1] + 1.8); // above player head
            const dy_max = dp[1] - (player_pos[1] - 0.5); // below player feet
            if (dx < 1.0 and dz < 1.0 and dy_min < 0.5 and dy_max > -0.5) {
                const item = Entity.ItemStack{
                    .block = state.entities.item_block[i],
                    .count = state.entities.item_count[i],
                    .durability = state.entities.item_durability[i],
                };
                if (InventoryOps.addToInventory(state, item)) {
                    // Spawn pickup ghost animation before despawning
                    spawnPickupGhost(state, i);
                    state.entities.despawn(i);
                    continue;
                }
            }
        }

        // Merge nearby item drops of the same type (skip tools — unique durability)
        // MC-style throttle: every 2 ticks if moving, every 40 ticks if stationary
        const merge_interval: u32 = if (state.entities.flags[i].on_ground) 40 else 2;
        if (!Item.isToolItem(state.entities.item_block[i]) and state.entities.item_count[i] < Entity.MAX_STACK and @mod(state.entities.age_ticks[i], merge_interval) == 0) {
            var j: u32 = 1;
            while (j < i) {
                if (state.entities.kind[j] != .item_drop or
                    state.entities.item_block[j] != state.entities.item_block[i] or
                    Item.isToolItem(state.entities.item_block[j]))
                {
                    j += 1;
                    continue;
                }
                const dp = state.entities.pos[j];
                const ip = state.entities.pos[i];
                const mdx = dp[0] - ip[0];
                const mdy = dp[1] - ip[1];
                const mdz = dp[2] - ip[2];
                if (mdx * mdx + mdy * mdy + mdz * mdz < MERGE_RADIUS * MERGE_RADIUS) {
                    // Merge newer (i) into older (j) so the grounded item survives
                    const space = Entity.MAX_STACK - state.entities.item_count[j];
                    if (space > 0) {
                        const transfer = @min(space, state.entities.item_count[i]);
                        state.entities.item_count[j] += transfer;
                        state.entities.item_count[i] -= transfer;
                        if (state.entities.item_count[i] == 0) {
                            state.entities.despawn(i);
                            break; // i is gone, move on
                        }
                    }
                }
                j += 1;
            }
        }
    }
}

pub fn updateMobs(state: *GameState) void {
    const MOB_JUMP_VELOCITY: f32 = 8.0;

    for (1..state.entities.count) |idx| {
        const i: u32 = @intCast(idx);
        if (state.entities.kind[i] != .pig) continue;

        // Physics
        state.entities.prev_pos[i] = state.entities.pos[i];

        const ai_state = state.entities.mob_ai_state[i];
        var input_move = [3]f32{ 0, 0, 0 };
        if (ai_state == .walking) {
            input_move[0] = 1.0; // forward
        }

        // Jump if walking, on ground, and blocked (low horizontal velocity)
        if (ai_state == .walking and state.entities.flags[i].on_ground) {
            const vx = state.entities.vel[i][0];
            const vz = state.entities.vel[i][2];
            if (vx * vx + vz * vz < 0.1) {
                state.entities.vel[i][1] = MOB_JUMP_VELOCITY;
            }
        }

        Physics.updateEntity(&state.entities, i, &state.chunk_map, input_move, state.entities.mob_target_yaw[i], TICK_INTERVAL);

        // Walk animation phase — accumulate based on horizontal distance moved
        state.entities.prev_walk_anim[i] = state.entities.walk_anim[i];
        const dx = state.entities.pos[i][0] - state.entities.prev_pos[i][0];
        const dz = state.entities.pos[i][2] - state.entities.prev_pos[i][2];
        const horiz_dist = @sqrt(dx * dx + dz * dz);
        if (ai_state == .walking and horiz_dist > 0.001) {
            state.entities.walk_anim[i] += horiz_dist * 10.0;
        } else {
            state.entities.walk_anim[i] *= 0.8;
        }

        // Smoothly rotate toward target yaw
        const current_yaw = state.entities.rotation[i][0].value;
        const target_yaw = state.entities.mob_target_yaw[i].value;
        var diff = target_yaw - current_yaw;
        // Normalize to [-pi, pi]
        while (diff > std.math.pi) diff -= std.math.tau;
        while (diff < -std.math.pi) diff += std.math.tau;
        const turn_speed: f32 = 0.15;
        if (@abs(diff) < turn_speed) {
            state.entities.rotation[i][0] = state.entities.mob_target_yaw[i];
        } else {
            state.entities.rotation[i][0] = state.entities.rotation[i][0].offset(if (diff > 0) turn_speed else -turn_speed);
        }

        // AI timer
        if (state.entities.mob_ai_timer[i] > 0) {
            state.entities.mob_ai_timer[i] -= 1;
        } else {
            // Switch state
            if (ai_state == .idle) {
                state.entities.mob_ai_state[i] = .walking;
                // Pick random yaw using game_time + entity index as seed
                const seed = @as(u32, @bitCast(@as(i32, @truncate(state.game_time)))) +% i *% 2654435761;
                const angle_bits = seed *% 1103515245 +% 12345;
                state.entities.mob_target_yaw[i] = .{ .value = @as(f32, @floatFromInt(@mod(@as(i32, @bitCast(angle_bits >> 16)), @as(i32, 628)))) / 100.0 };
                // Walk for 60-150 ticks (2-5s)
                const timer_bits = angle_bits *% 1103515245 +% 12345;
                state.entities.mob_ai_timer[i] = @as(u16, @intCast(60 + (timer_bits >> 16) % 91));
            } else {
                state.entities.mob_ai_state[i] = .idle;
                // Idle for 60-300 ticks (2-10s)
                const seed = @as(u32, @bitCast(@as(i32, @truncate(state.game_time)))) +% i *% 2654435761;
                const timer_bits = seed *% 1103515245 +% 12345;
                state.entities.mob_ai_timer[i] = @as(u16, @intCast(60 + (timer_bits >> 16) % 241));
            }
        }
    }
}

pub fn updateMobCombat(state: *GameState) void {
    // Tick down hurt_time and despawn dead mobs (iterate backwards for safe despawn)
    var i: u32 = state.entities.count;
    while (i > 1) {
        i -= 1;
        if (state.entities.kind[i] != .pig) continue;

        if (state.entities.hurt_time[i] > 0) {
            state.entities.hurt_time[i] -= 1;
        }

        if (state.entities.mob_health[i] <= 0) {
            state.entities.despawn(i);
        }
    }
}

pub fn spawnPickupGhost(state: *GameState, entity_idx: u32) void {
    // Find first inactive slot (or oldest if all active)
    var best: usize = 0;
    var best_tick: u8 = 0;
    for (state.inv.pickup_ghosts, 0..) |ghost, idx| {
        if (!ghost.active) {
            best = idx;
            break;
        }
        if (ghost.tick > best_tick) {
            best_tick = ghost.tick;
            best = idx;
        }
    }
    state.inv.pickup_ghosts[best] = .{
        .active = true,
        .start_pos = state.entities.render_pos[entity_idx],
        .block = state.entities.item_block[entity_idx],
        .item_count = state.entities.item_count[entity_idx],
        .bob_offset = state.entities.bob_offset[entity_idx],
        .age_ticks = state.entities.age_ticks[entity_idx],
        .tick = 0,
    };
}
