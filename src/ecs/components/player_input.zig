// PlayerInput - processed input state for player control (CLIENT-ONLY component)
// Stores the current frame's input state for use by movement systems

pub const PlayerInput = struct {
    const Self = @This();

    // Movement input (-1 to 1 range)
    move_forward: f32 = 0, // W/S: positive = forward
    move_strafe: f32 = 0, // A/D: positive = right

    // Action flags
    jump: bool = false,
    shift: bool = false, // Crouch/descend
    sprint: bool = false,

    pub fn init() Self {
        return .{};
    }

    /// Clear all input state
    pub fn clear(self: *Self) void {
        self.move_forward = 0;
        self.move_strafe = 0;
        self.jump = false;
        self.shift = false;
        self.sprint = false;
    }
};
