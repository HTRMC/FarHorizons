const World = @import("../world.zig").World;
const Transform = @import("../components/transform.zig").Transform;
const Velocity = @import("../components/velocity.zig").Velocity;
const Animation = @import("../components/animation.zig").Animation;
const HeadRotation = @import("../components/head_rotation.zig").HeadRotation;
const RenderData = @import("../components/render_data.zig").RenderData;
const Age = @import("../components/age.zig").Age;

/// Render preparation system - prepares entity data for GPU upload
/// This system runs in the render_prep phase, after all game logic
pub fn run(world: *World) void {
    // This system primarily exists as a hook for future optimizations:
    // - Batching entities by render type
    // - Frustum culling
    // - LOD selection
    // - Instance buffer preparation

    // For now, we just ensure render data is up to date
    var entity_iter = world.entities.iterator();
    while (entity_iter.next()) |id| {
        const render = world.getComponentMut(RenderData, id) orelse continue;

        // Sync baby state from Age component
        if (world.getComponent(Age, id)) |age| {
            render.is_baby = age.isBaby();
        }
    }
}

/// Get render data for an entity (helper for EntityRenderer)
pub const EntityRenderState = struct {
    position_x: f32,
    position_y: f32,
    position_z: f32,
    yaw: f32,
    head_pitch: f32,
    head_yaw: f32,
    walk_animation: f32,
    walk_speed: f32,
    is_baby: bool,
    entity_type: RenderData.EntityType,
    model_type: RenderData.ModelType,
    texture_index: u8,
};

/// Compute interpolated render state for an entity
pub fn getRenderState(world: *World, id: @import("../entity.zig").EntityId, partial_tick: f32) ?EntityRenderState {
    const transform = world.getComponent(Transform, id) orelse return null;
    const render = world.getComponent(RenderData, id) orelse return null;

    // Get interpolated position
    const pos = transform.getInterpolatedPosition(partial_tick);
    const yaw = transform.getInterpolatedYaw(partial_tick);

    // Get interpolated head rotation
    var head_pitch: f32 = 0;
    var head_yaw: f32 = 0;
    if (world.getComponent(HeadRotation, id)) |head| {
        head_pitch = head.getInterpolatedPitch(partial_tick);
        head_yaw = head.getInterpolatedYaw(partial_tick);
    }

    // Get interpolated animation
    var walk_animation: f32 = 0;
    var walk_speed: f32 = 0;
    if (world.getComponent(Animation, id)) |anim| {
        walk_animation = anim.getInterpolatedWalkAnimation(partial_tick);
        walk_speed = anim.getInterpolatedWalkSpeed(partial_tick);
    }

    return .{
        .position_x = pos.x,
        .position_y = pos.y,
        .position_z = pos.z,
        .yaw = yaw,
        .head_pitch = head_pitch,
        .head_yaw = head_yaw,
        .walk_animation = walk_animation,
        .walk_speed = walk_speed,
        .is_baby = render.is_baby,
        .entity_type = render.entity_type,
        .model_type = render.model_type,
        .texture_index = render.texture_index,
    };
}
