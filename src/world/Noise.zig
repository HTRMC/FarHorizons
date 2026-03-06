const std = @import("std");
const c = @import("../platform/c.zig").c;
const WorldState = @import("WorldState.zig");

const Noise = @This();

const CS = WorldState.CHUNK_SIZE;

/// Coarse grid: 4-block step (matching Infdev's horizontal spacing)
pub const STEP = 4;
pub const SC = CS / STEP + 1; // 9 for CS=32
pub const SC2 = SC * SC;
pub const SC3 = SC * SC * SC;

const MAX_FEATURE_SET: c_uint = ~@as(c_uint, 0);

node: *anyopaque,

pub fn init() ?Noise {
    const perlin_id = findMetadataId("Perlin") orelse return null;
    const node_ptr = c.fnNewFromMetadata(perlin_id, MAX_FEATURE_SET) orelse return null;
    return .{ .node = node_ptr };
}

pub fn deinit(self: *Noise) void {
    c.fnDeleteNodeRef(self.node);
}

/// Infdev-style FBm for a coarse 2D grid.
/// Inverted octave weighting: starts at high freq (scale), halves freq and doubles amp each octave.
/// Output is NOT normalized — matches Infdev's raw summation.
pub fn infdevFbm2D(
    self: *const Noise,
    out: *[SC2]f32,
    grid_x_start: i32,
    grid_z_start: i32,
    seed: i32,
    scale: f32,
    octaves: u32,
) void {
    @memset(out, 0);
    var temp: [SC2]f32 = undefined;
    var freq: f32 = scale; // start at full scale (highest frequency)
    var inv_amp: f32 = 1.0; // amplitude = 1/inv_amp, starts at 1

    const gx: f32 = @floatFromInt(grid_x_start);
    const gz: f32 = @floatFromInt(grid_z_start);

    for (0..octaves) |_| {
        c.fnGenUniformGrid2D(
            self.node,
            &temp,
            gx * freq, // offset
            gz * freq,
            @intCast(SC),
            @intCast(SC),
            freq, // step between adjacent grid points
            freq,
            seed,
            null,
        );
        const amp = 1.0 / inv_amp;
        for (0..SC2) |i| {
            out[i] += temp[i] * amp;
        }
        freq *= 0.5; // halve frequency
        inv_amp *= 0.5; // double amplitude (1/inv_amp doubles)
    }
}

/// Infdev-style FBm for a coarse 3D grid.
/// Output order matches chunkIndex(bx, by, bz) = by*SC*SC + bz*SC + bx.
pub fn infdevFbm3D(
    self: *const Noise,
    out: *[SC3]f32,
    grid_x_start: i32,
    grid_y_start: i32,
    grid_z_start: i32,
    seed: i32,
    scale_xz: f32,
    scale_y: f32,
    octaves: u32,
) void {
    @memset(out, 0);
    var temp: [SC3]f32 = undefined;
    var freq_xz: f32 = scale_xz;
    var freq_y: f32 = scale_y;
    var inv_amp: f32 = 1.0;

    const gx: f32 = @floatFromInt(grid_x_start);
    const gy: f32 = @floatFromInt(grid_y_start);
    const gz: f32 = @floatFromInt(grid_z_start);

    for (0..octaves) |_| {
        // Swap y/z for FastNoise output order (z-outer, y-mid, x-inner)
        // so output[by*SC*SC + bz*SC + bx] = chunkIndex order
        c.fnGenUniformGrid3D(
            self.node,
            &temp,
            gx * freq_xz, // fn_x = world x
            gz * freq_xz, // fn_y = world z (swapped)
            gy * freq_y, // fn_z = world y (swapped)
            @intCast(SC),
            @intCast(SC),
            @intCast(SC),
            freq_xz,
            freq_xz,
            freq_y,
            seed,
            null,
        );
        const amp = 1.0 / inv_amp;
        for (0..SC3) |i| {
            out[i] += temp[i] * amp;
        }
        freq_xz *= 0.5;
        freq_y *= 0.5;
        inv_amp *= 0.5;
    }
}

/// Bilinear interpolation from coarse 2D grid to block position (bx, bz).
pub fn bilerp2D(grid: *const [SC2]f32, bx: usize, bz: usize) f32 {
    const sx = bx / STEP;
    const sz = bz / STEP;
    const fx: f32 = @as(f32, @floatFromInt(bx % STEP)) / STEP;
    const fz: f32 = @as(f32, @floatFromInt(bz % STEP)) / STEP;

    const idx_00 = sz * SC + sx;
    const idx_10 = idx_00 + 1;
    const idx_01 = idx_00 + SC;
    const idx_11 = idx_01 + 1;

    const v00 = grid[idx_00];
    const v10 = grid[idx_10];
    const v01 = grid[idx_01];
    const v11 = grid[idx_11];

    const top = v00 + (v10 - v00) * fx;
    const bot = v01 + (v11 - v01) * fx;
    return top + (bot - top) * fz;
}

/// Trilinear interpolation from coarse 3D grid to block position (bx, by, bz).
pub fn trilerp3D(grid: *const [SC3]f32, bx: usize, by: usize, bz: usize) f32 {
    const sx = bx / STEP;
    const sy = by / STEP;
    const sz = bz / STEP;
    const fx: f32 = @as(f32, @floatFromInt(bx % STEP)) / STEP;
    const fy: f32 = @as(f32, @floatFromInt(by % STEP)) / STEP;
    const fz: f32 = @as(f32, @floatFromInt(bz % STEP)) / STEP;

    const idx_000 = sy * SC * SC + sz * SC + sx;
    const idx_100 = idx_000 + 1;
    const idx_010 = idx_000 + SC * SC;
    const idx_110 = idx_010 + 1;
    const idx_001 = idx_000 + SC;
    const idx_101 = idx_001 + 1;
    const idx_011 = idx_000 + SC * SC + SC;
    const idx_111 = idx_011 + 1;

    const c00 = grid[idx_000] + (grid[idx_100] - grid[idx_000]) * fx;
    const c10 = grid[idx_010] + (grid[idx_110] - grid[idx_010]) * fx;
    const c01 = grid[idx_001] + (grid[idx_101] - grid[idx_001]) * fx;
    const c11 = grid[idx_011] + (grid[idx_111] - grid[idx_011]) * fx;

    const c0 = c00 + (c01 - c00) * fz;
    const c1 = c10 + (c11 - c10) * fz;

    return c0 + (c1 - c0) * fy;
}

/// Single-point Infdev-style FBm 3D (for sampleHeight).
pub fn sampleInfdevFbm3D(self: *const Noise, x: f32, y: f32, z: f32, seed: i32, scale_xz: f32, scale_y: f32, octaves: u32) f32 {
    var total: f32 = 0;
    var freq_xz: f32 = scale_xz;
    var freq_y: f32 = scale_y;
    var inv_amp: f32 = 1.0;
    for (0..octaves) |_| {
        // y/z swapped to match grid ordering
        total += c.fnGenSingle3D(self.node, x * freq_xz, z * freq_xz, y * freq_y, seed) / inv_amp;
        freq_xz *= 0.5;
        freq_y *= 0.5;
        inv_amp *= 0.5;
    }
    return total;
}

/// Single-point standard FBm 2D.
pub fn sampleFbm2D(self: *const Noise, x: f32, z: f32, seed: i32, base_freq: f32, octaves: u32) f32 {
    var total: f32 = 0;
    var amp: f32 = 1.0;
    var freq: f32 = base_freq;
    var max_amp: f32 = 0;
    for (0..octaves) |_| {
        total += c.fnGenSingle2D(self.node, x * freq, z * freq, seed) * amp;
        max_amp += amp;
        amp *= 0.5;
        freq *= 2.0;
    }
    return total / max_amp;
}

fn findMetadataId(name: []const u8) ?c_int {
    const count = c.fnGetMetadataCount();
    var i: c_int = 0;
    while (i < count) : (i += 1) {
        const meta_name = c.fnGetMetadataName(i) orelse continue;
        if (std.mem.eql(u8, std.mem.span(meta_name), name)) return i;
    }
    std.log.err("[Noise] Metadata '{s}' not found", .{name});
    return null;
}
