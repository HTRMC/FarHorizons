const std = @import("std");
const zlm = @import("zlm");
const GameState = @import("../GameState.zig");
const Entity = GameState.Entity;
const WorldState = @import("../WorldState.zig");
const BlockState = WorldState.BlockState;
const Physics = @import("Physics.zig");

pub fn toggleMode(state: *GameState) void {
    if (state.game_mode == .survival) return; // no flying in survival
    const P = Entity.PLAYER;
    switch (state.mode) {
        .flying => {
            state.entities.pos[P] = .{
                state.camera.position.x,
                state.camera.position.y - GameState.EYE_OFFSET,
                state.camera.position.z,
            };
            state.entities.prev_pos[P] = state.entities.pos[P];
            state.entities.vel[P] = .{ 0.0, 0.0, 0.0 };
            state.entities.flags[P].on_ground = false;
            state.jump_requested = false;
            state.jump_cooldown = 5;
            state.combat.fall_start_y = state.entities.pos[P][1];
            state.mode = .walking;
        },
        .walking => {
            const epos = state.entities.pos[P];
            state.camera.position = zlm.Vec3.init(
                epos[0],
                epos[1] + GameState.EYE_OFFSET,
                epos[2],
            );
            state.prev_camera_pos = state.camera.position;
            state.mode = .flying;
        },
    }
}

pub fn updatePlayerMovement(state: *GameState, player: u32, move_speed: f32) void {
    updateWaterState(state);

    switch (state.mode) {
        .flying => {
            const forward_input = state.input_move[0];
            const right_input = state.input_move[2];
            const up_input = state.input_move[1];

            if (forward_input != 0.0 or right_input != 0.0 or up_input != 0.0) {
                const speed = move_speed * GameState.TICK_INTERVAL;
                state.camera.move(forward_input * speed, right_input * speed, up_input * speed);
            }

            state.entities.pos[player] = .{
                state.camera.position.x,
                state.camera.position.y - GameState.EYE_OFFSET,
                state.camera.position.z,
            };
        },
        .walking => {
            const flags = state.entities.flags[player];

            if (state.jump_cooldown > 0) {
                state.jump_cooldown -= 1;
            } else if (state.jump_requested and flags.on_ladder) {
                state.entities.vel[player][1] = Physics.LADDER_CLIMB_SPEED;
            } else if (state.jump_requested and !flags.in_water and flags.on_ground) {
                state.entities.vel[player][1] = GameState.PLAYER_JUMP_VELOCITY;
            }
            state.jump_requested = false;

            Physics.updateEntity(&state.entities, player, &state.chunk_map, state.input_move, state.camera.yaw.toRadians(), GameState.TICK_INTERVAL);

            const epos = state.entities.pos[player];
            state.camera.position = zlm.Vec3.init(
                epos[0],
                epos[1] + GameState.EYE_OFFSET,
                epos[2],
            );
        },
    }
}

pub fn updateWaterState(state: *GameState) void {
    const floori = Physics.floori;
    const P = Entity.PLAYER;
    const epos = state.entities.pos[P];

    // In flying mode, use camera position; in walking mode, use entity position
    const pos_x: f32 = if (state.mode == .flying) state.camera.position.x else epos[0];
    const pos_y: f32 = if (state.mode == .flying) state.camera.position.y - GameState.EYE_OFFSET else epos[1];
    const pos_z: f32 = if (state.mode == .flying) state.camera.position.z else epos[2];
    const px = floori(pos_x);
    const pz = floori(pos_z);

    const feet_block = state.chunk_map.getBlock(px, floori(pos_y), pz);
    const eye_block = state.chunk_map.getBlock(px, floori(pos_y + GameState.EYE_OFFSET), pz);

    state.entities.flags[P].in_water = (BlockState.getBlock(feet_block) == .water);
    state.entities.flags[P].eyes_in_water = (BlockState.getBlock(eye_block) == .water);

    // Ladder detection: check feet and mid-body
    state.entities.flags[P].on_ladder = isLadder(feet_block) or
        isLadder(state.chunk_map.getBlock(px, floori(pos_y + 0.9), pz));

    // Water vision time: MC 0-600 ticks @20Hz → 0-900 @30Hz
    if (state.entities.flags[P].eyes_in_water) {
        if (state.entities.water_vision_time[P] < 900) state.entities.water_vision_time[P] += 1;
    } else {
        state.entities.water_vision_time[P] = 0;
    }
}

pub fn waterVision(state: *const GameState) f32 {
    const t: f32 = @floatFromInt(state.entities.water_vision_time[Entity.PLAYER]);
    const a = std.math.clamp(t / 150.0, 0.0, 1.0);
    const b = std.math.clamp((t - 150.0) / 750.0, 0.0, 1.0);
    return a * 0.6 + b * 0.4;
}

fn isLadder(block_state: BlockState.StateId) bool {
    return BlockState.getBlock(block_state) == .ladder;
}
