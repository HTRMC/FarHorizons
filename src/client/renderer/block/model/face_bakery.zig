const std = @import("std");
const BlockElement = @import("block_element.zig").BlockElement;
const BlockElementFace = @import("block_element.zig").BlockElementFace;
const BlockElementRotation = @import("block_element.zig").BlockElementRotation;
const Direction = @import("block_element.zig").Direction;
const BakedQuad = @import("baked_quad.zig").BakedQuad;
const FaceInfo = @import("../face_info.zig").FaceInfo;

/// Bakes block model faces into BakedQuads
/// Matches net/minecraft/client/renderer/block/model/FaceBakery.java
pub const FaceBakery = struct {
    /// Bake a face into a BakedQuad
    pub fn bakeQuad(
        from: [3]f32,
        to: [3]f32,
        face: BlockElementFace,
        facing: Direction,
        element_rotation: ?BlockElementRotation,
        shade: bool,
        light_emission: u8,
        texture_index: u32,
    ) BakedQuad {
        // Get face info for vertex ordering
        const face_info = FaceInfo.fromFacing(facing);

        // Calculate vertex positions
        var positions: [4][3]f32 = undefined;
        var packed_uvs: [4]u64 = undefined;

        // Get UVs (use defaults if not specified)
        const uvs = face.uv orelse defaultFaceUV(from, to, facing);

        for (0..4) |i| {
            // Get vertex info for this corner
            const vertex_info = face_info.getVertexInfo(@intCast(i));

            // Select coordinates based on vertex info
            var vertex: [3]f32 = .{
                vertex_info.x_face.select(from[0], from[1], from[2], to[0], to[1], to[2]),
                vertex_info.y_face.select(from[0], from[1], from[2], to[0], to[1], to[2]),
                vertex_info.z_face.select(from[0], from[1], from[2], to[0], to[1], to[2]),
            };

            // Convert from 0-16 to 0-1 range
            vertex[0] /= 16.0;
            vertex[1] /= 16.0;
            vertex[2] /= 16.0;

            // Apply element rotation if present
            if (element_rotation) |rot| {
                rotateVertex(&vertex, rot);
            }

            positions[i] = vertex;

            // Get UV for this vertex
            const u = getU(uvs, face.rotation, @intCast(i));
            const v = getV(uvs, face.rotation, @intCast(i));
            packed_uvs[i] = packUV(u, v);
        }

        return BakedQuad{
            .position0 = positions[0],
            .position1 = positions[1],
            .position2 = positions[2],
            .position3 = positions[3],
            .packed_uv0 = packed_uvs[0],
            .packed_uv1 = packed_uvs[1],
            .packed_uv2 = packed_uvs[2],
            .packed_uv3 = packed_uvs[3],
            .texture_index = texture_index,
            .tint_index = face.tint_index,
            .direction = facing,
            .shade = shade,
            .light_emission = light_emission,
        };
    }

    /// Calculate default UVs based on face direction
    fn defaultFaceUV(from: [3]f32, to: [3]f32, facing: Direction) [4]f32 {
        return switch (facing) {
            .down => .{ from[0], 16.0 - to[2], to[0], 16.0 - from[2] },
            .up => .{ from[0], from[2], to[0], to[2] },
            .north => .{ 16.0 - to[0], 16.0 - to[1], 16.0 - from[0], 16.0 - from[1] },
            .south => .{ from[0], 16.0 - to[1], to[0], 16.0 - from[1] },
            .west => .{ from[2], 16.0 - to[1], to[2], 16.0 - from[1] },
            .east => .{ 16.0 - to[2], 16.0 - to[1], 16.0 - from[2], 16.0 - from[1] },
        };
    }

    /// Get U coordinate for vertex, accounting for rotation
    /// Vertex mapping: 0=top-left, 1=bottom-left, 2=bottom-right, 3=top-right
    fn getU(uvs: [4]f32, rotation: i32, vertex: u32) f32 {
        const rotated_vertex = rotateVertexIndex(vertex, rotation);
        return switch (rotated_vertex) {
            0, 1 => uvs[0], // u1 (left vertices)
            2, 3 => uvs[2], // u2 (right vertices)
            else => unreachable,
        };
    }

    /// Get V coordinate for vertex, accounting for rotation
    /// Vertex mapping: 0=top-left, 1=bottom-left, 2=bottom-right, 3=top-right
    fn getV(uvs: [4]f32, rotation: i32, vertex: u32) f32 {
        const rotated_vertex = rotateVertexIndex(vertex, rotation);
        return switch (rotated_vertex) {
            0, 3 => uvs[1], // v1 (top vertices)
            1, 2 => uvs[3], // v2 (bottom vertices)
            else => unreachable,
        };
    }

    /// Rotate vertex index by UV rotation amount
    fn rotateVertexIndex(vertex: u32, rotation: i32) u32 {
        const steps: u32 = @intCast(@divFloor(rotation, 90));
        return (vertex + steps) % 4;
    }

    /// Pack U and V into a single u64
    fn packUV(u: f32, v: f32) u64 {
        const u_bits: u32 = @bitCast(u);
        const v_bits: u32 = @bitCast(v);
        return (@as(u64, u_bits) << 32) | @as(u64, v_bits);
    }

    /// Apply element rotation to a vertex
    fn rotateVertex(vertex: *[3]f32, rotation: BlockElementRotation) void {
        // Translate to rotation origin
        const origin = rotation.origin;
        vertex[0] -= origin[0] / 16.0;
        vertex[1] -= origin[1] / 16.0;
        vertex[2] -= origin[2] / 16.0;

        // Convert angle to radians
        const angle_rad = rotation.angle * std.math.pi / 180.0;
        const cos_a = @cos(angle_rad);
        const sin_a = @sin(angle_rad);

        // Rotate around the specified axis
        switch (rotation.axis) {
            'x' => {
                const y = vertex[1];
                const z = vertex[2];
                vertex[1] = y * cos_a - z * sin_a;
                vertex[2] = y * sin_a + z * cos_a;
            },
            'y' => {
                const x = vertex[0];
                const z = vertex[2];
                vertex[0] = x * cos_a + z * sin_a;
                vertex[2] = -x * sin_a + z * cos_a;
            },
            'z' => {
                const x = vertex[0];
                const y = vertex[1];
                vertex[0] = x * cos_a - y * sin_a;
                vertex[1] = x * sin_a + y * cos_a;
            },
            else => {},
        }

        // Apply rescale if needed
        if (rotation.rescale) {
            const scale = 1.0 / @max(cos_a, sin_a);
            switch (rotation.axis) {
                'x' => {
                    vertex[1] *= scale;
                    vertex[2] *= scale;
                },
                'y' => {
                    vertex[0] *= scale;
                    vertex[2] *= scale;
                },
                'z' => {
                    vertex[0] *= scale;
                    vertex[1] *= scale;
                },
                else => {},
            }
        }

        // Translate back from rotation origin
        vertex[0] += origin[0] / 16.0;
        vertex[1] += origin[1] / 16.0;
        vertex[2] += origin[2] / 16.0;
    }
};
