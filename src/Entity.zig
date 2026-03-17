const std = @import("std");

pub const EntityId = u32;
pub const PLAYER: EntityId = 0;
pub const MAX_ENTITIES: u32 = 256;

pub const EntityKind = enum(u8) {
    player,
};

pub const EntityFlags = packed struct(u8) {
    on_ground: bool = false,
    in_water: bool = false,
    on_ladder: bool = false,
    eyes_in_water: bool = false,
    _pad: u4 = 0,
};

pub const EntityStore = struct {
    pos: [MAX_ENTITIES][3]f32 = .{.{ 0, 0, 0 }} ** MAX_ENTITIES,
    vel: [MAX_ENTITIES][3]f32 = .{.{ 0, 0, 0 }} ** MAX_ENTITIES,
    prev_pos: [MAX_ENTITIES][3]f32 = .{.{ 0, 0, 0 }} ** MAX_ENTITIES,
    render_pos: [MAX_ENTITIES][3]f32 = .{.{ 0, 0, 0 }} ** MAX_ENTITIES,
    rotation: [MAX_ENTITIES][2]f32 = .{.{ 0, 0 }} ** MAX_ENTITIES,
    flags: [MAX_ENTITIES]EntityFlags = .{@as(EntityFlags, .{})} ** MAX_ENTITIES,
    kind: [MAX_ENTITIES]EntityKind = .{.player} ** MAX_ENTITIES,
    water_vision_time: [MAX_ENTITIES]u16 = .{0} ** MAX_ENTITIES,
    count: u32 = 0,

    pub fn spawn(self: *EntityStore, entity_kind: EntityKind, spawn_pos: [3]f32) EntityId {
        std.debug.assert(self.count < MAX_ENTITIES);
        const id = self.count;
        self.pos[id] = spawn_pos;
        self.vel[id] = .{ 0, 0, 0 };
        self.prev_pos[id] = spawn_pos;
        self.render_pos[id] = spawn_pos;
        self.rotation[id] = .{ 0, 0 };
        self.flags[id] = .{};
        self.kind[id] = entity_kind;
        self.water_vision_time[id] = 0;
        self.count += 1;
        return id;
    }
};
