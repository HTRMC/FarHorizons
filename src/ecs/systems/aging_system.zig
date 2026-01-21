const World = @import("../world.zig").World;
const Age = @import("../components/age.zig").Age;
const PhysicsBody = @import("../components/physics.zig").PhysicsBody;
const RenderData = @import("../components/render_data.zig").RenderData;
const Breeding = @import("../components/breeding.zig").Breeding;

/// Aging system - handles baby growth and breeding cooldowns
/// Extracted from AgeableMob.tickAge()
pub fn run(world: *World) void {
    var entity_iter = world.entities.iterator();
    while (entity_iter.next()) |id| {
        const age = world.getComponentMut(Age, id) orelse continue;

        // Tick the age system, returns true if crossed baby/adult boundary
        const crossed_boundary = age.tick();

        if (crossed_boundary) {
            // Update physics body dimensions
            if (world.getComponentMut(PhysicsBody, id)) |body| {
                if (age.isBaby()) {
                    body.width *= Age.BABY_SCALE;
                    body.height *= Age.BABY_SCALE;
                } else {
                    // Grew up - restore adult size
                    body.width /= Age.BABY_SCALE;
                    body.height /= Age.BABY_SCALE;
                }
            }

            // Update render data
            if (world.getComponentMut(RenderData, id)) |render| {
                render.is_baby = age.isBaby();
            }
        }

        // Reset love mode if not adult
        if (age.age != 0) {
            if (world.getComponentMut(Breeding, id)) |breeding| {
                breeding.in_love = 0;
            }
        }
    }
}
