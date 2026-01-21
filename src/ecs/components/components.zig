// ECS Component definitions
// Each component is a plain data struct extracted from the old entity hierarchy

pub const Transform = @import("transform.zig").Transform;
pub const Velocity = @import("velocity.zig").Velocity;
pub const PhysicsBody = @import("physics.zig").PhysicsBody;
pub const Health = @import("health.zig").Health;
pub const Age = @import("age.zig").Age;
pub const Breeding = @import("breeding.zig").Breeding;
pub const Animation = @import("animation.zig").Animation;
pub const HeadRotation = @import("head_rotation.zig").HeadRotation;
pub const Jump = @import("jump.zig").Jump;
pub const AIState = @import("ai.zig").AIState;
pub const GoalType = @import("ai.zig").GoalType;
pub const GoalData = @import("ai.zig").GoalData;
pub const GoalEntry = @import("ai.zig").GoalEntry;
pub const Flag = @import("ai.zig").Flag;
pub const LookControlState = @import("look_control.zig").LookControlState;
pub const RenderData = @import("render_data.zig").RenderData;
pub const CowData = @import("cow_data.zig").CowData;
pub const Tags = @import("tags.zig").Tags;
