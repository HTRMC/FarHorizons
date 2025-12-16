// KeyboardInput - polls keyboard state and calculates normalized movement vector

const std = @import("std");
const shared = @import("Shared");
const Vec2 = struct { x: f32, z: f32 };
const Window = @import("Window.zig").Window;
const InputConstants = @import("InputConstants.zig");

/// Input state
pub const Input = struct {
    forward: bool = false,
    backward: bool = false,
    left: bool = false,
    right: bool = false,
    jump: bool = false,
    shift: bool = false,
    sprint: bool = false,
};

pub const KeyboardInput = struct {
    const Self = @This();

    window: *Window,

    // Current key press state
    key_presses: Input = .{},

    // Normalized movement vector
    // x = left/right (-1 to 1), z = forward/backward (-1 to 1)
    move_vector: Vec2 = .{ .x = 0, .z = 0 },

    pub fn init(window: *Window) Self {
        return .{
            .window = window,
        };
    }

    /// Calculate impulse from positive/negative key pair
    fn calculateImpulse(positive: bool, negative: bool) f32 {
        if (positive == negative) {
            return 0.0;
        }
        return if (positive) 1.0 else -1.0;
    }

    /// Poll keyboard state and update move vector
    pub fn tick(self: *Self) void {
        // Poll key states
        self.key_presses = Input{
            .forward = self.window.isKeyPressed(InputConstants.KEY_W),
            .backward = self.window.isKeyPressed(InputConstants.KEY_S),
            .left = self.window.isKeyPressed(InputConstants.KEY_A),
            .right = self.window.isKeyPressed(InputConstants.KEY_D),
            .jump = self.window.isKeyPressed(InputConstants.KEY_SPACE),
            .shift = self.window.isKeyPressed(InputConstants.KEY_LEFT_SHIFT),
            .sprint = self.window.isKeyPressed(InputConstants.KEY_LEFT_CONTROL),
        };

        // Calculate impulses
        const forward_impulse = calculateImpulse(self.key_presses.forward, self.key_presses.backward);
        const left_impulse = calculateImpulse(self.key_presses.left, self.key_presses.right);

        // Normalize the vector
        const length_sq = left_impulse * left_impulse + forward_impulse * forward_impulse;
        if (length_sq > 1.0) {
            const length = @sqrt(length_sq);
            self.move_vector = .{
                .x = left_impulse / length,
                .z = forward_impulse / length,
            };
        } else {
            self.move_vector = .{
                .x = left_impulse,
                .z = forward_impulse,
            };
        }
    }

    pub fn getKeyPresses(self: *const Self) Input {
        return self.key_presses;
    }

    pub fn getMoveVector(self: *const Self) Vec2 {
        return self.move_vector;
    }
};
