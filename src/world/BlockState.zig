const std = @import("std");
const RenderLayer = @import("BlockTypes.zig").RenderLayer;

// ==== Property Types ====

pub const Facing = enum(u2) { south, north, east, west };
pub const Half = enum(u1) { bottom, top };
pub const SlabType = enum(u2) { bottom, top, double };
pub const Placement = enum(u3) { standing, wall_south, wall_north, wall_east, wall_west };
pub const StairShape = enum(u3) { straight, inner_left, inner_right, outer_left, outer_right };

// ==== Block Identity ====

pub const Block = enum(u8) {
    air,
    glass,
    grass_block,
    dirt,
    stone,
    glowstone,
    sand,
    snow,
    water,
    gravel,
    cobblestone,
    oak_log,
    oak_planks,
    bricks,
    bedrock,
    gold_ore,
    iron_ore,
    coal_ore,
    diamond_ore,
    sponge,
    pumice,
    wool,
    gold_block,
    iron_block,
    diamond_block,
    bookshelf,
    obsidian,
    oak_leaves,
    oak_slab,
    oak_stairs,
    torch,
    ladder,
    oak_door,
    oak_fence,

    pub fn isShaped(self: Block) bool {
        return switch (self) {
            .oak_slab, .oak_stairs, .torch, .ladder, .oak_door, .oak_fence => true,
            else => false,
        };
    }
};

pub const NUM_BLOCKS = @typeInfo(Block).@"enum".fields.len;

// ==== State ID ====

pub const StateId = u16;
pub const AABB = struct { min: [3]f32, max: [3]f32 };
pub const Transform = enum { none, flip_y, rotate_90, rotate_180, rotate_270, flip_y_rotate_90, flip_y_rotate_180, flip_y_rotate_270 };
pub const BlockBox = struct { min: [3]f32, max: [3]f32 };
pub const BlockBoxes = struct { boxes: [3]BlockBox, count: u8 };

fn stateCount(block: Block) u16 {
    return switch (block) {
        .oak_slab => 3,
        .oak_stairs => 40, // 4 facings × 2 halves × 5 shapes
        .torch => 5,
        .ladder => 4,
        .oak_door => 16,
        .oak_fence => 16,
        else => 1,
    };
}

pub const TOTAL_STATES: u16 = blk: {
    var total: u16 = 0;
    for (0..NUM_BLOCKS) |i| {
        total += stateCount(@enumFromInt(i));
    }
    break :blk total;
};

// ==== Comptime State Tables ====

const state_to_block_table: [TOTAL_STATES]Block = blk: {
    var table: [TOTAL_STATES]Block = undefined;
    var offset: u16 = 0;
    for (0..NUM_BLOCKS) |i| {
        const block: Block = @enumFromInt(i);
        const count = stateCount(block);
        for (0..count) |_| {
            table[offset] = block;
            offset += 1;
        }
    }
    break :blk table;
};

const state_to_props_table: [TOTAL_STATES]u8 = blk: {
    var table: [TOTAL_STATES]u8 = undefined;
    var offset: u16 = 0;
    for (0..NUM_BLOCKS) |i| {
        const count = stateCount(@enumFromInt(i));
        for (0..count) |p| {
            table[offset] = @intCast(p);
            offset += 1;
        }
    }
    break :blk table;
};

const block_offset_table: [NUM_BLOCKS]u16 = blk: {
    var table: [NUM_BLOCKS]u16 = undefined;
    var offset: u16 = 0;
    for (0..NUM_BLOCKS) |i| {
        table[i] = offset;
        offset += stateCount(@enumFromInt(i));
    }
    break :blk table;
};

// ==== Lookup Functions ====

pub inline fn getBlock(state: StateId) Block {
    return state_to_block_table[state];
}

pub inline fn getProps(state: StateId) u8 {
    return state_to_props_table[state];
}

pub inline fn fromBlockProps(block: Block, props: u8) StateId {
    return block_offset_table[@intFromEnum(block)] + props;
}

pub inline fn defaultState(block: Block) StateId {
    return block_offset_table[@intFromEnum(block)];
}

pub fn stateCountOf(block: Block) u16 {
    return stateCount(block);
}

// ==== Property Extractors ====

pub fn getFacing(state: StateId) ?Facing {
    const block = getBlock(state);
    const props = getProps(state);
    return switch (block) {
        .oak_stairs, .ladder => @enumFromInt(@as(u2, @truncate(props))),
        .oak_door => @enumFromInt(@as(u2, @truncate(props))),
        else => null,
    };
}

pub fn getHalf(state: StateId) ?Half {
    return switch (getBlock(state)) {
        .oak_stairs => @enumFromInt(@as(u1, @truncate(getProps(state) >> 2))),
        .oak_door => @enumFromInt(@as(u1, @truncate(getProps(state) >> 2))),
        else => null,
    };
}

pub fn getStairShape(state: StateId) ?StairShape {
    if (getBlock(state) != .oak_stairs) return null;
    return @enumFromInt(@as(u3, @truncate(getProps(state) >> 3)));
}

/// Construct a stair StateId from individual properties.
/// Bit layout: shape(3)[5:3] | half(1)[2] | facing(2)[1:0]
pub fn makeStairState(facing: Facing, half: Half, shape: StairShape) StateId {
    const props: u8 = @intFromEnum(facing) |
        (@as(u8, @intFromEnum(half)) << 2) |
        (@as(u8, @intFromEnum(shape)) << 3);
    return fromBlockProps(.oak_stairs, props);
}

pub fn getSlabType(state: StateId) ?SlabType {
    return switch (getBlock(state)) {
        .oak_slab => @enumFromInt(@as(u2, @truncate(getProps(state)))),
        else => null,
    };
}

pub fn getPlacement(state: StateId) ?Placement {
    return switch (getBlock(state)) {
        .torch => @enumFromInt(@as(u3, @truncate(getProps(state)))),
        else => null,
    };
}

pub fn isOpen(state: StateId) bool {
    return getBlock(state) == .oak_door and (getProps(state) >> 3) & 1 != 0;
}

pub fn getFenceConnections(state: StateId) ?struct { n: bool, s: bool, e: bool, w: bool } {
    if (getBlock(state) != .oak_fence) return null;
    const p = getProps(state);
    return .{
        .n = p & 1 != 0,
        .s = (p >> 1) & 1 != 0,
        .e = (p >> 2) & 1 != 0,
        .w = (p >> 3) & 1 != 0,
    };
}

// ==== Per-State Comptime Properties ====

const StateProps = struct {
    is_opaque: bool,
    is_solid: bool,
    is_solid_shaped: bool,
    culls_self: bool,
    is_targetable: bool,
    is_shaped: bool,
    render_layer: RenderLayer,
    emitted_light: [3]u8,
    hitbox: ?AABB,
};

fn computeProps(block: Block, props: u8) StateProps {
    const slab_type: SlabType = if (block == .oak_slab)
        @enumFromInt(@as(u2, @truncate(props)))
    else
        .bottom; // unused default
    const is_double_slab = block == .oak_slab and slab_type == .double;
    const door_open = block == .oak_door and (props >> 3) & 1 != 0;

    return .{
        .is_opaque = switch (block) {
            .air, .glass, .water, .oak_leaves => false,
            .oak_slab => is_double_slab,
            .oak_stairs, .torch, .ladder, .oak_door, .oak_fence => false,
            else => true,
        },
        .is_solid = switch (block) {
            .air, .water, .torch, .ladder => false,
            .oak_door => !door_open,
            else => true,
        },
        .is_solid_shaped = switch (block) {
            .oak_slab => !is_double_slab,
            else => false,
        },
        .culls_self = switch (block) {
            .glass, .water => true,
            .air, .oak_leaves => false,
            .oak_slab => is_double_slab,
            .oak_stairs, .torch, .ladder, .oak_door, .oak_fence => false,
            else => true,
        },
        .is_targetable = block != .air and block != .water,
        .is_shaped = switch (block) {
            .oak_slab => !is_double_slab,
            .oak_stairs, .torch, .ladder, .oak_door, .oak_fence => true,
            else => false,
        },
        .render_layer = switch (block) {
            .glass, .water => .translucent,
            .oak_leaves, .torch, .ladder, .oak_door, .oak_fence => .cutout,
            else => .solid,
        },
        .emitted_light = switch (block) {
            .glowstone => .{ 255, 200, 100 },
            .torch => .{ 200, 160, 80 },
            else => .{ 0, 0, 0 },
        },
        .hitbox = computeHitbox(block, props),
    };
}

fn computeHitbox(block: Block, props: u8) ?AABB {
    switch (block) {
        .torch => {
            const placement: Placement = @enumFromInt(@as(u3, @truncate(props)));
            return switch (placement) {
                .standing => .{ .min = .{ 6.0 / 16.0, 0.0, 6.0 / 16.0 }, .max = .{ 10.0 / 16.0, 10.0 / 16.0, 10.0 / 16.0 } },
                .wall_south => .{ .min = .{ 5.5 / 16.0, 3.0 / 16.0, 11.0 / 16.0 }, .max = .{ 10.5 / 16.0, 1.0, 1.0 } },
                .wall_north => .{ .min = .{ 5.5 / 16.0, 3.0 / 16.0, 0.0 }, .max = .{ 10.5 / 16.0, 1.0, 5.0 / 16.0 } },
                .wall_east => .{ .min = .{ 11.0 / 16.0, 3.0 / 16.0, 5.5 / 16.0 }, .max = .{ 1.0, 1.0, 10.5 / 16.0 } },
                .wall_west => .{ .min = .{ 0.0, 3.0 / 16.0, 5.5 / 16.0 }, .max = .{ 5.0 / 16.0, 1.0, 10.5 / 16.0 } },
            };
        },
        .ladder => {
            const facing: Facing = @enumFromInt(@as(u2, @truncate(props)));
            return switch (facing) {
                .south => .{ .min = .{ 0.0, 0.0, 0.0 }, .max = .{ 1.0, 1.0, 3.0 / 16.0 } },
                .north => .{ .min = .{ 0.0, 0.0, 13.0 / 16.0 }, .max = .{ 1.0, 1.0, 1.0 } },
                .east => .{ .min = .{ 0.0, 0.0, 0.0 }, .max = .{ 3.0 / 16.0, 1.0, 1.0 } },
                .west => .{ .min = .{ 13.0 / 16.0, 0.0, 0.0 }, .max = .{ 1.0, 1.0, 1.0 } },
            };
        },
        .oak_slab => {
            const slab_type: SlabType = @enumFromInt(@as(u2, @truncate(props)));
            return switch (slab_type) {
                .bottom => .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 0.5, 1 } },
                .top => .{ .min = .{ 0, 0.5, 0 }, .max = .{ 1, 1, 1 } },
                .double => null,
            };
        },
        .oak_door => {
            const facing: Facing = @enumFromInt(@as(u2, @truncate(props)));
            const open_bit = (props >> 3) & 1 != 0;
            // Door hitbox: 3px slab on one edge, determined by facing + open
            // Closed: east→west_edge, south→south_edge, west→east_edge, north→north_edge
            // Open adds 90° CW rotation: east→south_edge, south→east_edge, etc.
            const edge = computeDoorEdge(facing, open_bit);
            return door_edge_hitboxes[edge];
        },
        .oak_fence => {
            const n = props & 1 != 0;
            const s = (props >> 1) & 1 != 0;
            const e = (props >> 2) & 1 != 0;
            const w = (props >> 3) & 1 != 0;
            return .{
                .min = .{
                    if (w) 0.0 else 6.0 / 16.0,
                    0.0,
                    if (n) 0.0 else 6.0 / 16.0,
                },
                .max = .{
                    if (e) 1.0 else 10.0 / 16.0,
                    1.0,
                    if (s) 1.0 else 10.0 / 16.0,
                },
            };
        },
        else => return null,
    }
}

// Door edge: 0=west_edge, 1=south_edge, 2=east_edge, 3=north_edge
fn computeDoorEdge(facing: Facing, open_bit: bool) u2 {
    // Closed: south→1, north→3, east→0, west→2
    const base: u2 = switch (facing) {
        .south => 1,
        .north => 3,
        .east => 0,
        .west => 2,
    };
    // Open rotates 90° CW (add 1 mod 4)
    return if (open_bit) base +% 1 else base;
}

const door_edge_hitboxes = [4]AABB{
    // 0: west edge (x=0..3/16)
    .{ .min = .{ 0.0, 0.0, 0.0 }, .max = .{ 3.0 / 16.0, 1.0, 1.0 } },
    // 1: south edge (z=13/16..1)
    .{ .min = .{ 0.0, 0.0, 13.0 / 16.0 }, .max = .{ 1.0, 1.0, 1.0 } },
    // 2: east edge (x=13/16..1)
    .{ .min = .{ 13.0 / 16.0, 0.0, 0.0 }, .max = .{ 1.0, 1.0, 1.0 } },
    // 3: north edge (z=0..3/16)
    .{ .min = .{ 0.0, 0.0, 0.0 }, .max = .{ 1.0, 1.0, 3.0 / 16.0 } },
};

const state_props: [TOTAL_STATES]StateProps = blk: {
    var table: [TOTAL_STATES]StateProps = undefined;
    for (0..TOTAL_STATES) |i| {
        table[i] = computeProps(state_to_block_table[i], state_to_props_table[i]);
    }
    break :blk table;
};

// ==== Property Query Functions ====

pub inline fn isOpaque(state: StateId) bool {
    return state_props[state].is_opaque;
}
pub inline fn isSolid(state: StateId) bool {
    return state_props[state].is_solid;
}
pub inline fn isSolidShaped(state: StateId) bool {
    return state_props[state].is_solid_shaped;
}
pub inline fn cullsSelf(state: StateId) bool {
    return state_props[state].culls_self;
}
pub inline fn isTargetable(state: StateId) bool {
    return state_props[state].is_targetable;
}
pub inline fn isShaped(state: StateId) bool {
    return state_props[state].is_shaped;
}
pub inline fn renderLayer(state: StateId) RenderLayer {
    return state_props[state].render_layer;
}
pub inline fn emittedLight(state: StateId) [3]u8 {
    return state_props[state].emitted_light;
}
pub inline fn getHitbox(state: StateId) ?AABB {
    return state_props[state].hitbox;
}

// ==== Collision ====

fn oneBox(min: [3]f32, max: [3]f32) BlockBoxes {
    return .{ .boxes = .{ .{ .min = min, .max = max }, undefined, undefined }, .count = 1 };
}

fn fullCubeBox() BlockBoxes {
    return oneBox(.{ 0, 0, 0 }, .{ 1, 1, 1 });
}

fn computeCollision(block: Block, props: u8) BlockBoxes {
    switch (block) {
        .oak_slab => {
            const slab_type: SlabType = @enumFromInt(@as(u2, @truncate(props)));
            return switch (slab_type) {
                .bottom => oneBox(.{ 0, 0, 0 }, .{ 1, 0.5, 1 }),
                .top => oneBox(.{ 0, 0.5, 0 }, .{ 1, 1, 1 }),
                .double => fullCubeBox(),
            };
        },
        .oak_stairs => return computeStairBoxes(props),
        .torch, .ladder, .oak_door => {
            const hitbox = computeHitbox(block, props) orelse return fullCubeBox();
            return oneBox(hitbox.min, hitbox.max);
        },
        .oak_fence => {
            const n = props & 1 != 0;
            const s = (props >> 1) & 1 != 0;
            const e = (props >> 2) & 1 != 0;
            const w = (props >> 3) & 1 != 0;
            const min_x: f32 = if (w) 0.0 else 6.0 / 16.0;
            const max_x: f32 = if (e) 1.0 else 10.0 / 16.0;
            const min_z: f32 = if (n) 0.0 else 6.0 / 16.0;
            const max_z: f32 = if (s) 1.0 else 10.0 / 16.0;
            const n_count = @as(u8, @intFromBool(n)) + @intFromBool(s) + @intFromBool(e) + @intFromBool(w);
            if (n_count >= 2 and (n or s) and (e or w)) {
                return .{
                    .boxes = .{
                        .{ .min = .{ 6.0 / 16.0, 0, min_z }, .max = .{ 10.0 / 16.0, 1.5, max_z } },
                        .{ .min = .{ min_x, 0, 6.0 / 16.0 }, .max = .{ max_x, 1.5, 10.0 / 16.0 } },
                        undefined,
                    },
                    .count = 2,
                };
            }
            return oneBox(.{ min_x, 0, min_z }, .{ max_x, 1.5, max_z });
        },
        else => return fullCubeBox(),
    }
}

fn computeStairBoxes(props: u8) BlockBoxes {
    const facing: Facing = @enumFromInt(@as(u2, @truncate(props)));
    const half: Half = @enumFromInt(@as(u1, @truncate(props >> 2)));
    const shape: StairShape = @enumFromInt(@as(u3, @truncate(props >> 3)));
    const base_box: BlockBox = if (half == .bottom)
        .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 0.5, 1 } }
    else
        .{ .min = .{ 0, 0.5, 0 }, .max = .{ 1, 1, 1 } };
    const sy0: f32 = if (half == .bottom) 0.5 else 0.0;
    const sy1: f32 = if (half == .bottom) 1.0 else 0.5;
    switch (shape) {
        .straight => {
            const step = straightStepBox(facing, sy0, sy1);
            return .{ .boxes = .{ base_box, step, undefined }, .count = 2 };
        },
        .inner_left, .inner_right => {
            const back = straightStepBox(facing, sy0, sy1);
            const side_facing: Facing = if (shape == .inner_right) rotateCW(facing) else rotateCCW(facing);
            const side = quadrantBox(facing, side_facing, sy0, sy1);
            return .{ .boxes = .{ base_box, back, side }, .count = 3 };
        },
        .outer_left, .outer_right => {
            const side_facing: Facing = if (shape == .outer_right) rotateCW(facing) else rotateCCW(facing);
            const corner = quadrantBox(facing, side_facing, sy0, sy1);
            return .{ .boxes = .{ base_box, corner, undefined }, .count = 2 };
        },
    }
}

fn straightStepBox(facing: Facing, sy0: f32, sy1: f32) BlockBox {
    return switch (facing) {
        .south => .{ .min = .{ 0, sy0, 0 }, .max = .{ 1, sy1, 0.5 } },
        .north => .{ .min = .{ 0, sy0, 0.5 }, .max = .{ 1, sy1, 1 } },
        .east => .{ .min = .{ 0, sy0, 0 }, .max = .{ 0.5, sy1, 1 } },
        .west => .{ .min = .{ 0.5, sy0, 0 }, .max = .{ 1, sy1, 1 } },
    };
}

fn quadrantBox(facing: Facing, side: Facing, sy0: f32, sy1: f32) BlockBox {
    const x0: f32 = if (facing == .east or side == .east) 0.0 else if (facing == .west or side == .west) 0.5 else 0.0;
    const x1: f32 = if (facing == .west or side == .west) 1.0 else if (facing == .east or side == .east) 0.5 else 1.0;
    const z0: f32 = if (facing == .south or side == .south) 0.0 else if (facing == .north or side == .north) 0.5 else 0.0;
    const z1: f32 = if (facing == .north or side == .north) 1.0 else if (facing == .south or side == .south) 0.5 else 1.0;
    return .{ .min = .{ x0, sy0, z0 }, .max = .{ x1, sy1, z1 } };
}

fn rotateCW(facing: Facing) Facing {
    return switch (facing) { .south => .west, .west => .north, .north => .east, .east => .south };
}

fn rotateCCW(facing: Facing) Facing {
    return switch (facing) { .south => .east, .east => .north, .north => .west, .west => .south };
}

const collision_table: [TOTAL_STATES]BlockBoxes = blk: {
    var table: [TOTAL_STATES]BlockBoxes = undefined;
    for (0..TOTAL_STATES) |i| {
        table[i] = computeCollision(state_to_block_table[i], state_to_props_table[i]);
    }
    break :blk table;
};

pub inline fn getCollisionBoxes(state: StateId) BlockBoxes {
    return collision_table[state];
}

pub const TexIndices = struct { top: i16, side: i16 };

/// Per-state mesh texture indices (top/bottom face vs side faces).
/// For non-shaped full-cube blocks this is the primary texture lookup.
/// Shaped blocks use getShapedTexIndices from the model registry instead.
pub inline fn blockTexIndices(state: StateId) TexIndices {
    return tex_indices_table[state];
}

const tex_indices_table: [TOTAL_STATES]TexIndices = blk: {
    var table: [TOTAL_STATES]TexIndices = undefined;
    for (0..TOTAL_STATES) |i| {
        table[i] = computeTexIndices(state_to_block_table[i], state_to_props_table[i]);
    }
    break :blk table;
};

fn computeTexIndices(block: Block, props: u8) TexIndices {
    return switch (block) {
        .air => .{ .top = -1, .side = -1 },
        .glass => .{ .top = 0, .side = 0 },
        .grass_block => .{ .top = 1, .side = 1 },
        .dirt => .{ .top = 2, .side = 2 },
        .stone => .{ .top = 3, .side = 3 },
        .glowstone => .{ .top = 4, .side = 4 },
        .sand => .{ .top = 5, .side = 5 },
        .snow => .{ .top = 6, .side = 6 },
        .water => .{ .top = 7, .side = 7 },
        .gravel => .{ .top = 8, .side = 8 },
        .cobblestone => .{ .top = 9, .side = 9 },
        .oak_log => .{ .top = 27, .side = 10 },
        .oak_planks => .{ .top = 11, .side = 11 },
        .bricks => .{ .top = 12, .side = 12 },
        .bedrock => .{ .top = 13, .side = 13 },
        .gold_ore => .{ .top = 14, .side = 14 },
        .iron_ore => .{ .top = 15, .side = 15 },
        .coal_ore => .{ .top = 16, .side = 16 },
        .diamond_ore => .{ .top = 17, .side = 17 },
        .sponge => .{ .top = 18, .side = 18 },
        .pumice => .{ .top = 19, .side = 19 },
        .wool => .{ .top = 20, .side = 20 },
        .gold_block => .{ .top = 21, .side = 21 },
        .iron_block => .{ .top = 22, .side = 22 },
        .diamond_block => .{ .top = 23, .side = 23 },
        .bookshelf => .{ .top = 24, .side = 24 },
        .obsidian => .{ .top = 25, .side = 25 },
        .oak_leaves => .{ .top = 26, .side = 26 },
        .oak_slab => .{ .top = 11, .side = 11 },
        .oak_stairs => .{ .top = 11, .side = 11 },
        .torch => .{ .top = 28, .side = 28 },
        .ladder => .{ .top = 29, .side = 29 },
        .oak_door => blk: {
            const half: Half = @enumFromInt(@as(u1, @truncate(props >> 2)));
            break :blk if (half == .bottom) .{ .top = 32, .side = 32 } else .{ .top = 33, .side = 33 };
        },
        .oak_fence => .{ .top = 11, .side = 11 },
    };
}

// ==== Block Behavior Functions ====

pub fn connectsToFence(state: StateId) bool {
    const block = getBlock(state);
    return block == .oak_fence or (isSolid(state) and isOpaque(state));
}

pub fn fenceFromConnections(n: bool, s: bool, e: bool, w: bool) StateId {
    const conn: u4 = (@as(u4, @intFromBool(n))) |
        (@as(u4, @intFromBool(s)) << 1) |
        (@as(u4, @intFromBool(e)) << 2) |
        (@as(u4, @intFromBool(w)) << 3);
    return fromBlockProps(.oak_fence, conn);
}

pub fn isStairs(state: StateId) bool {
    return getBlock(state) == .oak_stairs;
}

pub fn isDoor(state: StateId) bool {
    return getBlock(state) == .oak_door;
}

pub fn isDoorBottom(state: StateId) bool {
    if (getBlock(state) != .oak_door) return false;
    return (getProps(state) >> 2) & 1 == 0; // half bit = 0 → bottom
}

pub fn isFence(state: StateId) bool {
    return getBlock(state) == .oak_fence;
}

pub fn toggleDoor(state: StateId) StateId {
    if (getBlock(state) != .oak_door) return state;
    return fromBlockProps(.oak_door, getProps(state) ^ 0b1000); // flip open bit
}

pub fn doorBottomToTop(state: StateId) StateId {
    if (getBlock(state) != .oak_door) return state;
    return fromBlockProps(.oak_door, getProps(state) | 0b0100); // set half bit to top
}

pub fn doorTopToBottom(state: StateId) StateId {
    if (getBlock(state) != .oak_door) return state;
    return fromBlockProps(.oak_door, getProps(state) & ~@as(u8, 0b0100)); // clear half bit
}

/// Get the default/canonical state for inventory display (pick block).
pub fn getCanonicalState(state: StateId) StateId {
    return switch (getBlock(state)) {
        .oak_slab => fromBlockProps(.oak_slab, @intFromEnum(SlabType.bottom)),
        .oak_stairs => makeStairState(.south, .bottom, .straight),
        .torch => defaultState(.torch), // standing
        .ladder => fromBlockProps(.ladder, @intFromEnum(Facing.south)),
        .oak_door => makeDoorState(.south, .bottom, false),
        .oak_fence => defaultState(.oak_fence), // post only
        else => state,
    };
}

/// Get the state used for isometric inventory/GUI display.
/// Chooses facing/orientation that looks best at the isometric view angle (30°, 225°).
pub fn getDisplayState(state: StateId) StateId {
    return switch (getBlock(state)) {
        .oak_slab => state, // preserve bottom/top/double
        .oak_stairs => makeStairState(.east, .bottom, .straight),
        .torch => fromBlockProps(.torch, @intFromEnum(Placement.standing)),
        .ladder => fromBlockProps(.ladder, @intFromEnum(Facing.north)),
        .oak_door => makeDoorState(.south, .bottom, false),
        .oak_fence => defaultState(.oak_fence),
        else => state,
    };
}

/// Construct a door StateId from individual properties.
pub fn makeDoorState(facing: Facing, half: Half, open_flag: bool) StateId {
    const props: u8 = @intFromEnum(facing) |
        (@as(u8, @intFromEnum(half)) << 2) |
        (@as(u8, @intFromBool(open_flag)) << 3);
    return fromBlockProps(.oak_door, props);
}

// ==== Model Info ====

pub const ModelInfo = struct {
    json_file: []const u8,
    transform: Transform,
};

fn computeModelInfo(block: Block, props: u8) ?ModelInfo {
    switch (block) {
        .oak_slab => {
            const slab_type: SlabType = @enumFromInt(@as(u2, @truncate(props)));
            return switch (slab_type) {
                .bottom => .{ .json_file = "oak_slab.json", .transform = .none },
                .top => .{ .json_file = "oak_slab.json", .transform = .flip_y },
                .double => null, // full cube, no special model
            };
        },
        .oak_stairs => {
            const facing: Facing = @enumFromInt(@as(u2, @truncate(props)));
            const half: Half = @enumFromInt(@as(u1, @truncate(props >> 2)));
            const shape: StairShape = @enumFromInt(@as(u3, @truncate(props >> 3)));
            const json_file: []const u8 = switch (shape) {
                .straight => "oak_stairs.json",
                .inner_left, .inner_right => "oak_stairs_inner.json",
                .outer_left, .outer_right => "oak_stairs_outer.json",
            };
            // For left/right: left is the same shape as right rotated 90° CW
            // (south,inner_left = same physical shape as east,inner_right)
            const shape_rotation: u16 = switch (shape) {
                .straight, .inner_right, .outer_right => 0,
                .inner_left, .outer_left => 90,
            };
            const facing_rotation: u16 = switch (facing) {
                .south => 0,
                .east => 90,
                .north => 180,
                .west => 270,
            };
            const total_rotation = (facing_rotation + shape_rotation) % 360;
            const rot_transform: Transform = switch (total_rotation) {
                0 => .none,
                90 => .rotate_90,
                180 => .rotate_180,
                270 => .rotate_270,
                else => .none,
            };
            return .{
                .json_file = json_file,
                .transform = if (half == .bottom) rot_transform else switch (rot_transform) {
                    .none => .flip_y,
                    .rotate_90 => .flip_y_rotate_90,
                    .rotate_180 => .flip_y_rotate_180,
                    .rotate_270 => .flip_y_rotate_270,
                    else => .flip_y,
                },
            };
        },
        .torch => {
            const placement: Placement = @enumFromInt(@as(u3, @truncate(props)));
            return switch (placement) {
                .standing => .{ .json_file = "torch_standing.json", .transform = .none },
                .wall_south => .{ .json_file = "torch_wall.json", .transform = .rotate_90 },
                .wall_north => .{ .json_file = "torch_wall.json", .transform = .rotate_270 },
                .wall_east => .{ .json_file = "torch_wall.json", .transform = .rotate_180 },
                .wall_west => .{ .json_file = "torch_wall.json", .transform = .none },
            };
        },
        .ladder => {
            const facing: Facing = @enumFromInt(@as(u2, @truncate(props)));
            return .{
                .json_file = "ladder.json",
                .transform = facingToRotation(facing),
            };
        },
        .oak_door => {
            const facing: Facing = @enumFromInt(@as(u2, @truncate(props)));
            const half: Half = @enumFromInt(@as(u1, @truncate(props >> 2)));
            const open_flag = (props >> 3) & 1 != 0;
            return .{
                .json_file = if (half == .bottom) "oak_door_bottom.json" else "oak_door_top.json",
                .transform = doorTransform(facing, open_flag),
            };
        },
        .oak_fence => {
            return .{
                .json_file = fence_model_files[props & 0xF],
                .transform = .none,
            };
        },
        else => return null,
    }
}

fn facingToRotation(facing: Facing) Transform {
    return switch (facing) {
        .south => .none,
        .north => .rotate_180,
        .east => .rotate_90,
        .west => .rotate_270,
    };
}

fn doorTransform(facing: Facing, open_flag: bool) Transform {
    // Base angles: east=0, south=90, west=180, north=270. Open adds 90°.
    const base: u16 = switch (facing) {
        .east => 0,
        .south => 90,
        .west => 180,
        .north => 270,
    };
    const angle = (base + if (open_flag) @as(u16, 90) else 0) % 360;
    return switch (angle) {
        0 => .none,
        90 => .rotate_90,
        180 => .rotate_180,
        270 => .rotate_270,
        else => .none,
    };
}

const fence_model_files = [16][]const u8{
    "oak_fence_post.json", // 0000
    "oak_fence_n.json", // 0001
    "oak_fence_s.json", // 0010
    "oak_fence_ns.json", // 0011
    "oak_fence_e.json", // 0100
    "oak_fence_ne.json", // 0101
    "oak_fence_se.json", // 0110
    "oak_fence_nse.json", // 0111
    "oak_fence_w.json", // 1000
    "oak_fence_nw.json", // 1001
    "oak_fence_sw.json", // 1010
    "oak_fence_nsw.json", // 1011
    "oak_fence_ew.json", // 1100
    "oak_fence_new.json", // 1101
    "oak_fence_sew.json", // 1110
    "oak_fence_nsew.json", // 1111
};

pub const model_info_table: [TOTAL_STATES]?ModelInfo = blk: {
    var table: [TOTAL_STATES]?ModelInfo = undefined;
    for (0..TOTAL_STATES) |i| {
        table[i] = computeModelInfo(state_to_block_table[i], state_to_props_table[i]);
    }
    break :blk table;
};

// ==== Tests ====

test "total state count" {
    try std.testing.expectEqual(@as(u16, 112), TOTAL_STATES);
}

test "simple block round-trip" {
    const air = defaultState(.air);
    try std.testing.expectEqual(Block.air, getBlock(air));
    try std.testing.expectEqual(@as(u8, 0), getProps(air));

    const stone = defaultState(.stone);
    try std.testing.expectEqual(Block.stone, getBlock(stone));
}

test "slab states" {
    const bottom = fromBlockProps(.oak_slab, @intFromEnum(SlabType.bottom));
    const top = fromBlockProps(.oak_slab, @intFromEnum(SlabType.top));
    const double = fromBlockProps(.oak_slab, @intFromEnum(SlabType.double));

    try std.testing.expectEqual(SlabType.bottom, getSlabType(bottom).?);
    try std.testing.expectEqual(SlabType.top, getSlabType(top).?);
    try std.testing.expectEqual(SlabType.double, getSlabType(double).?);

    // Double slab is opaque, others aren't
    try std.testing.expect(isOpaque(double));
    try std.testing.expect(!isOpaque(bottom));
    try std.testing.expect(!isOpaque(top));
}

test "door toggle" {
    const closed = makeDoorState(.east, .bottom, false);
    try std.testing.expect(!isOpen(closed));
    try std.testing.expect(isSolid(closed));

    const opened = toggleDoor(closed);
    try std.testing.expect(isOpen(opened));
    try std.testing.expect(!isSolid(opened));

    // Toggle back
    try std.testing.expectEqual(closed, toggleDoor(opened));
}

test "door bottom to top" {
    const bottom = makeDoorState(.south, .bottom, false);
    const top = doorBottomToTop(bottom);
    try std.testing.expectEqual(Half.bottom, getHalf(bottom).?);
    try std.testing.expectEqual(Half.top, getHalf(top).?);
    try std.testing.expectEqual(Facing.south, getFacing(top).?);
}

test "fence connections" {
    const post = fenceFromConnections(false, false, false, false);
    try std.testing.expectEqual(Block.oak_fence, getBlock(post));

    const conns = getFenceConnections(post).?;
    try std.testing.expect(!conns.n and !conns.s and !conns.e and !conns.w);

    const nsew = fenceFromConnections(true, true, true, true);
    const conns2 = getFenceConnections(nsew).?;
    try std.testing.expect(conns2.n and conns2.s and conns2.e and conns2.w);
}

test "model info" {
    // Stairs south/bottom/straight = no rotation
    const stairs_s = makeStairState(.south, .bottom, .straight);
    const info = model_info_table[stairs_s].?;
    try std.testing.expect(std.mem.eql(u8, info.json_file, "oak_stairs.json"));
    try std.testing.expectEqual(Transform.none, info.transform);

    // Stairs north/bottom/straight = 180
    const stairs_n = makeStairState(.north, .bottom, .straight);
    try std.testing.expectEqual(Transform.rotate_180, model_info_table[stairs_n].?.transform);

    // Stairs south/top/straight = flip_y
    const stairs_top = makeStairState(.south, .top, .straight);
    try std.testing.expectEqual(Transform.flip_y, model_info_table[stairs_top].?.transform);

    // Stairs inner corner
    const stairs_inner = makeStairState(.south, .bottom, .inner_right);
    try std.testing.expect(std.mem.eql(u8, model_info_table[stairs_inner].?.json_file, "oak_stairs_inner.json"));

    // Stairs outer corner
    const stairs_outer = makeStairState(.south, .bottom, .outer_left);
    try std.testing.expect(std.mem.eql(u8, model_info_table[stairs_outer].?.json_file, "oak_stairs_outer.json"));

    // Simple block = no model info
    try std.testing.expectEqual(@as(?ModelInfo, null), model_info_table[defaultState(.stone)]);

    // Double slab = no model info (rendered as full cube)
    try std.testing.expectEqual(@as(?ModelInfo, null), model_info_table[fromBlockProps(.oak_slab, @intFromEnum(SlabType.double))]);
}

test "hitbox consistency" {
    // Standing torch has small hitbox
    const torch_state = fromBlockProps(.torch, @intFromEnum(Placement.standing));
    const hb = getHitbox(torch_state).?;
    try std.testing.expect(hb.min[0] > 0.0 and hb.max[0] < 1.0);

    // Full cube block has no hitbox (null = implicit full cube)
    try std.testing.expectEqual(@as(?AABB, null), getHitbox(defaultState(.stone)));

    // Double slab = full cube
    try std.testing.expectEqual(@as(?AABB, null), getHitbox(fromBlockProps(.oak_slab, @intFromEnum(SlabType.double))));
}

test "canonical states" {
    // All stair variants canonicalize to south/bottom/straight
    const stairs_e = makeStairState(.east, .top, .inner_left);
    try std.testing.expectEqual(makeStairState(.south, .bottom, .straight), getCanonicalState(stairs_e));

    // Open door canonicalizes to closed bottom south
    const door_open = makeDoorState(.west, .top, true);
    try std.testing.expectEqual(makeDoorState(.south, .bottom, false), getCanonicalState(door_open));

    // Simple blocks are their own canonical state
    const stone = defaultState(.stone);
    try std.testing.expectEqual(stone, getCanonicalState(stone));
}
