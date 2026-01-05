const std = @import("std");
const shared = @import("Shared");
const renderer = @import("Renderer");

const Vec3 = shared.Vec3;
const Mat4 = shared.Mat4;
const Vertex = renderer.Vertex;

/// Minecraft-style cow model
/// Replicates MC's coordinate system exactly:
/// - Y=24 is ground level in model space
/// - Parts have pivot points (PartPose.offset)
/// - Boxes are defined relative to pivot
/// - Final output is scaled to world coords (1 block = 16 pixels)
pub const CowModel = struct {
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

    /// Generate cow mesh exactly like Minecraft
    pub fn generateMesh(self: *Self, walk_animation: f32) !struct { vertices: []Vertex, indices: []u32 } {
        var vertices: std.ArrayList(Vertex) = .empty;
        var indices: std.ArrayList(u32) = .empty;

        // Animation from QuadrupedModel.setupAnim()
        // rightHindLeg.xRot = cos(animPos * 0.6662) * 1.4 * animSpeed
        // leftHindLeg.xRot = cos(animPos * 0.6662 + PI) * 1.4 * animSpeed
        // rightFrontLeg.xRot = cos(animPos * 0.6662 + PI) * 1.4 * animSpeed
        // leftFrontLeg.xRot = cos(animPos * 0.6662) * 1.4 * animSpeed
        const anim_speed: f32 = 1.0;
        const right_hind_rot = @cos(walk_animation * 0.6662) * 1.4 * anim_speed;
        const left_hind_rot = @cos(walk_animation * 0.6662 + std.math.pi) * 1.4 * anim_speed;
        const right_front_rot = @cos(walk_animation * 0.6662 + std.math.pi) * 1.4 * anim_speed;
        const left_front_rot = @cos(walk_animation * 0.6662) * 1.4 * anim_speed;

        // Head: PartPose.offset(0, 4, -8)
        // box(-4, -4, -6, 8, 8, 6) texOffs(0, 0)
        try self.addModelPart(&vertices, &indices, .{
            .pivot = .{ 0, 4, -8 },
            .rotation = .{ 0, 0, 0 },
            .boxes = &[_]Box{
                .{ .origin = .{ -4, -4, -6 }, .size = .{ 8, 8, 6 }, .uv = .{ 0, 0 } }, // head
                .{ .origin = .{ -5, -5, -5 }, .size = .{ 1, 3, 1 }, .uv = .{ 22, 0 } }, // right horn
                .{ .origin = .{ 4, -5, -5 }, .size = .{ 1, 3, 1 }, .uv = .{ 22, 0 } }, // left horn
            },
        });

        // Body: PartPose.offsetAndRotation(0, 5, 2, PI/2, 0, 0)
        // box(-6, -10, -7, 12, 18, 10) texOffs(18, 4)
        try self.addModelPart(&vertices, &indices, .{
            .pivot = .{ 0, 5, 2 },
            .rotation = .{ std.math.pi / 2.0, 0, 0 },
            .boxes = &[_]Box{
                .{ .origin = .{ -6, -10, -7 }, .size = .{ 12, 18, 10 }, .uv = .{ 18, 4 } },
            },
        });

        // Right hind leg: PartPose.offset(-4, 12, 7)
        // box(-2, 0, -2, 4, 12, 4) texOffs(0, 16)
        try self.addModelPart(&vertices, &indices, .{
            .pivot = .{ -4, 12, 7 },
            .rotation = .{ right_hind_rot, 0, 0 },
            .boxes = &[_]Box{
                .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 12, 4 }, .uv = .{ 0, 16 } },
            },
        });

        // Left hind leg: PartPose.offset(4, 12, 7)
        try self.addModelPart(&vertices, &indices, .{
            .pivot = .{ 4, 12, 7 },
            .rotation = .{ left_hind_rot, 0, 0 },
            .boxes = &[_]Box{
                .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 12, 4 }, .uv = .{ 0, 16 }, .mirror = true },
            },
        });

        // Right front leg: PartPose.offset(-4, 12, -5)
        try self.addModelPart(&vertices, &indices, .{
            .pivot = .{ -4, 12, -5 },
            .rotation = .{ right_front_rot, 0, 0 },
            .boxes = &[_]Box{
                .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 12, 4 }, .uv = .{ 0, 16 } },
            },
        });

        // Left front leg: PartPose.offset(4, 12, -5)
        try self.addModelPart(&vertices, &indices, .{
            .pivot = .{ 4, 12, -5 },
            .rotation = .{ left_front_rot, 0, 0 },
            .boxes = &[_]Box{
                .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 12, 4 }, .uv = .{ 0, 16 }, .mirror = true },
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

        // Apply rotation around pivot (in local space, so pivot is origin)
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

        // UV calculations - Minecraft box UV layout
        const u_scale = 1.0 / TEX_WIDTH;
        const v_scale = 1.0 / TEX_HEIGHT;

        const white = [3]f32{ 1.0, 1.0, 1.0 };

        // Face vertices with proper UV mapping
        // Minecraft UV layout for a box:
        // Top row: [depth][top][depth][bottom]
        // Bottom row: [left][front][right][back]

        // All faces use CCW winding when viewed from outside after Y-flip

        // Bottom face (Y-) - after Y-flip this is at TOP, viewed from +Y
        // CCW from +Y: 0,4,5,1
        try self.addQuad(vertices, indices, base_idx + 0, corners, .{ 0, 4, 5, 1 }, white, .{
            .{ (u + d) * u_scale, (v + d) * v_scale }, // corner 0
            .{ (u + d) * u_scale, (v) * v_scale }, // corner 4 (was uv3)
            .{ (u + d + w) * u_scale, (v) * v_scale }, // corner 5 (was uv2)
            .{ (u + d + w) * u_scale, (v + d) * v_scale }, // corner 1 (was uv1)
        }, box.mirror);

        // Top face (Y+) - after Y-flip this is at BOTTOM, viewed from -Y
        // CCW from -Y: 3,2,6,7
        try self.addQuad(vertices, indices, base_idx + 4, corners, .{ 3, 2, 6, 7 }, white, .{
            .{ (u + d + w) * u_scale, (v + d) * v_scale }, // corner 3
            .{ (u + d + w + w) * u_scale, (v + d) * v_scale }, // corner 2 (was uv3)
            .{ (u + d + w + w) * u_scale, (v) * v_scale }, // corner 6 (was uv2)
            .{ (u + d + w) * u_scale, (v) * v_scale }, // corner 7 (was uv1)
        }, box.mirror);

        // West face (X-) - viewed from -X
        // CCW from -X: 0,3,7,4
        try self.addQuad(vertices, indices, base_idx + 8, corners, .{ 0, 3, 7, 4 }, white, .{
            .{ (u + d) * u_scale, (v + d) * v_scale },
            .{ (u + d) * u_scale, (v + d + h) * v_scale },
            .{ (u) * u_scale, (v + d + h) * v_scale },
            .{ (u) * u_scale, (v + d) * v_scale },
        }, box.mirror);

        // East face (X+) - viewed from +X
        // CCW from +X: 1,5,6,2
        try self.addQuad(vertices, indices, base_idx + 12, corners, .{ 1, 5, 6, 2 }, white, .{
            .{ (u + d + w) * u_scale, (v + d) * v_scale },
            .{ (u + d + w) * u_scale, (v + d + h) * v_scale },
            .{ (u + d + w + d) * u_scale, (v + d + h) * v_scale },
            .{ (u + d + w + d) * u_scale, (v + d) * v_scale },
        }, box.mirror);

        // North face (Z-) - viewed from -Z (this is FRONT of cow)
        // CCW from -Z: 0,1,2,3
        try self.addQuad(vertices, indices, base_idx + 16, corners, .{ 0, 1, 2, 3 }, white, .{
            .{ (u + d + w) * u_scale, (v + d) * v_scale }, // corner 0
            .{ (u + d) * u_scale, (v + d) * v_scale }, // corner 1 (was uv3)
            .{ (u + d) * u_scale, (v + d + h) * v_scale }, // corner 2 (was uv2)
            .{ (u + d + w) * u_scale, (v + d + h) * v_scale }, // corner 3 (was uv1)
        }, box.mirror);

        // South face (Z+) - viewed from +Z (this is BACK of cow)
        // CCW from +Z: 4,7,6,5
        try self.addQuad(vertices, indices, base_idx + 20, corners, .{ 4, 7, 6, 5 }, white, .{
            .{ (u + d + w + d) * u_scale, (v + d) * v_scale }, // corner 4
            .{ (u + d + w + d) * u_scale, (v + d + h) * v_scale }, // corner 7 (was uv3)
            .{ (u + d + w + d + w) * u_scale, (v + d + h) * v_scale }, // corner 6 (was uv2)
            .{ (u + d + w + d + w) * u_scale, (v + d) * v_scale }, // corner 5 (was uv1)
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
        _ = mirror; // TODO: implement UV mirroring if needed

        // Vertices in order matching corner_indices
        try vertices.append(self.allocator, .{ .pos = corners[corner_indices[0]], .color = color, .uv = uvs[0], .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[corner_indices[1]], .color = color, .uv = uvs[1], .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[corner_indices[2]], .color = color, .uv = uvs[2], .tex_index = 0 });
        try vertices.append(self.allocator, .{ .pos = corners[corner_indices[3]], .color = color, .uv = uvs[3], .tex_index = 0 });

        // Two triangles for the quad (CCW winding)
        try indices.append(self.allocator, base_idx + 0);
        try indices.append(self.allocator, base_idx + 1);
        try indices.append(self.allocator, base_idx + 2);
        try indices.append(self.allocator, base_idx + 0);
        try indices.append(self.allocator, base_idx + 2);
        try indices.append(self.allocator, base_idx + 3);
    }
};
