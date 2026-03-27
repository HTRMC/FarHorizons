const std = @import("std");
const vk = @import("../../platform/volk.zig");
const ShaderCompiler = @import("ShaderCompiler.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const zlm = @import("zlm");
const GameState = @import("../../world/GameState.zig");
const Entity = GameState.Entity;
const Item = @import("../../world/item/Item.zig");
const WorldState = @import("../../world/WorldState.zig");
const BlockState = WorldState.BlockState;
const EntityRenderer = @import("EntityRenderer.zig");
const EntityVertex = EntityRenderer.EntityVertex;
const gpu_alloc_mod = @import("../../allocators/GpuAllocator.zig");
const GpuAllocator = gpu_alloc_mod.GpuAllocator;
const BufferAllocation = gpu_alloc_mod.BufferAllocation;
const TextureManager = @import("TextureManager.zig");
const stbi = @import("../../platform/stb_image.zig");
const app_config = @import("../../app_config.zig");

const CUBE_VERTICES = 36;
const SIDE_VERTS = 24;
const TOPBOT_VERTS = 12;
const MAX_SHAPE_VERTS = 64 * 6;
// Max verts per item mesh: 16x16 texture, worst case ~256 pixel spans × 2 faces + ~128 edges
const MAX_ITEM_MESH_VERTS = 1500;
const ITEM_TEXTURE_COUNT = 26;
const MAX_TOTAL_ITEM_VERTS = ITEM_TEXTURE_COUNT * MAX_ITEM_MESH_VERTS;
const TOTAL_BUFFER_VERTS = CUBE_VERTICES + MAX_TOTAL_ITEM_VERTS + MAX_SHAPE_VERTS;

const PushConstants = extern struct {
    mvp: [16]f32,
    tex_layer: i32,
    contrast: f32,
    _pad0: i32 = 0,
    _pad1: i32 = 0,
    ambient_light: [3]f32,
    sky_level: f32,
    block_light: [3]f32,
    _pad2: f32 = 0,
};

const ItemMesh = struct {
    start: u32,
    count: u32,
};

pub const ItemDropRenderer = struct {
    pipeline: vk.VkPipeline,
    pipeline_layout: vk.VkPipelineLayout,
    descriptor_set_layout: vk.VkDescriptorSetLayout,
    descriptor_pool: vk.VkDescriptorPool,
    descriptor_set: vk.VkDescriptorSet,
    vertex_alloc: BufferAllocation,
    gpu_alloc: *GpuAllocator,
    item_meshes: [ITEM_TEXTURE_COUNT]ItemMesh,
    shaped_vert_start: u32,

    pub fn init(
        allocator: std.mem.Allocator,
        shader_compiler: *ShaderCompiler,
        ctx: *const VulkanContext,
        swapchain_format: vk.VkFormat,
        gpu_alloc: *GpuAllocator,
        block_tex_view: vk.VkImageView,
        block_tex_sampler: vk.VkSampler,
    ) !ItemDropRenderer {
        var self = ItemDropRenderer{
            .pipeline = null,
            .pipeline_layout = null,
            .descriptor_set_layout = null,
            .descriptor_pool = null,
            .descriptor_set = null,
            .vertex_alloc = BufferAllocation.EMPTY,
            .gpu_alloc = gpu_alloc,
            .item_meshes = [_]ItemMesh{.{ .start = 0, .count = 0 }} ** ITEM_TEXTURE_COUNT,
            .shaped_vert_start = CUBE_VERTICES,
        };

        try self.createResources(ctx, gpu_alloc, block_tex_view, block_tex_sampler);
        try self.createPipeline(shader_compiler, ctx, swapchain_format);
        self.uploadCubeVertices();
        self.generateItemMeshes(allocator);

        return self;
    }

    pub fn deinit(self: *ItemDropRenderer, device: vk.VkDevice) void {
        vk.destroyPipeline(device, self.pipeline, null);
        vk.destroyPipelineLayout(device, self.pipeline_layout, null);
        vk.destroyDescriptorPool(device, self.descriptor_pool, null);
        vk.destroyDescriptorSetLayout(device, self.descriptor_set_layout, null);
        self.gpu_alloc.destroyBuffer(self.vertex_alloc);
    }

    pub fn recordDraw(
        self: *const ItemDropRenderer,
        command_buffer: vk.VkCommandBuffer,
        game_state: *const GameState,
        mvp: zlm.Mat4,
        ambient_light: [3]f32,
        sun_dir: [3]f32,
    ) void {
        var has_work = false;
        for (1..game_state.entities.count) |i| {
            if (game_state.entities.kind[i] == .item_drop) {
                has_work = true;
                break;
            }
        }
        if (!has_work) {
            for (game_state.inv.pickup_ghosts) |ghost| {
                if (ghost.active) {
                    has_work = true;
                    break;
                }
            }
        }
        if (!has_work) return;

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

        _ = sun_dir;
        const contrast: f32 = 0.0;

        // Draw live item drops
        for (1..game_state.entities.count) |i| {
            if (game_state.entities.kind[i] != .item_drop) continue;

            const pos = game_state.entities.render_pos[i];
            const age_f: f32 = @floatFromInt(game_state.entities.age_ticks[i]);
            const bob_offset = game_state.entities.bob_offset[i];

            const bob = @sin(age_f * 0.1 + bob_offset) * 0.05 + 0.0625;
            const spin = age_f / 20.0 + bob_offset;

            const item_block = game_state.entities.item_block[i];
            const item_mesh_idx = getItemMeshIndex(item_block);
            const is_flat = item_mesh_idx != null;
            const display_state = if (!is_flat) BlockState.getDisplayState(item_block) else 0;
            const is_shaped = if (!is_flat) BlockState.isShaped(display_state) else false;
            const item_count = game_state.entities.item_count[i];

            const scale: f32 = if (is_flat) 0.35 else if (is_shaped) 0.35 else 0.25;

            const cos_s = @cos(spin);
            const sin_s = @sin(spin);

            const center_y = pos[1] + bob + scale * 0.5;
            const light = game_state.sampleLightAt(pos[0], center_y, pos[2]);
            const block_light = light.block;
            const sky_level = light.sky;

            const render_count: u32 = if (item_count <= 1) 1 else if (item_count <= 16) 2 else if (item_count <= 32) 3 else if (item_count <= 48) 4 else 5;

            var seed: u32 = @as(u32, @bitCast(bob_offset)) *% 2654435761;

            for (0..render_count) |copy| {
                var ox: f32 = 0;
                var oy: f32 = 0;
                var oz: f32 = 0;
                if (copy > 0) {
                    if (is_flat) {
                        // Flat items: stack like a deck of cards along Z with small XY jitter
                        const layer_spacing: f32 = 0.0625 * 1.5; // model_depth * 1.5
                        const rc_f: f32 = @floatFromInt(render_count);
                        const copy_f: f32 = @floatFromInt(copy);
                        oz = (copy_f - (rc_f - 1.0) * 0.5) * layer_spacing;
                        ox = hashFloat(&seed) * 0.075 * scale;
                        oy = hashFloat(&seed) * 0.075 * scale;
                    } else {
                        ox = hashFloat(&seed) * 0.15 * scale;
                        oy = hashFloat(&seed) * 0.15 * scale;
                        oz = hashFloat(&seed) * 0.15 * scale;
                    }
                }

                const model = zlm.Mat4{ .m = .{
                    cos_s * scale,  0,             sin_s * scale, 0,
                    0,              scale,         0,             0,
                    -sin_s * scale, 0,             cos_s * scale, 0,
                    pos[0] + ox,    center_y + oy, pos[2] + oz,   1,
                } };

                const drop_mvp = zlm.Mat4.mul(mvp, model);

                if (item_mesh_idx) |idx| {
                    self.drawItemDrop(command_buffer, drop_mvp, ambient_light, sky_level, block_light, contrast, idx);
                } else if (is_shaped) {
                    self.drawShapedDrop(command_buffer, drop_mvp, ambient_light, sky_level, block_light, contrast, display_state);
                } else {
                    self.drawCubeDrop(command_buffer, drop_mvp, ambient_light, sky_level, block_light, contrast, item_block);
                }
            }
        }

        // Draw pickup ghost animations (items flying to player)
        const player_pos = game_state.entities.render_pos[0];
        const player_target = [3]f32{ player_pos[0], player_pos[1] + 0.9, player_pos[2] };

        for (game_state.inv.pickup_ghosts) |ghost| {
            if (!ghost.active) continue;

            const t: f32 = (@as(f32, @floatFromInt(ghost.tick)) + game_state.render_alpha) / 3.0;
            const eased = t * t;

            const gx = ghost.start_pos[0] + (player_target[0] - ghost.start_pos[0]) * eased;
            const gy = ghost.start_pos[1] + (player_target[1] - ghost.start_pos[1]) * eased;
            const gz = ghost.start_pos[2] + (player_target[2] - ghost.start_pos[2]) * eased;

            const ghost_mesh_idx = getItemMeshIndex(ghost.block);
            const ghost_is_flat = ghost_mesh_idx != null;
            const display_state = if (!ghost_is_flat) BlockState.getDisplayState(ghost.block) else 0;
            const is_shaped = if (!ghost_is_flat) BlockState.isShaped(display_state) else false;
            const scale: f32 = (if (ghost_is_flat) @as(f32, 0.35) else if (is_shaped) @as(f32, 0.35) else @as(f32, 0.25)) * (1.0 - eased * 0.5);

            const age_f: f32 = @floatFromInt(ghost.age_ticks);
            const spin = age_f / 20.0 + ghost.bob_offset;
            const cos_s = @cos(spin);
            const sin_s = @sin(spin);

            const light = game_state.sampleLightAt(gx, gy, gz);
            const block_light = light.block;
            const sky_level = light.sky;

            const model = zlm.Mat4{ .m = .{
                cos_s * scale,  0,     sin_s * scale, 0,
                0,              scale, 0,             0,
                -sin_s * scale, 0,     cos_s * scale, 0,
                gx,             gy,    gz,            1,
            } };

            const drop_mvp = zlm.Mat4.mul(mvp, model);

            if (ghost_mesh_idx) |idx| {
                self.drawItemDrop(command_buffer, drop_mvp, ambient_light, sky_level, block_light, contrast, idx);
            } else if (is_shaped) {
                self.drawShapedDrop(command_buffer, drop_mvp, ambient_light, sky_level, block_light, contrast, display_state);
            } else {
                self.drawCubeDrop(command_buffer, drop_mvp, ambient_light, sky_level, block_light, contrast, ghost.block);
            }
        }
    }

    fn hashFloat(seed: *u32) f32 {
        seed.* = seed.* *% 1103515245 +% 12345;
        const bits: i32 = @bitCast(seed.* >> 16);
        return @as(f32, @floatFromInt(@mod(bits, 200) - 100)) / 100.0;
    }

    fn getItemMeshIndex(item_block: BlockState.StateId) ?usize {
        if (Item.isToolItem(item_block)) {
            const info = Item.toolFromId(item_block) orelse return null;
            return @as(usize, @intFromEnum(info.tier)) * 5 + @intFromEnum(info.tool_type);
        }
        if (BlockState.getBlock(item_block) == .stick) {
            return 25; // stick is last item texture
        }
        return null;
    }

    fn drawCubeDrop(
        self: *const ItemDropRenderer,
        command_buffer: vk.VkCommandBuffer,
        drop_mvp: zlm.Mat4,
        ambient_light: [3]f32,
        sky_level: f32,
        block_light: [3]f32,
        contrast: f32,
        item_block: BlockState.StateId,
    ) void {
        const tex = BlockState.blockTexIndices(item_block);

        const pc_side = PushConstants{
            .mvp = drop_mvp.m,
            .tex_layer = tex.side,
            .contrast = contrast,
            .ambient_light = ambient_light,
            .sky_level = sky_level,
            .block_light = block_light,
        };
        vk.cmdPushConstants(command_buffer, self.pipeline_layout, vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(PushConstants), @ptrCast(&pc_side));
        vk.cmdDraw(command_buffer, SIDE_VERTS, 1, 0, 0);

        const pc_top = PushConstants{
            .mvp = drop_mvp.m,
            .tex_layer = tex.top,
            .contrast = contrast,
            .ambient_light = ambient_light,
            .sky_level = sky_level,
            .block_light = block_light,
        };
        vk.cmdPushConstants(command_buffer, self.pipeline_layout, vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(PushConstants), @ptrCast(&pc_top));
        vk.cmdDraw(command_buffer, TOPBOT_VERTS, 1, SIDE_VERTS, 0);
    }

    fn drawItemDrop(
        self: *const ItemDropRenderer,
        command_buffer: vk.VkCommandBuffer,
        drop_mvp: zlm.Mat4,
        ambient_light: [3]f32,
        sky_level: f32,
        block_light: [3]f32,
        contrast: f32,
        mesh_idx: usize,
    ) void {
        const mesh = self.item_meshes[mesh_idx];
        if (mesh.count == 0) return;

        const tex_layer: i32 = @intCast(TextureManager.ITEM_TEXTURE_BASE + mesh_idx);
        const pc = PushConstants{
            .mvp = drop_mvp.m,
            .tex_layer = tex_layer,
            .contrast = contrast,
            .ambient_light = ambient_light,
            .sky_level = sky_level,
            .block_light = block_light,
        };
        vk.cmdPushConstants(command_buffer, self.pipeline_layout, vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(PushConstants), @ptrCast(&pc));
        vk.cmdDraw(command_buffer, mesh.count, 1, mesh.start, 0);
    }

    fn drawShapedDrop(
        self: *const ItemDropRenderer,
        command_buffer: vk.VkCommandBuffer,
        drop_mvp: zlm.Mat4,
        ambient_light: [3]f32,
        sky_level: f32,
        block_light: [3]f32,
        contrast: f32,
        display_state: BlockState.StateId,
    ) void {
        const vertices: [*]EntityVertex = @ptrCast(@alignCast(self.vertex_alloc.mapped_ptr orelse return));

        const shape_faces = WorldState.getShapeFaces(display_state);
        const tex_indices = WorldState.getShapedTexIndices(display_state);
        if (shape_faces.len == 0) return;

        const block = BlockState.getBlock(display_state);
        const is_torch = block == .torch;

        var vert_count: u32 = self.shaped_vert_start;

        const RunInfo = struct { start: u32, count: u32, tex: u8 };
        var runs: [64]RunInfo = undefined;
        var run_count: usize = 0;

        for (shape_faces, 0..) |sf, sf_idx| {
            const mi = sf.model_index;
            var corners: [4][3]f32 = undefined;
            var uvs: [4][2]f32 = undefined;
            var normal: [3]f32 = undefined;

            if (mi < WorldState.EXTRA_MODEL_BASE) {
                if (mi < 6) {
                    const n = WorldState.face_neighbor_offsets[mi];
                    normal = .{ @floatFromInt(n[0]), @floatFromInt(n[1]), @floatFromInt(n[2]) };
                    for (0..4) |ci| {
                        const fv = WorldState.face_vertices[mi][ci];
                        corners[ci] = .{ fv.px, fv.py, fv.pz };
                        uvs[ci] = .{ fv.u, fv.v };
                    }
                } else {
                    continue;
                }
            } else {
                const em = WorldState.getRegistry().extra_models[@as(usize, mi) - WorldState.EXTRA_MODEL_BASE];
                corners = em.corners;
                uvs = em.uvs;
                normal = em.normal;
            }

            if (is_torch) {
                if (@abs(normal[0]) > 0.1 and @abs(normal[2]) > 0.1) continue;
            }

            if (vert_count + 6 > TOTAL_BUFFER_VERTS) break;

            const face_tex: u8 = if (sf_idx < tex_indices.len) tex_indices[sf_idx] else 0;

            const base = EntityVertex{ .px = 0, .py = 0, .pz = 0, .nx = normal[0], .ny = normal[1], .nz = normal[2], .u = 0, .v = 0 };
            var va = base;
            va.px = corners[0][0] - 0.5;
            va.py = corners[0][1] - 0.5;
            va.pz = corners[0][2] - 0.5;
            va.u = uvs[0][0];
            va.v = uvs[0][1];
            var vb = base;
            vb.px = corners[1][0] - 0.5;
            vb.py = corners[1][1] - 0.5;
            vb.pz = corners[1][2] - 0.5;
            vb.u = uvs[1][0];
            vb.v = uvs[1][1];
            var vc = base;
            vc.px = corners[2][0] - 0.5;
            vc.py = corners[2][1] - 0.5;
            vc.pz = corners[2][2] - 0.5;
            vc.u = uvs[2][0];
            vc.v = uvs[2][1];
            var vd = base;
            vd.px = corners[3][0] - 0.5;
            vd.py = corners[3][1] - 0.5;
            vd.pz = corners[3][2] - 0.5;
            vd.u = uvs[3][0];
            vd.v = uvs[3][1];

            vertices[vert_count + 0] = va;
            vertices[vert_count + 1] = vb;
            vertices[vert_count + 2] = vc;
            vertices[vert_count + 3] = va;
            vertices[vert_count + 4] = vc;
            vertices[vert_count + 5] = vd;

            if (run_count > 0 and runs[run_count - 1].tex == face_tex) {
                runs[run_count - 1].count += 6;
            } else {
                if (run_count >= 64) break;
                runs[run_count] = .{ .start = vert_count, .count = 6, .tex = face_tex };
                run_count += 1;
            }

            vert_count += 6;
        }

        for (0..run_count) |r| {
            const pc = PushConstants{
                .mvp = drop_mvp.m,
                .tex_layer = @intCast(runs[r].tex),
                .contrast = contrast,
                .ambient_light = ambient_light,
                .sky_level = sky_level,
                .block_light = block_light,
            };
            vk.cmdPushConstants(command_buffer, self.pipeline_layout, vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(PushConstants), @ptrCast(&pc));
            vk.cmdDraw(command_buffer, runs[r].count, 1, runs[r].start, 0);
        }
    }

    // ---- Mesh generation from item textures (MC ItemModelGenerator style) ----

    fn generateItemMeshes(self: *ItemDropRenderer, allocator: std.mem.Allocator) void {
        const vertices: [*]EntityVertex = @ptrCast(@alignCast(self.vertex_alloc.mapped_ptr orelse return));

        const sep = std.fs.path.sep_str;
        const assets_path = app_config.getAssetsPath(allocator) catch return;
        defer allocator.free(assets_path);

        var vert_offset: u32 = CUBE_VERTICES;

        const item_texture_names = [ITEM_TEXTURE_COUNT][]const u8{
            "wooden_pickaxe.png",  "wooden_axe.png",  "wooden_shovel.png",  "wooden_sword.png",  "wooden_hoe.png",
            "stone_pickaxe.png",   "stone_axe.png",   "stone_shovel.png",   "stone_sword.png",   "stone_hoe.png",
            "iron_pickaxe.png",    "iron_axe.png",    "iron_shovel.png",    "iron_sword.png",    "iron_hoe.png",
            "gold_pickaxe.png",    "gold_axe.png",    "gold_shovel.png",    "gold_sword.png",    "gold_hoe.png",
            "diamond_pickaxe.png", "diamond_axe.png", "diamond_shovel.png", "diamond_sword.png", "diamond_hoe.png",
            "stick.png",
        };

        for (0..ITEM_TEXTURE_COUNT) |i| {
            const texture_path = std.fmt.allocPrintSentinel(allocator, "{s}" ++ sep ++ "textures" ++ sep ++ "item" ++ sep ++ "{s}", .{ assets_path, item_texture_names[i] }, 0) catch continue;
            defer allocator.free(texture_path);

            var tw: c_int = 0;
            var th: c_int = 0;
            var tc: c_int = 0;
            const pixels = stbi.load(texture_path.ptr, &tw, &th, &tc, 4) orelse {
                std.log.warn("Item mesh: missing texture {s}", .{item_texture_names[i]});
                continue;
            };
            defer stbi.free(pixels);

            if (tw != 16 or th != 16) {
                std.log.warn("Item mesh: {s} is {d}x{d}, expected 16x16", .{ item_texture_names[i], tw, th });
                continue;
            }

            const start = vert_offset;
            vert_offset = generateMeshFromTexture(vertices, vert_offset, pixels);
            self.item_meshes[i] = .{ .start = start, .count = vert_offset - start };
        }

        self.shaped_vert_start = vert_offset;
        std.log.info("Item meshes generated: {d} vertices for {d} items", .{ vert_offset - CUBE_VERTICES, ITEM_TEXTURE_COUNT });
    }

    pub fn generateMeshFromTexture(vertices: [*]EntityVertex, start: u32, pixels: [*]const u8) u32 {
        var count = start;
        const px_size: f32 = 1.0 / 16.0;
        const depth: f32 = 0.5 / 16.0; // half-pixel thick, total 1/16

        // MC approach: single full-texture front/back faces.
        // Transparent pixels handled by alpha discard in fragment shader.
        // No expansion or indent needed — eliminates z-fighting.
        if (count + 12 > TOTAL_BUFFER_VERTS) return count;

        const h: f32 = 0.5;
        // Front face (+Z) — full texture quad
        count = emitQuad(vertices, count, .{ -h, -h, depth }, .{ h, -h, depth }, .{ h, h, depth }, .{ -h, h, depth }, .{ 0, 0, 1 }, .{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } });

        // Back face (-Z) — mirrored UVs
        count = emitQuad(vertices, count, .{ h, -h, -depth }, .{ -h, -h, -depth }, .{ -h, h, -depth }, .{ h, h, -depth }, .{ 0, 0, -1 }, .{ .{ 1, 1 }, .{ 0, 1 }, .{ 0, 0 }, .{ 1, 0 } });

        // Build opacity grid for side edge detection
        var is_opaque: [16][16]bool = undefined;
        for (0..16) |py| {
            for (0..16) |px| {
                const idx = (py * 16 + px) * 4;
                is_opaque[py][px] = pixels[idx + 3] > 6;
            }
        }

        // Side edges: per-pixel quads at transparency boundaries (MC approach)
        // Extend Z slightly past front/back faces to close seam gaps (T-junction fix).
        // No XY expansion — sides stay at exact pixel boundaries.
        const depth_ext: f32 = depth + 0.001;
        for (0..16) |py| {
            for (0..16) |px| {
                if (!is_opaque[py][px]) continue;

                const sx0: f32 = @as(f32, @floatFromInt(px)) * px_size - 0.5;
                const sx1: f32 = sx0 + px_size;
                const sy0: f32 = @as(f32, @floatFromInt(15 - py)) * px_size - 0.5;
                const sy1: f32 = sy0 + px_size;

                // UV with shrink to avoid nearest-neighbor boundary artifacts (MC UV_SHRINK=0.1)
                const su0: f32 = (@as(f32, @floatFromInt(px)) + 0.1) / 16.0;
                const su1: f32 = (@as(f32, @floatFromInt(px)) + 0.9) / 16.0;
                const sv0: f32 = (@as(f32, @floatFromInt(py)) + 0.1) / 16.0;
                const sv1: f32 = (@as(f32, @floatFromInt(py)) + 0.9) / 16.0;
                // Top edge (py-1 is transparent or OOB)
                if (py == 0 or !is_opaque[py - 1][px]) {
                    if (count + 6 > TOTAL_BUFFER_VERTS) return count;
                    count = emitQuad(vertices, count, .{ sx0, sy1, depth_ext }, .{ sx1, sy1, depth_ext }, .{ sx1, sy1, -depth_ext }, .{ sx0, sy1, -depth_ext }, .{ 0, 1, 0 }, .{ .{ su0, sv0 }, .{ su1, sv0 }, .{ su1, sv1 }, .{ su0, sv1 } });
                }

                // Bottom edge (py+1 is transparent or OOB)
                if (py == 15 or !is_opaque[py + 1][px]) {
                    if (count + 6 > TOTAL_BUFFER_VERTS) return count;
                    count = emitQuad(vertices, count, .{ sx0, sy0, -depth_ext }, .{ sx1, sy0, -depth_ext }, .{ sx1, sy0, depth_ext }, .{ sx0, sy0, depth_ext }, .{ 0, -1, 0 }, .{ .{ su0, sv1 }, .{ su1, sv1 }, .{ su1, sv0 }, .{ su0, sv0 } });
                }

                // Left edge (px-1 is transparent or OOB)
                if (px == 0 or !is_opaque[py][px - 1]) {
                    if (count + 6 > TOTAL_BUFFER_VERTS) return count;
                    count = emitQuad(vertices, count, .{ sx0, sy0, -depth_ext }, .{ sx0, sy0, depth_ext }, .{ sx0, sy1, depth_ext }, .{ sx0, sy1, -depth_ext }, .{ -1, 0, 0 }, .{ .{ su0, sv1 }, .{ su0, sv0 }, .{ su1, sv0 }, .{ su1, sv1 } });
                }

                // Right edge (px+1 is transparent or OOB)
                if (px == 15 or !is_opaque[py][px + 1]) {
                    if (count + 6 > TOTAL_BUFFER_VERTS) return count;
                    count = emitQuad(vertices, count, .{ sx1, sy0, depth_ext }, .{ sx1, sy0, -depth_ext }, .{ sx1, sy1, -depth_ext }, .{ sx1, sy1, depth_ext }, .{ 1, 0, 0 }, .{ .{ su1, sv1 }, .{ su1, sv0 }, .{ su0, sv0 }, .{ su0, sv1 } });
                }
            }
        }

        return count;
    }

    pub fn emitQuad(
        vertices: [*]EntityVertex,
        start: u32,
        p0: [3]f32,
        p1: [3]f32,
        p2: [3]f32,
        p3: [3]f32,
        n: [3]f32,
        uvs: [4][2]f32,
    ) u32 {
        const base = EntityVertex{ .px = 0, .py = 0, .pz = 0, .nx = n[0], .ny = n[1], .nz = n[2], .u = 0, .v = 0 };
        var va = base;
        va.px = p0[0];
        va.py = p0[1];
        va.pz = p0[2];
        va.u = uvs[0][0];
        va.v = uvs[0][1];
        var vb = base;
        vb.px = p1[0];
        vb.py = p1[1];
        vb.pz = p1[2];
        vb.u = uvs[1][0];
        vb.v = uvs[1][1];
        var vc = base;
        vc.px = p2[0];
        vc.py = p2[1];
        vc.pz = p2[2];
        vc.u = uvs[2][0];
        vc.v = uvs[2][1];
        var vd = base;
        vd.px = p3[0];
        vd.py = p3[1];
        vd.pz = p3[2];
        vd.u = uvs[3][0];
        vd.v = uvs[3][1];
        vertices[start + 0] = va;
        vertices[start + 1] = vb;
        vertices[start + 2] = vc;
        vertices[start + 3] = va;
        vertices[start + 4] = vc;
        vertices[start + 5] = vd;
        return start + 6;
    }

    fn uploadCubeVertices(self: *ItemDropRenderer) void {
        const vertices: [*]EntityVertex = @ptrCast(@alignCast(self.vertex_alloc.mapped_ptr orelse return));

        const s: f32 = 0.5;
        var count: u32 = 0;

        // Side faces first (24 verts): front, back, right, left
        count = addCubeQuad(vertices, count, -s, -s, s, s, -s, s, s, s, s, -s, s, s, 0, 0, 1);
        count = addCubeQuad(vertices, count, s, -s, -s, -s, -s, -s, -s, s, -s, s, s, -s, 0, 0, -1);
        count = addCubeQuad(vertices, count, s, -s, s, s, -s, -s, s, s, -s, s, s, s, 1, 0, 0);
        count = addCubeQuad(vertices, count, -s, -s, -s, -s, -s, s, -s, s, s, -s, s, -s, -1, 0, 0);
        // Top/bottom (12 verts)
        count = addCubeQuad(vertices, count, -s, s, s, s, s, s, s, s, -s, -s, s, -s, 0, 1, 0);
        _ = addCubeQuad(vertices, count, -s, -s, -s, s, -s, -s, s, -s, s, -s, -s, s, 0, -1, 0);
    }

    fn addCubeQuad(
        vertices: [*]EntityVertex,
        start: u32,
        x0: f32,
        y0: f32,
        z0: f32,
        x1: f32,
        y1: f32,
        z1: f32,
        x2: f32,
        y2: f32,
        z2: f32,
        x3: f32,
        y3: f32,
        z3: f32,
        nx: f32,
        ny: f32,
        nz: f32,
    ) u32 {
        const base = EntityVertex{ .px = 0, .py = 0, .pz = 0, .nx = nx, .ny = ny, .nz = nz, .u = 0, .v = 0 };
        var va = base;
        va.px = x0;
        va.py = y0;
        va.pz = z0;
        va.u = 0;
        va.v = 1;
        var vb = base;
        vb.px = x1;
        vb.py = y1;
        vb.pz = z1;
        vb.u = 1;
        vb.v = 1;
        var vc = base;
        vc.px = x2;
        vc.py = y2;
        vc.pz = z2;
        vc.u = 1;
        vc.v = 0;
        var vd = base;
        vd.px = x3;
        vd.py = y3;
        vd.pz = z3;
        vd.u = 0;
        vd.v = 0;
        vertices[start + 0] = va;
        vertices[start + 1] = vb;
        vertices[start + 2] = vc;
        vertices[start + 3] = va;
        vertices[start + 4] = vc;
        vertices[start + 5] = vd;
        return start + 6;
    }

    fn createResources(self: *ItemDropRenderer, ctx: *const VulkanContext, gpu_alloc: *GpuAllocator, block_tex_view: vk.VkImageView, block_tex_sampler: vk.VkSampler) !void {
        const buffer_size: vk.VkDeviceSize = TOTAL_BUFFER_VERTS * @sizeOf(EntityVertex);
        self.vertex_alloc = try gpu_alloc.createBuffer(
            buffer_size,
            vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            .host_visible,
        );

        const bindings = [_]vk.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT, .pImmutableSamplers = null },
            .{ .binding = 1, .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT, .pImmutableSamplers = null },
        };
        self.descriptor_set_layout = try vk.createDescriptorSetLayout(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .bindingCount = 2,
            .pBindings = &bindings,
        }, null);

        const pool_sizes = [_]vk.VkDescriptorPoolSize{
            .{ .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1 },
            .{ .type = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1 },
        };
        self.descriptor_pool = try vk.createDescriptorPool(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .maxSets = 1,
            .poolSizeCount = 2,
            .pPoolSizes = &pool_sizes,
        }, null);

        var set: vk.VkDescriptorSet = undefined;
        try vk.allocateDescriptorSets(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = self.descriptor_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &self.descriptor_set_layout,
        }, @ptrCast(&set));
        self.descriptor_set = set;

        const buf_info = vk.VkDescriptorBufferInfo{ .buffer = self.vertex_alloc.buffer, .offset = 0, .range = buffer_size };
        const tex_info = vk.VkDescriptorImageInfo{
            .sampler = block_tex_sampler,
            .imageView = block_tex_view,
            .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        vk.updateDescriptorSets(ctx.device, 2, &[_]vk.VkWriteDescriptorSet{
            .{ .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .pNext = null, .dstSet = self.descriptor_set, .dstBinding = 0, .dstArrayElement = 0, .descriptorCount = 1, .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pImageInfo = null, .pBufferInfo = &buf_info, .pTexelBufferView = null },
            .{ .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .pNext = null, .dstSet = self.descriptor_set, .dstBinding = 1, .dstArrayElement = 0, .descriptorCount = 1, .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &tex_info, .pBufferInfo = null, .pTexelBufferView = null },
        }, 0, null);
    }

    fn createPipeline(self: *ItemDropRenderer, shader_compiler: *ShaderCompiler, ctx: *const VulkanContext, swapchain_format: vk.VkFormat) !void {
        const device = ctx.device;

        const vert_spirv = try shader_compiler.compile("item_drop.vert", .vertex);
        defer shader_compiler.allocator.free(vert_spirv);
        const frag_spirv = try shader_compiler.compile("item_drop.frag", .fragment);
        defer shader_compiler.allocator.free(frag_spirv);

        const vert_module = try vk.createShaderModule(device, &vk.VkShaderModuleCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .pNext = null, .flags = 0, .codeSize = vert_spirv.len, .pCode = @ptrCast(@alignCast(vert_spirv.ptr)) }, null);
        defer vk.destroyShaderModule(device, vert_module, null);
        const frag_module = try vk.createShaderModule(device, &vk.VkShaderModuleCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .pNext = null, .flags = 0, .codeSize = frag_spirv.len, .pCode = @ptrCast(@alignCast(frag_spirv.ptr)) }, null);
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
            .{ .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT, .offset = 0, .size = 64 },
            .{ .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT, .offset = 64, .size = @sizeOf(PushConstants) - 64 },
        };
        self.pipeline_layout = try vk.createPipelineLayout(device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 1,
            .pSetLayouts = &self.descriptor_set_layout,
            .pushConstantRangeCount = 2,
            .pPushConstantRanges = &push_ranges,
        }, null);

        const color_fmt = [_]vk.VkFormat{swapchain_format};
        const rendering_info = vk.VkPipelineRenderingCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO, .pNext = null, .viewMask = 0, .colorAttachmentCount = 1, .pColorAttachmentFormats = &color_fmt, .depthAttachmentFormat = vk.VK_FORMAT_D32_SFLOAT, .stencilAttachmentFormat = vk.VK_FORMAT_UNDEFINED };
        const dyn_states = [_]vk.VkDynamicState{ vk.VK_DYNAMIC_STATE_VIEWPORT, vk.VK_DYNAMIC_STATE_SCISSOR };
        const dyn_info = vk.VkPipelineDynamicStateCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO, .pNext = null, .flags = 0, .dynamicStateCount = 2, .pDynamicStates = &dyn_states };

        const pipeline_info = vk.VkGraphicsPipelineCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = &rendering_info,
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
            .pDynamicState = @ptrCast(&dyn_info),
            .layout = self.pipeline_layout,
            .renderPass = null,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };

        var pipeline: vk.VkPipeline = undefined;
        try vk.createGraphicsPipelines(device, null, 1, &[_]vk.VkGraphicsPipelineCreateInfo{pipeline_info}, null, @ptrCast(&pipeline));
        self.pipeline = pipeline;

        std.log.info("Item drop pipeline created", .{});
    }
};
