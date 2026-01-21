/// PhysicsBody component - physical properties for collision and movement
/// Extracted from Entity.zig: width, height, and physics constants
pub const PhysicsBody = struct {
    /// Bounding box width (diameter)
    width: f32 = 0.9,

    /// Bounding box height
    height: f32 = 1.4,

    /// Gravity multiplier (1.0 = normal gravity)
    gravity_scale: f32 = 1.0,

    /// Drag coefficient
    drag: f32 = 0.98,

    /// Ground friction coefficient
    ground_friction: f32 = 0.91,

    /// Step height for automatic step-up
    step_height: f32 = 0.6,

    // Physics constants (matching Minecraft)
    pub const GRAVITY: f32 = 0.08;
    pub const DEFAULT_DRAG: f32 = 0.98;
    pub const DEFAULT_GROUND_FRICTION: f32 = 0.91;
    pub const DEFAULT_STEP_HEIGHT: f32 = 0.6;

    pub fn init() PhysicsBody {
        return .{};
    }

    pub fn initWithSize(width: f32, height: f32) PhysicsBody {
        return .{
            .width = width,
            .height = height,
        };
    }

    /// Create physics body for adult cow
    pub fn cow() PhysicsBody {
        return .{
            .width = 0.9,
            .height = 1.4,
        };
    }

    /// Create physics body for baby cow
    pub fn babyCow() PhysicsBody {
        return .{
            .width = 0.45,
            .height = 0.7,
        };
    }

    /// Get half width (for AABB calculations)
    pub fn halfWidth(self: *const PhysicsBody) f32 {
        return self.width / 2.0;
    }

    /// Get effective gravity
    pub fn effectiveGravity(self: *const PhysicsBody) f32 {
        return GRAVITY * self.gravity_scale;
    }
};
