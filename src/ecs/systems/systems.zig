// ECS Systems module
// Systems operate on entities with specific component combinations

pub const animation_system = @import("animation_system.zig");
pub const aging_system = @import("aging_system.zig");
pub const breeding_system = @import("breeding_system.zig");
pub const health_system = @import("health_system.zig");
pub const ai_system = @import("ai_system.zig");
pub const physics_system = @import("physics_system.zig");
pub const render_prep_system = @import("render_prep_system.zig");
pub const player_input_system = @import("player_input_system.zig");
pub const player_movement_system = @import("player_movement_system.zig");
pub const cleanup_system = @import("cleanup_system.zig");
