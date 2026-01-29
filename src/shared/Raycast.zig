/// Raycast module - exact port of Minecraft's raycasting algorithm
/// From: net.minecraft.world.level.BlockGetter.traverseBlocks
/// And: net.minecraft.world.phys.AABB.clip
const std = @import("std");
const math = @import("Math.zig");
const Vec3 = math.Vec3;
const voxel_shape = @import("VoxelShape.zig");
const Direction = voxel_shape.Direction;

/// Result of a block raycast
/// Equivalent to Minecraft's BlockHitResult
pub const BlockHitResult = struct {
    /// The exact location where the ray hit
    location: Vec3,
    /// The face direction that was hit
    direction: Direction,
    /// The block position that was hit
    block_pos: BlockPos,
    /// Whether this is a miss (no block hit)
    miss: bool,
    /// Whether the ray started inside the block
    inside: bool,

    pub const BlockPos = struct {
        x: i32,
        y: i32,
        z: i32,
    };

    /// Create a miss result
    /// Equivalent to BlockHitResult.miss()
    pub fn missFn(location: Vec3, direction: Direction, pos: BlockPos) BlockHitResult {
        return .{
            .location = location,
            .direction = direction,
            .block_pos = pos,
            .miss = true,
            .inside = false,
        };
    }

    /// Create a hit result
    pub fn hit(location: Vec3, direction: Direction, pos: BlockPos, inside: bool) BlockHitResult {
        return .{
            .location = location,
            .direction = direction,
            .block_pos = pos,
            .miss = false,
            .inside = inside,
        };
    }

    /// Get the type of hit result
    pub fn getType(self: *const BlockHitResult) HitType {
        return if (self.miss) .miss else .block;
    }
};

pub const HitType = enum {
    miss,
    block,
};

/// AABB structure for ray intersection
/// Equivalent to Minecraft's AABB
pub const AABB = struct {
    min_x: f64,
    min_y: f64,
    min_z: f64,
    max_x: f64,
    max_y: f64,
    max_z: f64,

    pub fn init(min_x: f64, min_y: f64, min_z: f64, max_x: f64, max_y: f64, max_z: f64) AABB {
        return .{
            .min_x = @min(min_x, max_x),
            .min_y = @min(min_y, max_y),
            .min_z = @min(min_z, max_z),
            .max_x = @max(min_x, max_x),
            .max_y = @max(min_y, max_y),
            .max_z = @max(min_z, max_z),
        };
    }

    /// Create AABB from block position (unit cube at that position)
    pub fn fromBlockPos(pos: BlockHitResult.BlockPos) AABB {
        return .{
            .min_x = @floatFromInt(pos.x),
            .min_y = @floatFromInt(pos.y),
            .min_z = @floatFromInt(pos.z),
            .max_x = @floatFromInt(pos.x + 1),
            .max_y = @floatFromInt(pos.y + 1),
            .max_z = @floatFromInt(pos.z + 1),
        };
    }

    /// Move AABB by offset
    pub fn move(self: AABB, pos: BlockHitResult.BlockPos) AABB {
        const dx: f64 = @floatFromInt(pos.x);
        const dy: f64 = @floatFromInt(pos.y);
        const dz: f64 = @floatFromInt(pos.z);
        return .{
            .min_x = self.min_x + dx,
            .min_y = self.min_y + dy,
            .min_z = self.min_z + dz,
            .max_x = self.max_x + dx,
            .max_y = self.max_y + dy,
            .max_z = self.max_z + dz,
        };
    }

    /// Ray-AABB intersection
    /// Equivalent to AABB.clip(Vec3 from, Vec3 to)
    /// Returns the intersection point if hit, null otherwise
    pub fn clip(self: AABB, from: Vec3, to: Vec3) ?Vec3 {
        return clipStatic(
            self.min_x,
            self.min_y,
            self.min_z,
            self.max_x,
            self.max_y,
            self.max_z,
            from,
            to,
        );
    }

    /// Static ray-AABB intersection
    /// Equivalent to AABB.clip(double minX, ..., Vec3 from, Vec3 to)
    pub fn clipStatic(
        min_x: f64,
        min_y: f64,
        min_z: f64,
        max_x: f64,
        max_y: f64,
        max_z: f64,
        from: Vec3,
        to: Vec3,
    ) ?Vec3 {
        var scale_ref: f64 = 1.0;
        const dx: f64 = to.x - from.x;
        const dy: f64 = to.y - from.y;
        const dz: f64 = to.z - from.z;

        const direction = getDirectionInternal(
            min_x,
            min_y,
            min_z,
            max_x,
            max_y,
            max_z,
            from,
            &scale_ref,
            null,
            dx,
            dy,
            dz,
        );

        if (direction == null) {
            return null;
        }

        return Vec3{
            .x = @floatCast(from.x + scale_ref * dx),
            .y = @floatCast(from.y + scale_ref * dy),
            .z = @floatCast(from.z + scale_ref * dz),
        };
    }

    /// Ray-AABB intersection returning BlockHitResult
    /// Equivalent to AABB.clip(Iterable<AABB>, Vec3 from, Vec3 to, BlockPos pos)
    pub fn clipWithResult(aabbs: []const AABB, from: Vec3, to: Vec3, pos: BlockHitResult.BlockPos) ?BlockHitResult {
        var scale_ref: f64 = 1.0;
        var direction: ?Direction = null;
        const dx: f64 = to.x - from.x;
        const dy: f64 = to.y - from.y;
        const dz: f64 = to.z - from.z;

        for (aabbs) |aabb| {
            const moved = aabb.move(pos);
            direction = getDirectionInternal(
                moved.min_x,
                moved.min_y,
                moved.min_z,
                moved.max_x,
                moved.max_y,
                moved.max_z,
                from,
                &scale_ref,
                direction,
                dx,
                dy,
                dz,
            );
        }

        if (direction == null) {
            return null;
        }

        const location = Vec3{
            .x = @floatCast(from.x + scale_ref * dx),
            .y = @floatCast(from.y + scale_ref * dy),
            .z = @floatCast(from.z + scale_ref * dz),
        };

        return BlockHitResult.hit(location, direction.?, pos, false);
    }
};

/// Get direction from ray-AABB intersection
/// Equivalent to AABB.getDirection(...)
fn getDirectionInternal(
    min_x: f64,
    min_y: f64,
    min_z: f64,
    max_x: f64,
    max_y: f64,
    max_z: f64,
    from: Vec3,
    scale_ref: *f64,
    direction: ?Direction,
    dx: f64,
    dy: f64,
    dz: f64,
) ?Direction {
    var result = direction;
    const EPSILON: f64 = 1.0e-7;

    if (dx > EPSILON) {
        result = clipPoint(scale_ref, result, dx, dy, dz, min_x, min_y, max_y, min_z, max_z, .west, from.x, from.y, from.z);
    } else if (dx < -EPSILON) {
        result = clipPoint(scale_ref, result, dx, dy, dz, max_x, min_y, max_y, min_z, max_z, .east, from.x, from.y, from.z);
    }

    if (dy > EPSILON) {
        result = clipPoint(scale_ref, result, dy, dz, dx, min_y, min_z, max_z, min_x, max_x, .down, from.y, from.z, from.x);
    } else if (dy < -EPSILON) {
        result = clipPoint(scale_ref, result, dy, dz, dx, max_y, min_z, max_z, min_x, max_x, .up, from.y, from.z, from.x);
    }

    if (dz > EPSILON) {
        result = clipPoint(scale_ref, result, dz, dx, dy, min_z, min_x, max_x, min_y, max_y, .north, from.z, from.x, from.y);
    } else if (dz < -EPSILON) {
        result = clipPoint(scale_ref, result, dz, dx, dy, max_z, min_x, max_x, min_y, max_y, .south, from.z, from.x, from.y);
    }

    return result;
}

/// Clip point helper
/// Equivalent to AABB.clipPoint(...)
fn clipPoint(
    scale_ref: *f64,
    direction: ?Direction,
    da: f64,
    db: f64,
    dc: f64,
    point: f64,
    min_b: f64,
    max_b: f64,
    min_c: f64,
    max_c: f64,
    new_direction: Direction,
    from_a: f64,
    from_b: f64,
    from_c: f64,
) ?Direction {
    const EPSILON: f64 = 1.0e-7;
    const s = (point - from_a) / da;
    const pb = from_b + s * db;
    const pc = from_c + s * dc;

    if (0.0 < s and s < scale_ref.* and min_b - EPSILON < pb and pb < max_b + EPSILON and min_c - EPSILON < pc and pc < max_c + EPSILON) {
        scale_ref.* = s;
        return new_direction;
    }

    return direction;
}

/// Mth utility functions - exact ports from Minecraft
pub const Mth = struct {
    /// Equivalent to Mth.floor(double)
    pub fn floor(v: f64) i32 {
        const i: i32 = @intFromFloat(v);
        return if (v < @as(f64, @floatFromInt(i))) i - 1 else i;
    }

    /// Equivalent to Mth.lfloor(double)
    pub fn lfloor(v: f64) i64 {
        const i: i64 = @intFromFloat(v);
        return if (v < @as(f64, @floatFromInt(i))) i - 1 else i;
    }

    /// Equivalent to Mth.frac(double)
    pub fn frac(num: f64) f64 {
        return num - @as(f64, @floatFromInt(lfloor(num)));
    }

    /// Equivalent to Mth.sign(double)
    pub fn sign(number: f64) i32 {
        if (number == 0.0) {
            return 0;
        }
        return if (number > 0.0) 1 else -1;
    }

    /// Equivalent to Mth.lerp(double, double, double)
    pub fn lerp(alpha: f64, p0: f64, p1: f64) f64 {
        return p0 + alpha * (p1 - p0);
    }
};

/// Get approximate nearest direction from a vector
/// Equivalent to Direction.getApproximateNearest(double, double, double)
pub fn getApproximateNearest(dx: f64, dy: f64, dz: f64) Direction {
    const directions = [_]Direction{ .down, .up, .north, .south, .west, .east };
    const normals = [_][3]f64{
        .{ 0, -1, 0 }, // down
        .{ 0, 1, 0 }, // up
        .{ 0, 0, -1 }, // north
        .{ 0, 0, 1 }, // south
        .{ -1, 0, 0 }, // west
        .{ 1, 0, 0 }, // east
    };

    var result: Direction = .north;
    var highest_dot: f64 = -std.math.inf(f64);

    for (directions, normals) |dir, normal| {
        const dot = dx * normal[0] + dy * normal[1] + dz * normal[2];
        if (dot > highest_dot) {
            highest_dot = dot;
            result = dir;
        }
    }

    return result;
}

/// Block position containing helper
pub fn containingBlockPos(x: f64, y: f64, z: f64) BlockHitResult.BlockPos {
    return .{
        .x = Mth.floor(x),
        .y = Mth.floor(y),
        .z = Mth.floor(z),
    };
}

/// Traverse blocks along a ray - exact port of BlockGetter.traverseBlocks
/// This is the core raycasting algorithm
///
/// Parameters:
/// - from: Ray start position
/// - to: Ray end position
/// - getBlockShape: Function to get the AABB(s) for a block at given position
///                  Returns null for air/empty blocks
///
/// Returns: BlockHitResult (either a hit or miss)
pub fn traverseBlocks(
    from: Vec3,
    to: Vec3,
    comptime Context: type,
    context: Context,
    comptime getBlockShape: fn (ctx: Context, pos: BlockHitResult.BlockPos) ?[]const AABB,
) BlockHitResult {
    if (from.x == to.x and from.y == to.y and from.z == to.z) {
        const delta = Vec3{ .x = from.x - to.x, .y = from.y - to.y, .z = from.z - to.z };
        return BlockHitResult.missFn(
            to,
            getApproximateNearest(delta.x, delta.y, delta.z),
            containingBlockPos(to.x, to.y, to.z),
        );
    }

    // Lerp with -1.0e-7 to avoid edge cases
    // Equivalent to: double toX = Mth.lerp(-1.0E-7, to.x, from.x);
    const to_x = Mth.lerp(-1.0e-7, to.x, from.x);
    const to_y = Mth.lerp(-1.0e-7, to.y, from.y);
    const to_z = Mth.lerp(-1.0e-7, to.z, from.z);
    const from_x = Mth.lerp(-1.0e-7, from.x, to.x);
    const from_y = Mth.lerp(-1.0e-7, from.y, to.y);
    const from_z = Mth.lerp(-1.0e-7, from.z, to.z);

    var current_block_x = Mth.floor(from_x);
    var current_block_y = Mth.floor(from_y);
    var current_block_z = Mth.floor(from_z);

    const first_pos = BlockHitResult.BlockPos{
        .x = current_block_x,
        .y = current_block_y,
        .z = current_block_z,
    };

    if (getBlockShape(context, first_pos)) |aabbs| {
        if (AABB.clipWithResult(aabbs, from, to, first_pos)) |result| {
            return result;
        }
    }

    // DDA algorithm
    const dx = to_x - from_x;
    const dy = to_y - from_y;
    const dz = to_z - from_z;

    const sign_x = Mth.sign(dx);
    const sign_y = Mth.sign(dy);
    const sign_z = Mth.sign(dz);

    const t_delta_x: f64 = if (sign_x == 0) std.math.floatMax(f64) else @as(f64, @floatFromInt(sign_x)) / dx;
    const t_delta_y: f64 = if (sign_y == 0) std.math.floatMax(f64) else @as(f64, @floatFromInt(sign_y)) / dy;
    const t_delta_z: f64 = if (sign_z == 0) std.math.floatMax(f64) else @as(f64, @floatFromInt(sign_z)) / dz;

    var t_x = t_delta_x * (if (sign_x > 0) 1.0 - Mth.frac(from_x) else Mth.frac(from_x));
    var t_y = t_delta_y * (if (sign_y > 0) 1.0 - Mth.frac(from_y) else Mth.frac(from_y));
    var t_z = t_delta_z * (if (sign_z > 0) 1.0 - Mth.frac(from_z) else Mth.frac(from_z));

    while (t_x <= 1.0 or t_y <= 1.0 or t_z <= 1.0) {
        if (t_x < t_y) {
            if (t_x < t_z) {
                current_block_x += sign_x;
                t_x += t_delta_x;
            } else {
                current_block_z += sign_z;
                t_z += t_delta_z;
            }
        } else if (t_y < t_z) {
            current_block_y += sign_y;
            t_y += t_delta_y;
        } else {
            current_block_z += sign_z;
            t_z += t_delta_z;
        }

        const pos = BlockHitResult.BlockPos{
            .x = current_block_x,
            .y = current_block_y,
            .z = current_block_z,
        };

        if (getBlockShape(context, pos)) |aabbs| {
            if (AABB.clipWithResult(aabbs, from, to, pos)) |result| {
                return result;
            }
        }
    }

    const delta = Vec3{ .x = from.x - to.x, .y = from.y - to.y, .z = from.z - to.z };
    return BlockHitResult.missFn(
        to,
        getApproximateNearest(delta.x, delta.y, delta.z),
        containingBlockPos(to.x, to.y, to.z),
    );
}

/// Simple raycast for full blocks only (no complex shapes)
/// Uses a unit cube AABB for each solid block
pub fn traverseBlocksSimple(
    from: Vec3,
    to: Vec3,
    comptime Context: type,
    context: Context,
    comptime isSolid: fn (ctx: Context, pos: BlockHitResult.BlockPos) bool,
) BlockHitResult {
    // Unit cube AABB (0,0,0 to 1,1,1)
    const unit_cube = [_]AABB{AABB.init(0, 0, 0, 1, 1, 1)};

    const Wrapper = struct {
        ctx: Context,
        is_solid_fn: *const fn (ctx: Context, pos: BlockHitResult.BlockPos) bool,

        fn getShape(self: @This(), pos: BlockHitResult.BlockPos) ?[]const AABB {
            if (self.is_solid_fn(self.ctx, pos)) {
                return &unit_cube;
            }
            return null;
        }
    };

    const wrapper = Wrapper{
        .ctx = context,
        .is_solid_fn = isSolid,
    };

    return traverseBlocks(from, to, Wrapper, wrapper, Wrapper.getShape);
}
