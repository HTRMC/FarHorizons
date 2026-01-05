const std = @import("std");
const shared = @import("Shared");
const Vec3 = shared.Vec3;
const Mat4 = shared.Mat4;

/// Entity type identifier
pub const EntityType = enum(u8) {
    cow= 0,
    pig= 1,
    sheep= 2,
    player = 3,
    // Add more as needed
};

/// Base entity data shared by all entity types
pub const Entity = struct {
    const Self = @This();

    // Unique entity ID
    id: u64,

    // Entity type
    entity_type: EntityType,

    // World position (center of the entity at feet level)
    position: Vec3,

    // Previous position (for interpolation)
    prev_position: Vec3,

    // Velocity
    velocity: Vec3 = Vec3.ZERO,

    // Rotation around the Y-axis (yaw) in degrees
    yaw: f32 = 0,

    // Previous yaw (for interpolation)
    prev_yaw: f32 = 0,

    // Head rotation (pitch) in degrees
    head_pitch: f32 = 0,

    // Body rotation offset from yaw
    body_yaw_offset: f32 = 0,

    // Whether entity is on ground
    on_ground: bool = true,

    // Animation time (ticks)
    tick_count: u64 = 0,

    // Walk animation parameter (0-1 cycle)
    walk_animation: f32 = 0,

    // Walk animation speed
    walk_speed: f32 = 0,

    /// Create a new entity
    pub fn init(id: u64, entity_type: EntityType, position: Vec3) Self {
        return Self{
            .id = id,
            .entity_type = entity_type,
            .position = position,
            .prev_position = position,
        };
    }

    /// Update entity state (call once per tick)
    pub fn tick(self: *Self) void {
        self.prev_position = self.position;
        self.prev_yaw = self.yaw;
        self.tick_count += 1;

        // Update walk animation based on velocity (like MC's limb swing)
        const horizontal_speed = @sqrt(self.velocity.x * self.velocity.x + self.velocity.z * self.velocity.z);
        if (horizontal_speed > 0.01) {
            self.walk_speed = @min(1.0, horizontal_speed * 4.0);
            // Just increment - cos() in the model handles periodicity naturally
            // The 0.6662 multiplier in the model creates the proper walk cycle
            self.walk_animation += horizontal_speed;
        } else {
            self.walk_speed *= 0.9; // Smoothly reduce animation speed when stopping
        }
    }

    /// Get interpolated position for rendering
    pub fn getPosition(self: *const Self, partial_tick: f32) Vec3 {
        return Vec3{
            .x = self.prev_position.x + (self.position.x - self.prev_position.x) * partial_tick,
            .y = self.prev_position.y + (self.position.y - self.prev_position.y) * partial_tick,
            .z = self.prev_position.z + (self.position.z - self.prev_position.z) * partial_tick,
        };
    }

    /// Get interpolated yaw for rendering
    pub fn getYaw(self: *const Self, partial_tick: f32) f32 {
        // Handle yaw wrap-around
        var delta = self.yaw - self.prev_yaw;
        while (delta > 180) delta -= 360;
        while (delta < -180) delta += 360;
        return self.prev_yaw + delta * partial_tick;
    }

    /// Set position (also updates prev_position)
    pub fn setPosition(self: *Self, pos: Vec3) void {
        self.position = pos;
        self.prev_position = pos;
    }

    /// Move entity by delta
    pub fn move(self: *Self, delta: Vec3) void {
        self.position.x += delta.x;
        self.position.y += delta.y;
        self.position.z += delta.z;
    }

    /// Get model matrix for rendering
    pub fn getModelMatrix(self: *const Self, partial_tick: f32) Mat4 {
        const pos = self.getPosition(partial_tick);
        const yaw_rad = self.getYaw(partial_tick) * std.math.pi / 180.0;

        // Translate to position, then rotate around Y
        // Order: first rotate, then translate (in column-major order, multiply right to left)
        const rotation = Mat4.rotationY(yaw_rad);
        const translation = Mat4.translation(pos);
        return Mat4.multiply(translation, rotation);
    }
};

/// Manager for all entities in the world
pub const EntityManager = struct {
    const Self = @This();

    entities: std.AutoHashMap(u64, Entity),
    next_id: u64 = 1,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .entities = std.AutoHashMap(u64, Entity).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.entities.deinit();
    }

    /// Spawn a new entity
    pub fn spawn(self: *Self, entity_type: EntityType, position: Vec3) !u64 {
        const id = self.next_id;
        self.next_id += 1;

        try self.entities.put(id, Entity.init(id, entity_type, position));
        return id;
    }

    /// Get entity by ID
    pub fn get(self: *const Self, id: u64) ?*Entity {
        return self.entities.getPtr(id);
    }

    /// Remove entity by ID
    pub fn remove(self: *Self, id: u64) void {
        _ = self.entities.remove(id);
    }

    /// Tick all entities
    pub fn tickAll(self: *Self) void {
        var iter = self.entities.valueIterator();
        while (iter.next()) |entity| {
            entity.tick();
        }
    }

    /// Get iterator over all entities
    pub fn iterator(self: *Self) std.AutoHashMap(u64, Entity).ValueIterator {
        return self.entities.valueIterator();
    }
};