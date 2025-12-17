const std = @import("std");
const BlockElement = @import("BlockElement.zig").BlockElement;
const BlockElementFace = @import("BlockElement.zig").BlockElementFace;
const BlockElementRotation = @import("BlockElement.zig").BlockElementRotation;
const Direction = @import("BlockElement.zig").Direction;
const BakedQuad = @import("BakedQuad.zig").BakedQuad;
const FaceInfo = @import("../FaceInfo.zig").FaceInfo;

/// 3x3 matrix for UV transformation (only need rotation/flip, no translation)
const Mat3 = struct {
    m: [9]f32, // Row-major: m[0-2] = row 0, m[3-5] = row 1, m[6-8] = row 2

    const IDENTITY = Mat3{ .m = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 } };

    /// Create rotation matrix around Z axis
    fn rotateZ(angle_rad: f32) Mat3 {
        const c = @cos(angle_rad);
        const s = @sin(angle_rad);
        return .{ .m = .{ c, -s, 0, s, c, 0, 0, 0, 1 } };
    }

    /// Create rotation matrix around Y axis
    fn rotateY(angle_rad: f32) Mat3 {
        const c = @cos(angle_rad);
        const s = @sin(angle_rad);
        return .{ .m = .{ c, 0, s, 0, 1, 0, -s, 0, c } };
    }

    /// Create rotation matrix around X axis
    fn rotateX(angle_rad: f32) Mat3 {
        const c = @cos(angle_rad);
        const s = @sin(angle_rad);
        return .{ .m = .{ 1, 0, 0, 0, c, -s, 0, s, c } };
    }

    /// Multiply two matrices: result = self * other
    fn mul(self: Mat3, other: Mat3) Mat3 {
        var result: Mat3 = undefined;
        for (0..3) |row| {
            for (0..3) |col| {
                var sum: f32 = 0;
                for (0..3) |k| {
                    sum += self.m[row * 3 + k] * other.m[k * 3 + col];
                }
                result.m[row * 3 + col] = sum;
            }
        }
        return result;
    }

    /// Transform a 2D point (u, v) -> (u', v') using just XY components
    fn transformUV(self: Mat3, u: f32, v: f32) [2]f32 {
        // Treat UV as (u, v, 0) and transform, return (x, y)
        const x = self.m[0] * u + self.m[1] * v + self.m[2] * 0;
        const y = self.m[3] * u + self.m[4] * v + self.m[5] * 0;
        return .{ x, y };
    }

    /// Transform direction vector (for finding new face)
    fn transformDir(self: Mat3, x: f32, y: f32, z: f32) [3]f32 {
        return .{
            self.m[0] * x + self.m[1] * y + self.m[2] * z,
            self.m[3] * x + self.m[4] * y + self.m[5] * z,
            self.m[6] * x + self.m[7] * y + self.m[8] * z,
        };
    }

    /// Invert the matrix (for affine transforms)
    fn invert(self: Mat3) Mat3 {
        // For rotation matrices, inverse = transpose
        return .{ .m = .{
            self.m[0], self.m[3], self.m[6],
            self.m[1], self.m[4], self.m[7],
            self.m[2], self.m[5], self.m[8],
        } };
    }

    fn isIdentity(self: Mat3) bool {
        const eps: f32 = 0.0001;
        return @abs(self.m[0] - 1) < eps and @abs(self.m[1]) < eps and @abs(self.m[2]) < eps and
            @abs(self.m[3]) < eps and @abs(self.m[4] - 1) < eps and @abs(self.m[5]) < eps and
            @abs(self.m[6]) < eps and @abs(self.m[7]) < eps and @abs(self.m[8] - 1) < eps;
    }
};

/// VANILLA_UV_TRANSFORM_LOCAL_TO_GLOBAL - transforms from face-local UV space to world space
/// Matches BlockMath.java VANILLA_UV_TRANSFORM_LOCAL_TO_GLOBAL
fn getLocalToGlobalTransform(face: Direction) Mat3 {
    const PI: f32 = 3.14159265358979323846;
    return switch (face) {
        .south => Mat3.IDENTITY,
        .east => Mat3.rotateY(PI / 2.0),
        .west => Mat3.rotateY(-PI / 2.0),
        .north => Mat3.rotateY(PI),
        .up => Mat3.rotateX(-PI / 2.0),
        .down => Mat3.rotateX(PI / 2.0),
    };
}

/// Get the model rotation matrix from x/y degrees
fn getModelRotationMatrix(x_deg: i16, y_deg: i16) Mat3 {
    const PI: f32 = 3.14159265358979323846;
    const x_rad = @as(f32, @floatFromInt(x_deg)) * PI / 180.0;
    const y_rad = @as(f32, @floatFromInt(y_deg)) * PI / 180.0;

    // Compose Y rotation then X rotation (same order as Java)
    if (x_deg == 0 and y_deg == 0) {
        return Mat3.IDENTITY;
    } else if (x_deg == 0) {
        return Mat3.rotateY(y_rad);
    } else if (y_deg == 0) {
        return Mat3.rotateX(x_rad);
    } else {
        return Mat3.rotateY(y_rad).mul(Mat3.rotateX(x_rad));
    }
}

/// Find closest direction from a normal vector
fn findClosestDirection(nx: f32, ny: f32, nz: f32) Direction {
    var best: Direction = .up;
    var best_dot: f32 = -999.0;

    const dirs = [_]Direction{ .down, .up, .north, .south, .west, .east };
    const normals = [_][3]f32{
        .{ 0, -1, 0 }, // down
        .{ 0, 1, 0 }, // up
        .{ 0, 0, -1 }, // north
        .{ 0, 0, 1 }, // south
        .{ -1, 0, 0 }, // west
        .{ 1, 0, 0 }, // east
    };

    for (dirs, normals) |dir, normal| {
        const dot = nx * normal[0] + ny * normal[1] + nz * normal[2];
        if (dot > best_dot) {
            best_dot = dot;
            best = dir;
        }
    }
    return best;
}

/// Get the UV face transformation matrix
/// Matches BlockMath.getFaceTransformation
fn getFaceTransformMatrix(model_transform: Mat3, original_face: Direction) Mat3 {
    if (model_transform.isIdentity()) {
        return Mat3.IDENTITY;
    }

    // faceAction = transformation.compose(LOCAL_TO_GLOBAL[originalFace])
    const local_to_global = getLocalToGlobalTransform(original_face);
    const face_action = model_transform.mul(local_to_global);

    // Transform the normal (0, 0, 1) to find new face direction
    const transformed_normal = face_action.transformDir(0, 0, 1);
    const new_face = findClosestDirection(transformed_normal[0], transformed_normal[1], transformed_normal[2]);

    // result = GLOBAL_TO_LOCAL[newFace].compose(faceAction)
    const global_to_local = getLocalToGlobalTransform(new_face).invert();
    return global_to_local.mul(face_action);
}

/// Bakes block model faces into BakedQuads
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

            // Get UV for this vertex (divided by 16 to normalize)
            const raw_u = getU(uvs, face.rotation, @intCast(i));
            const raw_v = getV(uvs, face.rotation, @intCast(i));
            // Normalize UVs from 0-16 to 0-1 range
            const u = raw_u / 16.0;
            const v = raw_v / 16.0;
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
        // Apply Y rotation first, then X
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
    /// Uses clockwise rotation convention (looking down +Y for Y rotation)
    /// Minecraft blockstate rotation order: X first, then Y
    fn rotatePosition(pos: *[3]f32, x_deg: i16, y_deg: i16) void {
        // Center around (0.5, 0.5, 0.5)
        var rx = pos[0] - 0.5;
        var ry = pos[1] - 0.5;
        var rz = pos[2] - 0.5;

        // Apply X rotation first (around X axis)
        // X90: Up→North, North→Down (front face rotates down)
        if (x_deg != 0) {
            const cos_x = cosFromDegrees(x_deg);
            const sin_x = sinFromDegrees(x_deg);
            const new_y = ry * cos_x + rz * sin_x;
            const new_z = -ry * sin_x + rz * cos_x;
            ry = new_y;
            rz = new_z;
        }

        // Apply Y rotation second (around Y axis) - CLOCKWISE when viewed from +Y
        // Y90: North→East→South→West
        if (y_deg != 0) {
            const cos_y = cosFromDegrees(y_deg);
            const sin_y = sinFromDegrees(y_deg);
            const new_x = rx * cos_y - rz * sin_y;
            const new_z = rx * sin_y + rz * cos_y;
            rx = new_x;
            rz = new_z;
        }

        // Translate back
        pos[0] = rx + 0.5;
        pos[1] = ry + 0.5;
        pos[2] = rz + 0.5;
    }

    /// Rotate face direction by model rotation (public for culling)
    /// Must match the position rotation formula exactly (X first, then Y)
    pub fn rotateFaceDirection(dir: Direction, x_deg: i16, y_deg: i16) Direction {
        var result = dir;

        // Apply X rotation first (around X axis)
        // X90: Up→North→Down→South→Up (front face rotates down)
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

        // Apply Y rotation second (around Y axis) - CLOCKWISE when viewed from +Y
        // Y90: North→East→South→West→North
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

        return result;
    }

    /// Counter-rotate UVs for uvlock (maintain world-aligned textures)
    /// Uses matrix transforms matching Java's inverseFaceTransformation
    fn rotateUVs(quad: *BakedQuad, x_deg: i16, y_deg: i16) void {
        // Get the model rotation matrix
        const model_transform = getModelRotationMatrix(x_deg, y_deg);

        // Get the UV transformation matrix for this face
        // This matches BlockMath.getFaceTransformation(transformation, originalSide)
        const face_transform = getFaceTransformMatrix(model_transform, quad.direction);

        // Get the inverse for UV counter-rotation (matches inverseFaceTransformation)
        const uv_transform = face_transform.invert();

        // If identity transform, nothing to do
        if (uv_transform.isIdentity()) {
            return;
        }

        // Transform each UV coordinate using the matrix
        quad.packed_uv0 = transformPackedUVMatrix(quad.packed_uv0, uv_transform);
        quad.packed_uv1 = transformPackedUVMatrix(quad.packed_uv1, uv_transform);
        quad.packed_uv2 = transformPackedUVMatrix(quad.packed_uv2, uv_transform);
        quad.packed_uv3 = transformPackedUVMatrix(quad.packed_uv3, uv_transform);
    }

    /// Transform a packed UV by a matrix
    /// Matches Java's bakeVertex: cornerToCenter -> transform -> centerToCorner
    fn transformPackedUVMatrix(packed_uv: u64, transform: Mat3) u64 {
        // Unpack UV
        const u_bits: u32 = @intCast(packed_uv >> 32);
        const v_bits: u32 = @intCast(packed_uv & 0xFFFFFFFF);
        var u: f32 = @bitCast(u_bits);
        var v: f32 = @bitCast(v_bits);

        // cornerToCenter: shift from 0-1 to centered around 0
        u = u - 0.5;
        v = v - 0.5;

        // Apply matrix transform (u, v, 0) -> (u', v', z')
        const transformed = transform.transformUV(u, v);

        // centerToCorner: shift back to 0-1
        u = transformed[0] + 0.5;
        v = transformed[1] + 0.5;

        // Repack
        const new_u_bits: u32 = @bitCast(u);
        const new_v_bits: u32 = @bitCast(v);
        return (@as(u64, new_u_bits) << 32) | @as(u64, new_v_bits);
    }

    /// Rotate element bounds (from/to) by model rotation
    /// Bounds are in block coordinates (0-16), rotated around center (8,8,8)
    /// Returns the rotated bounding box as (from, to)
    pub fn rotateElementBounds(from: [3]f32, to: [3]f32, x_deg: i16, y_deg: i16) struct { from: [3]f32, to: [3]f32 } {
        if (x_deg == 0 and y_deg == 0) {
            return .{ .from = from, .to = to };
        }

        // Rotate all 8 corners of the box
        var corners: [8][3]f32 = undefined;
        for (0..8) |i| {
            corners[i] = .{
                if (i & 1 != 0) to[0] else from[0],
                if (i & 2 != 0) to[1] else from[1],
                if (i & 4 != 0) to[2] else from[2],
            };
            rotatePosition16(&corners[i], x_deg, y_deg);
        }

        // Find min/max of rotated corners
        var new_from = corners[0];
        var new_to = corners[0];
        for (corners[1..]) |c| {
            new_from[0] = @min(new_from[0], c[0]);
            new_from[1] = @min(new_from[1], c[1]);
            new_from[2] = @min(new_from[2], c[2]);
            new_to[0] = @max(new_to[0], c[0]);
            new_to[1] = @max(new_to[1], c[1]);
            new_to[2] = @max(new_to[2], c[2]);
        }

        return .{ .from = new_from, .to = new_to };
    }

    /// Rotate a position in 0-16 space around center (8,8,8)
    fn rotatePosition16(pos: *[3]f32, x_deg: i16, y_deg: i16) void {
        // Center around (8, 8, 8)
        var rx = pos[0] - 8.0;
        var ry = pos[1] - 8.0;
        var rz = pos[2] - 8.0;

        // Apply Y rotation first (around Y axis) - CLOCKWISE when viewed from +Y
        if (y_deg != 0) {
            const cos_y = cosFromDegrees(y_deg);
            const sin_y = sinFromDegrees(y_deg);
            const new_x = rx * cos_y - rz * sin_y;
            const new_z = rx * sin_y + rz * cos_y;
            rx = new_x;
            rz = new_z;
        }

        // Apply X rotation (around X axis)
        if (x_deg != 0) {
            const cos_x = cosFromDegrees(x_deg);
            const sin_x = sinFromDegrees(x_deg);
            const new_y = ry * cos_x + rz * sin_x;
            const new_z = -ry * sin_x + rz * cos_x;
            ry = new_y;
            rz = new_z;
        }

        // Translate back
        pos[0] = rx + 8.0;
        pos[1] = ry + 8.0;
        pos[2] = rz + 8.0;
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
