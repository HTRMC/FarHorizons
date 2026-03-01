const std = @import("std");
const vk = @import("../../platform/volk.zig");
const c = @import("../../platform/c.zig").c;
const ShaderCompiler = @import("ShaderCompiler.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const vk_utils = @import("vk_utils.zig");
const types = @import("types.zig");
const UiVertex = types.UiVertex;
const tracy = @import("../../platform/tracy.zig");
const app_config = @import("../../app_config.zig");

const MAX_QUADS = 4096;
const MAX_VERTICES = MAX_QUADS * 6;
const MAX_DRAW_LAYERS = 8;

const DrawLayer = struct {
    normal_start: u32 = 0,
    normal_count: u32 = 0,
    inverted_start: u32 = 0,
    inverted_count: u32 = 0,
};

pub const SpriteRect = struct {
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
};

pub const UiRenderer = struct {
    pipeline: vk.VkPipeline,
    inverted_pipeline: vk.VkPipeline,
    pipeline_layout: vk.VkPipelineLayout,
    descriptor_set_layout: vk.VkDescriptorSetLayout,
    descriptor_pool: vk.VkDescriptorPool,
    descriptor_set: vk.VkDescriptorSet,
    vertex_buffer: vk.VkBuffer,
    vertex_buffer_memory: vk.VkDeviceMemory,
    vertex_count: u32,
    inverted_vertex_count: u32 = 0,
    screen_width: f32,
    screen_height: f32,
    mapped_vertices: ?[*]UiVertex,
    clip_rect: [4]f32 = .{ -1e9, -1e9, 1e9, 1e9 },
    clip_stack: [8][4]f32 = undefined,
    clip_depth: u8 = 0,
    clip_scale: f32 = 1.0,

    // Per-screen draw layers for proper z-ordering
    draw_layers: [MAX_DRAW_LAYERS]DrawLayer = [_]DrawLayer{.{}} ** MAX_DRAW_LAYERS,
    draw_layer_count: u8 = 0,
    layer_normal_start: u32 = 0,
    layer_inverted_start: u32 = 0,

    // Atlas texture (1x1 white fallback if no real atlas)
    atlas_image: vk.VkImage,
    atlas_image_memory: vk.VkDeviceMemory,
    atlas_image_view: vk.VkImageView,
    atlas_sampler: vk.VkSampler,

    // HUD sprite rects (valid after loadHudAtlas)
    crosshair_rect: SpriteRect = .{ .u0 = 0, .v0 = 0, .u1 = 0, .v1 = 0 },
    hotbar_rect: SpriteRect = .{ .u0 = 0, .v0 = 0, .u1 = 0, .v1 = 0 },
    selection_rect: SpriteRect = .{ .u0 = 0, .v0 = 0, .u1 = 0, .v1 = 0 },
    offhand_rect: SpriteRect = .{ .u0 = 0, .v0 = 0, .u1 = 0, .v1 = 0 },
    // Original pixel dimensions of each sprite (for sizing at scale)
    crosshair_size: [2]f32 = .{ 0, 0 },
    hotbar_size: [2]f32 = .{ 0, 0 },
    selection_size: [2]f32 = .{ 0, 0 },
    offhand_size: [2]f32 = .{ 0, 0 },
    hud_atlas_loaded: bool = false,

    pub fn init(
        shader_compiler: *ShaderCompiler,
        ctx: *const VulkanContext,
        swapchain_format: vk.VkFormat,
    ) !UiRenderer {
        const tz = tracy.zone(@src(), "UiRenderer.init");
        defer tz.end();

        var self = UiRenderer{
            .pipeline = null,
            .inverted_pipeline = null,
            .pipeline_layout = null,
            .descriptor_set_layout = null,
            .descriptor_pool = null,
            .descriptor_set = null,
            .vertex_buffer = null,
            .vertex_buffer_memory = null,
            .vertex_count = 0,
            .screen_width = 800.0,
            .screen_height = 600.0,
            .mapped_vertices = null,
            .atlas_image = null,
            .atlas_image_memory = null,
            .atlas_image_view = null,
            .atlas_sampler = null,
        };

        try self.createVertexBuffer(ctx);
        try self.createFallbackAtlas(ctx);
        try self.createDescriptors(ctx);
        try self.createPipeline(shader_compiler, ctx, swapchain_format);

        std.log.info("UiRenderer initialized", .{});
        return self;
    }

    pub fn deinit(self: *UiRenderer, device: vk.VkDevice) void {
        vk.destroyPipeline(device, self.pipeline, null);
        vk.destroyPipeline(device, self.inverted_pipeline, null);
        vk.destroyPipelineLayout(device, self.pipeline_layout, null);
        vk.destroyDescriptorPool(device, self.descriptor_pool, null);
        vk.destroyDescriptorSetLayout(device, self.descriptor_set_layout, null);
        vk.destroyBuffer(device, self.vertex_buffer, null);
        vk.freeMemory(device, self.vertex_buffer_memory, null);
        vk.destroySampler(device, self.atlas_sampler, null);
        vk.destroyImageView(device, self.atlas_image_view, null);
        vk.destroyImage(device, self.atlas_image, null);
        vk.freeMemory(device, self.atlas_image_memory, null);
    }

    pub fn beginFrame(self: *UiRenderer, device: vk.VkDevice) void {
        var data: ?*anyopaque = null;
        vk.mapMemory(device, self.vertex_buffer_memory, 0, MAX_VERTICES * @sizeOf(UiVertex), 0, &data) catch return;
        self.mapped_vertices = @ptrCast(@alignCast(data));
        self.vertex_count = 0;
        self.inverted_vertex_count = 0;
        self.draw_layer_count = 0;
    }

    pub fn endFrame(self: *UiRenderer, device: vk.VkDevice) void {
        if (self.mapped_vertices != null) {
            vk.unmapMemory(device, self.vertex_buffer_memory);
            self.mapped_vertices = null;
        }
    }

    /// Begin a new draw layer. Call before rendering each screen.
    pub fn beginLayer(self: *UiRenderer) void {
        self.layer_normal_start = self.vertex_count;
        self.layer_inverted_start = self.inverted_vertex_count;
    }

    /// End the current draw layer. Call after rendering each screen.
    pub fn endLayer(self: *UiRenderer) void {
        if (self.draw_layer_count >= MAX_DRAW_LAYERS) return;
        const normal_count = self.vertex_count - self.layer_normal_start;
        const inverted_count = self.inverted_vertex_count - self.layer_inverted_start;
        if (normal_count == 0 and inverted_count == 0) return;
        self.draw_layers[self.draw_layer_count] = .{
            .normal_start = self.layer_normal_start,
            .normal_count = normal_count,
            .inverted_start = self.layer_inverted_start,
            .inverted_count = inverted_count,
        };
        self.draw_layer_count += 1;
    }

    pub fn recordDraw(self: *const UiRenderer, command_buffer: vk.VkCommandBuffer) void {
        if (self.vertex_count == 0 and self.inverted_vertex_count == 0) return;

        const ortho = orthoMatrix(self.screen_width, self.screen_height);

        // Draw per-layer: for each screen layer, draw inverted then normal,
        // so that later screens' widgets render on top of earlier screens.
        for (self.draw_layers[0..self.draw_layer_count]) |layer| {
            if (layer.inverted_count > 0) {
                vk.cmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.inverted_pipeline);
                vk.cmdBindDescriptorSets(
                    command_buffer,
                    vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
                    self.pipeline_layout,
                    0,
                    1,
                    &[_]vk.VkDescriptorSet{self.descriptor_set},
                    0,
                    null,
                );
                vk.cmdPushConstants(
                    command_buffer,
                    self.pipeline_layout,
                    vk.VK_SHADER_STAGE_VERTEX_BIT,
                    0,
                    64,
                    &ortho,
                );
                // Inverted vertices are stored at the end of the buffer, growing downward.
                // layer.inverted_start is the count of inverted verts before this layer started.
                const first = MAX_VERTICES - layer.inverted_start - layer.inverted_count;
                vk.cmdDraw(command_buffer, layer.inverted_count, 1, first, 0);
            }

            if (layer.normal_count > 0) {
                vk.cmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);
                vk.cmdBindDescriptorSets(
                    command_buffer,
                    vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
                    self.pipeline_layout,
                    0,
                    1,
                    &[_]vk.VkDescriptorSet{self.descriptor_set},
                    0,
                    null,
                );
                vk.cmdPushConstants(
                    command_buffer,
                    self.pipeline_layout,
                    vk.VK_SHADER_STAGE_VERTEX_BIT,
                    0,
                    64,
                    &ortho,
                );
                vk.cmdDraw(command_buffer, layer.normal_count, 1, layer.normal_start, 0);
            }
        }
    }

    pub fn updateScreenSize(self: *UiRenderer, width: u32, height: u32, scale: f32) void {
        self.screen_width = @floatFromInt(width);
        self.screen_height = @floatFromInt(height);
        self.clip_scale = scale;
    }

    // ── Clip rect ──

    pub fn setClipRect(self: *UiRenderer, x: f32, y: f32, w: f32, h: f32) void {
        self.clip_rect = .{ x, y, x + w, y + h };
    }

    pub fn clearClipRect(self: *UiRenderer) void {
        self.clip_rect = .{ -1e9, -1e9, 1e9, 1e9 };
    }

    /// Push a clip rect that intersects with the current one.
    pub fn pushClipRect(self: *UiRenderer, x: f32, y: f32, w: f32, h: f32) void {
        if (self.clip_depth < 8) {
            self.clip_stack[self.clip_depth] = self.clip_rect;
            self.clip_depth += 1;
        }
        // Intersect with current clip rect
        const new = [4]f32{
            @max(self.clip_rect[0], x),
            @max(self.clip_rect[1], y),
            @min(self.clip_rect[2], x + w),
            @min(self.clip_rect[3], y + h),
        };
        self.clip_rect = new;
    }

    /// Restore the previous clip rect from the stack.
    pub fn popClipRect(self: *UiRenderer) void {
        if (self.clip_depth > 0) {
            self.clip_depth -= 1;
            self.clip_rect = self.clip_stack[self.clip_depth];
        } else {
            self.clip_rect = .{ -1e9, -1e9, 1e9, 1e9 };
        }
    }

    // ── Drawing primitives ──

    /// Draw a solid-color rectangle.
    pub fn drawRect(self: *UiRenderer, x: f32, y: f32, w: f32, h: f32, color: [4]f32) void {
        if (w <= 0 or h <= 0 or color[3] < 0.01) return;
        const verts = self.mapped_vertices orelse return;
        if (self.vertex_count + 6 > MAX_VERTICES) return;

        const x0 = x;
        const y0 = y;
        const x1 = x + w;
        const y1 = y + h;

        // Negative UV.x signals solid color in fragment shader
        const s = self.clip_scale;
        const cr = [4]f32{ self.clip_rect[0] * s, self.clip_rect[1] * s, self.clip_rect[2] * s, self.clip_rect[3] * s };
        verts[self.vertex_count + 0] = .{ .px = x0, .py = y0, .u = -1, .v = -1, .r = color[0], .g = color[1], .b = color[2], .a = color[3], .clip_min_x = cr[0], .clip_min_y = cr[1], .clip_max_x = cr[2], .clip_max_y = cr[3] };
        verts[self.vertex_count + 1] = .{ .px = x1, .py = y0, .u = -1, .v = -1, .r = color[0], .g = color[1], .b = color[2], .a = color[3], .clip_min_x = cr[0], .clip_min_y = cr[1], .clip_max_x = cr[2], .clip_max_y = cr[3] };
        verts[self.vertex_count + 2] = .{ .px = x0, .py = y1, .u = -1, .v = -1, .r = color[0], .g = color[1], .b = color[2], .a = color[3], .clip_min_x = cr[0], .clip_min_y = cr[1], .clip_max_x = cr[2], .clip_max_y = cr[3] };
        verts[self.vertex_count + 3] = .{ .px = x1, .py = y0, .u = -1, .v = -1, .r = color[0], .g = color[1], .b = color[2], .a = color[3], .clip_min_x = cr[0], .clip_min_y = cr[1], .clip_max_x = cr[2], .clip_max_y = cr[3] };
        verts[self.vertex_count + 4] = .{ .px = x1, .py = y1, .u = -1, .v = -1, .r = color[0], .g = color[1], .b = color[2], .a = color[3], .clip_min_x = cr[0], .clip_min_y = cr[1], .clip_max_x = cr[2], .clip_max_y = cr[3] };
        verts[self.vertex_count + 5] = .{ .px = x0, .py = y1, .u = -1, .v = -1, .r = color[0], .g = color[1], .b = color[2], .a = color[3], .clip_min_x = cr[0], .clip_min_y = cr[1], .clip_max_x = cr[2], .clip_max_y = cr[3] };

        self.vertex_count += 6;
    }

    /// Draw a textured rectangle with UV coordinates and tint color.
    pub fn drawTexturedRect(self: *UiRenderer, x: f32, y: f32, w: f32, h: f32, uv_left: f32, uv_top: f32, uv_right: f32, uv_bottom: f32, tint: [4]f32) void {
        if (w <= 0 or h <= 0 or tint[3] < 0.01) return;
        const verts = self.mapped_vertices orelse return;
        if (self.vertex_count + 6 > MAX_VERTICES) return;

        const x0 = x;
        const y0 = y;
        const x1 = x + w;
        const y1 = y + h;

        const s2 = self.clip_scale;
        const cr = [4]f32{ self.clip_rect[0] * s2, self.clip_rect[1] * s2, self.clip_rect[2] * s2, self.clip_rect[3] * s2 };
        verts[self.vertex_count + 0] = .{ .px = x0, .py = y0, .u = uv_left, .v = uv_top, .r = tint[0], .g = tint[1], .b = tint[2], .a = tint[3], .clip_min_x = cr[0], .clip_min_y = cr[1], .clip_max_x = cr[2], .clip_max_y = cr[3] };
        verts[self.vertex_count + 1] = .{ .px = x1, .py = y0, .u = uv_right, .v = uv_top, .r = tint[0], .g = tint[1], .b = tint[2], .a = tint[3], .clip_min_x = cr[0], .clip_min_y = cr[1], .clip_max_x = cr[2], .clip_max_y = cr[3] };
        verts[self.vertex_count + 2] = .{ .px = x0, .py = y1, .u = uv_left, .v = uv_bottom, .r = tint[0], .g = tint[1], .b = tint[2], .a = tint[3], .clip_min_x = cr[0], .clip_min_y = cr[1], .clip_max_x = cr[2], .clip_max_y = cr[3] };
        verts[self.vertex_count + 3] = .{ .px = x1, .py = y0, .u = uv_right, .v = uv_top, .r = tint[0], .g = tint[1], .b = tint[2], .a = tint[3], .clip_min_x = cr[0], .clip_min_y = cr[1], .clip_max_x = cr[2], .clip_max_y = cr[3] };
        verts[self.vertex_count + 4] = .{ .px = x1, .py = y1, .u = uv_right, .v = uv_bottom, .r = tint[0], .g = tint[1], .b = tint[2], .a = tint[3], .clip_min_x = cr[0], .clip_min_y = cr[1], .clip_max_x = cr[2], .clip_max_y = cr[3] };
        verts[self.vertex_count + 5] = .{ .px = x0, .py = y1, .u = uv_left, .v = uv_bottom, .r = tint[0], .g = tint[1], .b = tint[2], .a = tint[3], .clip_min_x = cr[0], .clip_min_y = cr[1], .clip_max_x = cr[2], .clip_max_y = cr[3] };

        self.vertex_count += 6;
    }

    /// Draw a 9-slice textured rectangle. border = inset in pixels for corners/edges.
    pub fn drawNineSlice(self: *UiRenderer, x: f32, y: f32, w: f32, h: f32, border: f32, uv_l: f32, uv_t: f32, uv_r: f32, uv_b: f32, atlas_w: f32, atlas_h: f32, tint: [4]f32) void {
        if (w <= 0 or h <= 0 or border <= 0) {
            self.drawTexturedRect(x, y, w, h, uv_l, uv_t, uv_r, uv_b, tint);
            return;
        }

        const bu = border / atlas_w; // border in UV space
        const bv = border / atlas_h;
        const b = border; // border in pixel space

        // Clamp border to half the size
        const bx = @min(b, w / 2);
        const by = @min(b, h / 2);
        const bux = @min(bu, (uv_r - uv_l) / 2);
        const bvy = @min(bv, (uv_b - uv_t) / 2);

        // Top-left, top-center, top-right
        self.drawTexturedRect(x, y, bx, by, uv_l, uv_t, uv_l + bux, uv_t + bvy, tint);
        self.drawTexturedRect(x + bx, y, w - bx * 2, by, uv_l + bux, uv_t, uv_r - bux, uv_t + bvy, tint);
        self.drawTexturedRect(x + w - bx, y, bx, by, uv_r - bux, uv_t, uv_r, uv_t + bvy, tint);

        // Middle-left, center, middle-right
        self.drawTexturedRect(x, y + by, bx, h - by * 2, uv_l, uv_t + bvy, uv_l + bux, uv_b - bvy, tint);
        self.drawTexturedRect(x + bx, y + by, w - bx * 2, h - by * 2, uv_l + bux, uv_t + bvy, uv_r - bux, uv_b - bvy, tint);
        self.drawTexturedRect(x + w - bx, y + by, bx, h - by * 2, uv_r - bux, uv_t + bvy, uv_r, uv_b - bvy, tint);

        // Bottom-left, bottom-center, bottom-right
        self.drawTexturedRect(x, y + h - by, bx, by, uv_l, uv_b - bvy, uv_l + bux, uv_b, tint);
        self.drawTexturedRect(x + bx, y + h - by, w - bx * 2, by, uv_l + bux, uv_b - bvy, uv_r - bux, uv_b, tint);
        self.drawTexturedRect(x + w - bx, y + h - by, bx, by, uv_r - bux, uv_b - bvy, uv_r, uv_b, tint);
    }

    /// Draw a rectangle outline (border).
    pub fn drawRectOutline(self: *UiRenderer, x: f32, y: f32, w: f32, h: f32, thickness: f32, color: [4]f32) void {
        if (thickness <= 0 or color[3] < 0.01) return;
        // Top edge
        self.drawRect(x, y, w, thickness, color);
        // Bottom edge
        self.drawRect(x, y + h - thickness, w, thickness, color);
        // Left edge
        self.drawRect(x, y + thickness, thickness, h - thickness * 2, color);
        // Right edge
        self.drawRect(x + w - thickness, y + thickness, thickness, h - thickness * 2, color);
    }

    /// Draw a sprite from the HUD atlas at the given position and scale.
    pub fn drawSprite(self: *UiRenderer, sprite: SpriteRect, x: f32, y: f32, w: f32, h: f32, tint: [4]f32) void {
        self.drawTexturedRect(x, y, w, h, sprite.u0, sprite.v0, sprite.u1, sprite.v1, tint);
    }

    /// Draw a textured rectangle into the inverted-blend region (end of vertex buffer).
    pub fn drawTexturedRectInverted(self: *UiRenderer, x: f32, y: f32, w: f32, h: f32, uv_left: f32, uv_top: f32, uv_right: f32, uv_bottom: f32, tint: [4]f32) void {
        if (w <= 0 or h <= 0) return;
        const verts = self.mapped_vertices orelse return;
        if (self.vertex_count + self.inverted_vertex_count + 6 > MAX_VERTICES) return;

        const base = MAX_VERTICES - self.inverted_vertex_count - 6;

        const x0 = x;
        const y0 = y;
        const x1 = x + w;
        const y1 = y + h;

        const s2 = self.clip_scale;
        const cr = [4]f32{ self.clip_rect[0] * s2, self.clip_rect[1] * s2, self.clip_rect[2] * s2, self.clip_rect[3] * s2 };
        verts[base + 0] = .{ .px = x0, .py = y0, .u = uv_left, .v = uv_top, .r = tint[0], .g = tint[1], .b = tint[2], .a = tint[3], .clip_min_x = cr[0], .clip_min_y = cr[1], .clip_max_x = cr[2], .clip_max_y = cr[3] };
        verts[base + 1] = .{ .px = x1, .py = y0, .u = uv_right, .v = uv_top, .r = tint[0], .g = tint[1], .b = tint[2], .a = tint[3], .clip_min_x = cr[0], .clip_min_y = cr[1], .clip_max_x = cr[2], .clip_max_y = cr[3] };
        verts[base + 2] = .{ .px = x0, .py = y1, .u = uv_left, .v = uv_bottom, .r = tint[0], .g = tint[1], .b = tint[2], .a = tint[3], .clip_min_x = cr[0], .clip_min_y = cr[1], .clip_max_x = cr[2], .clip_max_y = cr[3] };
        verts[base + 3] = .{ .px = x1, .py = y0, .u = uv_right, .v = uv_top, .r = tint[0], .g = tint[1], .b = tint[2], .a = tint[3], .clip_min_x = cr[0], .clip_min_y = cr[1], .clip_max_x = cr[2], .clip_max_y = cr[3] };
        verts[base + 4] = .{ .px = x1, .py = y1, .u = uv_right, .v = uv_bottom, .r = tint[0], .g = tint[1], .b = tint[2], .a = tint[3], .clip_min_x = cr[0], .clip_min_y = cr[1], .clip_max_x = cr[2], .clip_max_y = cr[3] };
        verts[base + 5] = .{ .px = x0, .py = y1, .u = uv_left, .v = uv_bottom, .r = tint[0], .g = tint[1], .b = tint[2], .a = tint[3], .clip_min_x = cr[0], .clip_min_y = cr[1], .clip_max_x = cr[2], .clip_max_y = cr[3] };

        self.inverted_vertex_count += 6;
    }

    /// Draw a sprite with inverted blending.
    pub fn drawSpriteInverted(self: *UiRenderer, sprite: SpriteRect, x: f32, y: f32, w: f32, h: f32, tint: [4]f32) void {
        self.drawTexturedRectInverted(x, y, w, h, sprite.u0, sprite.v0, sprite.u1, sprite.v1, tint);
    }

    /// Load HUD sprite textures into a vertical atlas, replacing the 1x1 fallback.
    pub fn loadHudAtlas(self: *UiRenderer, allocator: std.mem.Allocator, ctx: *const VulkanContext) !void {
        const base_path = try app_config.getAppDataPath(allocator);
        defer allocator.free(base_path);

        const sep = std.fs.path.sep_str;
        const hud_dir = sep ++ "assets" ++ sep ++ "farhorizons" ++ sep ++ "textures" ++ sep ++ "gui" ++ sep ++ "sprites" ++ sep ++ "hud" ++ sep;

        const sprite_names = [_][]const u8{ "crosshair.png", "hotbar.png", "hotbar_selection.png", "hotbar_offhand_left.png" };
        const sprite_count = sprite_names.len;

        var widths: [sprite_count]c_int = undefined;
        var heights: [sprite_count]c_int = undefined;
        var pixels: [sprite_count][*]u8 = undefined;
        var loaded_count: usize = 0;

        defer for (0..loaded_count) |i| {
            c.stbi_image_free(pixels[i]);
        };

        var atlas_width: c_int = 0;
        var atlas_height: c_int = 0;

        for (sprite_names, 0..) |name, i| {
            const path = try std.fmt.allocPrintSentinel(allocator, "{s}{s}{s}", .{ base_path, hud_dir, name }, 0);
            defer allocator.free(path);

            var tw: c_int = 0;
            var th: c_int = 0;
            var tc: c_int = 0;
            pixels[i] = c.stbi_load(path.ptr, &tw, &th, &tc, 4) orelse {
                std.log.err("Failed to load HUD sprite: {s}", .{name});
                return error.TextureLoadFailed;
            };
            loaded_count += 1;
            widths[i] = tw;
            heights[i] = th;
            if (tw > atlas_width) atlas_width = tw;
            atlas_height += th;
        }

        const aw: u32 = @intCast(atlas_width);
        const ah: u32 = @intCast(atlas_height);
        const atlas_bytes: usize = @intCast(@as(u64, aw) * @as(u64, ah) * 4);

        // Create staging buffer
        var staging_buffer: vk.VkBuffer = undefined;
        var staging_memory: vk.VkDeviceMemory = undefined;
        try vk_utils.createBuffer(
            ctx,
            atlas_bytes,
            vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &staging_buffer,
            &staging_memory,
        );

        {
            var data: ?*anyopaque = null;
            try vk.mapMemory(ctx.device, staging_memory, 0, atlas_bytes, 0, &data);
            const dst: [*]u8 = @ptrCast(data.?);
            // Clear to transparent black
            @memset(dst[0..atlas_bytes], 0);

            // Copy each sprite into the atlas at the correct vertical offset
            var y_offset: u32 = 0;
            for (0..sprite_count) |i| {
                const sw: u32 = @intCast(widths[i]);
                const sh: u32 = @intCast(heights[i]);
                const src: [*]const u8 = pixels[i];
                for (0..sh) |row| {
                    const dst_offset = (y_offset + @as(u32, @intCast(row))) * aw * 4;
                    const src_offset = @as(u32, @intCast(row)) * sw * 4;
                    @memcpy(dst[dst_offset..][0 .. sw * 4], src[src_offset..][0 .. sw * 4]);
                }
                y_offset += sh;
            }
            vk.unmapMemory(ctx.device, staging_memory);
        }

        // Destroy old fallback atlas
        vk.destroyImageView(ctx.device, self.atlas_image_view, null);
        vk.destroyImage(ctx.device, self.atlas_image, null);
        vk.freeMemory(ctx.device, self.atlas_image_memory, null);

        // Create new atlas image
        const image_info = vk.VkImageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = vk.VK_IMAGE_TYPE_2D,
            .format = vk.VK_FORMAT_R8G8B8A8_UNORM,
            .extent = .{ .width = aw, .height = ah, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
            .usage = vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT | vk.VK_IMAGE_USAGE_SAMPLED_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        };

        self.atlas_image = try vk.createImage(ctx.device, &image_info, null);

        var mem_requirements: vk.VkMemoryRequirements = undefined;
        vk.getImageMemoryRequirements(ctx.device, self.atlas_image, &mem_requirements);

        const memory_type_index = try vk_utils.findMemoryType(
            ctx.physical_device,
            mem_requirements.memoryTypeBits,
            vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        );

        self.atlas_image_memory = try vk.allocateMemory(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = mem_requirements.size,
            .memoryTypeIndex = memory_type_index,
        }, null);
        try vk.bindImageMemory(ctx.device, self.atlas_image, self.atlas_image_memory, 0);

        // Upload via command buffer
        const cmd_alloc_info = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = ctx.command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };

        var cmd_buffers: [1]vk.VkCommandBuffer = undefined;
        try vk.allocateCommandBuffers(ctx.device, &cmd_alloc_info, &cmd_buffers);
        const cmd = cmd_buffers[0];

        try vk.beginCommandBuffer(cmd, &.{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        });

        // Transition to transfer dst
        const to_transfer = vk.VkImageMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = 0,
            .dstAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = self.atlas_image,
            .subresourceRange = .{ .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 },
        };
        vk.cmdPipelineBarrier(cmd, vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, vk.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &[_]vk.VkImageMemoryBarrier{to_transfer});

        const region = vk.VkBufferImageCopy{
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = .{ .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{ .width = aw, .height = ah, .depth = 1 },
        };
        vk.cmdCopyBufferToImage(cmd, staging_buffer, self.atlas_image, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &[_]vk.VkBufferImageCopy{region});

        // Transition to shader read
        const to_shader = vk.VkImageMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = self.atlas_image,
            .subresourceRange = .{ .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 },
        };
        vk.cmdPipelineBarrier(cmd, vk.VK_PIPELINE_STAGE_TRANSFER_BIT, vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &[_]vk.VkImageMemoryBarrier{to_shader});

        try vk.endCommandBuffer(cmd);

        const submit_infos = [_]vk.VkSubmitInfo{.{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = null,
            .pWaitDstStageMask = null,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd,
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = null,
        }};
        try vk.queueSubmit(ctx.graphics_queue, 1, &submit_infos, null);
        try vk.queueWaitIdle(ctx.graphics_queue);
        vk.freeCommandBuffers(ctx.device, ctx.command_pool, 1, &cmd_buffers);

        vk.destroyBuffer(ctx.device, staging_buffer, null);
        vk.freeMemory(ctx.device, staging_memory, null);

        // Create new image view
        self.atlas_image_view = try vk.createImageView(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = self.atlas_image,
            .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
            .format = vk.VK_FORMAT_R8G8B8A8_UNORM,
            .components = .{
                .r = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = .{ .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 },
        }, null);

        // Update descriptor set with new image view (reuse existing sampler)
        const desc_image_info = vk.VkDescriptorImageInfo{
            .sampler = self.atlas_sampler,
            .imageView = self.atlas_image_view,
            .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        const write = vk.VkWriteDescriptorSet{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = self.descriptor_set,
            .dstBinding = 1,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &desc_image_info,
            .pBufferInfo = null,
            .pTexelBufferView = null,
        };
        vk.updateDescriptorSets(ctx.device, 1, &[_]vk.VkWriteDescriptorSet{write}, 0, null);

        // Compute UV rects for each sprite
        const faw: f32 = @floatFromInt(atlas_width);
        const fah: f32 = @floatFromInt(atlas_height);
        var y_off: f32 = 0;

        // crosshair
        self.crosshair_size = .{ @floatFromInt(widths[0]), @floatFromInt(heights[0]) };
        self.crosshair_rect = .{ .u0 = 0, .v0 = y_off / fah, .u1 = @as(f32, @floatFromInt(widths[0])) / faw, .v1 = (y_off + @as(f32, @floatFromInt(heights[0]))) / fah };
        y_off += @floatFromInt(heights[0]);

        // hotbar
        self.hotbar_size = .{ @floatFromInt(widths[1]), @floatFromInt(heights[1]) };
        self.hotbar_rect = .{ .u0 = 0, .v0 = y_off / fah, .u1 = @as(f32, @floatFromInt(widths[1])) / faw, .v1 = (y_off + @as(f32, @floatFromInt(heights[1]))) / fah };
        y_off += @floatFromInt(heights[1]);

        // selection
        self.selection_size = .{ @floatFromInt(widths[2]), @floatFromInt(heights[2]) };
        self.selection_rect = .{ .u0 = 0, .v0 = y_off / fah, .u1 = @as(f32, @floatFromInt(widths[2])) / faw, .v1 = (y_off + @as(f32, @floatFromInt(heights[2]))) / fah };
        y_off += @floatFromInt(heights[2]);

        // offhand
        self.offhand_size = .{ @floatFromInt(widths[3]), @floatFromInt(heights[3]) };
        self.offhand_rect = .{ .u0 = 0, .v0 = y_off / fah, .u1 = @as(f32, @floatFromInt(widths[3])) / faw, .v1 = (y_off + @as(f32, @floatFromInt(heights[3]))) / fah };

        self.hud_atlas_loaded = true;
        std.log.info("HUD atlas loaded: {}x{} ({} sprites)", .{ aw, ah, sprite_count });
    }

    // ── Vulkan setup ──

    fn createVertexBuffer(self: *UiRenderer, ctx: *const VulkanContext) !void {
        const buffer_size: vk.VkDeviceSize = MAX_VERTICES * @sizeOf(UiVertex);
        try vk_utils.createBuffer(
            ctx,
            buffer_size,
            vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &self.vertex_buffer,
            &self.vertex_buffer_memory,
        );
    }

    /// Create a 1x1 white pixel as fallback atlas (avoids null descriptor).
    fn createFallbackAtlas(self: *UiRenderer, ctx: *const VulkanContext) !void {
        // Create 1x1 RGBA image
        const image_info = vk.VkImageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = vk.VK_IMAGE_TYPE_2D,
            .format = vk.VK_FORMAT_R8G8B8A8_UNORM,
            .extent = .{ .width = 1, .height = 1, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
            .usage = vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT | vk.VK_IMAGE_USAGE_SAMPLED_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        };

        self.atlas_image = try vk.createImage(ctx.device, &image_info, null);

        var mem_requirements: vk.VkMemoryRequirements = undefined;
        vk.getImageMemoryRequirements(ctx.device, self.atlas_image, &mem_requirements);

        const memory_type_index = try vk_utils.findMemoryType(
            ctx.physical_device,
            mem_requirements.memoryTypeBits,
            vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        );

        const alloc_info = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = mem_requirements.size,
            .memoryTypeIndex = memory_type_index,
        };

        self.atlas_image_memory = try vk.allocateMemory(ctx.device, &alloc_info, null);
        try vk.bindImageMemory(ctx.device, self.atlas_image, self.atlas_image_memory, 0);

        // Upload 1x1 white pixel via staging buffer
        var staging_buffer: vk.VkBuffer = undefined;
        var staging_memory: vk.VkDeviceMemory = undefined;
        try vk_utils.createBuffer(
            ctx,
            4,
            vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &staging_buffer,
            &staging_memory,
        );

        {
            var data: ?*anyopaque = null;
            try vk.mapMemory(ctx.device, staging_memory, 0, 4, 0, &data);
            const dst: [*]u8 = @ptrCast(data.?);
            dst[0] = 0xFF;
            dst[1] = 0xFF;
            dst[2] = 0xFF;
            dst[3] = 0xFF;
            vk.unmapMemory(ctx.device, staging_memory);
        }

        // Upload via command buffer
        const cmd_alloc_info2 = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = ctx.command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };

        var cmd_buffers: [1]vk.VkCommandBuffer = undefined;
        try vk.allocateCommandBuffers(ctx.device, &cmd_alloc_info2, &cmd_buffers);
        const cmd = cmd_buffers[0];

        try vk.beginCommandBuffer(cmd, &.{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        });

        const to_transfer = vk.VkImageMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = 0,
            .dstAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = self.atlas_image,
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        vk.cmdPipelineBarrier(cmd, vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, vk.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &[_]vk.VkImageMemoryBarrier{to_transfer});

        const region = vk.VkBufferImageCopy{
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{ .width = 1, .height = 1, .depth = 1 },
        };
        vk.cmdCopyBufferToImage(cmd, staging_buffer, self.atlas_image, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &[_]vk.VkBufferImageCopy{region});

        const to_shader = vk.VkImageMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = self.atlas_image,
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        vk.cmdPipelineBarrier(cmd, vk.VK_PIPELINE_STAGE_TRANSFER_BIT, vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &[_]vk.VkImageMemoryBarrier{to_shader});

        try vk.endCommandBuffer(cmd);

        const submit_infos = [_]vk.VkSubmitInfo{.{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = null,
            .pWaitDstStageMask = null,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd,
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = null,
        }};
        try vk.queueSubmit(ctx.graphics_queue, 1, &submit_infos, null);
        try vk.queueWaitIdle(ctx.graphics_queue);
        vk.freeCommandBuffers(ctx.device, ctx.command_pool, 1, &cmd_buffers);

        vk.destroyBuffer(ctx.device, staging_buffer, null);
        vk.freeMemory(ctx.device, staging_memory, null);

        // Image view
        self.atlas_image_view = try vk.createImageView(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = self.atlas_image,
            .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
            .format = vk.VK_FORMAT_R8G8B8A8_UNORM,
            .components = .{
                .r = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        }, null);

        // Sampler (nearest-neighbor)
        self.atlas_sampler = try vk.createSampler(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .magFilter = vk.VK_FILTER_NEAREST,
            .minFilter = vk.VK_FILTER_NEAREST,
            .mipmapMode = vk.VK_SAMPLER_MIPMAP_MODE_NEAREST,
            .addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .mipLodBias = 0.0,
            .anisotropyEnable = vk.VK_FALSE,
            .maxAnisotropy = 1.0,
            .compareEnable = vk.VK_FALSE,
            .compareOp = 0,
            .minLod = 0.0,
            .maxLod = 0.0,
            .borderColor = vk.VK_BORDER_COLOR_INT_OPAQUE_BLACK,
            .unnormalizedCoordinates = vk.VK_FALSE,
        }, null);

        std.log.info("UI atlas fallback created (1x1 white)", .{});
    }

    fn createDescriptors(self: *UiRenderer, ctx: *const VulkanContext) !void {
        // Binding 0: vertex SSBO, Binding 1: atlas sampler
        const bindings = [_]vk.VkDescriptorSetLayoutBinding{
            .{
                .binding = 0,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
                .pImmutableSamplers = null,
            },
            .{
                .binding = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
                .pImmutableSamplers = null,
            },
        };

        const layout_info = vk.VkDescriptorSetLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .bindingCount = bindings.len,
            .pBindings = &bindings,
        };

        self.descriptor_set_layout = try vk.createDescriptorSetLayout(ctx.device, &layout_info, null);

        const pool_sizes = [_]vk.VkDescriptorPoolSize{
            .{ .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1 },
            .{ .type = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1 },
        };

        const pool_info = vk.VkDescriptorPoolCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .maxSets = 1,
            .poolSizeCount = pool_sizes.len,
            .pPoolSizes = &pool_sizes,
        };

        self.descriptor_pool = try vk.createDescriptorPool(ctx.device, &pool_info, null);

        const ds_alloc_info = vk.VkDescriptorSetAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = self.descriptor_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &self.descriptor_set_layout,
        };

        var sets: [1]vk.VkDescriptorSet = undefined;
        try vk.allocateDescriptorSets(ctx.device, &ds_alloc_info, &sets);
        self.descriptor_set = sets[0];

        // Write binding 0: vertex SSBO
        const buffer_info = vk.VkDescriptorBufferInfo{
            .buffer = self.vertex_buffer,
            .offset = 0,
            .range = MAX_VERTICES * @sizeOf(UiVertex),
        };

        // Write binding 1: atlas sampler
        const image_info = vk.VkDescriptorImageInfo{
            .sampler = self.atlas_sampler,
            .imageView = self.atlas_image_view,
            .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };

        const writes = [_]vk.VkWriteDescriptorSet{
            .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = self.descriptor_set,
                .dstBinding = 0,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .pImageInfo = null,
                .pBufferInfo = &buffer_info,
                .pTexelBufferView = null,
            },
            .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = self.descriptor_set,
                .dstBinding = 1,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .pImageInfo = &image_info,
                .pBufferInfo = null,
                .pTexelBufferView = null,
            },
        };

        vk.updateDescriptorSets(ctx.device, writes.len, &writes, 0, null);
    }

    fn createPipeline(self: *UiRenderer, shader_compiler: *ShaderCompiler, ctx: *const VulkanContext, swapchain_format: vk.VkFormat) !void {
        const tz = tracy.zone(@src(), "UiRenderer.createPipeline");
        defer tz.end();

        const vert_spirv = try shader_compiler.compile("ui.vert", .vertex);
        defer shader_compiler.allocator.free(vert_spirv);

        const frag_spirv = try shader_compiler.compile("ui.frag", .fragment);
        defer shader_compiler.allocator.free(frag_spirv);

        const vert_module = try vk.createShaderModule(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = vert_spirv.len,
            .pCode = @ptrCast(@alignCast(vert_spirv.ptr)),
        }, null);
        defer vk.destroyShaderModule(ctx.device, vert_module, null);

        const frag_module = try vk.createShaderModule(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = frag_spirv.len,
            .pCode = @ptrCast(@alignCast(frag_spirv.ptr)),
        }, null);
        defer vk.destroyShaderModule(ctx.device, frag_module, null);

        const shader_stages = [_]vk.VkPipelineShaderStageCreateInfo{
            .{
                .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stage = vk.VK_SHADER_STAGE_VERTEX_BIT,
                .module = vert_module,
                .pName = "main",
                .pSpecializationInfo = null,
            },
            .{
                .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
                .module = frag_module,
                .pName = "main",
                .pSpecializationInfo = null,
            },
        };

        const vertex_input_info = vk.VkPipelineVertexInputStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .vertexBindingDescriptionCount = 0,
            .pVertexBindingDescriptions = null,
            .vertexAttributeDescriptionCount = 0,
            .pVertexAttributeDescriptions = null,
        };

        const input_assembly = vk.VkPipelineInputAssemblyStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .primitiveRestartEnable = vk.VK_FALSE,
        };

        const viewport_state = vk.VkPipelineViewportStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .viewportCount = 1,
            .pViewports = null,
            .scissorCount = 1,
            .pScissors = null,
        };

        const rasterizer = vk.VkPipelineRasterizationStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthClampEnable = vk.VK_FALSE,
            .rasterizerDiscardEnable = vk.VK_FALSE,
            .polygonMode = vk.VK_POLYGON_MODE_FILL,
            .cullMode = vk.VK_CULL_MODE_NONE,
            .frontFace = vk.VK_FRONT_FACE_COUNTER_CLOCKWISE,
            .depthBiasEnable = vk.VK_FALSE,
            .depthBiasConstantFactor = 0.0,
            .depthBiasClamp = 0.0,
            .depthBiasSlopeFactor = 0.0,
            .lineWidth = 1.0,
        };

        const multisampling = vk.VkPipelineMultisampleStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .rasterizationSamples = vk.VK_SAMPLE_COUNT_1_BIT,
            .sampleShadingEnable = vk.VK_FALSE,
            .minSampleShading = 1.0,
            .pSampleMask = null,
            .alphaToCoverageEnable = vk.VK_FALSE,
            .alphaToOneEnable = vk.VK_FALSE,
        };

        // Depth test DISABLED — UI always on top of world
        const depth_stencil = vk.VkPipelineDepthStencilStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthTestEnable = vk.VK_FALSE,
            .depthWriteEnable = vk.VK_FALSE,
            .depthCompareOp = vk.VK_COMPARE_OP_LESS_OR_EQUAL,
            .depthBoundsTestEnable = vk.VK_FALSE,
            .stencilTestEnable = vk.VK_FALSE,
            .front = std.mem.zeroes(vk.VkStencilOpState),
            .back = std.mem.zeroes(vk.VkStencilOpState),
            .minDepthBounds = 0.0,
            .maxDepthBounds = 1.0,
        };

        const color_blend_attachment = vk.VkPipelineColorBlendAttachmentState{
            .blendEnable = vk.VK_TRUE,
            .srcColorBlendFactor = vk.VK_BLEND_FACTOR_SRC_ALPHA,
            .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .colorBlendOp = vk.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .alphaBlendOp = vk.VK_BLEND_OP_ADD,
            .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT | vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT,
        };

        const color_blending = vk.VkPipelineColorBlendStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .logicOpEnable = vk.VK_FALSE,
            .logicOp = 0,
            .attachmentCount = 1,
            .pAttachments = &color_blend_attachment,
            .blendConstants = .{ 0.0, 0.0, 0.0, 0.0 },
        };

        const push_constant_range = vk.VkPushConstantRange{
            .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
            .offset = 0,
            .size = 64, // mat4
        };

        const pipeline_layout_info = vk.VkPipelineLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 1,
            .pSetLayouts = &self.descriptor_set_layout,
            .pushConstantRangeCount = 1,
            .pPushConstantRanges = &push_constant_range,
        };

        self.pipeline_layout = try vk.createPipelineLayout(ctx.device, &pipeline_layout_info, null);

        const color_attachment_format = [_]vk.VkFormat{swapchain_format};
        const rendering_create_info = vk.VkPipelineRenderingCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
            .pNext = null,
            .viewMask = 0,
            .colorAttachmentCount = 1,
            .pColorAttachmentFormats = &color_attachment_format,
            .depthAttachmentFormat = vk.VK_FORMAT_D32_SFLOAT,
            .stencilAttachmentFormat = vk.VK_FORMAT_UNDEFINED,
        };

        const dynamic_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
        const dynamic_state_info = c.VkPipelineDynamicStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .dynamicStateCount = dynamic_states.len,
            .pDynamicStates = &dynamic_states,
        };

        // Inverted blend: ONE_MINUS_DST_COLOR for Minecraft-style crosshair
        const inverted_blend_attachment = vk.VkPipelineColorBlendAttachmentState{
            .blendEnable = vk.VK_TRUE,
            .srcColorBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR,
            .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR,
            .colorBlendOp = vk.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ZERO,
            .alphaBlendOp = vk.VK_BLEND_OP_ADD,
            .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT | vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT,
        };

        const inverted_color_blending = vk.VkPipelineColorBlendStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .logicOpEnable = vk.VK_FALSE,
            .logicOp = 0,
            .attachmentCount = 1,
            .pAttachments = &inverted_blend_attachment,
            .blendConstants = .{ 0.0, 0.0, 0.0, 0.0 },
        };

        const pipeline_infos = [2]vk.VkGraphicsPipelineCreateInfo{
            // [0] Normal alpha-blend pipeline
            .{
                .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
                .pNext = &rendering_create_info,
                .flags = 0,
                .stageCount = 2,
                .pStages = &shader_stages,
                .pVertexInputState = &vertex_input_info,
                .pInputAssemblyState = &input_assembly,
                .pTessellationState = null,
                .pViewportState = &viewport_state,
                .pRasterizationState = &rasterizer,
                .pMultisampleState = &multisampling,
                .pDepthStencilState = &depth_stencil,
                .pColorBlendState = &color_blending,
                .pDynamicState = &dynamic_state_info,
                .layout = self.pipeline_layout,
                .renderPass = null,
                .subpass = 0,
                .basePipelineHandle = null,
                .basePipelineIndex = -1,
            },
            // [1] Inverted-blend pipeline
            .{
                .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
                .pNext = &rendering_create_info,
                .flags = 0,
                .stageCount = 2,
                .pStages = &shader_stages,
                .pVertexInputState = &vertex_input_info,
                .pInputAssemblyState = &input_assembly,
                .pTessellationState = null,
                .pViewportState = &viewport_state,
                .pRasterizationState = &rasterizer,
                .pMultisampleState = &multisampling,
                .pDepthStencilState = &depth_stencil,
                .pColorBlendState = &inverted_color_blending,
                .pDynamicState = &dynamic_state_info,
                .layout = self.pipeline_layout,
                .renderPass = null,
                .subpass = 0,
                .basePipelineHandle = null,
                .basePipelineIndex = -1,
            },
        };

        var pipelines: [2]vk.VkPipeline = undefined;
        try vk.createGraphicsPipelines(ctx.device, ctx.pipeline_cache, 2, &pipeline_infos, null, &pipelines);
        self.pipeline = pipelines[0];
        self.inverted_pipeline = pipelines[1];

        std.log.info("UI rendering pipelines created (normal + inverted)", .{});
    }

    fn orthoMatrix(w: f32, h: f32) [16]f32 {
        // Maps (0,0) top-left -> (-1,-1), (w,h) bottom-right -> (1,1)
        return .{
            2.0 / w, 0.0,     0.0, 0.0,
            0.0,     2.0 / h, 0.0, 0.0,
            0.0,     0.0,     1.0, 0.0,
            -1.0,    -1.0,    0.0, 1.0,
        };
    }
};
