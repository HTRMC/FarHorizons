const std = @import("std");
const WorldState = @import("WorldState.zig");

const Noise = @This();

const CS = WorldState.CHUNK_SIZE;

/// Coarse grid: 4-block step (matching Infdev's horizontal spacing)
pub const STEP = 4;
pub const SC = CS / STEP + 1; // 9 for CS=32
pub const SC2 = SC * SC;
pub const SC3 = SC * SC * SC;

// SIMD batch width for vectorized Perlin sampling
pub const VEC_LEN = 4;
const F64xN = @Vector(VEC_LEN, f64);
const I32xN = @Vector(VEC_LEN, i32);

// ============================================================
// RNG — splitmix64 for deterministic permutation table init
// ============================================================

const Rng = struct {
    state: u64,

    fn init(seed: u64) Rng {
        return .{ .state = seed };
    }

    fn next(self: *Rng) u64 {
        self.state +%= 0x9e3779b97f4a7c15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        return z ^ (z >> 31);
    }

    fn nextF64(self: *Rng) f64 {
        return @as(f64, @floatFromInt(self.next() >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
    }

    fn bounded(self: *Rng, max: u32) u32 {
        return @intCast(self.next() % max);
    }
};

// ============================================================
// Improved Perlin noise — exact port of Java's a.java
// ============================================================

pub const Perlin = struct {
    perm: [512]i32,
    x_off: f64,
    y_off: f64,
    z_off: f64,

    pub fn init(rng: *Rng) Perlin {
        var self: Perlin = undefined;

        // Random offsets (Java: this.b/c/d = nextDouble() * 256)
        self.x_off = rng.nextF64() * 256.0;
        self.y_off = rng.nextF64() * 256.0;
        self.z_off = rng.nextF64() * 256.0;

        // Initialize identity permutation
        for (0..256) |i| {
            self.perm[i] = @intCast(i);
        }

        // Fisher-Yates shuffle (Java: nextInt(256 - i) + i)
        for (0..256) |i| {
            const j = rng.bounded(@intCast(256 - i)) + @as(u32, @intCast(i));
            const tmp = self.perm[i];
            self.perm[i] = self.perm[j];
            self.perm[j] = tmp;
        }

        // Duplicate for wrapping
        for (0..256) |i| {
            self.perm[i + 256] = self.perm[i];
        }

        return self;
    }

    /// Ken Perlin's improved gradient function (Java a.java line 75)
    /// 16 gradient directions: 12 edges of a cube + 4 repeats
    inline fn grad(hash: i32, x: f64, y: f64, z: f64) f64 {
        const h: u4 = @intCast(hash & 15);
        const u = if (h < 8) x else y;
        const v = if (h < 4) y else if (h != 12 and h != 14) z else x;
        return (if (h & 1 == 0) u else -u) + (if (h & 2 == 0) v else -v);
    }

    /// Quintic fade curve: 6t^5 - 15t^4 + 10t^3
    inline fn fade(t: f64) f64 {
        return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
    }

    inline fn lerp(t: f64, a: f64, b: f64) f64 {
        return a + t * (b - a);
    }

    /// 3D improved Perlin noise (Java a.java line 34, method b)
    pub fn sample3D(self: *const Perlin, xin: f64, yin: f64, zin: f64) f64 {
        const x = xin + self.x_off;
        const y = yin + self.y_off;
        const z = zin + self.z_off;

        // Floor (Java: cast to int, then adjust for negative)
        const xi: i32 = @intFromFloat(@floor(x));
        const yi: i32 = @intFromFloat(@floor(y));
        const zi: i32 = @intFromFloat(@floor(z));

        // Wrap to 0-255
        const X: usize = @intCast(xi & 255);
        const Y: usize = @intCast(yi & 255);
        const Z: usize = @intCast(zi & 255);

        // Fractional parts
        const xf = x - @as(f64, @floatFromInt(xi));
        const yf = y - @as(f64, @floatFromInt(yi));
        const zf = z - @as(f64, @floatFromInt(zi));

        // Fade curves
        const u = fade(xf);
        const v = fade(yf);
        const w = fade(zf);

        // Hash coordinates of the 8 cube corners
        const p = &self.perm;
        const A = p[X] + @as(i32, @intCast(Y));
        const AA = p[@intCast(A)] + @as(i32, @intCast(Z));
        const AB = p[@intCast(A + 1)] + @as(i32, @intCast(Z));
        const B = p[X + 1] + @as(i32, @intCast(Y));
        const BA = p[@intCast(B)] + @as(i32, @intCast(Z));
        const BB = p[@intCast(B + 1)] + @as(i32, @intCast(Z));

        // Gradient dot products and trilinear interpolation
        return lerp(w, lerp(v, lerp(u, grad(p[@intCast(AA)], xf, yf, zf), grad(p[@intCast(BA)], xf - 1.0, yf, zf)), lerp(u, grad(p[@intCast(AB)], xf, yf - 1.0, zf), grad(p[@intCast(BB)], xf - 1.0, yf - 1.0, zf))), lerp(v, lerp(u, grad(p[@intCast(AA + 1)], xf, yf, zf - 1.0), grad(p[@intCast(BA + 1)], xf - 1.0, yf, zf - 1.0)), lerp(u, grad(p[@intCast(AB + 1)], xf, yf - 1.0, zf - 1.0), grad(p[@intCast(BB + 1)], xf - 1.0, yf - 1.0, zf - 1.0))));
    }

    /// 2D Perlin noise — calls 3D with z=0 (Java a.java line 82)
    pub fn sample2D(self: *const Perlin, x: f64, y: f64) f64 {
        return self.sample3D(x, y, 0.0);
    }

    // ---- SIMD vectorized helpers ----

    inline fn fadeVec(t: F64xN) F64xN {
        const six: F64xN = @splat(6.0);
        const fifteen: F64xN = @splat(15.0);
        const ten: F64xN = @splat(10.0);
        return t * t * t * (t * (t * six - fifteen) + ten);
    }

    inline fn lerpVec(t: F64xN, a: F64xN, b: F64xN) F64xN {
        return a + t * (b - a);
    }

    /// Vectorized gradient using SIMD selects instead of branches
    inline fn gradVec(hash_arr: [VEC_LEN]i32, x: F64xN, y: F64xN, z: F64xN) F64xN {
        const h: I32xN = @as(I32xN, hash_arr) & @as(I32xN, @splat(@as(i32, 15)));
        const zero: I32xN = @splat(0);

        // u = (h < 8) ? x : y
        const u_val = @select(f64, h < @as(I32xN, @splat(@as(i32, 8))), x, y);

        // v = (h < 4) ? y : ((h == 12 || h == 14) ? x : z)
        // (h & 13) == 12 is true exactly for h=12 and h=14
        const is_12_or_14 = (h & @as(I32xN, @splat(@as(i32, 13)))) == @as(I32xN, @splat(@as(i32, 12)));
        const inner_v = @select(f64, is_12_or_14, x, z);
        const v_val = @select(f64, h < @as(I32xN, @splat(@as(i32, 4))), y, inner_v);

        // Signs: (h & 1 == 0) ? u : -u, (h & 2 == 0) ? v : -v
        const u_signed = @select(f64, (h & @as(I32xN, @splat(@as(i32, 1)))) == zero, u_val, -u_val);
        const v_signed = @select(f64, (h & @as(I32xN, @splat(@as(i32, 2)))) == zero, v_val, -v_val);

        return u_signed + v_signed;
    }

    /// Evaluate VEC_LEN Perlin noise samples in parallel using SIMD.
    /// Produces bit-identical results to VEC_LEN calls of sample3D.
    pub fn sample3D_vec(self: *const Perlin, xs: F64xN, ys: F64xN, zs: F64xN) F64xN {
        const x = xs + @as(F64xN, @splat(self.x_off));
        const y = ys + @as(F64xN, @splat(self.y_off));
        const z = zs + @as(F64xN, @splat(self.z_off));

        const x_floor = @floor(x);
        const y_floor = @floor(y);
        const z_floor = @floor(z);
        const xi: I32xN = @intFromFloat(x_floor);
        const yi: I32xN = @intFromFloat(y_floor);
        const zi: I32xN = @intFromFloat(z_floor);

        const xf = x - x_floor;
        const yf = y - y_floor;
        const zf = z - z_floor;

        const u = fadeVec(xf);
        const v = fadeVec(yf);
        const w = fadeVec(zf);

        // Wrap to 0-255 and gather perm table entries (scalar per lane)
        const mask255: I32xN = @splat(255);
        const X_v = xi & mask255;
        const Y_v = yi & mask255;
        const Z_v = zi & mask255;

        const p = &self.perm;
        var h_corners: [8][VEC_LEN]i32 = undefined;

        inline for (0..VEC_LEN) |lane| {
            const X: usize = @intCast(X_v[lane]);
            const Y: usize = @intCast(Y_v[lane]);
            const Z: usize = @intCast(Z_v[lane]);

            const A_val = p[X] + @as(i32, @intCast(Y));
            const AA = p[@intCast(A_val)] + @as(i32, @intCast(Z));
            const AB = p[@intCast(A_val + 1)] + @as(i32, @intCast(Z));
            const B_val = p[X + 1] + @as(i32, @intCast(Y));
            const BA = p[@intCast(B_val)] + @as(i32, @intCast(Z));
            const BB = p[@intCast(B_val + 1)] + @as(i32, @intCast(Z));

            h_corners[0][lane] = p[@intCast(AA)];
            h_corners[1][lane] = p[@intCast(BA)];
            h_corners[2][lane] = p[@intCast(AB)];
            h_corners[3][lane] = p[@intCast(BB)];
            h_corners[4][lane] = p[@intCast(AA + 1)];
            h_corners[5][lane] = p[@intCast(BA + 1)];
            h_corners[6][lane] = p[@intCast(AB + 1)];
            h_corners[7][lane] = p[@intCast(BB + 1)];
        }

        const one: F64xN = @splat(1.0);
        const xf1 = xf - one;
        const yf1 = yf - one;
        const zf1 = zf - one;

        return lerpVec(w, lerpVec(v, lerpVec(u, gradVec(h_corners[0], xf, yf, zf), gradVec(h_corners[1], xf1, yf, zf)), lerpVec(u, gradVec(h_corners[2], xf, yf1, zf), gradVec(h_corners[3], xf1, yf1, zf))), lerpVec(v, lerpVec(u, gradVec(h_corners[4], xf, yf, zf1), gradVec(h_corners[5], xf1, yf, zf1)), lerpVec(u, gradVec(h_corners[6], xf, yf1, zf1), gradVec(h_corners[7], xf1, yf1, zf1))));
    }
};

// ============================================================
// OctavePerlin — exact port of Java's c.java (inverted FBm)
// ============================================================

const MAX_OCTAVES = 16;

pub const OctavePerlin = struct {
    perlin: [MAX_OCTAVES]Perlin,
    num_octaves: u32,

    pub fn init(rng: *Rng, num_octaves: u32) OctavePerlin {
        var self: OctavePerlin = undefined;
        self.num_octaves = num_octaves;
        for (0..num_octaves) |i| {
            self.perlin[i] = Perlin.init(rng);
        }
        return self;
    }

    /// Inverted FBm 3D (c.java line 31): freq halves, amp doubles each octave.
    /// Caller pre-multiplies coordinates by the base scale.
    pub fn sample3D(self: *const OctavePerlin, x: f64, y: f64, z: f64) f64 {
        var total: f64 = 0;
        var freq: f64 = 1.0;
        for (0..self.num_octaves) |i| {
            total += self.perlin[i].sample3D(x * freq, y * freq, z * freq) / freq;
            freq /= 2.0;
        }
        return total;
    }

    /// Inverted FBm 2D (c.java line 19): same weighting, calls 2D Perlin.
    pub fn sample2D(self: *const OctavePerlin, x: f64, z: f64) f64 {
        var total: f64 = 0;
        var freq: f64 = 1.0;
        for (0..self.num_octaves) |i| {
            total += self.perlin[i].sample2D(x * freq, z * freq) / freq;
            freq /= 2.0;
        }
        return total;
    }

    /// Fill a coarse 2D grid using the batch approach from Infdev.
    /// Matches a.java batch with y_count=1, y_scale=0 (2D slice at y=0).
    /// Output order: [z][x] → out[iz * SC + ix]
    pub fn fillGrid2D(
        self: *const OctavePerlin,
        out: *[SC2]f32,
        gx_start: i32,
        gz_start: i32,
        x_scale: f64,
        z_scale: f64,
    ) void {
        @memset(out, 0);
        var freq: f64 = 1.0;

        for (0..self.num_octaves) |oct| {
            const p = &self.perlin[oct];
            const amp: f32 = @floatCast(1.0 / freq);

            for (0..SC) |iz| {
                const z = @as(f64, @floatFromInt(gz_start + @as(i32, @intCast(iz)))) * z_scale * freq;
                const z_splat: F64xN = @splat(z);
                const y_zero: F64xN = @splat(@as(f64, 0));

                var ix: usize = 0;
                while (ix + VEC_LEN <= SC) : (ix += VEC_LEN) {
                    var x_arr: [VEC_LEN]f64 = undefined;
                    inline for (0..VEC_LEN) |lane| {
                        x_arr[lane] = @as(f64, @floatFromInt(gx_start + @as(i32, @intCast(ix + lane)))) * x_scale * freq;
                    }
                    const results = p.sample3D_vec(x_arr, y_zero, z_splat);
                    inline for (0..VEC_LEN) |lane| {
                        out[iz * SC + ix + lane] += @as(f32, @floatCast(results[lane])) * amp;
                    }
                }
                while (ix < SC) : (ix += 1) {
                    const x = @as(f64, @floatFromInt(gx_start + @as(i32, @intCast(ix)))) * x_scale * freq;
                    out[iz * SC + ix] += @as(f32, @floatCast(p.sample3D(x, 0, z))) * amp;
                }
            }
            freq /= 2.0;
        }
    }

    /// Fill a coarse 3D grid matching Infdev's batch function.
    /// Output order: [y][z][x] → out[iy * SC*SC + iz * SC + ix] (matches chunkIndex)
    pub fn fillGrid3D(
        self: *const OctavePerlin,
        out: *[SC3]f32,
        gx_start: i32,
        gy_start: i32,
        gz_start: i32,
        x_scale: f64,
        y_scale: f64,
        z_scale: f64,
    ) void {
        @memset(out, 0);
        var freq: f64 = 1.0;

        for (0..self.num_octaves) |oct| {
            const p = &self.perlin[oct];
            const amp: f32 = @floatCast(1.0 / freq);

            for (0..SC) |ix| {
                const x = @as(f64, @floatFromInt(gx_start + @as(i32, @intCast(ix)))) * x_scale * freq;
                const x_splat: F64xN = @splat(x);
                for (0..SC) |iz| {
                    const z = @as(f64, @floatFromInt(gz_start + @as(i32, @intCast(iz)))) * z_scale * freq;
                    const z_splat: F64xN = @splat(z);

                    var iy: usize = 0;
                    while (iy + VEC_LEN <= SC) : (iy += VEC_LEN) {
                        var y_arr: [VEC_LEN]f64 = undefined;
                        inline for (0..VEC_LEN) |lane| {
                            y_arr[lane] = @as(f64, @floatFromInt(gy_start + @as(i32, @intCast(iy + lane)))) * y_scale * freq;
                        }
                        const results = p.sample3D_vec(x_splat, y_arr, z_splat);
                        inline for (0..VEC_LEN) |lane| {
                            out[(iy + lane) * SC * SC + iz * SC + ix] += @as(f32, @floatCast(results[lane])) * amp;
                        }
                    }
                    while (iy < SC) : (iy += 1) {
                        const y = @as(f64, @floatFromInt(gy_start + @as(i32, @intCast(iy)))) * y_scale * freq;
                        out[iy * SC * SC + iz * SC + ix] += @as(f32, @floatCast(p.sample3D(x, y, z))) * amp;
                    }
                }
            }
            freq /= 2.0;
        }
    }
};

// ============================================================
// NoiseGen — all terrain noise generators (matches a.java fields)
// ============================================================

pub const NoiseGen = struct {
    density_a: OctavePerlin, // this.b — 16 octaves
    density_b: OctavePerlin, // this.c — 16 octaves
    selector: OctavePerlin, // this.d — 8 octaves
    height_mod: OctavePerlin, // this.g — 10 octaves
    roughness: OctavePerlin, // this.h — 16 octaves

    /// Initialize all noise generators from a world seed.
    /// Order matches Infdev's constructor (a.java lines 32-39):
    /// each OctavePerlin consumes RNG state sequentially.
    pub fn init(world_seed: u64) NoiseGen {
        var rng = Rng.init(world_seed);
        return .{
            .density_a = OctavePerlin.init(&rng, 16), // this.b
            .density_b = OctavePerlin.init(&rng, 16), // this.c
            .selector = OctavePerlin.init(&rng, 8), // this.d
            // this.e (4 octaves) and this.f (4 octaves) are for sand/gravel surface — skip for now
            .height_mod = blk: {
                // Skip this.e and this.f (4+4 octaves = consume 8 Perlin inits)
                for (0..8) |_| _ = Perlin.init(&rng);
                break :blk OctavePerlin.init(&rng, 10); // this.g
            },
            .roughness = OctavePerlin.init(&rng, 16), // this.h
        };
    }
};

// ============================================================
// Interpolation — unchanged from previous implementation
// ============================================================

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
