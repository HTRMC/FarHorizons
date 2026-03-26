pub const handshake = @import("protocols/handshake.zig");
pub const chunk_request = @import("protocols/chunk_request.zig");
pub const chunk_transmission = @import("protocols/chunk_transmission.zig");
pub const player_position = @import("protocols/player_position.zig");
pub const block_update = @import("protocols/block_update.zig");
pub const position_correction = @import("protocols/position_correction.zig");
pub const accept_teleport = @import("protocols/accept_teleport.zig");
pub const player_input = @import("protocols/player_input.zig");

/// Register all protocol handlers (call once at startup).
pub fn registerAll() void {
    handshake.register();
    chunk_request.register();
    chunk_transmission.register();
    player_position.register();
    block_update.register();
    position_correction.register();
    accept_teleport.register();
    player_input.register();
}
