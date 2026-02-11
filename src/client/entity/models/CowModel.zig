const std = @import("std");
const renderer = @import("Renderer");
const mb = @import("ModelBuilder.zig");

const Vertex = renderer.Vertex;
const PartPose = mb.PartPose;
const CubeListBuilder = mb.CubeListBuilder;
const MeshDefinition = mb.MeshDefinition;
const LayerDefinition = mb.LayerDefinition;
const ModelPart = mb.ModelPart;

/// Minecraft-style cow model using the model builder system
/// Matches CowModel.java from MC 1.21+
pub const CowModel = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    root: ?*ModelPart = null,
    total_cubes: u32 = 0,

    // Named part references for animation
    head: ?*ModelPart = null,
    right_hind_leg: ?*ModelPart = null,
    left_hind_leg: ?*ModelPart = null,
    right_front_leg: ?*ModelPart = null,
    left_front_leg: ?*ModelPart = null,

    pub fn init(allocator: std.mem.Allocator) Self {
        var self = Self{
            .allocator = allocator,
        };
        self.buildModel();
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.root) |root| {
            root.deinit();
            self.allocator.destroy(root);
        }
    }

    fn buildModel(self: *Self) void {
        var layer = createBodyLayer(self.allocator);
        defer layer.deinit();

        self.root = layer.bake();

        // Get part references for animation
        if (self.root) |root| {
            self.head = root.getChild("head");
            self.right_hind_leg = root.getChild("right_hind_leg");
            self.left_hind_leg = root.getChild("left_hind_leg");
            self.right_front_leg = root.getChild("right_front_leg");
            self.left_front_leg = root.getChild("left_front_leg");
            self.total_cubes = root.countCubes();
        }
    }

    pub fn getVertexCount(self: *const Self) u32 {
        return self.total_cubes * 24;
    }

    pub fn getIndexCount(self: *const Self) u32 {
        return self.total_cubes * 36;
    }

    /// Create the body layer definition - matches CowModel.createBodyLayer()
    pub fn createBodyLayer(allocator: std.mem.Allocator) LayerDefinition {
        var mesh = MeshDefinition.init(allocator);
        const root = mesh.getRoot();

        // Head: PartPose.offset(0, 4, -8)
        // box(-4, -4, -6, 8, 8, 6) texOffs(0, 0) - head
        // box(-3, 1, -7, 6, 3, 1) texOffs(1, 33) - snout (muzzle)
        // box(-5, -5, -5, 1, 3, 1) texOffs(22, 0) - right horn
        // box(4, -5, -5, 1, 3, 1) texOffs(22, 0) - left horn
        var head_builder = CubeListBuilder.create(allocator);
        _ = head_builder.texOffs(0, 0).addBox(-4, -4, -6, 8, 8, 6);
        _ = head_builder.texOffs(1, 33).addBox(-3, 1, -7, 6, 3, 1);
        _ = head_builder.texOffs(22, 0).addBox(-5, -5, -5, 1, 3, 1);
        _ = head_builder.texOffs(22, 0).addBox(4, -5, -5, 1, 3, 1);
        _ = root.addOrReplaceChild("head", &head_builder, PartPose.offset(0, 4, -8));
        head_builder.deinit();

        // Body: PartPose.offsetAndRotation(0, 5, 2, PI/2, 0, 0)
        // box(-6, -10, -7, 12, 18, 10) texOffs(18, 4) - body
        // box(-2, 2, -8, 4, 6, 1) texOffs(52, 0) - udder
        var body_builder = CubeListBuilder.create(allocator);
        _ = body_builder.texOffs(18, 4).addBox(-6, -10, -7, 12, 18, 10);
        _ = body_builder.texOffs(52, 0).addBox(-2, 2, -8, 4, 6, 1);
        _ = root.addOrReplaceChild("body", &body_builder, PartPose.offsetAndRotation(0, 5, 2, std.math.pi / 2.0, 0, 0));
        body_builder.deinit();

        // Legs
        var right_leg_builder = CubeListBuilder.create(allocator);
        _ = right_leg_builder.texOffs(0, 16).addBox(-2, 0, -2, 4, 12, 4);

        var left_leg_builder = CubeListBuilder.create(allocator);
        _ = left_leg_builder.mirror().texOffs(0, 16).addBox(-2, 0, -2, 4, 12, 4);

        // Right hind leg: PartPose.offset(-4, 12, 7)
        _ = root.addOrReplaceChild("right_hind_leg", &right_leg_builder, PartPose.offset(-4, 12, 7));

        // Left hind leg: PartPose.offset(4, 12, 7)
        _ = root.addOrReplaceChild("left_hind_leg", &left_leg_builder, PartPose.offset(4, 12, 7));

        // Right front leg: PartPose.offset(-4, 12, -5)
        _ = root.addOrReplaceChild("right_front_leg", &right_leg_builder, PartPose.offset(-4, 12, -5));

        // Left front leg: PartPose.offset(4, 12, -5)
        _ = root.addOrReplaceChild("left_front_leg", &left_leg_builder, PartPose.offset(4, 12, -5));

        right_leg_builder.deinit();
        left_leg_builder.deinit();

        return LayerDefinition.create(mesh, 64, 64);
    }

    /// Generate cow mesh directly into a MeshWriter (zero allocations)
    pub fn generateMeshDirect(self: *Self, walk_animation: f32, walk_speed: f32, head_pitch: f32, head_yaw: f32, writer: *mb.MeshWriter) void {
        self.applyAnimation(walk_animation, walk_speed, head_pitch, head_yaw);
        if (self.root) |root| root.renderDirect(writer, mb.IDENTITY_MATRIX);
    }

    fn applyAnimation(self: *Self, walk_animation: f32, walk_speed: f32, head_pitch: f32, head_yaw: f32) void {
        const right_hind_rot = @cos(walk_animation * 0.6662) * 1.4 * walk_speed;
        const left_hind_rot = @cos(walk_animation * 0.6662 + std.math.pi) * 1.4 * walk_speed;
        const right_front_rot = @cos(walk_animation * 0.6662 + std.math.pi) * 1.4 * walk_speed;
        const left_front_rot = @cos(walk_animation * 0.6662) * 1.4 * walk_speed;

        if (self.head) |head| head.setRotation(head_pitch, head_yaw, 0);
        if (self.right_hind_leg) |leg| leg.setRotation(right_hind_rot, 0, 0);
        if (self.left_hind_leg) |leg| leg.setRotation(left_hind_rot, 0, 0);
        if (self.right_front_leg) |leg| leg.setRotation(right_front_rot, 0, 0);
        if (self.left_front_leg) |leg| leg.setRotation(left_front_rot, 0, 0);
    }

    /// Generate cow mesh with animation
    /// walk_animation: position in walk cycle (increases while walking)
    /// walk_speed: amplitude of leg swing (0=stationary, 1=full swing)
    /// head_pitch: vertical head rotation (positive = look down)
    /// head_yaw: horizontal head rotation (positive = look right)
    pub fn generateMesh(self: *Self, walk_animation: f32, walk_speed: f32, head_pitch: f32, head_yaw: f32) !struct { vertices: []Vertex, indices: []u32 } {
        self.applyAnimation(walk_animation, walk_speed, head_pitch, head_yaw);

        // Render to vertex/index buffers
        var vertices: std.ArrayList(Vertex) = .empty;
        var indices: std.ArrayList(u32) = .empty;

        if (self.root) |root| {
            try root.render(&vertices, &indices, mb.IDENTITY_MATRIX);
        }

        return .{
            .vertices = try vertices.toOwnedSlice(self.allocator),
            .indices = try indices.toOwnedSlice(self.allocator),
        };
    }
};
