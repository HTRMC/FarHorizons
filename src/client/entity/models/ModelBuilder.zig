const std = @import("std");
const renderer = @import("Renderer");
const Vertex = renderer.Vertex;

/// PartPose - stores the pose (position, rotation, scale) of a model part
/// Equivalent to Minecraft's PartPose record
pub const PartPose = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    x_rot: f32 = 0,
    y_rot: f32 = 0,
    z_rot: f32 = 0,
    x_scale: f32 = 1,
    y_scale: f32 = 1,
    z_scale: f32 = 1,

    pub const ZERO: PartPose = .{};

    pub fn offset(x: f32, y: f32, z: f32) PartPose {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn rotation(x_rot: f32, y_rot: f32, z_rot: f32) PartPose {
        return .{ .x_rot = x_rot, .y_rot = y_rot, .z_rot = z_rot };
    }

    pub fn offsetAndRotation(x: f32, y: f32, z: f32, x_rot: f32, y_rot: f32, z_rot: f32) PartPose {
        return .{ .x = x, .y = y, .z = z, .x_rot = x_rot, .y_rot = y_rot, .z_rot = z_rot };
    }

    pub fn translated(self: PartPose, x: f32, y: f32, z: f32) PartPose {
        return .{
            .x = self.x + x,
            .y = self.y + y,
            .z = self.z + z,
            .x_rot = self.x_rot,
            .y_rot = self.y_rot,
            .z_rot = self.z_rot,
            .x_scale = self.x_scale,
            .y_scale = self.y_scale,
            .z_scale = self.z_scale,
        };
    }

    pub fn withScale(self: PartPose, scale: f32) PartPose {
        return .{
            .x = self.x,
            .y = self.y,
            .z = self.z,
            .x_rot = self.x_rot,
            .y_rot = self.y_rot,
            .z_rot = self.z_rot,
            .x_scale = scale,
            .y_scale = scale,
            .z_scale = scale,
        };
    }
};

/// CubeDefinition - stores the definition of a single cube before baking
pub const CubeDefinition = struct {
    origin_x: f32,
    origin_y: f32,
    origin_z: f32,
    width: f32,
    height: f32,
    depth: f32,
    tex_offs_x: f32,
    tex_offs_y: f32,
    mirror: bool = false,
};

/// CubeListBuilder - builder for creating cube lists with texture offsets
/// Equivalent to Minecraft's CubeListBuilder
pub const CubeListBuilder = struct {
    allocator: std.mem.Allocator,
    cubes: std.ArrayList(CubeDefinition),
    tex_offs_x: f32 = 0,
    tex_offs_y: f32 = 0,
    is_mirror: bool = false,

    pub fn create(allocator: std.mem.Allocator) CubeListBuilder {
        return .{
            .allocator = allocator,
            .cubes = .empty,
        };
    }

    pub fn deinit(self: *CubeListBuilder) void {
        self.cubes.deinit(self.allocator);
    }

    pub fn texOffs(self: *CubeListBuilder, x: f32, y: f32) *CubeListBuilder {
        self.tex_offs_x = x;
        self.tex_offs_y = y;
        return self;
    }

    pub fn mirror(self: *CubeListBuilder) *CubeListBuilder {
        self.is_mirror = true;
        return self;
    }

    pub fn mirrorSet(self: *CubeListBuilder, m: bool) *CubeListBuilder {
        self.is_mirror = m;
        return self;
    }

    pub fn addBox(self: *CubeListBuilder, x: f32, y: f32, z: f32, width: f32, height: f32, depth: f32) *CubeListBuilder {
        self.cubes.append(self.allocator, .{
            .origin_x = x,
            .origin_y = y,
            .origin_z = z,
            .width = width,
            .height = height,
            .depth = depth,
            .tex_offs_x = self.tex_offs_x,
            .tex_offs_y = self.tex_offs_y,
            .mirror = self.is_mirror,
        }) catch {};
        return self;
    }

    pub fn getCubes(self: *const CubeListBuilder) []const CubeDefinition {
        return self.cubes.items;
    }
};

/// PartDefinition - represents a hierarchical part with cubes and children
pub const PartDefinition = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    cubes: std.ArrayList(CubeDefinition),
    pose: PartPose,
    children: std.StringHashMap(*PartDefinition),

    pub fn init(allocator: std.mem.Allocator, cubes: []const CubeDefinition, pose: PartPose) *PartDefinition {
        const self = allocator.create(PartDefinition) catch @panic("Failed to allocate PartDefinition");
        self.* = .{
            .allocator = allocator,
            .cubes = .empty,
            .pose = pose,
            .children = std.StringHashMap(*PartDefinition).init(allocator),
        };
        self.cubes.appendSlice(allocator, cubes) catch {};
        return self;
    }

    pub fn deinit(self: *Self) void {
        // Free all children recursively
        var iter = self.children.iterator();
        while (iter.next()) |entry| {
            // Free the duplicated name string
            self.allocator.free(entry.key_ptr.*);
            // Recursively deinit and destroy child
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.children.deinit();
        self.cubes.deinit(self.allocator);
    }

    pub fn addOrReplaceChild(self: *Self, name: []const u8, builder: *CubeListBuilder, pose: PartPose) *PartDefinition {
        const child = PartDefinition.init(self.allocator, builder.getCubes(), pose);
        const name_copy = self.allocator.dupe(u8, name) catch @panic("Failed to dupe name");
        self.children.put(name_copy, child) catch {};
        return child;
    }

    pub fn getChild(self: *Self, name: []const u8) ?*PartDefinition {
        return self.children.get(name);
    }
};

/// MeshDefinition - top-level container for model definition
pub const MeshDefinition = struct {
    allocator: std.mem.Allocator,
    root: *PartDefinition,

    pub fn init(allocator: std.mem.Allocator) MeshDefinition {
        return .{
            .allocator = allocator,
            .root = PartDefinition.init(allocator, &.{}, PartPose.ZERO),
        };
    }

    pub fn deinit(self: *MeshDefinition) void {
        self.root.deinit();
        self.allocator.destroy(self.root);
    }

    pub fn getRoot(self: *MeshDefinition) *PartDefinition {
        return self.root;
    }
};

/// ModelPart - runtime model part with baked vertices
/// Used after baking from PartDefinition
pub const ModelPart = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    cubes: []const BakedCube,
    children: std.StringHashMap(*ModelPart),
    pose: PartPose,
    // Runtime rotation (can be modified for animation)
    x_rot: f32 = 0,
    y_rot: f32 = 0,
    z_rot: f32 = 0,

    pub fn deinit(self: *Self) void {
        var iter = self.children.valueIterator();
        while (iter.next()) |child| {
            child.*.deinit();
            self.allocator.destroy(child.*);
        }
        self.children.deinit();
        self.allocator.free(self.cubes);
    }

    pub fn getChild(self: *Self, name: []const u8) ?*ModelPart {
        return self.children.get(name);
    }

    pub fn setRotation(self: *Self, x: f32, y: f32, z: f32) void {
        self.x_rot = x;
        self.y_rot = y;
        self.z_rot = z;
    }

    /// Render this part and all children, appending to vertex/index lists
    pub fn render(self: *Self, vertices: *std.ArrayList(Vertex), indices: *std.ArrayList(u32), parent_transform: [16]f32) !void {
        // Build transform for this part
        const local_transform = self.buildTransform();
        const world_transform = multiplyMatrices(parent_transform, local_transform);

        // Render all cubes in this part
        for (self.cubes) |cube| {
            try cube.render(self.allocator, vertices, indices, world_transform);
        }

        // Render children
        var iter = self.children.valueIterator();
        while (iter.next()) |child| {
            try child.*.render(vertices, indices, world_transform);
        }
    }

    fn buildTransform(self: *Self) [16]f32 {
        // Translation
        const tx = self.pose.x / 16.0;
        const ty = (24.0 - self.pose.y) / 16.0;
        const tz = self.pose.z / 16.0;

        // Rotation (pose + runtime animation)
        const rx = self.pose.x_rot + self.x_rot;
        const ry = self.pose.y_rot + self.y_rot;
        const rz = self.pose.z_rot + self.z_rot;

        return buildTransformMatrix(tx, ty, tz, rx, ry, rz);
    }
};

/// BakedCube - a cube with pre-calculated vertices
pub const BakedCube = struct {
    /// 6 faces, 4 vertices each = 24 vertices
    vertices: [24]CubeVertex,
    mirror: bool,

    pub fn render(self: *const BakedCube, allocator: std.mem.Allocator, vertices: *std.ArrayList(Vertex), indices: *std.ArrayList(u32), transform: [16]f32) !void {
        const base_idx: u32 = @intCast(vertices.items.len);

        // Add all 24 vertices, transformed
        for (self.vertices) |v| {
            const pos = transformPoint(transform, v.x, v.y, v.z);
            try vertices.append(allocator, .{
                .pos = pos,
                .color = .{ 1.0, 1.0, 1.0 },
                .uv = .{ v.u, v.v },
                .tex_index = 0,
            });
        }

        // Add indices for 6 faces (2 triangles each)
        for (0..6) |face| {
            const fi: u32 = @intCast(face * 4);
            // Triangle 1
            try indices.append(allocator, base_idx + fi + 0);
            try indices.append(allocator, base_idx + fi + 1);
            try indices.append(allocator, base_idx + fi + 2);
            // Triangle 2
            try indices.append(allocator, base_idx + fi + 0);
            try indices.append(allocator, base_idx + fi + 2);
            try indices.append(allocator, base_idx + fi + 3);
        }
    }
};

pub const CubeVertex = struct {
    x: f32,
    y: f32,
    z: f32,
    u: f32,
    v: f32,
};

/// LayerDefinition - contains mesh definition and texture size
pub const LayerDefinition = struct {
    mesh: MeshDefinition,
    tex_width: u32,
    tex_height: u32,

    pub fn create(mesh: MeshDefinition, tex_width: u32, tex_height: u32) LayerDefinition {
        return .{
            .mesh = mesh,
            .tex_width = tex_width,
            .tex_height = tex_height,
        };
    }

    pub fn deinit(self: *LayerDefinition) void {
        self.mesh.deinit();
    }

    /// Bake the mesh definition into runtime ModelParts
    pub fn bake(self: *LayerDefinition) *ModelPart {
        return bakePart(self.mesh.allocator, self.mesh.root, self.tex_width, self.tex_height);
    }
};

/// Bake a PartDefinition into a ModelPart
fn bakePart(allocator: std.mem.Allocator, def: *PartDefinition, tex_width: u32, tex_height: u32) *ModelPart {
    const part = allocator.create(ModelPart) catch @panic("Failed to allocate ModelPart");

    // Bake cubes
    var baked_cubes: std.ArrayList(BakedCube) = .empty;
    for (def.cubes.items) |cube_def| {
        baked_cubes.append(allocator, bakeCube(cube_def, tex_width, tex_height)) catch {};
    }

    // Bake children
    var baked_children = std.StringHashMap(*ModelPart).init(allocator);
    var iter = def.children.iterator();
    while (iter.next()) |entry| {
        const child_part = bakePart(allocator, entry.value_ptr.*, tex_width, tex_height);
        baked_children.put(entry.key_ptr.*, child_part) catch {};
    }

    part.* = .{
        .allocator = allocator,
        .cubes = baked_cubes.toOwnedSlice(allocator) catch &.{},
        .children = baked_children,
        .pose = def.pose,
    };

    return part;
}

/// Bake a CubeDefinition into a BakedCube with vertices
fn bakeCube(def: CubeDefinition, tex_width: u32, tex_height: u32) BakedCube {
    const ox = def.origin_x;
    const oy = def.origin_y;
    const oz = def.origin_z;
    const w = def.width;
    const h = def.height;
    const d = def.depth;
    const u = def.tex_offs_x;
    const v = def.tex_offs_y;

    const tw = @as(f32, @floatFromInt(tex_width));
    const th = @as(f32, @floatFromInt(tex_height));

    // 8 corners of the box (in model space, before any transforms)
    // Minecraft Y is inverted relative to our world (Y=24 is ground)
    const x0 = ox / 16.0;
    const x1 = (ox + w) / 16.0;
    const y0 = (24.0 - (oy + h)) / 16.0; // Flip Y
    const y1 = (24.0 - oy) / 16.0;
    const z0 = oz / 16.0;
    const z1 = (oz + d) / 16.0;

    // UV layout (Minecraft standard cube net):
    //
    //              +-------+-------+
    //              |  TOP  | BOTTOM|  <- V: [0, depth]
    //              | (w×d) |  (w×d)|
    //       +------+-------+-------+------+
    //       | WEST | NORTH | EAST  | SOUTH|  <- V: [depth, depth+height]
    //       | (d×h)| (w×h) | (d×h) | (w×h)|
    //       +------+-------+-------+------+
    //       ^      ^       ^       ^      ^
    //      U=0    U=d    U=d+w  U=d+w+d U=d+w+d+w
    //
    // Note: TOP/BOTTOM faces use width (w), while EAST face uses depth (d)
    const tex_u0 = u / tw;                       // Start of WEST
    const tex_u1 = (u + d) / tw;                 // Start of TOP/NORTH
    const tex_u2 = (u + d + w) / tw;             // Start of BOTTOM/EAST
    const tex_u2_bottom = (u + d + w + w) / tw;  // End of BOTTOM (width, not depth!)
    const tex_u3 = (u + d + w + d) / tw;         // End of EAST / Start of SOUTH
    const tex_u4 = (u + d + w + d + w) / tw;     // End of SOUTH
    const tex_v0 = v / th;
    const tex_v1 = (v + d) / th;
    const tex_v2 = (v + d + h) / th;

    var vertices: [24]CubeVertex = undefined;

    // Face order: DOWN, UP, WEST, EAST, NORTH, SOUTH
    // Each face has 4 vertices in CCW order when viewed from outside

    // DOWN face (Y-) - bottom of cube, becomes TOP after Y flip
    // UV region: (tex_u1, tex_v0) to (tex_u2, tex_v1)
    vertices[0] = .{ .x = x0, .y = y0, .z = z0, .u = tex_u2, .v = tex_v1 };
    vertices[1] = .{ .x = x1, .y = y0, .z = z0, .u = tex_u1, .v = tex_v1 };
    vertices[2] = .{ .x = x1, .y = y0, .z = z1, .u = tex_u1, .v = tex_v0 };
    vertices[3] = .{ .x = x0, .y = y0, .z = z1, .u = tex_u2, .v = tex_v0 };

    // UP face (Y+) - top of cube, becomes BOTTOM after Y flip
    // UV region: (tex_u2, tex_v0) to (tex_u2_bottom, tex_v1) - BOTTOM face in texture (uses width, not depth!)
    vertices[4] = .{ .x = x0, .y = y1, .z = z1, .u = tex_u2, .v = tex_v0 };
    vertices[5] = .{ .x = x1, .y = y1, .z = z1, .u = tex_u2_bottom, .v = tex_v0 };
    vertices[6] = .{ .x = x1, .y = y1, .z = z0, .u = tex_u2_bottom, .v = tex_v1 };
    vertices[7] = .{ .x = x0, .y = y1, .z = z0, .u = tex_u2, .v = tex_v1 };

    // WEST face (X-) - left side
    // UV region: (tex_u0, tex_v1) to (tex_u1, tex_v2)
    vertices[8] = .{ .x = x0, .y = y1, .z = z0, .u = tex_u1, .v = tex_v1 };
    vertices[9] = .{ .x = x0, .y = y0, .z = z0, .u = tex_u1, .v = tex_v2 };
    vertices[10] = .{ .x = x0, .y = y0, .z = z1, .u = tex_u0, .v = tex_v2 };
    vertices[11] = .{ .x = x0, .y = y1, .z = z1, .u = tex_u0, .v = tex_v1 };

    // EAST face (X+) - right side
    // UV region: (tex_u2, tex_v1) to (tex_u3, tex_v2)
    vertices[12] = .{ .x = x1, .y = y1, .z = z1, .u = tex_u2, .v = tex_v1 };
    vertices[13] = .{ .x = x1, .y = y0, .z = z1, .u = tex_u2, .v = tex_v2 };
    vertices[14] = .{ .x = x1, .y = y0, .z = z0, .u = tex_u3, .v = tex_v2 };
    vertices[15] = .{ .x = x1, .y = y1, .z = z0, .u = tex_u3, .v = tex_v1 };

    // NORTH face (Z-) - front
    // UV region: (tex_u1, tex_v1) to (tex_u2, tex_v2)
    vertices[16] = .{ .x = x1, .y = y1, .z = z0, .u = tex_u1, .v = tex_v1 };
    vertices[17] = .{ .x = x1, .y = y0, .z = z0, .u = tex_u1, .v = tex_v2 };
    vertices[18] = .{ .x = x0, .y = y0, .z = z0, .u = tex_u2, .v = tex_v2 };
    vertices[19] = .{ .x = x0, .y = y1, .z = z0, .u = tex_u2, .v = tex_v1 };

    // SOUTH face (Z+) - back
    // UV region: (tex_u3, tex_v1) to (tex_u4, tex_v2)
    vertices[20] = .{ .x = x0, .y = y1, .z = z1, .u = tex_u3, .v = tex_v1 };
    vertices[21] = .{ .x = x0, .y = y0, .z = z1, .u = tex_u3, .v = tex_v2 };
    vertices[22] = .{ .x = x1, .y = y0, .z = z1, .u = tex_u4, .v = tex_v2 };
    vertices[23] = .{ .x = x1, .y = y1, .z = z1, .u = tex_u4, .v = tex_v1 };

    // Apply mirroring if needed (swap U coordinates)
    if (def.mirror) {
        for (0..6) |face| {
            const fi = face * 4;
            // Swap vertices 0<->1 and 2<->3 UV u-coordinates
            const tmp0u = vertices[fi + 0].u;
            vertices[fi + 0].u = vertices[fi + 1].u;
            vertices[fi + 1].u = tmp0u;
            const tmp2u = vertices[fi + 2].u;
            vertices[fi + 2].u = vertices[fi + 3].u;
            vertices[fi + 3].u = tmp2u;
        }
    }

    return .{
        .vertices = vertices,
        .mirror = def.mirror,
    };
}

// Matrix helper functions

fn buildTransformMatrix(tx: f32, ty: f32, tz: f32, rx: f32, ry: f32, rz: f32) [16]f32 {
    const cos_x = @cos(rx);
    const sin_x = @sin(rx);
    const cos_y = @cos(ry);
    const sin_y = @sin(ry);
    const cos_z = @cos(rz);
    const sin_z = @sin(rz);

    // Combined rotation matrix (ZYX order) with translation
    // Column-major order
    return .{
        cos_y * cos_z,
        cos_x * sin_z + sin_x * sin_y * cos_z,
        sin_x * sin_z - cos_x * sin_y * cos_z,
        0,

        -cos_y * sin_z,
        cos_x * cos_z - sin_x * sin_y * sin_z,
        sin_x * cos_z + cos_x * sin_y * sin_z,
        0,

        sin_y,
        -sin_x * cos_y,
        cos_x * cos_y,
        0,

        tx,
        ty,
        tz,
        1,
    };
}

fn multiplyMatrices(a: [16]f32, b: [16]f32) [16]f32 {
    var result: [16]f32 = undefined;
    for (0..4) |col| {
        for (0..4) |row| {
            var sum: f32 = 0;
            for (0..4) |k| {
                sum += a[k * 4 + row] * b[col * 4 + k];
            }
            result[col * 4 + row] = sum;
        }
    }
    return result;
}

fn transformPoint(m: [16]f32, x: f32, y: f32, z: f32) [3]f32 {
    return .{
        m[0] * x + m[4] * y + m[8] * z + m[12],
        m[1] * x + m[5] * y + m[9] * z + m[13],
        m[2] * x + m[6] * y + m[10] * z + m[14],
    };
}

pub const IDENTITY_MATRIX: [16]f32 = .{
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
};
