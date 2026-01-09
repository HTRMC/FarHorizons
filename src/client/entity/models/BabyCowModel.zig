const std = @import("std");
const renderer = @import("Renderer");
const mb = @import("ModelBuilder.zig");

const Vertex = renderer.Vertex;
const PartPose = mb.PartPose;
const CubeListBuilder = mb.CubeListBuilder;
const MeshDefinition = mb.MeshDefinition;
const LayerDefinition = mb.LayerDefinition;
const ModelPart = mb.ModelPart;

/// Minecraft baby cow model using the model builder system
/// Matches BabyCowModel.java from MC 1.21+
/// Baby cows have:
/// - Proportionally larger head (6x6x5 vs 8x8x6)
/// - Shorter legs (6 pixels instead of 12)
/// - Smaller body (8x6x12 vs 12x18x10)
/// - Different pivot positions
/// - Body is NOT rotated (horizontal orientation)
pub const BabyCowModel = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    root: ?*ModelPart = null,

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
        }
    }

    /// Create the body layer definition - matches BabyCowModel.createBodyLayer()
    pub fn createBodyLayer(allocator: std.mem.Allocator) LayerDefinition {
        var mesh = MeshDefinition.init(allocator);
        const root = mesh.getRoot();

        // Head: PartPose.offset(0, 13.569, -5.1667)
        // box(-3, -4.569, -4.8333, 6, 6, 5) texOffs(0, 18) - main head
        // box(3, -5.569, -3.8333, 1, 2, 1) texOffs(8, 29) - right horn
        // box(-4, -5.569, -3.8333, 1, 2, 1) texOffs(4, 29) - left horn (mirrored)
        // box(-2, -1.569, -5.8333, 4, 3, 1) texOffs(12, 29) - snout
        var head_builder = CubeListBuilder.create(allocator);
        _ = head_builder.texOffs(0, 18).addBox(-3, -4.569, -4.8333, 6, 6, 5);
        _ = head_builder.texOffs(8, 29).addBox(3, -5.569, -3.8333, 1, 2, 1);
        _ = head_builder.texOffs(4, 29).mirror().addBox(-4, -5.569, -3.8333, 1, 2, 1).mirrorSet(false);
        _ = head_builder.texOffs(12, 29).addBox(-2, -1.569, -5.8333, 4, 3, 1);
        _ = root.addOrReplaceChild("head", &head_builder, PartPose.offset(0, 13.569, -5.1667));
        head_builder.deinit();

        // Body: PartPose.offset(3, 19, -5)
        // box(-7, -7, -1, 8, 6, 12) texOffs(0, 0)
        // Note: Baby body is NOT rotated like adult, it stays horizontal
        var body_builder = CubeListBuilder.create(allocator);
        _ = body_builder.texOffs(0, 0).addBox(-7, -7, -1, 8, 6, 12);
        _ = root.addOrReplaceChild("body", &body_builder, PartPose.offset(3, 19, -5));
        body_builder.deinit();

        // Legs (shorter than adult: 6 pixels instead of 12)
        // Right front leg: PartPose.offset(-2.5, 18, -3.5)
        // box(-1.5, 0, -1.5, 3, 6, 3) texOffs(22, 18)
        var right_front_leg_builder = CubeListBuilder.create(allocator);
        _ = right_front_leg_builder.texOffs(22, 18).addBox(-1.5, 0, -1.5, 3, 6, 3);
        _ = root.addOrReplaceChild("right_front_leg", &right_front_leg_builder, PartPose.offset(-2.5, 18, -3.5));
        right_front_leg_builder.deinit();

        // Left front leg: PartPose.offset(2.5, 18, -3.5)
        // box(-1.5, 0, -1.5, 3, 6, 3) texOffs(34, 18)
        var left_front_leg_builder = CubeListBuilder.create(allocator);
        _ = left_front_leg_builder.texOffs(34, 18).addBox(-1.5, 0, -1.5, 3, 6, 3);
        _ = root.addOrReplaceChild("left_front_leg", &left_front_leg_builder, PartPose.offset(2.5, 18, -3.5));
        left_front_leg_builder.deinit();

        // Right hind leg: PartPose.offset(-2.5, 18, 3.5)
        // box(-1.5, 0, -1.5, 3, 6, 3) texOffs(22, 27)
        var right_hind_leg_builder = CubeListBuilder.create(allocator);
        _ = right_hind_leg_builder.texOffs(22, 27).addBox(-1.5, 0, -1.5, 3, 6, 3);
        _ = root.addOrReplaceChild("right_hind_leg", &right_hind_leg_builder, PartPose.offset(-2.5, 18, 3.5));
        right_hind_leg_builder.deinit();

        // Left hind leg: PartPose.offset(2.5, 18, 3.5)
        // box(-1.5, 0, -1.5, 3, 6, 3) texOffs(34, 27)
        var left_hind_leg_builder = CubeListBuilder.create(allocator);
        _ = left_hind_leg_builder.texOffs(34, 27).addBox(-1.5, 0, -1.5, 3, 6, 3);
        _ = root.addOrReplaceChild("left_hind_leg", &left_hind_leg_builder, PartPose.offset(2.5, 18, 3.5));
        left_hind_leg_builder.deinit();

        return LayerDefinition.create(mesh, 64, 64);
    }

    /// Generate baby cow mesh with animation
    /// walk_animation: position in walk cycle (increases while walking)
    /// walk_speed: amplitude of leg swing (0=stationary, 1=full swing)
    /// head_pitch: vertical head rotation (positive = look down)
    /// head_yaw: horizontal head rotation (positive = look right)
    pub fn generateMesh(self: *Self, walk_animation: f32, walk_speed: f32, head_pitch: f32, head_yaw: f32) !struct { vertices: []Vertex, indices: []u32 } {
        // Apply animation - same as adult but with shorter legs
        const right_hind_rot = @cos(walk_animation * 0.6662) * 1.4 * walk_speed;
        const left_hind_rot = @cos(walk_animation * 0.6662 + std.math.pi) * 1.4 * walk_speed;
        const right_front_rot = @cos(walk_animation * 0.6662 + std.math.pi) * 1.4 * walk_speed;
        const left_front_rot = @cos(walk_animation * 0.6662) * 1.4 * walk_speed;

        // Set part rotations
        if (self.head) |head| {
            head.setRotation(head_pitch, head_yaw, 0);
        }
        if (self.right_hind_leg) |leg| {
            leg.setRotation(right_hind_rot, 0, 0);
        }
        if (self.left_hind_leg) |leg| {
            leg.setRotation(left_hind_rot, 0, 0);
        }
        if (self.right_front_leg) |leg| {
            leg.setRotation(right_front_rot, 0, 0);
        }
        if (self.left_front_leg) |leg| {
            leg.setRotation(left_front_rot, 0, 0);
        }

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
