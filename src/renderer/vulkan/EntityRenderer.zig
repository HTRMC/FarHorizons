const std = @import("std");
const vk = @import("../../platform/volk.zig");
const stbi = @import("../../platform/stb_image.zig");
const ShaderCompiler = @import("ShaderCompiler.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const vk_utils = @import("vk_utils.zig");
const tracy = @import("../../platform/tracy.zig");
const zlm = @import("zlm");
const gpu_alloc_mod = @import("../../allocators/GpuAllocator.zig");
const GpuAllocator = gpu_alloc_mod.GpuAllocator;
const BufferAllocation = gpu_alloc_mod.BufferAllocation;
const app_config = @import("../../app_config.zig");
const Io = std.Io;
const Dir = Io.Dir;

pub const EntityVertex = extern struct {
    px: f32,
    py: f32,
    pz: f32,
    nx: f32,
    ny: f32,
    nz: f32,
    u: f32,
    v: f32,
};

const MAX_VERTICES = 4096;

const EntityPushConstants = extern struct {
    mvp: [16]f32,
    ambient_light: [3]f32,
    contrast: f32,
    sun_dir: [3]f32,
    sky_level: f32,
    block_light: [3]f32,
    _pad: f32 = 0,
};

pub const EntityRenderer = struct {
    pipeline: vk.VkPipeline, // No depth test (inventory overlay)
    pipeline_depth: vk.VkPipeline, // With depth test (world rendering)
    pipeline_layout: vk.VkPipelineLayout,
    descriptor_set_layout: vk.VkDescriptorSetLayout,
    descriptor_pool: vk.VkDescriptorPool,
    descriptor_set: vk.VkDescriptorSet,
    vertex_alloc: BufferAllocation,
    gpu_alloc: *GpuAllocator,
    skin_image: vk.VkImage = null,
    skin_image_memory: vk.VkDeviceMemory = null,
    skin_image_view: vk.VkImageView = null,
    skin_sampler: vk.VkSampler = null,
    vertex_count: u32 = 0,
    visible: bool = false,
    // Viewport rectangle in pixel coords (set by UI layout)
    viewport_x: f32 = 0,
    viewport_y: f32 = 0,
    viewport_w: f32 = 0,
    viewport_h: f32 = 0,
    rotation_y: f32 = 0.4, // Model Y rotation (radians)
    // Third person world rendering
    world_visible: bool = false,
    world_pos: [3]f32 = .{ 0, 0, 0 },
    world_yaw: f32 = 0,

    pub fn init(allocator: std.mem.Allocator, shader_compiler: *ShaderCompiler, ctx: *const VulkanContext, swapchain_format: vk.VkFormat, gpu_alloc: *GpuAllocator) !EntityRenderer {
        const tz = tracy.zone(@src(), "EntityRenderer.init");
        defer tz.end();

        var self = EntityRenderer{
            .pipeline = null,
            .pipeline_depth = null,
            .pipeline_layout = null,
            .descriptor_set_layout = null,
            .descriptor_pool = null,
            .descriptor_set = null,
            .vertex_alloc = undefined,
            .gpu_alloc = gpu_alloc,
        };

        try self.createResources(allocator, ctx, gpu_alloc);
        try self.createPipeline(shader_compiler, ctx, swapchain_format);
        self.loadPlayerModel(allocator);

        return self;
    }

    pub fn deinit(self: *EntityRenderer, device: vk.VkDevice) void {
        vk.destroyPipeline(device, self.pipeline_depth, null);
        vk.destroyPipeline(device, self.pipeline, null);
        vk.destroyPipelineLayout(device, self.pipeline_layout, null);
        vk.destroyDescriptorPool(device, self.descriptor_pool, null);
        vk.destroyDescriptorSetLayout(device, self.descriptor_set_layout, null);
        self.gpu_alloc.destroyBuffer(self.vertex_alloc);
        if (self.skin_sampler != null) vk.destroySampler(device, self.skin_sampler, null);
        if (self.skin_image_view != null) vk.destroyImageView(device, self.skin_image_view, null);
        if (self.skin_image != null) vk.destroyImage(device, self.skin_image, null);
        if (self.skin_image_memory != null) vk.freeMemory(device, self.skin_image_memory, null);
    }

    pub fn recordDraw(self: *const EntityRenderer, command_buffer: vk.VkCommandBuffer, screen_width: f32, screen_height: f32, ui_scale: f32) void {
        if (!self.visible or self.vertex_count == 0) return;
        if (self.viewport_w <= 0 or self.viewport_h <= 0) return;

        const vp_x = self.viewport_x * ui_scale;
        const vp_y = self.viewport_y * ui_scale;
        const vp_w = self.viewport_w * ui_scale;
        const vp_h = self.viewport_h * ui_scale;

        const viewport = vk.VkViewport{
            .x = vp_x,
            .y = vp_y,
            .width = vp_w,
            .height = vp_h,
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };
        vk.cmdSetViewport(command_buffer, 0, 1, &[_]vk.VkViewport{viewport});

        const scissor = vk.VkRect2D{
            .offset = .{
                .x = @intFromFloat(@max(vp_x, 0)),
                .y = @intFromFloat(@max(vp_y, 0)),
            },
            .extent = .{
                .width = @intFromFloat(@max(vp_w, 1)),
                .height = @intFromFloat(@max(vp_h, 1)),
            },
        };
        vk.cmdSetScissor(command_buffer, 0, 1, &[_]vk.VkRect2D{scissor});

        // Clear depth buffer in this viewport region so world geometry doesn't interfere
        const clear_attachment = vk.VkClearAttachment{
            .aspectMask = vk.VK_IMAGE_ASPECT_DEPTH_BIT,
            .colorAttachment = 0,
            .clearValue = .{ .depthStencil = .{ .depth = 1.0, .stencil = 0 } },
        };
        const clear_rect = vk.VkClearRect{
            .rect = scissor,
            .baseArrayLayer = 0,
            .layerCount = 1,
        };
        vk.cmdClearAttachments(command_buffer, 1, &[_]vk.VkClearAttachment{clear_attachment}, 1, &[_]vk.VkClearRect{clear_rect});

        const aspect = vp_w / @max(vp_h, 1.0);
        const proj = zlm.Mat4.perspective(std.math.degreesToRadians(30.0), aspect, 0.1, 100.0);
        const eye = zlm.Vec3.init(
            @sin(self.rotation_y) * 4.5,
            1.2,
            @cos(self.rotation_y) * 4.5,
        );
        const view = zlm.Mat4.lookAt(eye, zlm.Vec3.init(0.0, 0.85, 0.0), zlm.Vec3.init(0.0, 1.0, 0.0));
        const mvp = zlm.Mat4.mul(proj, view);

        vk.cmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline_depth);
        vk.cmdBindDescriptorSets(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline_layout, 0, 1, &[_]vk.VkDescriptorSet{self.descriptor_set}, 0, null);
        const pc = EntityPushConstants{
            .mvp = mvp.m,
            .ambient_light = .{ 1.0, 1.0, 1.0 },
            .contrast = 0.25,
            .sun_dir = .{ 0.4, 0.8, 0.5 },
            .sky_level = 1.0,
            .block_light = .{ 0, 0, 0 },
        };
        vk.cmdPushConstants(command_buffer, self.pipeline_layout, vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(EntityPushConstants), @ptrCast(&pc));
        vk.cmdDraw(command_buffer, self.vertex_count, 1, 0, 0);

        // Restore full-screen viewport/scissor
        const full_viewport = vk.VkViewport{ .x = 0, .y = 0, .width = screen_width, .height = screen_height, .minDepth = 0, .maxDepth = 1 };
        vk.cmdSetViewport(command_buffer, 0, 1, &[_]vk.VkViewport{full_viewport});
        const full_scissor = vk.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = @intFromFloat(screen_width), .height = @intFromFloat(screen_height) } };
        vk.cmdSetScissor(command_buffer, 0, 1, &[_]vk.VkRect2D{full_scissor});
    }

    pub fn recordDrawWorld(self: *const EntityRenderer, command_buffer: vk.VkCommandBuffer, view_proj: zlm.Mat4, ambient_light: [3]f32, sun_dir: [3]f32, sky_level: f32, block_light: [3]f32) void {
        if (!self.world_visible or self.vertex_count == 0) return;

        const sin_y = @sin(self.world_yaw + std.math.pi);
        const cos_y = @cos(self.world_yaw + std.math.pi);
        const model = zlm.Mat4{
            .m = .{ cos_y, 0, -sin_y, 0, 0, 1, 0, 0, sin_y, 0, cos_y, 0, self.world_pos[0], self.world_pos[1], self.world_pos[2], 1 },
        };
        const mvp = zlm.Mat4.mul(view_proj, model);

        vk.cmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline_depth);
        vk.cmdBindDescriptorSets(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline_layout, 0, 1, &[_]vk.VkDescriptorSet{self.descriptor_set}, 0, null);
        const pc = EntityPushConstants{
            .mvp = mvp.m,
            .ambient_light = ambient_light,
            .contrast = 0.25,
            .sun_dir = sun_dir,
            .sky_level = sky_level,
            .block_light = block_light,
        };
        vk.cmdPushConstants(command_buffer, self.pipeline_layout, vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(EntityPushConstants), @ptrCast(&pc));
        vk.cmdDraw(command_buffer, self.vertex_count, 1, 0, 0);
    }

    // ============================================================
    // Player model loading
    // ============================================================

    const TARGET_HEIGHT = 1.8;

    fn loadPlayerModel(self: *EntityRenderer, allocator: std.mem.Allocator) void {
        const sep = std.fs.path.sep_str;
        const assets_path = app_config.getAssetsPath(allocator) catch return;
        defer allocator.free(assets_path);

        const model_path = std.fmt.allocPrintSentinel(allocator, "{s}" ++ sep ++ "models" ++ sep ++ "player.json", .{assets_path}, 0) catch return;
        defer allocator.free(model_path);

        const io = Io.Threaded.global_single_threaded.io();
        const data = Dir.readFileAlloc(.cwd(), io, model_path, allocator, .unlimited) catch {
            std.log.err("Failed to read player model", .{});
            return;
        };
        defer allocator.free(data);

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return;
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => return,
        };

        // Get texture size
        const tex_size = switch (root.get("texture_size") orelse return) {
            .array => |arr| arr.items,
            else => return,
        };
        const tex_w: f32 = @floatCast(jf(tex_size[0]));
        const tex_h: f32 = @floatCast(jf(tex_size[1]));

        const parts = switch (root.get("parts") orelse return) {
            .array => |arr| arr.items,
            else => return,
        };

        // Find model Y bounds
        var min_y: f64 = std.math.inf(f64);
        var max_y: f64 = -std.math.inf(f64);
        for (parts) |pv| {
            const p = switch (pv) { .object => |obj| obj, else => continue };
            const min_arr = switch (p.get("min") orelse continue) { .array => |a| a.items, else => continue };
            const size_arr = switch (p.get("size") orelse continue) { .array => |a| a.items, else => continue };
            if (min_arr.len < 3 or size_arr.len < 3) continue;
            min_y = @min(min_y, jf(min_arr[1]));
            max_y = @max(max_y, jf(min_arr[1]) + jf(size_arr[1]));
        }
        const model_height = max_y - min_y;
        if (model_height <= 0) return;
        const scale: f64 = TARGET_HEIGHT / model_height;

        const vertices: [*]EntityVertex = @ptrCast(@alignCast(self.vertex_alloc.mapped_ptr orelse return));
        var count: u32 = 0;

        for (parts) |pv| {
            const p = switch (pv) { .object => |obj| obj, else => continue };
            const min_arr = switch (p.get("min") orelse continue) { .array => |a| a.items, else => continue };
            const size_arr = switch (p.get("size") orelse continue) { .array => |a| a.items, else => continue };
            const uv_arr = switch (p.get("uv") orelse continue) { .array => |a| a.items, else => continue };
            if (min_arr.len < 3 or size_arr.len < 3 or uv_arr.len < 2) continue;

            const bx: f32 = @floatCast(jf(min_arr[0]) * scale);
            const by: f32 = @floatCast((jf(min_arr[1]) - min_y) * scale);
            const bz: f32 = @floatCast(jf(min_arr[2]) * scale);
            const bw: f32 = @floatCast(jf(size_arr[0]) * scale);
            const bh: f32 = @floatCast(jf(size_arr[1]) * scale);
            const bd: f32 = @floatCast(jf(size_arr[2]) * scale);

            // Box pixel dimensions (unscaled, for UV computation)
            const pw: f32 = @floatCast(jf(size_arr[0]));
            const ph: f32 = @floatCast(jf(size_arr[1]));
            const pd: f32 = @floatCast(jf(size_arr[2]));

            // UV origin in pixel coords
            const tu: f32 = @floatCast(jf(uv_arr[0]));
            const tv: f32 = @floatCast(jf(uv_arr[1]));

            count = addTexturedBox(vertices, count, bx, by, bz, bw, bh, bd, tu, tv, pw, ph, pd, tex_w, tex_h);
        }

        self.vertex_count = count;
        std.log.info("Player model loaded: {} parts, {} vertices", .{ parts.len, count });
    }

    /// Add a box with Minecraft-style UV layout.
    /// tu,tv = texture origin; pw,ph,pd = box pixel dimensions; tw,th = texture size.
    fn addTexturedBox(
        vertices: [*]EntityVertex,
        start: u32,
        x: f32,
        y: f32,
        z: f32,
        w: f32,
        h: f32,
        d: f32,
        tu: f32,
        tv: f32,
        pw: f32,
        ph: f32,
        pd: f32,
        tw: f32,
        th: f32,
    ) u32 {
        var count = start;
        const x0 = x;
        const y0 = y;
        const z0 = z;
        const x1 = x + w;
        const y1 = y + h;
        const z1 = z + d;

        // Minecraft UV layout for a box at (tu,tv) with pixel size (pw,ph,pd):
        //          +------+------+
        //          | Top  | Bot  |
        //    +-----+------+-----+------+
        //    |Right|Front | Left| Back |
        //    +-----+------+-----+------+
        // Right: (tu, tv+pd) to (tu+pd, tv+pd+ph)
        // Front: (tu+pd, tv+pd) to (tu+pd+pw, tv+pd+ph)
        // Left:  (tu+pd+pw, tv+pd) to (tu+2pd+pw, tv+pd+ph)
        // Back:  (tu+2pd+pw, tv+pd) to (tu+2pd+2pw, tv+pd+ph)
        // Top:   (tu+pd, tv) to (tu+pd+pw, tv+pd)
        // Bottom:(tu+pd+pw, tv) to (tu+pd+2pw, tv+pd)

        // Front face (z+) = MC front
        count = addQuad(vertices, count, x0, y0, z1, x1, y0, z1, x1, y1, z1, x0, y1, z1, 0, 0, 1, (tu + pd) / tw, (tv + pd + ph) / th, (tu + pd + pw) / tw, (tv + pd) / th);
        // Back face (z-) = MC back
        count = addQuad(vertices, count, x1, y0, z0, x0, y0, z0, x0, y1, z0, x1, y1, z0, 0, 0, -1, (tu + 2 * pd + pw) / tw, (tv + pd + ph) / th, (tu + 2 * pd + 2 * pw) / tw, (tv + pd) / th);
        // Right face (x+) = MC left
        count = addQuad(vertices, count, x1, y0, z1, x1, y0, z0, x1, y1, z0, x1, y1, z1, 1, 0, 0, (tu + pd + pw) / tw, (tv + pd + ph) / th, (tu + 2 * pd + pw) / tw, (tv + pd) / th);
        // Left face (x-) = MC right
        count = addQuad(vertices, count, x0, y0, z0, x0, y0, z1, x0, y1, z1, x0, y1, z0, -1, 0, 0, tu / tw, (tv + pd + ph) / th, (tu + pd) / tw, (tv + pd) / th);
        // Top face (y+)
        count = addQuad(vertices, count, x0, y1, z1, x1, y1, z1, x1, y1, z0, x0, y1, z0, 0, 1, 0, (tu + pd) / tw, tv / th, (tu + pd + pw) / tw, (tv + pd) / th);
        // Bottom face (y-)
        count = addQuad(vertices, count, x0, y0, z0, x1, y0, z0, x1, y0, z1, x0, y0, z1, 0, -1, 0, (tu + pd + pw) / tw, tv / th, (tu + pd + 2 * pw) / tw, (tv + pd) / th);

        return count;
    }

    /// Add a textured quad. u0,v0 = bottom-left UV, u1,v1 = top-right UV.
    fn addQuad(
        vertices: [*]EntityVertex,
        start: u32,
        x0: f32, y0: f32, z0: f32,
        x1: f32, y1: f32, z1: f32,
        x2: f32, y2: f32, z2: f32,
        x3: f32, y3: f32, z3: f32,
        nx: f32, ny: f32, nz: f32,
        uv_u0: f32, uv_v0: f32, uv_u1: f32, uv_v1: f32,
    ) u32 {
        // Quad vertices: v0=bottom-left, v1=bottom-right, v2=top-right, v3=top-left
        // UV: (u0,v0)=bottom-left, (u1,v1)=top-right in texture
        const base = EntityVertex{ .px = 0, .py = 0, .pz = 0, .nx = nx, .ny = ny, .nz = nz, .u = 0, .v = 0 };

        // v0: bottom-left
        var va = base;
        va.px = x0;
        va.py = y0;
        va.pz = z0;
        va.u = uv_u0;
        va.v = uv_v0;

        // v1: bottom-right
        var vb = base;
        vb.px = x1;
        vb.py = y1;
        vb.pz = z1;
        vb.u = uv_u1;
        vb.v = uv_v0;

        // v2: top-right
        var vc = base;
        vc.px = x2;
        vc.py = y2;
        vc.pz = z2;
        vc.u = uv_u1;
        vc.v = uv_v1;

        // v3: top-left
        var vd = base;
        vd.px = x3;
        vd.py = y3;
        vd.pz = z3;
        vd.u = uv_u0;
        vd.v = uv_v1;

        // Triangle 1: 0-1-2
        vertices[start] = va;
        vertices[start + 1] = vb;
        vertices[start + 2] = vc;

        // Triangle 2: 0-2-3
        vertices[start + 3] = va;
        vertices[start + 4] = vc;
        vertices[start + 5] = vd;

        return start + 6;
    }

    fn jf(val: anytype) f64 {
        const v: std.json.Value = val;
        return switch (v) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            else => 0,
        };
    }

    // ============================================================
    // Vulkan resources
    // ============================================================

    fn createResources(self: *EntityRenderer, allocator: std.mem.Allocator, ctx: *const VulkanContext, gpu_alloc: *GpuAllocator) !void {
        const vertex_buffer_size: vk.VkDeviceSize = MAX_VERTICES * @sizeOf(EntityVertex);
        self.vertex_alloc = try gpu_alloc.createBuffer(
            vertex_buffer_size,
            vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            .host_visible,
        );

        // Load skin texture
        try self.loadSkinTexture(allocator, ctx);

        // Descriptor set layout: binding 0 = vertex SSBO, binding 1 = skin texture
        const bindings = [_]vk.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT, .pImmutableSamplers = null },
            .{ .binding = 1, .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT, .pImmutableSamplers = null },
        };

        self.descriptor_set_layout = try vk.createDescriptorSetLayout(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pNext = null, .flags = 0,
            .bindingCount = 2,
            .pBindings = &bindings,
        }, null);

        const pool_sizes = [_]vk.VkDescriptorPoolSize{
            .{ .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1 },
            .{ .type = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1 },
        };

        self.descriptor_pool = try vk.createDescriptorPool(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .pNext = null, .flags = 0,
            .maxSets = 1,
            .poolSizeCount = 2,
            .pPoolSizes = &pool_sizes,
        }, null);

        var sets: [1]vk.VkDescriptorSet = undefined;
        try vk.allocateDescriptorSets(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = self.descriptor_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &self.descriptor_set_layout,
        }, &sets);
        self.descriptor_set = sets[0];

        // Write vertex buffer descriptor
        const buffer_info = vk.VkDescriptorBufferInfo{ .buffer = self.vertex_alloc.buffer, .offset = 0, .range = vertex_buffer_size };
        const image_desc_info = vk.VkDescriptorImageInfo{
            .sampler = self.skin_sampler,
            .imageView = self.skin_image_view,
            .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };

        const writes = [_]vk.VkWriteDescriptorSet{
            .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .pNext = null,
                .dstSet = self.descriptor_set, .dstBinding = 0, .dstArrayElement = 0,
                .descriptorCount = 1, .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .pImageInfo = null, .pBufferInfo = &buffer_info, .pTexelBufferView = null,
            },
            .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .pNext = null,
                .dstSet = self.descriptor_set, .dstBinding = 1, .dstArrayElement = 0,
                .descriptorCount = 1, .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .pImageInfo = &image_desc_info, .pBufferInfo = null, .pTexelBufferView = null,
            },
        };
        vk.updateDescriptorSets(ctx.device, 2, &writes, 0, null);
    }

    fn loadSkinTexture(self: *EntityRenderer, allocator: std.mem.Allocator, ctx: *const VulkanContext) !void {
        const sep = std.fs.path.sep_str;
        const assets_path = try app_config.getAssetsPath(allocator);
        defer allocator.free(assets_path);

        const path = try std.fmt.allocPrintSentinel(allocator, "{s}" ++ sep ++ "textures" ++ sep ++ "entity" ++ sep ++ "player.png", .{assets_path}, 0);
        defer allocator.free(path);

        var tw: c_int = 0;
        var th: c_int = 0;
        var tc: c_int = 0;
        const pixels: [*]u8 = stbi.load(path.ptr, &tw, &th, &tc, 4) orelse return error.TextureLoadFailed;
        defer stbi.free(pixels);

        const aw: u32 = @intCast(tw);
        const ah: u32 = @intCast(th);
        const atlas_bytes: vk.VkDeviceSize = @as(u64, aw) * ah * 4;

        // Create staging buffer
        var staging_buffer: vk.VkBuffer = undefined;
        var staging_memory: vk.VkDeviceMemory = undefined;
        try vk_utils.createBuffer(ctx, atlas_bytes, vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT, vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, &staging_buffer, &staging_memory);
        defer vk.destroyBuffer(ctx.device, staging_buffer, null);
        defer vk.freeMemory(ctx.device, staging_memory, null);

        {
            var data: ?*anyopaque = null;
            try vk.mapMemory(ctx.device, staging_memory, 0, atlas_bytes, 0, &data);
            const dst: [*]u8 = @ptrCast(data.?);
            @memcpy(dst[0..@intCast(atlas_bytes)], pixels[0..@intCast(atlas_bytes)]);
            vk.unmapMemory(ctx.device, staging_memory);
        }

        // Create image
        self.skin_image = try vk.createImage(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .pNext = null, .flags = 0,
            .imageType = vk.VK_IMAGE_TYPE_2D,
            .format = vk.VK_FORMAT_R8G8B8A8_UNORM,
            .extent = .{ .width = aw, .height = ah, .depth = 1 },
            .mipLevels = 1, .arrayLayers = 1,
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
            .usage = vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT | vk.VK_IMAGE_USAGE_SAMPLED_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0, .pQueueFamilyIndices = null,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        }, null);

        var mem_req: vk.VkMemoryRequirements = undefined;
        vk.getImageMemoryRequirements(ctx.device, self.skin_image, &mem_req);
        const mem_type = try vk_utils.findMemoryType(ctx.physical_device, mem_req.memoryTypeBits, vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        self.skin_image_memory = try vk.allocateMemory(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .pNext = null,
            .allocationSize = mem_req.size, .memoryTypeIndex = mem_type,
        }, null);
        try vk.bindImageMemory(ctx.device, self.skin_image, self.skin_image_memory, 0);

        // Upload via command buffer
        var cmd_bufs: [1]vk.VkCommandBuffer = undefined;
        try vk.allocateCommandBuffers(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .pNext = null,
            .commandPool = ctx.command_pool, .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1,
        }, &cmd_bufs);
        const cmd = cmd_bufs[0];

        try vk.beginCommandBuffer(cmd, &.{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .pNext = null,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, .pInheritanceInfo = null,
        });

        const subresource_range = vk.VkImageSubresourceRange{ .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };

        // UNDEFINED → TRANSFER_DST
        vk.cmdPipelineBarrier(cmd, vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, vk.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &[_]vk.VkImageMemoryBarrier{.{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .pNext = null,
            .srcAccessMask = 0, .dstAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = self.skin_image, .subresourceRange = subresource_range,
        }});

        // Copy buffer to image
        vk.cmdCopyBufferToImage(cmd, staging_buffer, self.skin_image, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &[_]vk.VkBufferImageCopy{.{
            .bufferOffset = 0, .bufferRowLength = 0, .bufferImageHeight = 0,
            .imageSubresource = .{ .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{ .width = aw, .height = ah, .depth = 1 },
        }});

        // TRANSFER_DST → SHADER_READ_ONLY
        vk.cmdPipelineBarrier(cmd, vk.VK_PIPELINE_STAGE_TRANSFER_BIT, vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &[_]vk.VkImageMemoryBarrier{.{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .pNext = null,
            .srcAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, .newLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = self.skin_image, .subresourceRange = subresource_range,
        }});

        try vk.endCommandBuffer(cmd);
        try vk.queueSubmit(ctx.graphics_queue, 1, &[_]vk.VkSubmitInfo{.{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO, .pNext = null,
            .waitSemaphoreCount = 0, .pWaitSemaphores = null, .pWaitDstStageMask = null,
            .commandBufferCount = 1, .pCommandBuffers = &cmd,
            .signalSemaphoreCount = 0, .pSignalSemaphores = null,
        }}, null);
        try vk.queueWaitIdle(ctx.graphics_queue);
        vk.freeCommandBuffers(ctx.device, ctx.command_pool, 1, &cmd_bufs);

        // Create image view
        self.skin_image_view = try vk.createImageView(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .pNext = null, .flags = 0,
            .image = self.skin_image, .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
            .format = vk.VK_FORMAT_R8G8B8A8_UNORM,
            .components = .{ .r = vk.VK_COMPONENT_SWIZZLE_IDENTITY, .g = vk.VK_COMPONENT_SWIZZLE_IDENTITY, .b = vk.VK_COMPONENT_SWIZZLE_IDENTITY, .a = vk.VK_COMPONENT_SWIZZLE_IDENTITY },
            .subresourceRange = subresource_range,
        }, null);

        // Create sampler (nearest filtering for pixel art)
        self.skin_sampler = try vk.createSampler(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO, .pNext = null, .flags = 0,
            .magFilter = vk.VK_FILTER_NEAREST, .minFilter = vk.VK_FILTER_NEAREST,
            .mipmapMode = vk.VK_SAMPLER_MIPMAP_MODE_NEAREST,
            .addressModeU = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeV = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeW = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .mipLodBias = 0, .anisotropyEnable = vk.VK_FALSE, .maxAnisotropy = 1,
            .compareEnable = vk.VK_FALSE, .compareOp = 0,
            .minLod = 0, .maxLod = 0,
            .borderColor = vk.VK_BORDER_COLOR_INT_OPAQUE_BLACK,
            .unnormalizedCoordinates = vk.VK_FALSE,
        }, null);

        std.log.info("Player skin loaded: {}x{}", .{ aw, ah });
    }

    fn createPipeline(self: *EntityRenderer, shader_compiler: *ShaderCompiler, ctx: *const VulkanContext, swapchain_format: vk.VkFormat) !void {
        const device = ctx.device;

        const vert_spirv = try shader_compiler.compile("entity.vert", .vertex);
        defer shader_compiler.allocator.free(vert_spirv);

        const frag_spirv = try shader_compiler.compile("entity.frag", .fragment);
        defer shader_compiler.allocator.free(frag_spirv);

        const vert_module = try vk.createShaderModule(device, &vk.VkShaderModuleCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .pNext = null, .flags = 0,
            .codeSize = vert_spirv.len, .pCode = @ptrCast(@alignCast(vert_spirv.ptr)),
        }, null);
        defer vk.destroyShaderModule(device, vert_module, null);

        const frag_module = try vk.createShaderModule(device, &vk.VkShaderModuleCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .pNext = null, .flags = 0,
            .codeSize = frag_spirv.len, .pCode = @ptrCast(@alignCast(frag_spirv.ptr)),
        }, null);
        defer vk.destroyShaderModule(device, frag_module, null);

        const shader_stages = [_]vk.VkPipelineShaderStageCreateInfo{
            .{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .pNext = null, .flags = 0, .stage = vk.VK_SHADER_STAGE_VERTEX_BIT, .module = vert_module, .pName = "main", .pSpecializationInfo = null },
            .{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .pNext = null, .flags = 0, .stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT, .module = frag_module, .pName = "main", .pSpecializationInfo = null },
        };

        const vertex_input_info = vk.VkPipelineVertexInputStateCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO, .pNext = null, .flags = 0, .vertexBindingDescriptionCount = 0, .pVertexBindingDescriptions = null, .vertexAttributeDescriptionCount = 0, .pVertexAttributeDescriptions = null };
        const input_assembly = vk.VkPipelineInputAssemblyStateCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, .pNext = null, .flags = 0, .topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, .primitiveRestartEnable = vk.VK_FALSE };
        const viewport_state = vk.VkPipelineViewportStateCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .pNext = null, .flags = 0, .viewportCount = 1, .pViewports = null, .scissorCount = 1, .pScissors = null };

        const rasterizer = vk.VkPipelineRasterizationStateCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO, .pNext = null, .flags = 0, .depthClampEnable = vk.VK_FALSE, .rasterizerDiscardEnable = vk.VK_FALSE, .polygonMode = vk.VK_POLYGON_MODE_FILL, .cullMode = vk.VK_CULL_MODE_BACK_BIT, .frontFace = vk.VK_FRONT_FACE_COUNTER_CLOCKWISE, .depthBiasEnable = vk.VK_FALSE, .depthBiasConstantFactor = 0, .depthBiasClamp = 0, .depthBiasSlopeFactor = 0, .lineWidth = 1 };
        const multisampling = vk.VkPipelineMultisampleStateCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, .pNext = null, .flags = 0, .rasterizationSamples = vk.VK_SAMPLE_COUNT_1_BIT, .sampleShadingEnable = vk.VK_FALSE, .minSampleShading = 1, .pSampleMask = null, .alphaToCoverageEnable = vk.VK_FALSE, .alphaToOneEnable = vk.VK_FALSE };

        const depth_off = vk.VkPipelineDepthStencilStateCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO, .pNext = null, .flags = 0, .depthTestEnable = vk.VK_FALSE, .depthWriteEnable = vk.VK_FALSE, .depthCompareOp = vk.VK_COMPARE_OP_LESS, .depthBoundsTestEnable = vk.VK_FALSE, .stencilTestEnable = vk.VK_FALSE, .front = std.mem.zeroes(vk.VkStencilOpState), .back = std.mem.zeroes(vk.VkStencilOpState), .minDepthBounds = 0, .maxDepthBounds = 1 };
        const depth_on = vk.VkPipelineDepthStencilStateCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO, .pNext = null, .flags = 0, .depthTestEnable = vk.VK_TRUE, .depthWriteEnable = vk.VK_TRUE, .depthCompareOp = vk.VK_COMPARE_OP_LESS, .depthBoundsTestEnable = vk.VK_FALSE, .stencilTestEnable = vk.VK_FALSE, .front = std.mem.zeroes(vk.VkStencilOpState), .back = std.mem.zeroes(vk.VkStencilOpState), .minDepthBounds = 0, .maxDepthBounds = 1 };

        const blend_att = vk.VkPipelineColorBlendAttachmentState{ .blendEnable = vk.VK_FALSE, .srcColorBlendFactor = vk.VK_BLEND_FACTOR_ONE, .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ZERO, .colorBlendOp = vk.VK_BLEND_OP_ADD, .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE, .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ZERO, .alphaBlendOp = vk.VK_BLEND_OP_ADD, .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT | vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT };
        const color_blending = vk.VkPipelineColorBlendStateCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .pNext = null, .flags = 0, .logicOpEnable = vk.VK_FALSE, .logicOp = 0, .attachmentCount = 1, .pAttachments = &blend_att, .blendConstants = .{ 0, 0, 0, 0 } };

        const push_ranges = [_]vk.VkPushConstantRange{
            .{ .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT, .offset = 0, .size = 64 },
            .{ .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT, .offset = 64, .size = @sizeOf(EntityPushConstants) - 64 },
        };
        self.pipeline_layout = try vk.createPipelineLayout(device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .pNext = null, .flags = 0,
            .setLayoutCount = 1, .pSetLayouts = &self.descriptor_set_layout,
            .pushConstantRangeCount = 2, .pPushConstantRanges = &push_ranges,
        }, null);

        const color_fmt = [_]vk.VkFormat{swapchain_format};
        const rendering_info = vk.VkPipelineRenderingCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO, .pNext = null, .viewMask = 0, .colorAttachmentCount = 1, .pColorAttachmentFormats = &color_fmt, .depthAttachmentFormat = vk.VK_FORMAT_D32_SFLOAT, .stencilAttachmentFormat = vk.VK_FORMAT_UNDEFINED };

        const dyn_states = [_]vk.VkDynamicState{ vk.VK_DYNAMIC_STATE_VIEWPORT, vk.VK_DYNAMIC_STATE_SCISSOR };
        const dyn_info = vk.VkPipelineDynamicStateCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO, .pNext = null, .flags = 0, .dynamicStateCount = 2, .pDynamicStates = &dyn_states };

        const base_info = vk.VkGraphicsPipelineCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .pNext = &rendering_info, .flags = 0,
            .stageCount = 2, .pStages = &shader_stages,
            .pVertexInputState = &vertex_input_info, .pInputAssemblyState = &input_assembly,
            .pTessellationState = null, .pViewportState = &viewport_state,
            .pRasterizationState = &rasterizer, .pMultisampleState = &multisampling,
            .pDepthStencilState = &depth_off, .pColorBlendState = &color_blending,
            .pDynamicState = @ptrCast(&dyn_info),
            .layout = self.pipeline_layout, .renderPass = null, .subpass = 0,
            .basePipelineHandle = null, .basePipelineIndex = -1,
        };

        var info_depth = base_info;
        info_depth.pDepthStencilState = &depth_on;

        const infos = [2]vk.VkGraphicsPipelineCreateInfo{ base_info, info_depth };
        var pipelines: [2]vk.VkPipeline = undefined;
        try vk.createGraphicsPipelines(device, null, 2, &infos, null, &pipelines);
        self.pipeline = pipelines[0];
        self.pipeline_depth = pipelines[1];

        std.log.info("Entity pipelines created", .{});
    }
};
