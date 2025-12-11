const std = @import("std");
const Direction = @import("BlockElement.zig").Direction;

/// A baked quad ready for rendering
/// Matches net/minecraft/client/renderer/block/model/BakedQuad.java
pub const BakedQuad = struct {
    pub const VERTEX_COUNT = 4;

    /// 4 vertex positions
    position0: [3]f32,
    position1: [3]f32,
    position2: [3]f32,
    position3: [3]f32,

    /// Packed UV coordinates for each vertex
    packed_uv0: u64,
    packed_uv1: u64,
    packed_uv2: u64,
    packed_uv3: u64,

    /// Texture array layer index
    texture_index: u32,

    /// Tint index (-1 for no tint)
    tint_index: i32,

    /// Face direction
    direction: Direction,

    /// Whether to apply ambient occlusion shading
    shade: bool,

    /// Light emission level (0-15)
    light_emission: u8,

    pub fn position(self: *const BakedQuad, vertex: u32) [3]f32 {
        return switch (vertex) {
            0 => self.position0,
            1 => self.position1,
            2 => self.position2,
            3 => self.position3,
            else => unreachable,
        };
    }

    pub fn packedUV(self: *const BakedQuad, vertex: u32) u64 {
        return switch (vertex) {
            0 => self.packed_uv0,
            1 => self.packed_uv1,
            2 => self.packed_uv2,
            3 => self.packed_uv3,
            else => unreachable,
        };
    }

    pub fn isTinted(self: *const BakedQuad) bool {
        return self.tint_index != -1;
    }
};
