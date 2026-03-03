const std = @import("std");
const c = @import("../platform/c.zig").c;
const WorldState = @import("WorldState.zig");

const Noise = @This();

const CS = WorldState.CHUNK_SIZE;
const CS2 = CS * CS;
const CS3 = CS * CS * CS;

/// UINT32_MAX = no SIMD limit (auto-detect best available)
const MAX_FEATURE_SET: c_uint = ~@as(c_uint, 0);

simplex_node: *anyopaque,

pub fn init() ?Noise {
    const simplex_id = findMetadataId("Simplex") orelse return null;
    const node = c.fnNewFromMetadata(simplex_id, MAX_FEATURE_SET) orelse return null;
    return .{ .simplex_node = node };
}

pub fn deinit(self: *Noise) void {
    c.fnDeleteNodeRef(self.simplex_node);
}

/// Fill a CHUNK_SIZE x CHUNK_SIZE grid with FBm 2D noise.
/// Output index: out[bz * CS + bx]
pub fn gridFbm2D(
    self: *const Noise,
    out: *[CS2]f32,
    ox: f32,
    oz: f32,
    seed: i32,
    base_freq: f32,
    octaves: u32,
) void {
    @memset(out, 0);
    var temp: [CS2]f32 = undefined;
    var amp: f32 = 1.0;
    var freq: f32 = base_freq;
    var max_amp: f32 = 0;

    for (0..octaves) |_| {
        // fnGenUniformGrid2D: x → world x, y → world z
        c.fnGenUniformGrid2D(
            self.simplex_node,
            &temp,
            ox * freq, // xOffset
            oz * freq, // yOffset (= world z)
            @intCast(CS), // xCount
            @intCast(CS), // yCount
            freq, // xStepSize
            freq, // yStepSize
            seed,
            null,
        );
        for (0..CS2) |i| {
            out[i] += temp[i] * amp;
        }
        max_amp += amp;
        amp *= 0.5;
        freq *= 2.0;
    }

    const inv = 1.0 / max_amp;
    for (0..CS2) |i| {
        out[i] *= inv;
    }
}

/// Fill a CHUNK_SIZE^3 grid with FBm 3D noise.
/// Output matches chunkIndex(bx, by, bz) = by * CS*CS + bz * CS + bx
/// by swapping y/z in the FastNoise call.
pub fn gridFbm3D(
    self: *const Noise,
    out: *[CS3]f32,
    ox: f32,
    oy: f32,
    oz: f32,
    seed: i32,
    base_freq: f32,
    octaves: u32,
) void {
    @memset(out, 0);
    var temp: [CS3]f32 = undefined;
    var amp: f32 = 1.0;
    var freq: f32 = base_freq;
    var max_amp: f32 = 0;

    for (0..octaves) |_| {
        // Swap y/z so output order matches chunkIndex(bx, by, bz):
        // FastNoise iterates z(outer),y(mid),x(inner) → out[fz*yC*xC + fy*xC + fx]
        // With fn_x=world_x, fn_y=world_z, fn_z=world_y:
        //   out[by*CS*CS + bz*CS + bx] = chunkIndex(bx, by, bz)
        c.fnGenUniformGrid3D(
            self.simplex_node,
            &temp,
            ox * freq, // xOffset (world x)
            oz * freq, // yOffset (world z — swapped)
            oy * freq, // zOffset (world y — swapped)
            @intCast(CS), // xCount
            @intCast(CS), // yCount (world z count)
            @intCast(CS), // zCount (world y count)
            freq, // xStepSize
            freq, // yStepSize
            freq, // zStepSize
            seed,
            null,
        );
        for (0..CS3) |i| {
            out[i] += temp[i] * amp;
        }
        max_amp += amp;
        amp *= 0.5;
        freq *= 2.0;
    }

    const inv = 1.0 / max_amp;
    for (0..CS3) |i| {
        out[i] *= inv;
    }
}

/// Single-point FBm 2D (for sampleHeight).
pub fn sampleFbm2D(self: *const Noise, x: f32, z: f32, seed: i32, base_freq: f32, octaves: u32) f32 {
    var total: f32 = 0;
    var amp: f32 = 1.0;
    var freq: f32 = base_freq;
    var max_amp: f32 = 0;
    for (0..octaves) |_| {
        total += c.fnGenSingle2D(self.simplex_node, x * freq, z * freq, seed) * amp;
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
