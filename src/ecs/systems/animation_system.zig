const World = @import("../world.zig").World;
const Animation = @import("../components/animation.zig").Animation;
const Velocity = @import("../components/velocity.zig").Velocity;

/// Animation system - updates walk animation based on velocity
/// Extracted from Entity.zig tick()
pub fn run(world: *World) void {
    // Iterate over entities with both Animation and Velocity
    var entity_iter = world.entities.iterator();
    while (entity_iter.next()) |id| {
        const animation = world.getComponentMut(Animation, id) orelse continue;
        const velocity = world.getComponent(Velocity, id) orelse continue;

        // Save previous values for interpolation
        animation.savePrevious();

        // Update animation based on horizontal speed
        const horizontal_speed = velocity.horizontalSpeed();
        animation.update(horizontal_speed);

        // Tick animation counter
        animation.tick();
    }
}
