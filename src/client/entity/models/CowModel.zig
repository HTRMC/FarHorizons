const std = @import("std");
const shared = @import("Shared");
const renderer = @import("Renderer");

const Vec3 = shared.Vec3;
const Mat4 = shared.Mat4;
const Vertex = renderer.Vertex;

/// Cow model dimensions (in pixels, 1 block = 16 pixels)
/// Based on Minecraft cow model
pub const CowModel = struct {
    const Self = @This();

    /// Texture dimensions
    const TEX_WIDTH: f32 = 64.0;
    const TEX_HEIGHT: f32 = 64.0;

    /// Body dimensions (in blocks, scaled down from pixel coords)
    const SCALE: f32 = 1.0 / 16.0; // Convert pixels to blocks

    /// Model part offsets and sizes
    const Body = struct {
        // Body box: 12x18x10 pixels, positioned at center
        const width: f32 = 12.0 * SCALE;
        const height: f32 = 10.0 * SCALE;
        const depth: f32 = 18.0 * SCALE;
        const y_offset: f32 = 11.0 * SCALE; // Height from ground to body bottom
    };

    const Head = struct {
        // Head box: 8x8x6 pixels
        const width: f32 = 8.0 * SCALE;
        const height: f32 = 8.0 * SCALE;
        const depth: f32 = 6.0 * SCALE;
        const y_offset: f32 = 16.0 * SCALE;
        const z_offset: f32 = -8.0 * SCALE; // Forward from body
    };

    const Leg = struct {
        // Leg box: 4x12x4 pixels
        const width: f32 = 4.0 * SCALE;
        const height: f32 = 12.0 * SCALE;
        const depth: f32 = 4.0 * SCALE;
    };

    const Horn = struct {
        // Horn box: 1x3x1 pixels
        const width: f32 = 1.0 * SCALE;
        const height: f32 = 3.0 * SCALE;
        const depth: f32 = 1.0 * SCALE;
    };

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Generate cow mesh vertices and indices
    /// Returns owned slices that caller must free
    pub fn generateMesh(self: *Self, walk_animation: f32) !struct { vertices: []Vertex, indices: []u32 } {
        var vertices: std.ArrayList(Vertex) = .empty;
        var indices: std.ArrayList(u32) = .empty;

        // Calculate leg rotation from walk animation
        const leg_angle = @sin(walk_animation) * 0.5; // +/- 0.5 radians

        // Body (centered at origin, y_offset up from ground)
        try self.addBox(
            &vertices,
            &indices,
            -Body.width / 2.0,
            Body.y_offset,
            -Body.depth / 2.0,
            Body.width,
            Body.height,
            Body.depth,
            18, 4, // UV offset in texture
            .{ 1.0, 1.0, 1.0 }, // White color (texture provides color)
        );

        // Head
        try self.addBox(
            &vertices,
            &indices,
            -Head.width / 2.0,
            Head.y_offset,
            Head.z_offset - Head.depth,
            Head.width,
            Head.height,
            Head.depth,
            0, 0,
            .{ 1.0, 1.0, 1.0 },
        );

        // Left horn
        try self.addBox(
            &vertices,
            &indices,
            -Head.width / 2.0 - Horn.width,
            Head.y_offset + Head.height - Horn.height,
            Head.z_offset - Head.depth / 2.0 - Horn.depth / 2.0,
            Horn.width,
            Horn.height,
            Horn.depth,
            22, 0,
            .{ 0.9, 0.9, 0.8 },
        );

        // Right horn
        try self.addBox(
            &vertices,
            &indices,
            Head.width / 2.0,
            Head.y_offset + Head.height - Horn.height,
            Head.z_offset - Head.depth / 2.0 - Horn.depth / 2.0,
            Horn.width,
            Horn.height,
            Horn.depth,
            22, 0,
            .{ 0.9, 0.9, 0.8 },
        );

        // Front left leg (animated)
        try self.addRotatedBox(
            &vertices,
            &indices,
            -Body.width / 2.0,
            0,
            -Body.depth / 2.0 + Leg.depth,
            Leg.width,
            Leg.height,
            Leg.depth,
            0, 16,
            .{ 1.0, 1.0, 1.0 },
            leg_angle, // Rotation
            0, Leg.height, 0, // Pivot at top of leg
        );

        // Front right leg (animated, opposite phase)
        try self.addRotatedBox(
            &vertices,
            &indices,
            Body.width / 2.0 - Leg.width,
            0,
            -Body.depth / 2.0 + Leg.depth,
            Leg.width,
            Leg.height,
            Leg.depth,
            0, 16,
            .{ 1.0, 1.0, 1.0 },
            -leg_angle,
            0, Leg.height, 0,
        );

        // Back left leg (animated, opposite to front left)
        try self.addRotatedBox(
            &vertices,
            &indices,
            -Body.width / 2.0,
            0,
            Body.depth / 2.0 - Leg.depth * 2,
            Leg.width,
            Leg.height,
            Leg.depth,
            0, 16,
            .{ 1.0, 1.0, 1.0 },
            -leg_angle,
            0, Leg.height, 0,
        );

        // Back right leg (animated)
        try self.addRotatedBox(
            &vertices,
            &indices,
            Body.width / 2.0 - Leg.width,
            0,
            Body.depth / 2.0 - Leg.depth * 2,
            Leg.width,
            Leg.height,
            Leg.depth,
            0, 16,
            .{ 1.0, 1.0, 1.0 },
            leg_angle,
            0, Leg.height, 0,
        );

        return .{
            .vertices = try vertices.toOwnedSlice(self.allocator),
            .indices = try indices.toOwnedSlice(self.allocator),
        };
    }

    /// Add a box with 6 faces
    fn addBox(
        self: *Self,
        vertices: *std.ArrayList(Vertex),
        indices: *std.ArrayList(u32),
        x: f32,
        y: f32,
        z: f32,
        width: f32,
        height: f32,
        depth: f32,
        u: f32,
        v: f32,
        color: [3]f32,
    ) !void {
        const base_index: u32 = @intCast(vertices.items.len);

        // Calculate UV coordinates for each face (Minecraft box UV layout)
        const u_scale = 1.0 / TEX_WIDTH;
        const v_scale = 1.0 / TEX_HEIGHT;

        // 8 corners of the box
        const corners = [8][3]f32{
            .{ x, y, z }, // 0: bottom-back-left
            .{ x + width, y, z }, // 1: bottom-back-right
            .{ x + width, y + height, z }, // 2: top-back-right
            .{ x, y + height, z }, // 3: top-back-left
            .{ x, y, z + depth }, // 4: bottom-front-left
            .{ x + width, y, z + depth }, // 5: bottom-front-right
            .{ x + width, y + height, z + depth }, // 6: top-front-right
            .{ x, y + height, z + depth }, // 7: top-front-left
        };

        // Front face (+Z)
        try vertices.append(self.allocator, .{ .pos = corners[4], .color = color, .uv = .{ (u + depth) * u_scale, (v + depth + height) * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[5], .color = color, .uv = .{ (u + depth + width) * u_scale, (v + depth + height) * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[6], .color = color, .uv = .{ (u + depth + width) * u_scale, (v + depth) * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[7], .color = color, .uv = .{ (u + depth) * u_scale, (v + depth) * v_scale }, .tex_index = 0 });

        // Back face (-Z)
        try vertices.append(self.allocator, .{ .pos = corners[1], .color = color, .uv = .{ (u + depth * 2 + width) * u_scale, (v + depth + height) * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[0], .color = color, .uv = .{ (u + depth * 2 + width * 2) * u_scale, (v + depth + height) * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[3], .color = color, .uv = .{ (u + depth * 2 + width * 2) * u_scale, (v + depth) * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[2], .color = color, .uv = .{ (u + depth * 2 + width) * u_scale, (v + depth) * v_scale }, .tex_index = 0 });

        // Left face (-X)
        try vertices.append(self.allocator, .{ .pos = corners[0], .color = color, .uv = .{ u * u_scale, (v + depth + height) * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[4], .color = color, .uv = .{ (u + depth) * u_scale, (v + depth + height) * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[7], .color = color, .uv = .{ (u + depth) * u_scale, (v + depth) * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[3], .color = color, .uv = .{ u * u_scale, (v + depth) * v_scale }, .tex_index = 0 });

        // Right face (+X)
        try vertices.append(self.allocator, .{ .pos = corners[5], .color = color, .uv = .{ (u + depth + width) * u_scale, (v + depth + height) * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[1], .color = color, .uv = .{ (u + depth * 2 + width) * u_scale, (v + depth + height) * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[2], .color = color, .uv = .{ (u + depth * 2 + width) * u_scale, (v + depth) * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[6], .color = color, .uv = .{ (u + depth + width) * u_scale, (v + depth) * v_scale }, .tex_index = 0 });

        // Top face (+Y)
        try vertices.append(self.allocator, .{ .pos = corners[7], .color = color, .uv = .{ (u + depth) * u_scale, v * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[6], .color = color, .uv = .{ (u + depth + width) * u_scale, v * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[2], .color = color, .uv = .{ (u + depth + width) * u_scale, (v + depth) * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[3], .color = color, .uv = .{ (u + depth) * u_scale, (v + depth) * v_scale }, .tex_index = 0 });

        // Bottom face (-Y)
        try vertices.append(self.allocator, .{ .pos = corners[0], .color = color, .uv = .{ (u + depth + width) * u_scale, v * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[1], .color = color, .uv = .{ (u + depth + width * 2) * u_scale, v * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[5], .color = color, .uv = .{ (u + depth + width * 2) * u_scale, (v + depth) * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[4], .color = color, .uv = .{ (u + depth + width) * u_scale, (v + depth) * v_scale }, .tex_index = 0 });

        // Add indices for all 6 faces (2 triangles per face, 6 faces)
        var i: u32 = 0;
        while (i < 6) : (i += 1) {
            const face_base = base_index + i * 4;
            try indices.append(self.allocator, face_base + 0);
            try indices.append(self.allocator, face_base + 1);
            try indices.append(self.allocator, face_base + 2);
            try indices.append(self.allocator, face_base + 0);
            try indices.append(self.allocator, face_base + 2);
            try indices.append(self.allocator, face_base + 3);
        }
    }

    /// Add a rotated box (for animated legs)
    fn addRotatedBox(
        self: *Self,
        vertices: *std.ArrayList(Vertex),
        indices: *std.ArrayList(u32),
        x: f32,
        y: f32,
        z: f32,
        width: f32,
        height: f32,
        depth: f32,
        u: f32,
        v: f32,
        color: [3]f32,
        rotation: f32, // Rotation around X axis (radians)
        pivot_x: f32,
        pivot_y: f32,
        pivot_z: f32,
    ) !void {
        const base_index: u32 = @intCast(vertices.items.len);
        const u_scale = 1.0 / TEX_WIDTH;
        const v_scale = 1.0 / TEX_HEIGHT;

        const cos_r = @cos(rotation);
        const sin_r = @sin(rotation);

        // Helper to rotate a point around X axis at pivot
        const rotatePoint = struct {
            fn f(px: f32, py: f32, pz: f32, ox: f32, oy: f32, oz: f32, c: f32, s: f32) [3]f32 {
                // Translate to pivot
                const ly = py - oy;
                const lz = pz - oz;
                // Rotate around X
                const ry = ly * c - lz * s;
                const rz = ly * s + lz * c;
                // Translate back
                return .{ px + ox, ry + oy, rz + oz };
            }
        }.f;

        // 8 corners, rotated
        const corners = [8][3]f32{
            rotatePoint(x, y, z, x + pivot_x, y + pivot_y, z + pivot_z, cos_r, sin_r),
            rotatePoint(x + width, y, z, x + pivot_x, y + pivot_y, z + pivot_z, cos_r, sin_r),
            rotatePoint(x + width, y + height, z, x + pivot_x, y + pivot_y, z + pivot_z, cos_r, sin_r),
            rotatePoint(x, y + height, z, x + pivot_x, y + pivot_y, z + pivot_z, cos_r, sin_r),
            rotatePoint(x, y, z + depth, x + pivot_x, y + pivot_y, z + pivot_z, cos_r, sin_r),
            rotatePoint(x + width, y, z + depth, x + pivot_x, y + pivot_y, z + pivot_z, cos_r, sin_r),
            rotatePoint(x + width, y + height, z + depth, x + pivot_x, y + pivot_y, z + pivot_z, cos_r, sin_r),
            rotatePoint(x, y + height, z + depth, x + pivot_x, y + pivot_y, z + pivot_z, cos_r, sin_r),
        };

        // Same face generation as addBox but with rotated corners
        // Front face
        try vertices.append(self.allocator, .{ .pos = corners[4], .color = color, .uv = .{ (u + depth) * u_scale, (v + depth + height) * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[5], .color = color, .uv = .{ (u + depth + width) * u_scale, (v + depth + height) * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[6], .color = color, .uv = .{ (u + depth + width) * u_scale, (v + depth) * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[7], .color = color, .uv = .{ (u + depth) * u_scale, (v + depth) * v_scale }, .tex_index = 0 });

        // Back face
        try vertices.append(self.allocator, .{ .pos = corners[1], .color = color, .uv = .{ (u + depth * 2 + width) * u_scale, (v + depth + height) * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[0], .color = color, .uv = .{ (u + depth * 2 + width * 2) * u_scale, (v + depth + height) * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[3], .color = color, .uv = .{ (u + depth * 2 + width * 2) * u_scale, (v + depth) * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[2], .color = color, .uv = .{ (u + depth * 2 + width) * u_scale, (v + depth) * v_scale }, .tex_index = 0 });

        // Left face
        try vertices.append(self.allocator, .{ .pos = corners[0], .color = color, .uv = .{ u * u_scale, (v + depth + height) * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[4], .color = color, .uv = .{ (u + depth) * u_scale, (v + depth + height) * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[7], .color = color, .uv = .{ (u + depth) * u_scale, (v + depth) * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[3], .color = color, .uv = .{ u * u_scale, (v + depth) * v_scale }, .tex_index = 0 });

        // Right face
        try vertices.append(self.allocator, .{ .pos = corners[5], .color = color, .uv = .{ (u + depth + width) * u_scale, (v + depth + height) * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[1], .color = color, .uv = .{ (u + depth * 2 + width) * u_scale, (v + depth + height) * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[2], .color = color, .uv = .{ (u + depth * 2 + width) * u_scale, (v + depth) * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[6], .color = color, .uv = .{ (u + depth + width) * u_scale, (v + depth) * v_scale }, .tex_index = 0 });

        // Top face
        try vertices.append(self.allocator, .{ .pos = corners[7], .color = color, .uv = .{ (u + depth) * u_scale, v * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[6], .color = color, .uv = .{ (u + depth + width) * u_scale, v * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[2], .color = color, .uv = .{ (u + depth + width) * u_scale, (v + depth) * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[3], .color = color, .uv = .{ (u + depth) * u_scale, (v + depth) * v_scale }, .tex_index = 0 });

        // Bottom face
        try vertices.append(self.allocator, .{ .pos = corners[0], .color = color, .uv = .{ (u + depth + width) * u_scale, v * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[1], .color = color, .uv = .{ (u + depth + width * 2) * u_scale, v * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[5], .color = color, .uv = .{ (u + depth + width * 2) * u_scale, (v + depth) * v_scale }, .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[4], .color = color, .uv = .{ (u + depth + width) * u_scale, (v + depth) * v_scale }, .tex_index = 0 });

        // Indices
        var i: u32 = 0;
        while (i < 6) : (i += 1) {
            const face_base = base_index + i * 4;
            try indices.append(self.allocator, face_base + 0);
            try indices.append(self.allocator, face_base + 1);
            try indices.append(self.allocator, face_base + 2);
            try indices.append(self.allocator, face_base + 0);
            try indices.append(self.allocator, face_base + 2);
            try indices.append(self.allocator, face_base + 3);
        }
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }
};
