const World = @import("../world.zig").World;
const Tags = @import("../components/tags.zig").Tags;
const EntityId = @import("../entity.zig").EntityId;

/// Cleanup system - destroys entities marked for removal
/// Runs in post_update phase after all game logic has finished
pub fn run(world: *World) void {
    // Collect entities to destroy (avoid mutating during iteration)
    var to_destroy: [256]EntityId = undefined;
    var count: usize = 0;

    var entity_iter = world.entities.iterator();
    while (entity_iter.next()) |id| {
        const tags = world.getComponent(Tags, id) orelse continue;
        if (tags.marked_for_removal) {
            if (count < to_destroy.len) {
                to_destroy[count] = id;
                count += 1;
            }
        }
    }

    for (to_destroy[0..count]) |id| {
        world.destroyEntity(id);
    }
}
