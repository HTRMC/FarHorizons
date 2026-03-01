const std = @import("std");
const vk = @import("../../platform/volk.zig");
const c = @import("../../platform/c.zig").c;
const ShaderCompiler = @import("ShaderCompiler.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const vk_utils = @import("vk_utils.zig");
const types = @import("types.zig");
const TextVertex = types.TextVertex;
const tracy = @import("../../platform/tracy.zig");
const app_config = @import("../../app_config.zig");

const ATLAS_COLS = 16;
const ATLAS_ROWS = 16;
const GLYPH_SIZE = 8;
const GLYPH_SCALE = 2;
const RENDER_SIZE = GLYPH_SIZE * GLYPH_SCALE;
const MAX_CHARS = 4096;
const MAX_VERTICES = MAX_CHARS * 6;

const sep = std.fs.path.sep_str;

pub const TextRenderer = struct {
    pipeline: vk.VkPipeline,
    pipeline_layout: vk.VkPipelineLayout,
    descriptor_set_layout: vk.VkDescriptorSetLayout,
    descriptor_pool: vk.VkDescriptorPool,
    descriptor_set: vk.VkDescriptorSet,
    vertex_buffer: vk.VkBuffer,
    vertex_buffer_memory: vk.VkDeviceMemory,
    font_image: vk.VkImage,
    font_image_memory: vk.VkDeviceMemory,
    font_image_view: vk.VkImageView,
    font_sampler: vk.VkSampler,
    glyph_widths: [256]u8,
    vertex_count: u32,
    screen_width: f32,
    screen_height: f32,
    mapped_vertices: ?[*]TextVertex,
    clip_rect: [4]f32 = .{ -1e9, -1e9, 1e9, 1e9 },
    clip_stack: [8][4]f32 = undefined,
    clip_depth: u8 = 0,
    clip_scale: f32 = 1.0,

    pub fn init(
        allocator: std.mem.Allocator,
        shader_compiler: *ShaderCompiler,
        ctx: *const VulkanContext,
        swapchain_format: vk.VkFormat,
    ) !TextRenderer {
        const tz = tracy.zone(@src(), "TextRenderer.init");
        defer tz.end();

        var self = TextRenderer{
            .pipeline = null,
            .pipeline_layout = null,
            .descriptor_set_layout = null,
            .descriptor_pool = null,
            .descriptor_set = null,
            .vertex_buffer = null,
            .vertex_buffer_memory = null,
            .font_image = null,
            .font_image_memory = null,
            .font_image_view = null,
            .font_sampler = null,
            .glyph_widths = [_]u8{0} ** 256,
            .vertex_count = 0,
            .screen_width = 800.0,
            .screen_height = 600.0,
            .mapped_vertices = null,
        };

        try self.createVertexBuffer(ctx);
        try self.createFontImage(allocator, ctx);
        try self.createDescriptors(ctx);
        try self.createPipeline(shader_compiler, ctx, swapchain_format);

        std.log.info("TextRenderer initialized", .{});
        return self;
    }

    pub fn deinit(self: *TextRenderer, device: vk.VkDevice) void {
        vk.destroyPipeline(device, self.pipeline, null);
        vk.destroyPipelineLayout(device, self.pipeline_layout, null);
        vk.destroyDescriptorPool(device, self.descriptor_pool, null);
        vk.destroyDescriptorSetLayout(device, self.descriptor_set_layout, null);
        vk.destroyBuffer(device, self.vertex_buffer, null);
        vk.freeMemory(device, self.vertex_buffer_memory, null);
        vk.destroySampler(device, self.font_sampler, null);
        vk.destroyImageView(device, self.font_image_view, null);
        vk.destroyImage(device, self.font_image, null);
        vk.freeMemory(device, self.font_image_memory, null);
    }

    pub fn beginFrame(self: *TextRenderer, device: vk.VkDevice) void {
        var data: ?*anyopaque = null;
        vk.mapMemory(device, self.vertex_buffer_memory, 0, MAX_VERTICES * @sizeOf(TextVertex), 0, &data) catch return;
        self.mapped_vertices = @ptrCast(@alignCast(data));
        self.vertex_count = 0;
    }

    pub fn setClipRect(self: *TextRenderer, x: f32, y: f32, w: f32, h: f32) void {
        self.clip_rect = .{ x, y, x + w, y + h };
    }

    pub fn clearClipRect(self: *TextRenderer) void {
        self.clip_rect = .{ -1e9, -1e9, 1e9, 1e9 };
    }

    pub fn pushClipRect(self: *TextRenderer, x: f32, y: f32, w: f32, h: f32) void {
        if (self.clip_depth < 8) {
            self.clip_stack[self.clip_depth] = self.clip_rect;
            self.clip_depth += 1;
        }
        const new = [4]f32{
            @max(self.clip_rect[0], x),
            @max(self.clip_rect[1], y),
            @min(self.clip_rect[2], x + w),
            @min(self.clip_rect[3], y + h),
        };
        self.clip_rect = new;
    }

    pub fn popClipRect(self: *TextRenderer) void {
        if (self.clip_depth > 0) {
            self.clip_depth -= 1;
            self.clip_rect = self.clip_stack[self.clip_depth];
        } else {
            self.clip_rect = .{ -1e9, -1e9, 1e9, 1e9 };
        }
    }

    pub fn drawText(self: *TextRenderer, x: f32, y: f32, text: []const u8, color: [4]f32) void {
        self.drawTextScaled(x, y, text, color, 1.0);
    }

    pub fn drawTextScaled(self: *TextRenderer, x: f32, y: f32, text: []const u8, color: [4]f32, scale: f32) void {
        const verts = self.mapped_vertices orelse return;
        var cursor_x = x;
        const gs: f32 = GLYPH_SCALE * scale;
        const rs: f32 = RENDER_SIZE * scale;

        for (text) |ch| {
            if (ch == ' ') {
                cursor_x += 4 * gs;
                continue;
            }
            const gw = self.glyph_widths[ch];
            if (gw == 0) continue;

            if (self.vertex_count + 6 > MAX_VERTICES) break;

            const col: f32 = @floatFromInt(ch % ATLAS_COLS);
            const row: f32 = @floatFromInt(ch / ATLAS_COLS);
            const glyph_w: f32 = @floatFromInt(gw);

            const uv_left = col / @as(f32, ATLAS_COLS);
            const uv_top = row / @as(f32, ATLAS_ROWS);
            const uv_right = (col + glyph_w / @as(f32, GLYPH_SIZE)) / @as(f32, ATLAS_COLS);
            const uv_bottom = (row + 1.0) / @as(f32, ATLAS_ROWS);

            const quad_w = glyph_w * gs;
            const px_left = cursor_x;
            const py_top = y;
            const px_right = cursor_x + quad_w;
            const py_bottom = y + rs;

            const s = self.clip_scale;
            const cr = [4]f32{ self.clip_rect[0] * s, self.clip_rect[1] * s, self.clip_rect[2] * s, self.clip_rect[3] * s };
            verts[self.vertex_count + 0] = .{ .px = px_left, .py = py_top, .u = uv_left, .v = uv_top, .r = color[0], .g = color[1], .b = color[2], .a = color[3], .clip_min_x = cr[0], .clip_min_y = cr[1], .clip_max_x = cr[2], .clip_max_y = cr[3] };
            verts[self.vertex_count + 1] = .{ .px = px_right, .py = py_top, .u = uv_right, .v = uv_top, .r = color[0], .g = color[1], .b = color[2], .a = color[3], .clip_min_x = cr[0], .clip_min_y = cr[1], .clip_max_x = cr[2], .clip_max_y = cr[3] };
            verts[self.vertex_count + 2] = .{ .px = px_left, .py = py_bottom, .u = uv_left, .v = uv_bottom, .r = color[0], .g = color[1], .b = color[2], .a = color[3], .clip_min_x = cr[0], .clip_min_y = cr[1], .clip_max_x = cr[2], .clip_max_y = cr[3] };

            verts[self.vertex_count + 3] = .{ .px = px_right, .py = py_top, .u = uv_right, .v = uv_top, .r = color[0], .g = color[1], .b = color[2], .a = color[3], .clip_min_x = cr[0], .clip_min_y = cr[1], .clip_max_x = cr[2], .clip_max_y = cr[3] };
            verts[self.vertex_count + 4] = .{ .px = px_right, .py = py_bottom, .u = uv_right, .v = uv_bottom, .r = color[0], .g = color[1], .b = color[2], .a = color[3], .clip_min_x = cr[0], .clip_min_y = cr[1], .clip_max_x = cr[2], .clip_max_y = cr[3] };
            verts[self.vertex_count + 5] = .{ .px = px_left, .py = py_bottom, .u = uv_left, .v = uv_bottom, .r = color[0], .g = color[1], .b = color[2], .a = color[3], .clip_min_x = cr[0], .clip_min_y = cr[1], .clip_max_x = cr[2], .clip_max_y = cr[3] };

            self.vertex_count += 6;
            cursor_x += quad_w + gs;
        }
    }

    pub fn endFrame(self: *TextRenderer, device: vk.VkDevice) void {
        if (self.mapped_vertices != null) {
            vk.unmapMemory(device, self.vertex_buffer_memory);
            self.mapped_vertices = null;
        }
    }

    pub fn recordDraw(self: *const TextRenderer, command_buffer: vk.VkCommandBuffer) void {
        if (self.vertex_count == 0) return;

        const ortho = orthoMatrix(self.screen_width, self.screen_height);

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
        vk.cmdDraw(command_buffer, self.vertex_count, 1, 0, 0);
    }

    pub fn measureText(self: *const TextRenderer, text: []const u8) f32 {
        var width: f32 = 0;
        for (text) |ch| {
            if (ch == ' ') {
                width += 4 * GLYPH_SCALE;
                continue;
            }
            const gw = self.glyph_widths[ch];
            if (gw == 0) continue;
            width += @as(f32, @floatFromInt(gw)) * GLYPH_SCALE + GLYPH_SCALE;
        }
        if (width > 0) width -= GLYPH_SCALE;
        return width;
    }

    pub fn measureTextWrapped(self: *const TextRenderer, text: []const u8, max_width: f32) struct { width: f32, height: f32 } {
        if (text.len == 0 or max_width <= 0) return .{ .width = 0, .height = 0 };

        const line_height: f32 = RENDER_SIZE;
        var line_count: f32 = 1;
        var line_w: f32 = 0;
        var max_line_w: f32 = 0;
        var word_start: usize = 0;

        var i: usize = 0;
        while (i <= text.len) {
            const at_end = i == text.len;
            const is_space = if (!at_end) text[i] == ' ' else true;

            if (is_space or at_end) {
                const word = text[word_start..i];
                const word_w = self.measureText(word);
                const space_w: f32 = if (line_w > 0) 4 * GLYPH_SCALE else 0;

                if (line_w > 0 and line_w + space_w + word_w > max_width) {
                    max_line_w = @max(max_line_w, line_w);
                    line_count += 1;
                    line_w = word_w;
                } else {
                    line_w += space_w + word_w;
                }

                if (word_w > max_width and line_w == word_w) {
                    max_line_w = @max(max_line_w, line_w);
                }

                if (!at_end) {
                    word_start = i + 1;
                }
            }
            i += 1;
        }
        max_line_w = @max(max_line_w, line_w);

        return .{ .width = @min(max_line_w, max_width), .height = line_count * line_height };
    }

    pub fn drawTextWrapped(self: *TextRenderer, x: f32, y: f32, text: []const u8, max_width: f32, color: [4]f32) f32 {
        if (text.len == 0 or max_width <= 0) return 0;

        const line_height: f32 = RENDER_SIZE;
        var line_y = y;
        var line_w: f32 = 0;
        var word_start: usize = 0;
        var line_start: usize = 0;
        var last_space: usize = 0;
        var has_space = false;

        var i: usize = 0;
        while (i <= text.len) {
            const at_end = i == text.len;
            const is_space = if (!at_end) text[i] == ' ' else true;

            if (is_space or at_end) {
                const word = text[word_start..i];
                const word_w = self.measureText(word);
                const space_w: f32 = if (line_w > 0) 4 * GLYPH_SCALE else 0;

                if (line_w > 0 and line_w + space_w + word_w > max_width) {
                    self.drawText(x, line_y, text[line_start..if (has_space) last_space else i], color);
                    line_y += line_height;
                    line_start = if (has_space) last_space + 1 else word_start;
                    line_w = self.measureText(text[line_start..i]);
                } else {
                    line_w += space_w + word_w;
                }

                if (!at_end) {
                    last_space = i;
                    has_space = true;
                    word_start = i + 1;
                }
            }
            i += 1;
        }

        if (line_start < text.len) {
            self.drawText(x, line_y, text[line_start..], color);
            line_y += line_height;
        }

        return line_y - y;
    }

    pub fn updateScreenSize(self: *TextRenderer, width: u32, height: u32, scale: f32) void {
        self.screen_width = @floatFromInt(width);
        self.screen_height = @floatFromInt(height);
        self.clip_scale = scale;
    }

    fn orthoMatrix(w: f32, h: f32) [16]f32 {
        return .{
            2.0 / w, 0.0,      0.0, 0.0,
            0.0,     2.0 / h,  0.0, 0.0,
            0.0,     0.0,      1.0, 0.0,
            -1.0,    -1.0,     0.0, 1.0,
        };
    }

    fn createVertexBuffer(self: *TextRenderer, ctx: *const VulkanContext) !void {
        const buffer_size: vk.VkDeviceSize = MAX_VERTICES * @sizeOf(TextVertex);
        try vk_utils.createBuffer(
            ctx,
            buffer_size,
            vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &self.vertex_buffer,
            &self.vertex_buffer_memory,
        );
    }

    fn createFontImage(self: *TextRenderer, allocator: std.mem.Allocator, ctx: *const VulkanContext) !void {
        const tz = tracy.zone(@src(), "TextRenderer.createFontImage");
        defer tz.end();

        const base_path = try app_config.getAppDataPath(allocator);
        defer allocator.free(base_path);

        const texture_path = try std.fmt.allocPrintSentinel(
            allocator,
            "{s}" ++ sep ++ "assets" ++ sep ++ "farhorizons" ++ sep ++ "textures" ++ sep ++ "font" ++ sep ++ "ascii.png",
            .{base_path},
            0,
        );
        defer allocator.free(texture_path);

        var tw: c_int = 0;
        var th: c_int = 0;
        var tc: c_int = 0;
        const pixels = c.stbi_load(texture_path.ptr, &tw, &th, &tc, 4) orelse {
            std.log.err("Failed to load font texture from {s}", .{texture_path});
            return error.FontLoadFailed;
        };
        defer c.stbi_image_free(pixels);

        const img_w: u32 = @intCast(tw);
        const img_h: u32 = @intCast(th);
        const image_size: vk.VkDeviceSize = @as(vk.VkDeviceSize, img_w) * img_h * 4;

        const pixel_data: [*]const u8 = @ptrCast(pixels);
        for (0..256) |ch| {
            const glyph_col = ch % ATLAS_COLS;
            const glyph_row = ch / ATLAS_COLS;
            const base_x = glyph_col * GLYPH_SIZE;
            const base_y = glyph_row * GLYPH_SIZE;

            var max_col: u8 = 0;
            var found = false;
            for (0..GLYPH_SIZE) |py| {
                for (0..GLYPH_SIZE) |px| {
                    const pixel_x = base_x + px;
                    const pixel_y = base_y + py;
                    const alpha = pixel_data[(pixel_y * img_w + pixel_x) * 4 + 3];
                    if (alpha > 0) {
                        if (!found or @as(u8, @intCast(px)) >= max_col) {
                            max_col = @intCast(px + 1);
                            found = true;
                        }
                    }
                }
            }
            self.glyph_widths[ch] = if (found) max_col else 0;
        }

        var staging_buffer: vk.VkBuffer = undefined;
        var staging_memory: vk.VkDeviceMemory = undefined;
        try vk_utils.createBuffer(
            ctx,
            image_size,
            vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &staging_buffer,
            &staging_memory,
        );

        {
            var data: ?*anyopaque = null;
            try vk.mapMemory(ctx.device, staging_memory, 0, image_size, 0, &data);
            const dst: [*]u8 = @ptrCast(data.?);
            const src: [*]const u8 = @ptrCast(pixels);
            @memcpy(dst[0..@intCast(image_size)], src[0..@intCast(image_size)]);
            vk.unmapMemory(ctx.device, staging_memory);
        }

        const image_info = vk.VkImageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = vk.VK_IMAGE_TYPE_2D,
            .format = vk.VK_FORMAT_R8G8B8A8_UNORM,
            .extent = .{ .width = img_w, .height = img_h, .depth = 1 },
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

        self.font_image = try vk.createImage(ctx.device, &image_info, null);

        var mem_requirements: vk.VkMemoryRequirements = undefined;
        vk.getImageMemoryRequirements(ctx.device, self.font_image, &mem_requirements);

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

        self.font_image_memory = try vk.allocateMemory(ctx.device, &alloc_info, null);
        try vk.bindImageMemory(ctx.device, self.font_image, self.font_image_memory, 0);

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

        const cmd_begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };
        try vk.beginCommandBuffer(cmd, &cmd_begin_info);

        const to_transfer = vk.VkImageMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = 0,
            .dstAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = self.font_image,
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
            .imageExtent = .{ .width = img_w, .height = img_h, .depth = 1 },
        };

        vk.cmdCopyBufferToImage(cmd, staging_buffer, self.font_image, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &[_]vk.VkBufferImageCopy{region});

        const to_shader = vk.VkImageMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = self.font_image,
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

        const view_info = vk.VkImageViewCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = self.font_image,
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
        };

        self.font_image_view = try vk.createImageView(ctx.device, &view_info, null);

        const sampler_info = vk.VkSamplerCreateInfo{
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
        };

        self.font_sampler = try vk.createSampler(ctx.device, &sampler_info, null);

        std.log.info("Font texture loaded ({}x{})", .{ img_w, img_h });
    }

    fn createDescriptors(self: *TextRenderer, ctx: *const VulkanContext) !void {
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

        const buffer_info = vk.VkDescriptorBufferInfo{
            .buffer = self.vertex_buffer,
            .offset = 0,
            .range = MAX_VERTICES * @sizeOf(TextVertex),
        };

        const image_info = vk.VkDescriptorImageInfo{
            .sampler = self.font_sampler,
            .imageView = self.font_image_view,
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

    fn createPipeline(self: *TextRenderer, shader_compiler: *ShaderCompiler, ctx: *const VulkanContext, swapchain_format: vk.VkFormat) !void {
        const tz = tracy.zone(@src(), "TextRenderer.createPipeline");
        defer tz.end();

        const vert_spirv = try shader_compiler.compile("text.vert", .vertex);
        defer shader_compiler.allocator.free(vert_spirv);

        const frag_spirv = try shader_compiler.compile("text.frag", .fragment);
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
            .size = 64,
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

        const pipeline_info = vk.VkGraphicsPipelineCreateInfo{
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
        };

        var pipelines: [1]vk.VkPipeline = undefined;
        try vk.createGraphicsPipelines(ctx.device, ctx.pipeline_cache, 1, &[_]vk.VkGraphicsPipelineCreateInfo{pipeline_info}, null, &pipelines);
        self.pipeline = pipelines[0];

        std.log.info("Text rendering pipeline created", .{});
    }
};
