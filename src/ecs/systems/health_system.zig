const World = @import("../world.zig").World;
const Health = @import("../components/health.zig").Health;
const Tags = @import("../components/tags.zig").Tags;

/// Health system - handles invulnerability timers, hurt animation, and death
/// Extracted from LivingEntity.tick()
pub fn run(world: *World) void {
    var entity_iter = world.entities.iterator();
    while (entity_iter.next()) |id| {
        const health = world.getComponentMut(Health, id) orelse continue;

        // Tick health timers
        health.tick(world.tick_count);

        // Check for death
        if (health.current <= 0 and !health.dead) {
            health.die();

            // Mark entity for removal
            if (world.getComponentMut(Tags, id)) |tags| {
                tags.marked_for_removal = true;
            }
        }
    }
}
