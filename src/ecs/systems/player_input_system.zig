// Player Input System - copies current input state to PlayerInput component
// CLIENT-ONLY: Only processes entities with is_local_player = true
// The client sets world.current_input before each tick

const World = @import("../world.zig").World;
const PlayerInput = @import("../components/player_input.zig").PlayerInput;
const Tags = @import("../components/tags.zig").Tags;

/// Player input system - copies current_input to local player's PlayerInput component
/// Only processes the local player entity (is_local_player = true)
pub fn run(world: *World) void {
    // Find the local player entity
    const local_id = world.local_player_id orelse return;

    // Verify it's still a valid local player
    const tags = world.getComponent(Tags, local_id) orelse return;
    if (!tags.is_local_player) return;

    // Get the PlayerInput component
    const input = world.getComponentMut(PlayerInput, local_id) orelse return;

    // Copy from world's current input state (set by client)
    input.move_forward = world.current_input.move_forward;
    input.move_strafe = world.current_input.move_strafe;
    input.jump = world.current_input.jump;
    input.shift = world.current_input.shift;
    input.sprint = world.current_input.sprint;
}
