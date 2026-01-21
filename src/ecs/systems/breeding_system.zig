const World = @import("../world.zig").World;
const Breeding = @import("../components/breeding.zig").Breeding;

/// Breeding system - handles love mode timers
/// Extracted from Animal.tick()
pub fn run(world: *World) void {
    var entity_iter = world.entities.iterator();
    while (entity_iter.next()) |id| {
        const breeding = world.getComponentMut(Breeding, id) orelse continue;

        // Tick breeding state, returns true if should spawn particles
        _ = breeding.tick();
        // TODO: Spawn heart particles at entity position when tick() returns true
    }
}
