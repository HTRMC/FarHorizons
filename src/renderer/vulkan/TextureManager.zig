const std = @import("std");
const vk = @import("../../platform/volk.zig");
const stbi = @import("../../platform/stb_image.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const vk_utils = @import("vk_utils.zig");
const app_config = @import("../../app_config.zig");
const tracy = @import("../../platform/tracy.zig");

const Io = std.Io;
const Dir = Io.Dir;

const ITEM_TEXTURE_COUNT = 25; // 5 tiers × 5 tool types
pub const ITEM_TEXTURE_BASE = 68; // first item layer in the texture array
const TOTAL_TEXTURE_COUNT = 68 + ITEM_TEXTURE_COUNT; // blocks + items

const item_texture_names = [ITEM_TEXTURE_COUNT][]const u8{
    // Ordered by tier * 5 + tool_type (matches Item.idFromTool encoding)
    "wood_pickaxe.png",  "wood_axe.png",  "wood_shovel.png",  "wood_sword.png",  "wood_hoe.png",
    "stone_pickaxe.png", "stone_axe.png", "stone_shovel.png", "stone_sword.png", "stone_hoe.png",
    "iron_pickaxe.png",  "iron_axe.png",  "iron_shovel.png",  "iron_sword.png",  "iron_hoe.png",
    "gold_pickaxe.png",  "gold_axe.png",  "gold_shovel.png",  "gold_sword.png",  "gold_hoe.png",
    "diamond_pickaxe.png","diamond_axe.png","diamond_shovel.png","diamond_sword.png","diamond_hoe.png",
};

const BLOCK_TEXTURE_COUNT = 68;
const block_texture_names = [BLOCK_TEXTURE_COUNT][]const u8{
    "glass.png",      "grass_block.png", "dirt.png",       "stone.png",        // 0-3
    "glowstone.png",  "sand.png",        "snow.png",       "water.png",        // 4-7
    "gravel.png",     "cobblestone.png", "oak_log.png",    "oak_planks.png",   // 8-11
    "bricks.png",     "bedrock.png",     "gold_ore.png",   "iron_ore.png",     // 12-15
    "coal_ore.png",   "diamond_ore.png", "sponge.png",     "pumice.png",       // 16-19
    "wool.png",       "gold_block.png",  "iron_block.png", "diamond_block.png",// 20-23
    "bookshelf.png",  "obsidian.png",    "oak_leaves.png", "oak_log_top.png",  // 24-27
    "torch.png",      "ladder.png",      "torch_fire.png", "torch_fire_particle.png", // 28-31
    "oak_door_bottom.png", "oak_door_top.png",                                 // 32-33
    "red_glowstone.png",     "crimson_glowstone.png",  "orange_glowstone.png",     // 34-36
    "peach_glowstone.png",   "lime_glowstone.png",     "green_glowstone.png",      // 37-39
    "teal_glowstone.png",    "cyan_glowstone.png",     "light_blue_glowstone.png", // 40-42
    "blue_glowstone.png",    "navy_glowstone.png",     "indigo_glowstone.png",     // 43-45
    "purple_glowstone.png",  "magenta_glowstone.png",  "pink_glowstone.png",       // 46-48
    "hot_pink_glowstone.png","white_glowstone.png",    "warm_white_glowstone.png", // 49-51
    "light_gray_glowstone.png","gray_glowstone.png",   "brown_glowstone.png",      // 52-54
    "tan_glowstone.png",     "black_glowstone.png",    "crafting_table.png",       // 55-57
    "destroy_stage_0.png", "destroy_stage_1.png", "destroy_stage_2.png",        // 58-60
    "destroy_stage_3.png", "destroy_stage_4.png", "destroy_stage_5.png",        // 61-63
    "destroy_stage_6.png", "destroy_stage_7.png", "destroy_stage_8.png",        // 64-66
    "destroy_stage_9.png",                                                       // 67
};

const TEX_W = 16;
const TEX_H = 16;
const FRAME_SIZE: usize = TEX_W * TEX_H * 4; // 1024 bytes per frame
const MAX_ANIMATED_TEXTURES = 8;
const TICK_RATE: f32 = 20.0; // Minecraft ticks per second
const TICK_INTERVAL: f32 = 1.0 / TICK_RATE;

const AnimatedTexture = struct {
    layer_index: u32,
    frame_count: u32,
    frametime: u32, // ticks per frame
    interpolate: bool,
    frame_data: []const u8, // all frames: frame_count * FRAME_SIZE
    current_frame: u32,
    sub_frame: u32,
    dirty: bool,
};

pub const TextureManager = struct {
    texture_image: vk.VkImage,
    texture_image_memory: vk.VkDeviceMemory,
    texture_image_view: vk.VkImageView,
    texture_sampler: vk.VkSampler,
    bindless_descriptor_set_layout: vk.VkDescriptorSetLayout,
    bindless_descriptor_pool: vk.VkDescriptorPool,
    bindless_descriptor_set: vk.VkDescriptorSet,

    // Animation state
    animations: [MAX_ANIMATED_TEXTURES]AnimatedTexture,
    animation_count: u32,
    anim_staging_buffer: vk.VkBuffer,
    anim_staging_memory: vk.VkDeviceMemory,
    anim_staging_ptr: [*]u8,
    tick_accumulator: f32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, ctx: *const VulkanContext) !TextureManager {
        const tz = tracy.zone(@src(), "TextureManager.init");
        defer tz.end();

        var self = TextureManager{
            .texture_image = null,
            .texture_image_memory = null,
            .texture_image_view = null,
            .texture_sampler = null,
            .bindless_descriptor_set_layout = null,
            .bindless_descriptor_pool = null,
            .bindless_descriptor_set = null,
            .animations = undefined,
            .animation_count = 0,
            .anim_staging_buffer = null,
            .anim_staging_memory = null,
            .anim_staging_ptr = undefined,
            .tick_accumulator = 0,
            .allocator = allocator,
        };

        try self.createTextureImage(allocator, ctx);
        try self.createAnimationStagingBuffer(ctx);
        try self.createBindlessDescriptorSet(ctx);

        return self;
    }

    pub fn deinit(self: *TextureManager, device: vk.VkDevice) void {
        for (0..self.animation_count) |i| {
            self.allocator.free(self.animations[i].frame_data);
        }
        if (self.anim_staging_buffer != null) {
            vk.destroyBuffer(device, self.anim_staging_buffer, null);
            vk.freeMemory(device, self.anim_staging_memory, null);
        }
        vk.destroyDescriptorPool(device, self.bindless_descriptor_pool, null);
        vk.destroyDescriptorSetLayout(device, self.bindless_descriptor_set_layout, null);
        vk.destroySampler(device, self.texture_sampler, null);
        vk.destroyImageView(device, self.texture_image_view, null);
        vk.destroyImage(device, self.texture_image, null);
        vk.freeMemory(device, self.texture_image_memory, null);
    }

    /// Advance animation timers. Call once per frame with frame delta time.
    pub fn tickAnimations(self: *TextureManager, dt: f32) void {
        self.tick_accumulator += dt;

        // Process accumulated ticks at 20Hz (Minecraft tick rate)
        while (self.tick_accumulator >= TICK_INTERVAL) {
            self.tick_accumulator -= TICK_INTERVAL;
            for (0..self.animation_count) |i| {
                var anim = &self.animations[i];
                anim.sub_frame += 1;
                if (anim.sub_frame >= anim.frametime) {
                    const old_frame = anim.current_frame;
                    anim.current_frame = (anim.current_frame + 1) % anim.frame_count;
                    anim.sub_frame = 0;
                    if (old_frame != anim.current_frame) {
                        anim.dirty = true;
                    }
                }
                // Interpolated textures need upload every tick
                if (anim.interpolate) {
                    anim.dirty = true;
                }
            }
        }
    }

    /// Record animation texture uploads into the given command buffer.
    /// Call at the start of frame recording, before any draw commands.
    pub fn recordAnimationUploads(self: *TextureManager, cmd: vk.VkCommandBuffer) void {
        var any_dirty = false;
        for (0..self.animation_count) |i| {
            if (self.animations[i].dirty) {
                any_dirty = true;
                break;
            }
        }
        if (!any_dirty) return;

        // Write interpolated frame data to staging buffer
        for (0..self.animation_count) |i| {
            var anim = &self.animations[i];
            if (!anim.dirty) continue;

            const staging_offset = i * FRAME_SIZE;
            const dst = self.anim_staging_ptr[staging_offset..][0..FRAME_SIZE];

            const cur_offset = anim.current_frame * FRAME_SIZE;
            const cur_pixels = anim.frame_data[cur_offset..][0..FRAME_SIZE];

            if (anim.interpolate and anim.frame_count > 1) {
                const next_frame = (anim.current_frame + 1) % anim.frame_count;
                const next_offset = next_frame * FRAME_SIZE;
                const next_pixels = anim.frame_data[next_offset..][0..FRAME_SIZE];
                const progress: f32 = @as(f32, @floatFromInt(anim.sub_frame)) /
                    @as(f32, @floatFromInt(anim.frametime));

                // Linear interpolation per component (Minecraft's mix())
                for (0..FRAME_SIZE) |p| {
                    const a: f32 = @floatFromInt(cur_pixels[p]);
                    const b: f32 = @floatFromInt(next_pixels[p]);
                    dst[p] = @intFromFloat(@min(255.0, @max(0.0, a + (b - a) * progress)));
                }
            } else {
                @memcpy(dst, cur_pixels);
            }

            anim.dirty = false;
        }

        // Barrier: SHADER_READ_ONLY → TRANSFER_DST for animated layers
        var barriers: [MAX_ANIMATED_TEXTURES]vk.VkImageMemoryBarrier = undefined;
        var barrier_count: u32 = 0;
        for (0..self.animation_count) |i| {
            barriers[barrier_count] = .{
                .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                .pNext = null,
                .srcAccessMask = vk.VK_ACCESS_SHADER_READ_BIT,
                .dstAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
                .oldLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                .newLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
                .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
                .image = self.texture_image,
                .subresourceRange = .{
                    .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseMipLevel = 0,
                    .levelCount = 1,
                    .baseArrayLayer = self.animations[i].layer_index,
                    .layerCount = 1,
                },
            };
            barrier_count += 1;
        }

        vk.cmdPipelineBarrier(
            cmd,
            vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            0,
            0,
            null,
            0,
            null,
            barrier_count,
            &barriers,
        );

        // Copy from staging buffer to image layers
        var regions: [MAX_ANIMATED_TEXTURES]vk.VkBufferImageCopy = undefined;
        for (0..self.animation_count) |i| {
            regions[i] = .{
                .bufferOffset = @intCast(i * FRAME_SIZE),
                .bufferRowLength = 0,
                .bufferImageHeight = 0,
                .imageSubresource = .{
                    .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                    .mipLevel = 0,
                    .baseArrayLayer = self.animations[i].layer_index,
                    .layerCount = 1,
                },
                .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
                .imageExtent = .{ .width = TEX_W, .height = TEX_H, .depth = 1 },
            };
        }

        vk.cmdCopyBufferToImage(
            cmd,
            self.anim_staging_buffer,
            self.texture_image,
            vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            self.animation_count,
            &regions,
        );

        // Barrier: TRANSFER_DST → SHADER_READ_ONLY
        for (0..barrier_count) |i| {
            barriers[i].srcAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT;
            barriers[i].dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT;
            barriers[i].oldLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
            barriers[i].newLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        }

        vk.cmdPipelineBarrier(
            cmd,
            vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            0,
            0,
            null,
            0,
            null,
            barrier_count,
            &barriers,
        );
    }

    pub fn updateFaceDescriptor(self: *TextureManager, ctx: *const VulkanContext, buffer: vk.VkBuffer, size: vk.VkDeviceSize) void {
        self.updateStorageDescriptor(ctx, 0, buffer, size);
    }

    pub fn updateChunkDataDescriptor(self: *TextureManager, ctx: *const VulkanContext, buffer: vk.VkBuffer, size: vk.VkDeviceSize) void {
        self.updateStorageDescriptor(ctx, 2, buffer, size);
    }

    pub fn updateModelDescriptor(self: *TextureManager, ctx: *const VulkanContext, buffer: vk.VkBuffer, size: vk.VkDeviceSize) void {
        self.updateStorageDescriptor(ctx, 3, buffer, size);
    }

    pub fn updateLightDescriptor(self: *TextureManager, ctx: *const VulkanContext, buffer: vk.VkBuffer, size: vk.VkDeviceSize) void {
        self.updateStorageDescriptor(ctx, 4, buffer, size);
    }

    fn updateStorageDescriptor(self: *TextureManager, ctx: *const VulkanContext, binding: u32, buffer: vk.VkBuffer, size: vk.VkDeviceSize) void {
        const buffer_info = vk.VkDescriptorBufferInfo{
            .buffer = buffer,
            .offset = 0,
            .range = size,
        };

        const descriptor_write = vk.VkWriteDescriptorSet{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = self.bindless_descriptor_set,
            .dstBinding = binding,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = &buffer_info,
            .pTexelBufferView = null,
        };

        vk.updateDescriptorSets(ctx.device, 1, &[_]vk.VkWriteDescriptorSet{descriptor_write}, 0, null);
    }

    fn createAnimationStagingBuffer(self: *TextureManager, ctx: *const VulkanContext) !void {
        if (self.animation_count == 0) return;

        const staging_size: vk.VkDeviceSize = @intCast(self.animation_count * FRAME_SIZE);
        try vk_utils.createBuffer(
            ctx,
            staging_size,
            vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &self.anim_staging_buffer,
            &self.anim_staging_memory,
        );

        var data: ?*anyopaque = null;
        try vk.mapMemory(ctx.device, self.anim_staging_memory, 0, staging_size, 0, &data);
        self.anim_staging_ptr = @ptrCast(data.?);
    }

    fn createTextureImage(self: *TextureManager, allocator: std.mem.Allocator, ctx: *const VulkanContext) !void {
        const tz = tracy.zone(@src(), "createTextureImage");
        defer tz.end();

        const assets_path = try app_config.getAssetsPath(allocator);
        defer allocator.free(assets_path);

        const sep = std.fs.path.sep_str;

        const layer_size: vk.VkDeviceSize = FRAME_SIZE;
        const total_size: vk.VkDeviceSize = layer_size * TOTAL_TEXTURE_COUNT;

        var staging_buffer: vk.VkBuffer = undefined;
        var staging_buffer_memory: vk.VkDeviceMemory = undefined;
        try vk_utils.createBuffer(
            ctx,
            total_size,
            vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &staging_buffer,
            &staging_buffer_memory,
        );
        defer vk.destroyBuffer(ctx.device, staging_buffer, null);
        defer vk.freeMemory(ctx.device, staging_buffer_memory, null);

        var data: ?*anyopaque = null;
        try vk.mapMemory(ctx.device, staging_buffer_memory, 0, total_size, 0, &data);
        const dst: [*]u8 = @ptrCast(data.?);

        self.animation_count = 0;

        for (0..BLOCK_TEXTURE_COUNT) |i| {
            const texture_path = try std.fmt.allocPrintSentinel(allocator, "{s}" ++ sep ++ "textures" ++ sep ++ "block" ++ sep ++ "{s}", .{ assets_path, block_texture_names[i] }, 0);
            defer allocator.free(texture_path);

            var tw: c_int = 0;
            var th: c_int = 0;
            var tc: c_int = 0;
            const pixels = stbi.load(texture_path.ptr, &tw, &th, &tc, 4) orelse {
                std.log.err("Failed to load texture image from {s}", .{texture_path});
                return error.TextureLoadFailed;
            };
            defer stbi.free(pixels);

            // Copy first frame (top 16x16) to staging buffer
            const offset = i * @as(usize, @intCast(layer_size));
            const src: [*]const u8 = @ptrCast(pixels);
            @memcpy(dst[offset..][0..FRAME_SIZE], src[0..FRAME_SIZE]);

            // Check for .mcmeta animation file
            const mcmeta_path = try std.fmt.allocPrintSentinel(allocator, "{s}" ++ sep ++ "textures" ++ sep ++ "block" ++ sep ++ "{s}.mcmeta", .{ assets_path, block_texture_names[i] }, 0);
            defer allocator.free(mcmeta_path);

            const frame_count: u32 = @intCast(@divTrunc(@as(u32, @intCast(th)), @as(u32, @intCast(tw))));
            if (frame_count > 1) {
                if (self.parseMcmeta(allocator, mcmeta_path, @intCast(i), frame_count, src, @intCast(tw), @intCast(th))) {
                    std.log.info("Texture loaded: {s} ({}x{}, {} animation frames)", .{ block_texture_names[i], tw, th, frame_count });
                } else {
                    std.log.info("Texture loaded: {s} ({}x{})", .{ block_texture_names[i], tw, th });
                }
            } else {
                std.log.info("Texture loaded: {s} ({}x{})", .{ block_texture_names[i], tw, th });
            }
        }

        for (0..ITEM_TEXTURE_COUNT) |i| {
            const texture_path = try std.fmt.allocPrintSentinel(allocator, "{s}" ++ sep ++ "textures" ++ sep ++ "item" ++ sep ++ "{s}", .{ assets_path, item_texture_names[i] }, 0);
            defer allocator.free(texture_path);

            var tw: c_int = 0;
            var th: c_int = 0;
            var tc: c_int = 0;
            const pixels = stbi.load(texture_path.ptr, &tw, &th, &tc, 4) orelse {
                std.log.warn("Missing item texture: {s}", .{item_texture_names[i]});
                const offset = (BLOCK_TEXTURE_COUNT + i) * @as(usize, @intCast(layer_size));
                @memset(dst[offset..][0..FRAME_SIZE], 0);
                continue;
            };
            defer stbi.free(pixels);

            const offset = (BLOCK_TEXTURE_COUNT + i) * @as(usize, @intCast(layer_size));
            const src: [*]const u8 = @ptrCast(pixels);
            @memcpy(dst[offset..][0..FRAME_SIZE], src[0..FRAME_SIZE]);
        }

        vk.unmapMemory(ctx.device, staging_buffer_memory);

        const image_info = vk.VkImageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = vk.VK_IMAGE_TYPE_2D,
            .format = vk.VK_FORMAT_R8G8B8A8_UNORM,
            .extent = .{ .width = TEX_W, .height = TEX_H, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = TOTAL_TEXTURE_COUNT,
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
            .usage = vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT | vk.VK_IMAGE_USAGE_SAMPLED_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        };

        self.texture_image = try vk.createImage(ctx.device, &image_info, null);

        var mem_requirements: vk.VkMemoryRequirements = undefined;
        vk.getImageMemoryRequirements(ctx.device, self.texture_image, &mem_requirements);

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

        self.texture_image_memory = try vk.allocateMemory(ctx.device, &alloc_info, null);
        try vk.bindImageMemory(ctx.device, self.texture_image, self.texture_image_memory, 0);

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

        const to_transfer_barrier = vk.VkImageMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = 0,
            .dstAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = self.texture_image,
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = TOTAL_TEXTURE_COUNT,
            },
        };

        vk.cmdPipelineBarrier(
            cmd,
            vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &[_]vk.VkImageMemoryBarrier{to_transfer_barrier},
        );

        var regions: [TOTAL_TEXTURE_COUNT]vk.VkBufferImageCopy = undefined;
        for (0..TOTAL_TEXTURE_COUNT) |i| {
            regions[i] = .{
                .bufferOffset = @intCast(i * @as(usize, @intCast(layer_size))),
                .bufferRowLength = 0,
                .bufferImageHeight = 0,
                .imageSubresource = .{
                    .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                    .mipLevel = 0,
                    .baseArrayLayer = @intCast(i),
                    .layerCount = 1,
                },
                .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
                .imageExtent = .{ .width = TEX_W, .height = TEX_H, .depth = 1 },
            };
        }

        vk.cmdCopyBufferToImage(
            cmd,
            staging_buffer,
            self.texture_image,
            vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            TOTAL_TEXTURE_COUNT,
            &regions,
        );

        const to_shader_barrier = vk.VkImageMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = self.texture_image,
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = TOTAL_TEXTURE_COUNT,
            },
        };

        vk.cmdPipelineBarrier(
            cmd,
            vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &[_]vk.VkImageMemoryBarrier{to_shader_barrier},
        );

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

        const view_info = vk.VkImageViewCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = self.texture_image,
            .viewType = vk.VK_IMAGE_VIEW_TYPE_2D_ARRAY,
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
                .layerCount = TOTAL_TEXTURE_COUNT,
            },
        };

        self.texture_image_view = try vk.createImageView(ctx.device, &view_info, null);

        const sampler_info = vk.VkSamplerCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .magFilter = vk.VK_FILTER_NEAREST,
            .minFilter = vk.VK_FILTER_NEAREST,
            .mipmapMode = vk.VK_SAMPLER_MIPMAP_MODE_NEAREST,
            .addressModeU = vk.VK_SAMPLER_ADDRESS_MODE_REPEAT,
            .addressModeV = vk.VK_SAMPLER_ADDRESS_MODE_REPEAT,
            .addressModeW = vk.VK_SAMPLER_ADDRESS_MODE_REPEAT,
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

        self.texture_sampler = try vk.createSampler(ctx.device, &sampler_info, null);
    }

    /// Try to parse a .mcmeta file and register an animated texture.
    /// Returns true if animation was registered.
    fn parseMcmeta(
        self: *TextureManager,
        allocator: std.mem.Allocator,
        mcmeta_path: [:0]const u8,
        layer_index: u32,
        frame_count: u32,
        pixels: [*]const u8,
        width: u32,
        height: u32,
    ) bool {
        if (self.animation_count >= MAX_ANIMATED_TEXTURES) return false;

        const io = Io.Threaded.global_single_threaded.io();
        const file = Dir.openFileAbsolute(io, mcmeta_path, .{}) catch return false;
        defer file.close(io);

        const stat = file.stat(io) catch return false;
        const mcmeta_data = allocator.alloc(u8, stat.size) catch return false;
        defer allocator.free(mcmeta_data);
        _ = file.readPositionalAll(io, mcmeta_data, 0) catch return false;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, mcmeta_data, .{}) catch return false;
        defer parsed.deinit();

        const anim_obj = (parsed.value.object.get("animation") orelse return false).object;

        var frametime: u32 = 1;
        if (anim_obj.get("frametime")) |ft| {
            frametime = @intCast(@max(1, switch (ft) {
                .integer => |v| v,
                else => 1,
            }));
        }

        var interpolate = false;
        if (anim_obj.get("interpolate")) |interp| {
            interpolate = switch (interp) {
                .bool => |v| v,
                else => false,
            };
        }

        // Store all frame pixel data (each frame is width x width x 4 bytes)
        const total_pixels = frame_count * FRAME_SIZE;
        const frame_data = allocator.alloc(u8, total_pixels) catch return false;

        // Extract each frame from the vertical strip
        const row_bytes = width * 4;
        for (0..frame_count) |f| {
            const frame_dst = frame_data[f * FRAME_SIZE ..][0..FRAME_SIZE];
            const strip_y_start = f * width; // frame f starts at row f*width in the strip
            for (0..width) |row| {
                const src_offset = (strip_y_start + row) * row_bytes;
                const dst_offset = row * row_bytes;
                @memcpy(
                    frame_dst[dst_offset..][0..row_bytes],
                    pixels[src_offset..][0..row_bytes],
                );
            }
        }

        _ = height;

        self.animations[self.animation_count] = .{
            .layer_index = layer_index,
            .frame_count = frame_count,
            .frametime = frametime,
            .interpolate = interpolate,
            .frame_data = frame_data,
            .current_frame = 0,
            .sub_frame = 0,
            .dirty = false,
        };
        self.animation_count += 1;

        std.log.info("Animated texture registered: layer {}, {} frames, frametime={}, interpolate={}", .{
            layer_index, frame_count, frametime, interpolate,
        });

        return true;
    }

    fn createBindlessDescriptorSet(self: *TextureManager, ctx: *const VulkanContext) !void {
        const tz = tracy.zone(@src(), "createBindlessDescriptorSet");
        defer tz.end();

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
            .{
                .binding = 2,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
                .pImmutableSamplers = null,
            },
            .{
                .binding = 3,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
                .pImmutableSamplers = null,
            },
            .{
                .binding = 4,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
                .pImmutableSamplers = null,
            },
        };

        const binding_flags = [_]vk.VkDescriptorBindingFlags{
            vk.VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT,
            vk.VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT,
            vk.VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT,
            vk.VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT,
            vk.VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT,
        };

        const binding_flags_info = vk.VkDescriptorSetLayoutBindingFlagsCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
            .pNext = null,
            .bindingCount = bindings.len,
            .pBindingFlags = &binding_flags,
        };

        const layout_info = vk.VkDescriptorSetLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pNext = &binding_flags_info,
            .flags = vk.VK_DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT,
            .bindingCount = bindings.len,
            .pBindings = &bindings,
        };

        self.bindless_descriptor_set_layout = try vk.createDescriptorSetLayout(ctx.device, &layout_info, null);

        const pool_sizes = [_]vk.VkDescriptorPoolSize{
            .{
                .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 4,
            },
            .{
                .type = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .descriptorCount = 1,
            },
        };

        const pool_info = vk.VkDescriptorPoolCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .pNext = null,
            .flags = vk.VK_DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT,
            .maxSets = 1,
            .poolSizeCount = pool_sizes.len,
            .pPoolSizes = &pool_sizes,
        };

        self.bindless_descriptor_pool = try vk.createDescriptorPool(ctx.device, &pool_info, null);

        const alloc_info = vk.VkDescriptorSetAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = self.bindless_descriptor_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &self.bindless_descriptor_set_layout,
        };

        var descriptor_sets: [1]vk.VkDescriptorSet = undefined;
        try vk.allocateDescriptorSets(ctx.device, &alloc_info, &descriptor_sets);
        self.bindless_descriptor_set = descriptor_sets[0];

        const image_info = vk.VkDescriptorImageInfo{
            .sampler = self.texture_sampler,
            .imageView = self.texture_image_view,
            .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };

        const descriptor_write = vk.VkWriteDescriptorSet{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = self.bindless_descriptor_set,
            .dstBinding = 1,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &image_info,
            .pBufferInfo = null,
            .pTexelBufferView = null,
        };

        vk.updateDescriptorSets(ctx.device, 1, &[_]vk.VkWriteDescriptorSet{descriptor_write}, 0, null);
        std.log.info("Descriptor set created (texture array with {} layers, {} animated)", .{ TOTAL_TEXTURE_COUNT, self.animation_count });
    }
};
