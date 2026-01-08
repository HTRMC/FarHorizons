const std = @import("std");
const shared = @import("Shared");
const renderer = @import("Renderer");

const Vec3 = shared.Vec3;
const Mat4 = shared.Mat4;
const Vertex = renderer.Vertex;

/// Minecraft baby cow model
/// Based on BabyCowModel.java from MC 1.21+
/// Baby cows have:
/// - Proportionally larger head
/// - Shorter legs (6 pixels instead of 12)
/// - Smaller body
/// - Different pivot positions
pub const BabyCowModel = struct {
    const Self = @This();

    const TEX_WIDTH: f32 = 64.0;
    const TEX_HEIGHT: f32 = 64.0;

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Generate baby cow mesh
    /// walk_animation: position in walk cycle (increases while walking)
    /// walk_speed: amplitude of leg swing (0=stationary, 1=full swing)
    /// head_pitch: vertical head rotation (positive = look down)
    /// head_yaw: horizontal head rotation (positive = look right)
    pub fn generateMesh(self: *Self, walk_animation: f32, walk_speed: f32, head_pitch: f32, head_yaw: f32) !struct { vertices: []Vertex, indices: []u32 } {
        var vertices: std.ArrayList(Vertex) = .empty;
        var indices: std.ArrayList(u32) = .empty;

        // Animation (same as adult but with shorter legs)
        const right_hind_rot = @cos(walk_animation * 0.6662) * 1.4 * walk_speed;
        const left_hind_rot = @cos(walk_animation * 0.6662 + std.math.pi) * 1.4 * walk_speed;
        const right_front_rot = @cos(walk_animation * 0.6662 + std.math.pi) * 1.4 * walk_speed;
        const left_front_rot = @cos(walk_animation * 0.6662) * 1.4 * walk_speed;

        // Head: PartPose.offset(0, 13.569, -5.1667)
        // From BabyCowModel.java:
        // box(-3, -4.569, -4.8333, 6, 6, 5) texOffs(0, 18) - main head
        // box(3, -5.569, -3.8333, 1, 2, 1) texOffs(8, 29) - right horn
        // box(-4, -5.569, -3.8333, 1, 2, 1) texOffs(4, 29) - left horn (mirrored)
        // box(-2, -1.569, -5.8333, 4, 3, 1) texOffs(12, 29) - snout
        try self.addModelPart(&vertices, &indices, .{
            .pivot = .{ 0, 13.569, -5.1667 },
            .rotation = .{ head_pitch, head_yaw, 0 },
            .boxes = &[_]Box{
                .{ .origin = .{ -3, -4.569, -4.8333 }, .size = .{ 6, 6, 5 }, .uv = .{ 0, 18 } }, // head
                .{ .origin = .{ 3, -5.569, -3.8333 }, .size = .{ 1, 2, 1 }, .uv = .{ 8, 29 } }, // right horn
                .{ .origin = .{ -4, -5.569, -3.8333 }, .size = .{ 1, 2, 1 }, .uv = .{ 4, 29 }, .mirror = true }, // left horn
                .{ .origin = .{ -2, -1.569, -5.8333 }, .size = .{ 4, 3, 1 }, .uv = .{ 12, 29 } }, // snout
            },
        });

        // Body: PartPose.offset(3, 19, -5)
        // box(-7, -7, -1, 8, 6, 12) texOffs(0, 0)
        // Note: Baby body is NOT rotated like adult, it's horizontal
        try self.addModelPart(&vertices, &indices, .{
            .pivot = .{ 3, 19, -5 },
            .rotation = .{ 0, 0, 0 },
            .boxes = &[_]Box{
                .{ .origin = .{ -7, -7, -1 }, .size = .{ 8, 6, 12 }, .uv = .{ 0, 0 } },
            },
        });

        // Right front leg: PartPose.offset(-2.5, 18, -3.5)
        // box(-1.5, 0, -1.5, 3, 6, 3) texOffs(22, 18)
        try self.addModelPart(&vertices, &indices, .{
            .pivot = .{ -2.5, 18, -3.5 },
            .rotation = .{ right_front_rot, 0, 0 },
            .boxes = &[_]Box{
                .{ .origin = .{ -1.5, 0, -1.5 }, .size = .{ 3, 6, 3 }, .uv = .{ 22, 18 } },
            },
        });

        // Left front leg: PartPose.offset(2.5, 18, -3.5)
        // box(-1.5, 0, -1.5, 3, 6, 3) texOffs(34, 18)
        try self.addModelPart(&vertices, &indices, .{
            .pivot = .{ 2.5, 18, -3.5 },
            .rotation = .{ left_front_rot, 0, 0 },
            .boxes = &[_]Box{
                .{ .origin = .{ -1.5, 0, -1.5 }, .size = .{ 3, 6, 3 }, .uv = .{ 34, 18 } },
            },
        });

        // Right hind leg: PartPose.offset(-2.5, 18, 3.5)
        // box(-1.5, 0, -1.5, 3, 6, 3) texOffs(22, 27)
        try self.addModelPart(&vertices, &indices, .{
            .pivot = .{ -2.5, 18, 3.5 },
            .rotation = .{ right_hind_rot, 0, 0 },
            .boxes = &[_]Box{
                .{ .origin = .{ -1.5, 0, -1.5 }, .size = .{ 3, 6, 3 }, .uv = .{ 22, 27 } },
            },
        });

        // Left hind leg: PartPose.offset(2.5, 18, 3.5)
        // box(-1.5, 0, -1.5, 3, 6, 3) texOffs(34, 27)
        try self.addModelPart(&vertices, &indices, .{
            .pivot = .{ 2.5, 18, 3.5 },
            .rotation = .{ left_hind_rot, 0, 0 },
            .boxes = &[_]Box{
                .{ .origin = .{ -1.5, 0, -1.5 }, .size = .{ 3, 6, 3 }, .uv = .{ 34, 27 } },
            },
        });

        return .{
            .vertices = try vertices.toOwnedSlice(self.allocator),
            .indices = try indices.toOwnedSlice(self.allocator),
        };
    }

    const Box = struct {
        origin: [3]f32, // x, y, z offset from pivot
        size: [3]f32, // width, height, depth
        uv: [2]f32, // texture offset
        mirror: bool = false,
    };

    const ModelPart = struct {
        pivot: [3]f32, // pivot point in model space
        rotation: [3]f32, // x, y, z rotation in radians
        boxes: []const Box,
    };

    /// Add a model part with pivot, rotation, and boxes
    fn addModelPart(
        self: *Self,
        vertices: *std.ArrayList(Vertex),
        indices: *std.ArrayList(u32),
        part: ModelPart,
    ) !void {
        for (part.boxes) |box| {
            try self.addBox(vertices, indices, part.pivot, part.rotation, box);
        }
    }

    /// Add a single box with transformation
    fn addBox(
        self: *Self,
        vertices: *std.ArrayList(Vertex),
        indices: *std.ArrayList(u32),
        pivot: [3]f32,
        rotation: [3]f32,
        box: Box,
    ) !void {
        const base_idx: u32 = @intCast(vertices.items.len);

        const ox = box.origin[0];
        const oy = box.origin[1];
        const oz = box.origin[2];
        const w = box.size[0];
        const h = box.size[1];
        const d = box.size[2];
        const u = box.uv[0];
        const v = box.uv[1];

        // 8 corners of the box in local space (relative to pivot)
        var corners: [8][3]f32 = .{
            .{ ox, oy, oz }, // 0: min
            .{ ox + w, oy, oz }, // 1
            .{ ox + w, oy + h, oz }, // 2
            .{ ox, oy + h, oz }, // 3
            .{ ox, oy, oz + d }, // 4
            .{ ox + w, oy, oz + d }, // 5
            .{ ox + w, oy + h, oz + d }, // 6: max
            .{ ox, oy + h, oz + d }, // 7
        };

        // Apply rotation around pivot
        const cos_x = @cos(rotation[0]);
        const sin_x = @sin(rotation[0]);
        const cos_y = @cos(rotation[1]);
        const sin_y = @sin(rotation[1]);
        const cos_z = @cos(rotation[2]);
        const sin_z = @sin(rotation[2]);

        for (&corners) |*corner| {
            var x = corner[0];
            var y = corner[1];
            var z = corner[2];

            // Rotate around X axis
            if (rotation[0] != 0) {
                const ny = y * cos_x - z * sin_x;
                const nz = y * sin_x + z * cos_x;
                y = ny;
                z = nz;
            }

            // Rotate around Y axis
            if (rotation[1] != 0) {
                const nx = x * cos_y + z * sin_y;
                const nz = -x * sin_y + z * cos_y;
                x = nx;
                z = nz;
            }

            // Rotate around Z axis
            if (rotation[2] != 0) {
                const nx = x * cos_z - y * sin_z;
                const ny = x * sin_z + y * cos_z;
                x = nx;
                y = ny;
            }

            // Add pivot offset and convert to world space
            // MC model: Y=24 is ground, we want Y=0 as ground
            // Scale: 1/16 (pixels to blocks)
            const scale: f32 = 1.0 / 16.0;
            corner[0] = (x + pivot[0]) * scale;
            corner[1] = (24.0 - (y + pivot[1])) * scale; // Flip Y and offset to ground
            corner[2] = (z + pivot[2]) * scale;
        }

        // UV calculations
        const u_scale = 1.0 / TEX_WIDTH;
        const v_scale = 1.0 / TEX_HEIGHT;

        const white = [3]f32{ 1.0, 1.0, 1.0 };

        // Bottom face (Y-)
        try self.addQuad(vertices, indices, base_idx + 0, corners, .{ 0, 4, 5, 1 }, white, .{
            .{ (u + d + w) * u_scale, (v + d) * v_scale },
            .{ (u + d + w) * u_scale, (v) * v_scale },
            .{ (u + d) * u_scale, (v) * v_scale },
            .{ (u + d) * u_scale, (v + d) * v_scale },
        }, box.mirror);

        // Top face (Y+)
        try self.addQuad(vertices, indices, base_idx + 4, corners, .{ 3, 2, 6, 7 }, white, .{
            .{ (u + d + w + w) * u_scale, (v + d) * v_scale },
            .{ (u + d + w) * u_scale, (v + d) * v_scale },
            .{ (u + d + w) * u_scale, (v) * v_scale },
            .{ (u + d + w + w) * u_scale, (v) * v_scale },
        }, box.mirror);

        // West face (X-)
        try self.addQuad(vertices, indices, base_idx + 8, corners, .{ 0, 3, 7, 4 }, white, .{
            .{ (u + d + w) * u_scale, (v + d) * v_scale },
            .{ (u + d + w) * u_scale, (v + d + h) * v_scale },
            .{ (u + d + w + d) * u_scale, (v + d + h) * v_scale },
            .{ (u + d + w + d) * u_scale, (v + d) * v_scale },
        }, box.mirror);

        // East face (X+)
        try self.addQuad(vertices, indices, base_idx + 12, corners, .{ 1, 5, 6, 2 }, white, .{
            .{ (u + d) * u_scale, (v + d) * v_scale },
            .{ (u) * u_scale, (v + d) * v_scale },
            .{ (u) * u_scale, (v + d + h) * v_scale },
            .{ (u + d) * u_scale, (v + d + h) * v_scale },
        }, box.mirror);

        // North face (Z-)
        try self.addQuad(vertices, indices, base_idx + 16, corners, .{ 0, 1, 2, 3 }, white, .{
            .{ (u + d + w) * u_scale, (v + d) * v_scale },
            .{ (u + d) * u_scale, (v + d) * v_scale },
            .{ (u + d) * u_scale, (v + d + h) * v_scale },
            .{ (u + d + w) * u_scale, (v + d + h) * v_scale },
        }, box.mirror);

        // South face (Z+)
        try self.addQuad(vertices, indices, base_idx + 20, corners, .{ 4, 7, 6, 5 }, white, .{
            .{ (u + d + w + d) * u_scale, (v + d) * v_scale },
            .{ (u + d + w + d) * u_scale, (v + d + h) * v_scale },
            .{ (u + d + w + d + w) * u_scale, (v + d + h) * v_scale },
            .{ (u + d + w + d + w) * u_scale, (v + d) * v_scale },
        }, box.mirror);
    }

    fn addQuad(
        self: *Self,
        vertices: *std.ArrayList(Vertex),
        indices: *std.ArrayList(u32),
        base_idx: u32,
        corners: [8][3]f32,
        corner_indices: [4]u3,
        color: [3]f32,
        uvs: [4][2]f32,
        mirror: bool,
    ) !void {
        var final_uvs = uvs;
        if (mirror) {
            const tmp0 = final_uvs[0];
            final_uvs[0] = final_uvs[1];
            final_uvs[1] = tmp0;
            const tmp3 = final_uvs[3];
            final_uvs[3] = final_uvs[2];
            final_uvs[2] = tmp3;
        }

        try vertices.append(self.allocator, .{ .pos = corners[corner_indices[0]], .color = color, .uv = final_uvs[0], .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[corner_indices[1]], .color = color, .uv = final_uvs[1], .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[corner_indices[2]], .color = color, .uv = final_uvs[2], .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[corner_indices[3]], .color = color, .uv = final_uvs[3], .tex_index = 0 });

        try indices.append(self.allocator, base_idx + 0);
        try indices.append(self.allocator, base_idx + 1);
        try indices.append(self.allocator, base_idx + 2);
        try indices.append(self.allocator, base_idx + 0);
        try indices.append(self.allocator, base_idx + 2);
        try indices.append(self.allocator, base_idx + 3);
    }
};
