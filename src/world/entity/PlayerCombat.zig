const WorldState = @import("../../world/WorldState.zig");

pub const PlayerCombat = struct {
    break_progress: f32 = 0,
    breaking_pos: ?WorldState.WorldBlockPos = null,
    attack_held: bool = false,
    attack_damage: f32 = 1.0,
    health: f32 = 20.0,
    max_health: f32 = 20.0,
    air_supply: u16 = 300,
    max_air: u16 = 300,
    damage_cooldown: u8 = 0,
    entity_attack_cooldown: u8 = 0,
    fall_start_y: f32 = 0.0,
    was_on_ground: bool = true,
};
