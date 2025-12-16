// LocalPlayer - client-side player with input handling and aiStep

const std = @import("std");
const shared = @import("Shared");
const math = shared.math;
const Vec3 = math.Vec3;
const Player = shared.Player;
const Abilities = shared.Abilities;
const platform = @import("Platform");
const KeyboardInput = platform.KeyboardInput;

pub const LocalPlayer = struct {
    const Self = @This();

    // Vertical movement multiplier (from LocalPlayer.java:801)
    // Vertical speed = flyingSpeed * 3.0
    pub const VERTICAL_FLYING_MULTIPLIER: f32 = 3.0;

    // Base player
    player: Player = Player.init(),

    // Input handler
    input: *KeyboardInput,

    pub fn init(input: *KeyboardInput) Self {
        var local_player = Self{
            .input = input,
        };
        // Start in spectator-like flying mode
        local_player.player.abilities.flying = true;
        local_player.player.abilities.may_fly = true;
        return local_player;
    }

    // Forward Player methods
    pub fn getDeltaMovement(self: *const Self) Vec3 {
        return self.player.getDeltaMovement();
    }

    pub fn setDeltaMovement(self: *Self, movement: Vec3) void {
        self.player.setDeltaMovement(movement);
    }

    pub fn getYRot(self: *const Self) f32 {
        return self.player.getYRot();
    }

    pub fn setYRot(self: *Self, yaw: f32) void {
        self.player.setYRot(yaw);
    }

    pub fn getXRot(self: *const Self) f32 {
        return self.player.getXRot();
    }

    pub fn setXRot(self: *Self, pitch: f32) void {
        self.player.setXRot(pitch);
    }

    pub fn getAbilities(self: *Self) *Abilities {
        return self.player.getAbilities();
    }

    pub fn setPosition(self: *Self, pos: Vec3) void {
        self.player.setPosition(pos);
    }

    pub fn turn(self: *Self, yaw: f64, pitch: f64) void {
        self.player.turn(yaw, pitch);
    }

    pub fn setOldPosAndRot(self: *Self) void {
        self.player.setOldPosAndRot();
    }

    pub fn getPosition(self: *const Self, partial_tick: f32) Vec3 {
        return self.player.getPosition(partial_tick);
    }

    pub fn getViewYRot(self: *const Self, partial_tick: f32) f32 {
        return self.player.getViewYRot(partial_tick);
    }

    pub fn getViewXRot(self: *const Self, partial_tick: f32) f32 {
        return self.player.getViewXRot(partial_tick);
    }

    /// Main tick method - called each frame
    pub fn aiStep(self: *Self) void {
        // Update sprint state from input
        self.player.setSprinting(self.input.key_presses.sprint);

        const abilities = self.player.getAbilities();

        // Handle vertical movement when flying (LocalPlayer.java:794-801)
        if (abilities.flying) {
            var input_ya: i32 = 0;
            if (self.input.key_presses.shift) {
                input_ya -= 1;
            }
            if (self.input.key_presses.jump) {
                input_ya += 1;
            }
            if (input_ya != 0) {
                // Add vertical velocity: inputYa * flyingSpeed * 3.0
                const vertical_speed = @as(f32, @floatFromInt(input_ya)) * abilities.getFlyingSpeed() * VERTICAL_FLYING_MULTIPLIER;
                const movement = self.getDeltaMovement();
                self.setDeltaMovement(Vec3{
                    .x = movement.x,
                    .y = movement.y + vertical_speed,
                    .z = movement.z,
                });
            }
        }

        // Get movement input vector from keyboard
        const move_vec = self.input.getMoveVector();

        // Create input Vec3 (x = strafe, y = 0, z = forward)
        // x is strafe (left/right), z is forward/backward
        const input = Vec3{
            .x = move_vec.x, // left/right
            .y = 0,
            .z = move_vec.z, // forward/backward
        };

        // Call player travel
        self.player.travel(input);
    }
};
