const Camera = @import("renderer/Camera.zig");

const GameState = @This();

camera: Camera,

pub fn init(width: u32, height: u32) GameState {
    return .{ .camera = Camera.init(width, height) };
}
