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
const GameState = @import("../../world/GameState.zig");
const Entity = GameState.Entity;
const EntityRenderer = @import("EntityRenderer.zig");
const EntityVertex = EntityRenderer.EntityVertex;
const Io = std.Io;
const Dir = Io.Dir;

const MAX_VERTICES = 4096;

const EntityPushConstants = extern struct {
    mvp: [16]f32,              // 0-63
    ambient_light: [3]f32,     // 64-75
    contrast: f32,             // 76-79  (ambientContrast.w)
    sun_dir: [3]f32,           // 80-91
    sky_level: f32,            // 92-95  (sunDirSky.w)
    block_light: [3]f32,       // 96-107
    model_yaw: f32 = 0,        // 108-111 (blockLightYaw.w)
    leg_phase: f32 = 0,        // 112-115
    hurt_tint: f32 = 0,        // 116-119
};

pub const MobRenderer = struct {
    pipeline: vk.VkPipeline,
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

    pub fn init(allocator: std.mem.Allocator, shader_compiler: *ShaderCompiler, ctx: *const VulkanContext, swapchain_format: vk.VkFormat, gpu_alloc: *GpuAllocator) !MobRenderer {
        const tz = tracy.zone(@src(), "MobRenderer.init");
        defer tz.end();

        var self = MobRenderer{
            .pipeline = null,
            .pipeline_layout = null,
            .descriptor_set_layout = null,
            .descriptor_pool = null,
            .descriptor_set = null,
            .vertex_alloc = BufferAllocation.EMPTY,
            .gpu_alloc = gpu_alloc,
        };

        try self.createResources(allocator, ctx, gpu_alloc);
        try self.createPipeline(shader_compiler, ctx, swapchain_format);
        self.loadModel(allocator);

        return self;
    }

    pub fn deinit(self: *MobRenderer, device: vk.VkDevice) void {
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

    pub fn recordDraw(
        self: *const MobRenderer,
        command_buffer: vk.VkCommandBuffer,
        game_state: *const GameState,
        view_proj: zlm.Mat4,
        ambient_light: [3]f32,
        sun_dir: [3]f32,
    ) void {
        const tz = tracy.zone(@src(), "MobRenderer.recordDraw");
        defer tz.end();

        if (self.vertex_count == 0) return;

        // Check if any pigs exist
        var has_pigs = false;
        for (1..game_state.entities.count) |i| {
            if (game_state.entities.kind[i] == .pig) { has_pigs = true; break; }
        }
        if (!has_pigs) return;

        vk.cmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);
        vk.cmdBindDescriptorSets(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline_layout, 0, 1, &[_]vk.VkDescriptorSet{self.descriptor_set}, 0, null);

        for (1..game_state.entities.count) |i| {
            if (game_state.entities.kind[i] != .pig) continue;

            const pos = game_state.entities.render_pos[i];
            const angle = game_state.entities.rotation[i][0].offset(std.math.pi);
            const sin_y = angle.sin();
            const cos_y = angle.cos();
            const model = zlm.Mat4{
                .m = .{ cos_y, 0, -sin_y, 0, 0, 1, 0, 0, sin_y, 0, cos_y, 0, pos[0], pos[1], pos[2], 1 },
            };
            const mvp = zlm.Mat4.mul(view_proj, model);

            const light = game_state.sampleLightAt(pos[0], pos[1] + 0.45, pos[2]);
            const block_light = [3]f32{ light[0], light[1], light[2] };
            const sky_level = light[3];

            const hurt_tint: f32 = if (game_state.entities.hurt_time[i] > 0) 1.0 else 0.0;

            const pc = EntityPushConstants{
                .mvp = mvp.m,
                .ambient_light = ambient_light,
                .contrast = 1.0,
                .sun_dir = sun_dir,
                .sky_level = sky_level,
                .block_light = block_light,
                .model_yaw = angle.value,
                .leg_phase = game_state.entities.render_walk_anim[i],
                .hurt_tint = hurt_tint,
            };
            vk.cmdPushConstants(command_buffer, self.pipeline_layout, vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(EntityPushConstants), @ptrCast(&pc));
            vk.cmdDraw(command_buffer, self.vertex_count, 1, 0, 0);
        }
    }

    // ============================================================
    // Model loading (same approach as EntityRenderer)
    // ============================================================

    const TARGET_HEIGHT = 0.9;

    fn loadModel(self: *MobRenderer, allocator: std.mem.Allocator) void {
        const sep = std.fs.path.sep_str;
        const assets_path = app_config.getAssetsPath(allocator) catch return;
        defer allocator.free(assets_path);

        const model_path = std.fmt.allocPrintSentinel(allocator, "{s}" ++ sep ++ "models" ++ sep ++ "pig.json", .{assets_path}, 0) catch return;
        defer allocator.free(model_path);

        const io = Io.Threaded.global_single_threaded.io();
        const data = Dir.readFileAlloc(.cwd(), io, model_path, allocator, .unlimited) catch {
            std.log.err("Failed to read pig model", .{});
            return;
        };
        defer allocator.free(data);

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return;
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => return,
        };

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

            const pw: f32 = @floatCast(jf(size_arr[0]));
            const ph: f32 = @floatCast(jf(size_arr[1]));
            const pd: f32 = @floatCast(jf(size_arr[2]));

            const tu: f32 = @floatCast(jf(uv_arr[0]));
            const tv: f32 = @floatCast(jf(uv_arr[1]));

            count = EntityRenderer.EntityRenderer.addTexturedBox(vertices, count, bx, by, bz, bw, bh, bd, tu, tv, pw, ph, pd, tex_w, tex_h);
        }

        self.vertex_count = count;
        std.log.info("Pig model loaded: {} parts, {} vertices", .{ parts.len, count });
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
    // Vulkan resources (mirrors EntityRenderer)
    // ============================================================

    fn createResources(self: *MobRenderer, allocator: std.mem.Allocator, ctx: *const VulkanContext, gpu_alloc: *GpuAllocator) !void {
        const vertex_buffer_size: vk.VkDeviceSize = MAX_VERTICES * @sizeOf(EntityVertex);
        self.vertex_alloc = try gpu_alloc.createBuffer(
            vertex_buffer_size,
            vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            .host_visible,
        );

        try self.loadSkinTexture(allocator, ctx);

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

    fn loadSkinTexture(self: *MobRenderer, allocator: std.mem.Allocator, ctx: *const VulkanContext) !void {
        const sep = std.fs.path.sep_str;
        const assets_path = try app_config.getAssetsPath(allocator);
        defer allocator.free(assets_path);

        const path = try std.fmt.allocPrintSentinel(allocator, "{s}" ++ sep ++ "textures" ++ sep ++ "entity" ++ sep ++ "pig.png", .{assets_path}, 0);
        defer allocator.free(path);

        var tw: c_int = 0;
        var th: c_int = 0;
        var tc: c_int = 0;
        const pixels: [*]u8 = stbi.load(path.ptr, &tw, &th, &tc, 4) orelse return error.TextureLoadFailed;
        defer stbi.free(pixels);

        const aw: u32 = @intCast(tw);
        const ah: u32 = @intCast(th);
        const atlas_bytes: vk.VkDeviceSize = @as(u64, aw) * ah * 4;

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

        vk.cmdPipelineBarrier(cmd, vk.VK_PIPELINE_STAGE_HOST_BIT, vk.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &[_]vk.VkImageMemoryBarrier{.{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .pNext = null,
            .srcAccessMask = 0, .dstAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = self.skin_image, .subresourceRange = subresource_range,
        }});

        vk.cmdCopyBufferToImage(cmd, staging_buffer, self.skin_image, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &[_]vk.VkBufferImageCopy{.{
            .bufferOffset = 0, .bufferRowLength = 0, .bufferImageHeight = 0,
            .imageSubresource = .{ .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{ .width = aw, .height = ah, .depth = 1 },
        }});

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

        self.skin_image_view = try vk.createImageView(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .pNext = null, .flags = 0,
            .image = self.skin_image, .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
            .format = vk.VK_FORMAT_R8G8B8A8_UNORM,
            .components = .{ .r = vk.VK_COMPONENT_SWIZZLE_IDENTITY, .g = vk.VK_COMPONENT_SWIZZLE_IDENTITY, .b = vk.VK_COMPONENT_SWIZZLE_IDENTITY, .a = vk.VK_COMPONENT_SWIZZLE_IDENTITY },
            .subresourceRange = subresource_range,
        }, null);

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

        std.log.info("Pig skin loaded: {}x{}", .{ aw, ah });
    }

    fn createPipeline(self: *MobRenderer, shader_compiler: *ShaderCompiler, ctx: *const VulkanContext, swapchain_format: vk.VkFormat) !void {
        const device = ctx.device;

        const vert_spirv = try shader_compiler.compile("mob.vert", .vertex);
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
        const depth_stencil = vk.VkPipelineDepthStencilStateCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO, .pNext = null, .flags = 0, .depthTestEnable = vk.VK_TRUE, .depthWriteEnable = vk.VK_TRUE, .depthCompareOp = vk.VK_COMPARE_OP_LESS, .depthBoundsTestEnable = vk.VK_FALSE, .stencilTestEnable = vk.VK_FALSE, .front = std.mem.zeroes(vk.VkStencilOpState), .back = std.mem.zeroes(vk.VkStencilOpState), .minDepthBounds = 0, .maxDepthBounds = 1 };
        const blend_att = vk.VkPipelineColorBlendAttachmentState{ .blendEnable = vk.VK_FALSE, .srcColorBlendFactor = vk.VK_BLEND_FACTOR_ONE, .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ZERO, .colorBlendOp = vk.VK_BLEND_OP_ADD, .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE, .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ZERO, .alphaBlendOp = vk.VK_BLEND_OP_ADD, .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT | vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT };
        const color_blending = vk.VkPipelineColorBlendStateCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .pNext = null, .flags = 0, .logicOpEnable = vk.VK_FALSE, .logicOp = 0, .attachmentCount = 1, .pAttachments = &blend_att, .blendConstants = .{ 0, 0, 0, 0 } };

        const push_ranges = [_]vk.VkPushConstantRange{
            .{ .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT, .offset = 0, .size = @sizeOf(EntityPushConstants) },
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

        const pipeline_info = vk.VkGraphicsPipelineCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .pNext = &rendering_info, .flags = 0,
            .stageCount = 2, .pStages = &shader_stages,
            .pVertexInputState = &vertex_input_info, .pInputAssemblyState = &input_assembly,
            .pTessellationState = null, .pViewportState = &viewport_state,
            .pRasterizationState = &rasterizer, .pMultisampleState = &multisampling,
            .pDepthStencilState = &depth_stencil, .pColorBlendState = &color_blending,
            .pDynamicState = @ptrCast(&dyn_info),
            .layout = self.pipeline_layout, .renderPass = null, .subpass = 0,
            .basePipelineHandle = null, .basePipelineIndex = -1,
        };

        var pipeline: vk.VkPipeline = undefined;
        try vk.createGraphicsPipelines(device, null, 1, &[_]vk.VkGraphicsPipelineCreateInfo{pipeline_info}, null, @ptrCast(&pipeline));
        self.pipeline = pipeline;

        std.log.info("Mob pipeline created", .{});
    }
};
