const std = @import("std");
const BlockElement = @import("BlockElement.zig").BlockElement;
const BlockElementFace = @import("BlockElement.zig").BlockElementFace;
const BlockElementRotation = @import("BlockElement.zig").BlockElementRotation;
const Direction = @import("BlockElement.zig").Direction;
const BakedQuad = @import("BakedQuad.zig").BakedQuad;
const FaceInfo = @import("../FaceInfo.zig").FaceInfo;

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

    // =====================
    // Model-Level Rotation (from blockstate variant x/y)
    // =====================

    /// Apply model-level rotation (x/y from variant) to a baked quad
    /// x: rotation around X-axis (pitch) in degrees (0, 90, 180, 270)
    /// y: rotation around Y-axis (yaw) in degrees (0, 90, 180, 270)
    /// uvlock: if true, counter-rotate UVs to maintain world-aligned textures
    pub fn rotateQuad(quad: *BakedQuad, x: i16, y: i16, uvlock: bool) void {
        // Skip if no rotation
        if (x == 0 and y == 0) return;

        // Rotate all 4 vertex positions around block center (0.5, 0.5, 0.5)
        // Apply Y rotation first, then X (Minecraft order)
        rotatePosition(&quad.position0, x, y);
        rotatePosition(&quad.position1, x, y);
        rotatePosition(&quad.position2, x, y);
        rotatePosition(&quad.position3, x, y);

        // Rotate the face direction for correct culling
        quad.direction = rotateFaceDirection(quad.direction, x, y);

        // If uvlock is true, counter-rotate UVs to keep them world-aligned
        if (uvlock) {
            rotateUVs(quad, x, y);
        }
    }

    /// Rotate a position around block center (0.5, 0.5, 0.5)
    fn rotatePosition(pos: *[3]f32, x_deg: i16, y_deg: i16) void {
        // Center around (0.5, 0.5, 0.5)
        var rx = pos[0] - 0.5;
        var ry = pos[1] - 0.5;
        var rz = pos[2] - 0.5;

        // Apply Y rotation first (around Y axis)
        if (y_deg != 0) {
            const cos_y = cosFromDegrees(y_deg);
            const sin_y = sinFromDegrees(y_deg);
            const new_x = rx * cos_y + rz * sin_y;
            const new_z = -rx * sin_y + rz * cos_y;
            rx = new_x;
            rz = new_z;
        }

        // Apply X rotation (around X axis)
        if (x_deg != 0) {
            const cos_x = cosFromDegrees(x_deg);
            const sin_x = sinFromDegrees(x_deg);
            const new_y = ry * cos_x - rz * sin_x;
            const new_z = ry * sin_x + rz * cos_x;
            ry = new_y;
            rz = new_z;
        }

        // Translate back
        pos[0] = rx + 0.5;
        pos[1] = ry + 0.5;
        pos[2] = rz + 0.5;
    }

    /// Rotate face direction by model rotation (public for culling)
    pub fn rotateFaceDirection(dir: Direction, x_deg: i16, y_deg: i16) Direction {
        var result = dir;

        // Apply Y rotation (around Y axis) - affects horizontal faces
        // Y90: north→east→south→west→north
        const y_steps: u32 = @intCast(@divFloor(@mod(y_deg, 360), 90));
        for (0..y_steps) |_| {
            result = switch (result) {
                .north => .east,
                .east => .south,
                .south => .west,
                .west => .north,
                .up, .down => result, // unchanged by Y rotation
            };
        }

        // Apply X rotation (around X axis) - affects vertical faces
        // X90: up→north→down→south→up (west/east unchanged)
        const x_steps: u32 = @intCast(@divFloor(@mod(x_deg, 360), 90));
        for (0..x_steps) |_| {
            result = switch (result) {
                .up => .north,
                .north => .down,
                .down => .south,
                .south => .up,
                .west, .east => result, // unchanged by X rotation
            };
        }

        return result;
    }

    /// Counter-rotate UVs for uvlock (maintain world-aligned textures)
    fn rotateUVs(quad: *BakedQuad, x_deg: i16, y_deg: i16) void {
        const steps = calculateUVRotationSteps(quad.direction, x_deg, y_deg);
        if (steps == 0) return;

        // Rotate UV assignments between vertices
        const uvs = [4]u64{ quad.packed_uv0, quad.packed_uv1, quad.packed_uv2, quad.packed_uv3 };
        quad.packed_uv0 = uvs[(0 + steps) % 4];
        quad.packed_uv1 = uvs[(1 + steps) % 4];
        quad.packed_uv2 = uvs[(2 + steps) % 4];
        quad.packed_uv3 = uvs[(3 + steps) % 4];
    }

    /// Calculate UV rotation steps based on face and model rotation
    fn calculateUVRotationSteps(face: Direction, x_deg: i16, y_deg: i16) u32 {
        // For horizontal faces (up/down), Y rotation directly affects UV rotation
        // For vertical faces, the effect depends on both X and Y rotation
        const y_steps: u32 = @intCast(@divFloor(@mod(y_deg, 360), 90));
        const x_steps: u32 = @intCast(@divFloor(@mod(x_deg, 360), 90));

        return switch (face) {
            .up => y_steps,
            .down => (4 - y_steps) % 4, // Counter-rotate for down face
            .north, .south, .east, .west => blk: {
                // Vertical faces: X rotation can affect UV orientation
                if (x_steps == 2) {
                    // 180° X rotation flips vertical faces
                    break :blk 2;
                }
                break :blk 0;
            },
        };
    }

    /// Cosine for 90° multiples (fast path)
    fn cosFromDegrees(deg: i16) f32 {
        const normalized = @mod(deg, 360);
        return switch (normalized) {
            0 => 1.0,
            90 => 0.0,
            180 => -1.0,
            270 => 0.0,
            else => @cos(@as(f32, @floatFromInt(deg)) * std.math.pi / 180.0),
        };
    }

    /// Sine for 90° multiples (fast path)
    fn sinFromDegrees(deg: i16) f32 {
        const normalized = @mod(deg, 360);
        return switch (normalized) {
            0 => 0.0,
            90 => 1.0,
            180 => 0.0,
            270 => -1.0,
            else => @sin(@as(f32, @floatFromInt(deg)) * std.math.pi / 180.0),
        };
    }
};
