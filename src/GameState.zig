const Camera = @import("renderer/Camera.zig");
const zlm = @import("zlm");

const GameState = @This();

camera: Camera,

pub fn init(width: u32, height: u32) GameState {
    var cam = Camera.init(width, height);
    cam.target = zlm.Vec3.init(0.0, 0.0, 0.0);
    cam.distance = 160.0;
    cam.elevation = 0.5;
    return .{ .camera = cam };
}
