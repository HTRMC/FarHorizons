// Entity spawn functions module
// Provides convenience functions for spawning entities with all required components

pub const cow = @import("cow.zig");
pub const player = @import("player.zig");

// Re-export common spawn functions
pub const spawnCow = cow.spawnCow;
pub const spawnBabyCow = cow.spawnBabyCow;
pub const spawnMooshroom = cow.spawnMooshroom;
pub const spawnBabyMooshroom = cow.spawnBabyMooshroom;
pub const spawnPlayer = player.spawnPlayer;
