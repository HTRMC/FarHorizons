/// BlockOutlineRenderer - Renders the outline around targeted blocks
/// Similar to Minecraft's block highlight system
const std = @import("std");
const shared = @import("Shared");
const VoxelShape = shared.VoxelShape;
const Raycast = shared.Raycast;
const BlockHitResult = Raycast.BlockHitResult;
const BlockPos = BlockHitResult.BlockPos;
const RenderSystem = @import("RenderSystem.zig").RenderSystem;
const LineVertex = RenderSystem.LineVertex;

const Logger = shared.Logger;
const logger = Logger.init("BlockOutlineRenderer");

pub const BlockOutlineRenderer = struct {
    const Self = @This();

    /// Maximum number of edges we can render (12 edges for a simple box, more for complex shapes)
    const MAX_EDGES: usize = 64;

    /// Vertex buffer for line rendering (2 vertices per edge)
    line_vertices: [MAX_EDGES * 2]LineVertex = undefined,
    vertex_count: usize = 0,

    /// Outline color: black with 40% alpha (like Minecraft: ARGB.black(102) = 102/255 ≈ 0.4)
    const OUTLINE_COLOR: [4]f32 = .{ 0.0, 0.0, 0.0, 0.4 };

    pub fn init() Self {
        return .{};
    }

    /// Generate outline vertices for a block at the given position with the given shape
    /// Returns the number of vertices generated
    pub fn generateOutline(
        self: *Self,
        block_pos: BlockPos,
        shape: *const VoxelShape,
    ) usize {
        self.vertex_count = 0;

        // Context for edge consumer callback
        var ctx = EdgeContext{
            .renderer = self,
            .block_x = @floatFromInt(block_pos.x),
            .block_y = @floatFromInt(block_pos.y),
            .block_z = @floatFromInt(block_pos.z),
        };

        // Iterate over all edges in the shape
        shape.forAllEdges(&addEdge, @ptrCast(&ctx));

        return self.vertex_count;
    }

    /// Clear the outline (nothing to render)
    pub fn clear(self: *Self) void {
        self.vertex_count = 0;
    }

    /// Get the generated vertices as a slice
    pub fn getVertices(self: *const Self) []const LineVertex {
        return self.line_vertices[0..self.vertex_count];
    }

    /// Upload the current outline to the render system
    pub fn uploadToRenderSystem(self: *const Self, render_system: *RenderSystem) !void {
        if (self.vertex_count == 0) {
            render_system.clearLineVertices();
        } else {
            try render_system.uploadLineVertices(self.getVertices());
        }
    }

    /// Context passed to edge iteration callback
    const EdgeContext = struct {
        renderer: *Self,
        block_x: f32,
        block_y: f32,
        block_z: f32,
    };

    /// Callback for VoxelShape.forAllEdges
    fn addEdge(
        x1: f64,
        y1: f64,
        z1: f64,
        x2: f64,
        y2: f64,
        z2: f64,
        ctx_ptr: *anyopaque,
    ) void {
        const ctx: *EdgeContext = @ptrCast(@alignCast(ctx_ptr));
        const self = ctx.renderer;

        if (self.vertex_count + 2 > MAX_EDGES * 2) {
            return; // Buffer full
        }

        // Convert normalized coords (0-1) to world coords
        // Note: z-fighting is handled by view-space scaling in the vertex shader (like Minecraft)
        const fx1: f32 = @floatCast(x1);
        const fy1: f32 = @floatCast(y1);
        const fz1: f32 = @floatCast(z1);
        const fx2: f32 = @floatCast(x2);
        const fy2: f32 = @floatCast(y2);
        const fz2: f32 = @floatCast(z2);

        // First vertex
        self.line_vertices[self.vertex_count] = .{
            .pos = .{
                ctx.block_x + fx1,
                ctx.block_y + fy1,
                ctx.block_z + fz1,
            },
            .color = OUTLINE_COLOR,
        };
        self.vertex_count += 1;

        // Second vertex
        self.line_vertices[self.vertex_count] = .{
            .pos = .{
                ctx.block_x + fx2,
                ctx.block_y + fy2,
                ctx.block_z + fz2,
            },
            .color = OUTLINE_COLOR,
        };
        self.vertex_count += 1;
    }
};
