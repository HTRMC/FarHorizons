const std = @import("std");
const vk = @import("../../platform/volk.zig");
const ShaderCompiler = @import("ShaderCompiler.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const zlm = @import("zlm");
const GameState = @import("../../GameState.zig");
const Entity = GameState.Entity;
const WorldState = @import("../../world/WorldState.zig");
const BlockState = WorldState.BlockState;
const EntityRenderer = @import("EntityRenderer.zig");
const EntityVertex = EntityRenderer.EntityVertex;
const gpu_alloc_mod = @import("../../allocators/GpuAllocator.zig");
const GpuAllocator = gpu_alloc_mod.GpuAllocator;
const BufferAllocation = gpu_alloc_mod.BufferAllocation;

const CUBE_VERTICES = 36;
// Layout: 24 side verts (4 faces) then 12 top/bottom verts (2 faces)
const SIDE_VERTS = 24;
const TOPBOT_VERTS = 12;
// Extra space after cube for shaped block quads (up to 64 faces × 6 verts)
const MAX_SHAPE_VERTS = 64 * 6;
const TOTAL_BUFFER_VERTS = CUBE_VERTICES + MAX_SHAPE_VERTS;

const PushConstants = extern struct {
    mvp: [16]f32, // 64 bytes
    tex_layer: i32, // 4 bytes (offset 64)
    contrast: f32, // 4 bytes (offset 68)
    _pad0: i32 = 0, // 4 bytes
    _pad1: i32 = 0, // 4 bytes
    ambient_light: [3]f32, // 12 bytes (offset 80)
    sky_level: f32, // 4 bytes (offset 92)
    block_light: [3]f32, // 12 bytes (offset 96)
    _pad2: f32 = 0, // 4 bytes (offset 108)
};

pub const ItemDropRenderer = struct {
    pipeline: vk.VkPipeline,
    pipeline_layout: vk.VkPipelineLayout,
    descriptor_set_layout: vk.VkDescriptorSetLayout,
    descriptor_pool: vk.VkDescriptorPool,
    descriptor_set: vk.VkDescriptorSet,
    vertex_alloc: BufferAllocation,
    gpu_alloc: *GpuAllocator,

    pub fn init(
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
            .vertex_alloc = undefined,
            .gpu_alloc = gpu_alloc,
        };

        try self.createResources(ctx, gpu_alloc, block_tex_view, block_tex_sampler);
        try self.createPipeline(shader_compiler, ctx, swapchain_format);
        self.uploadCubeVertices();

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
        gs: *const GameState,
        mvp: zlm.Mat4,
        ambient_light: [3]f32,
        sun_dir: [3]f32,
    ) void {
        // Count item drops
        var drop_count: u32 = 0;
        for (1..gs.entities.count) |i| {
            if (gs.entities.kind[i] == .item_drop) drop_count += 1;
        }
        if (drop_count == 0) return;

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

        for (1..gs.entities.count) |i| {
            if (gs.entities.kind[i] != .item_drop) continue;

            const pos = gs.entities.render_pos[i];
            const age_f: f32 = @floatFromInt(gs.entities.age_ticks[i]);
            const bob_offset = gs.entities.bob_offset[i];

            const bob = @sin(age_f * 0.1 + bob_offset) * 0.05 + 0.0625;
            const spin = age_f / 20.0 + bob_offset;

            const item_block = gs.entities.item_block[i];
            const display_state = BlockState.getDisplayState(item_block);
            const is_shaped = BlockState.isShaped(display_state);
            const item_count = gs.entities.item_count[i];

            // Shaped blocks (torch, ladder, etc.) get a larger scale since their
            // model geometry is already smaller than a full cube
            const scale: f32 = if (is_shaped) 0.35 else 0.25;

            const cos_s = @cos(spin);
            const sin_s = @sin(spin);

            // Sample light at drop position
            const center_y = pos[1] + bob + scale * 0.5;
            const light = gs.sampleLightAt(pos[0], center_y, pos[2]);
            const block_light = [3]f32{ light[0], light[1], light[2] };
            const sky_level = light[3];

            // Number of copies to render based on stack count (Minecraft-style)
            const render_count: u32 = if (item_count <= 1) 1 else if (item_count <= 16) 2 else if (item_count <= 32) 3 else if (item_count <= 48) 4 else 5;

            // Deterministic offsets for stacked copies using a simple hash
            var seed: u32 = @as(u32, @bitCast(@as(i32, @intFromFloat(pos[0] * 100.0)))) +% @as(u32, @bitCast(@as(i32, @intFromFloat(pos[2] * 100.0)))) *% 7;

            for (0..render_count) |copy| {
                var ox: f32 = 0;
                var oy: f32 = 0;
                var oz: f32 = 0;
                if (copy > 0) {
                    // Random-ish offsets for extra copies (±0.15 * scale)
                    ox = hashFloat(&seed) * 0.15 * scale;
                    oy = hashFloat(&seed) * 0.15 * scale;
                    oz = hashFloat(&seed) * 0.15 * scale;
                }

                const model = zlm.Mat4{ .m = .{
                    cos_s * scale,  0,                 sin_s * scale,  0,
                    0,              scale,             0,              0,
                    -sin_s * scale, 0,                 cos_s * scale,  0,
                    pos[0] + ox,    center_y + oy,     pos[2] + oz,    1,
                } };

                const drop_mvp = zlm.Mat4.mul(mvp, model);

                if (BlockState.isShaped(display_state)) {
                    self.drawShapedDrop(command_buffer, drop_mvp, ambient_light, sky_level, block_light, contrast, display_state);
                } else {
                    self.drawCubeDrop(command_buffer, drop_mvp, ambient_light, sky_level, block_light, contrast, item_block);
                }
            }
        }
    }

    /// Simple hash to generate deterministic float in [-1, 1] from a seed.
    fn hashFloat(seed: *u32) f32 {
        seed.* = seed.* *% 1103515245 +% 12345;
        const bits: i32 = @bitCast(seed.* >> 16);
        return @as(f32, @floatFromInt(@mod(bits, 200) - 100)) / 100.0;
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

        // Draw 4 side faces with side texture
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

        // Draw top + bottom with top texture
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

        // Write shaped model vertices into buffer after the cube
        var vert_count: u32 = CUBE_VERTICES;

        // Track runs of consecutive faces with the same texture for batched draws
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
                    continue; // water models 6-11, skip
                }
            } else {
                const em = WorldState.getRegistry().extra_models[@as(usize, mi) - WorldState.EXTRA_MODEL_BASE];
                corners = em.corners;
                uvs = em.uvs;
                normal = em.normal;
            }

            // Skip cross quads for torch (diagonal flames look bad as a tiny spinning item)
            if (is_torch) {
                if (@abs(normal[0]) > 0.1 and @abs(normal[2]) > 0.1) continue;
            }

            if (vert_count + 6 > TOTAL_BUFFER_VERTS) break;

            const face_tex: u8 = if (sf_idx < tex_indices.len) tex_indices[sf_idx] else 0;

            // Center the model: shift from [0,1] to [-0.5,0.5]
            const base = EntityVertex{ .px = 0, .py = 0, .pz = 0, .nx = normal[0], .ny = normal[1], .nz = normal[2], .u = 0, .v = 0 };
            var va = base;
            va.px = corners[0][0] - 0.5; va.py = corners[0][1] - 0.5; va.pz = corners[0][2] - 0.5;
            va.u = uvs[0][0]; va.v = uvs[0][1];
            var vb = base;
            vb.px = corners[1][0] - 0.5; vb.py = corners[1][1] - 0.5; vb.pz = corners[1][2] - 0.5;
            vb.u = uvs[1][0]; vb.v = uvs[1][1];
            var vc = base;
            vc.px = corners[2][0] - 0.5; vc.py = corners[2][1] - 0.5; vc.pz = corners[2][2] - 0.5;
            vc.u = uvs[2][0]; vc.v = uvs[2][1];
            var vd = base;
            vd.px = corners[3][0] - 0.5; vd.py = corners[3][1] - 0.5; vd.pz = corners[3][2] - 0.5;
            vd.u = uvs[3][0]; vd.v = uvs[3][1];

            vertices[vert_count + 0] = va;
            vertices[vert_count + 1] = vb;
            vertices[vert_count + 2] = vc;
            vertices[vert_count + 3] = va;
            vertices[vert_count + 4] = vc;
            vertices[vert_count + 5] = vd;

            // Try to extend the current run if same texture
            if (run_count > 0 and runs[run_count - 1].tex == face_tex) {
                runs[run_count - 1].count += 6;
            } else {
                if (run_count >= 64) break;
                runs[run_count] = .{ .start = vert_count, .count = 6, .tex = face_tex };
                run_count += 1;
            }

            vert_count += 6;
        }

        // Issue draw calls per texture run
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

    fn uploadCubeVertices(self: *ItemDropRenderer) void {
        const vertices: [*]EntityVertex = @ptrCast(@alignCast(self.vertex_alloc.mapped_ptr orelse return));

        const s: f32 = 0.5;
        var count: u32 = 0;

        // Side faces first (24 verts): front, back, right, left
        count = addQuad(vertices, count, -s, -s, s, s, -s, s, s, s, s, -s, s, s, 0, 0, 1); // +Z
        count = addQuad(vertices, count, s, -s, -s, -s, -s, -s, -s, s, -s, s, s, -s, 0, 0, -1); // -Z
        count = addQuad(vertices, count, s, -s, s, s, -s, -s, s, s, -s, s, s, s, 1, 0, 0); // +X
        count = addQuad(vertices, count, -s, -s, -s, -s, -s, s, -s, s, s, -s, s, -s, -1, 0, 0); // -X
        // Top/bottom faces (12 verts)
        count = addQuad(vertices, count, -s, s, s, s, s, s, s, s, -s, -s, s, -s, 0, 1, 0); // +Y
        _ = addQuad(vertices, count, -s, -s, -s, s, -s, -s, s, -s, s, -s, -s, s, 0, -1, 0); // -Y
    }

    fn addQuad(
        vertices: [*]EntityVertex,
        start: u32,
        x0: f32, y0: f32, z0: f32,
        x1: f32, y1: f32, z1: f32,
        x2: f32, y2: f32, z2: f32,
        x3: f32, y3: f32, z3: f32,
        nx: f32, ny: f32, nz: f32,
    ) u32 {
        const base = EntityVertex{ .px = 0, .py = 0, .pz = 0, .nx = nx, .ny = ny, .nz = nz, .u = 0, .v = 0 };

        var va = base;
        va.px = x0; va.py = y0; va.pz = z0; va.u = 0; va.v = 1;
        var vb = base;
        vb.px = x1; vb.py = y1; vb.pz = z1; vb.u = 1; vb.v = 1;
        var vc = base;
        vc.px = x2; vc.py = y2; vc.pz = z2; vc.u = 1; vc.v = 0;
        var vd = base;
        vd.px = x3; vd.py = y3; vd.pz = z3; vd.u = 0; vd.v = 0;

        // Triangle 1: a, b, c
        vertices[start + 0] = va;
        vertices[start + 1] = vb;
        vertices[start + 2] = vc;
        // Triangle 2: a, c, d
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

        // Descriptor set layout: SSBO + block texture array
        const bindings = [_]vk.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT, .pImmutableSamplers = null },
            .{ .binding = 1, .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT, .pImmutableSamplers = null },
        };
        self.descriptor_set_layout = try vk.createDescriptorSetLayout(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .pNext = null, .flags = 0,
            .bindingCount = 2, .pBindings = &bindings,
        }, null);

        // Descriptor pool
        const pool_sizes = [_]vk.VkDescriptorPoolSize{
            .{ .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1 },
            .{ .type = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1 },
        };
        self.descriptor_pool = try vk.createDescriptorPool(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .pNext = null, .flags = 0,
            .maxSets = 1, .poolSizeCount = 2, .pPoolSizes = &pool_sizes,
        }, null);

        // Allocate descriptor set
        var set: vk.VkDescriptorSet = undefined;
        try vk.allocateDescriptorSets(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .pNext = null,
            .descriptorPool = self.descriptor_pool, .descriptorSetCount = 1,
            .pSetLayouts = &self.descriptor_set_layout,
        }, @ptrCast(&set));
        self.descriptor_set = set;

        // Write descriptors
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
        const rasterizer = vk.VkPipelineRasterizationStateCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO, .pNext = null, .flags = 0, .depthClampEnable = vk.VK_FALSE, .rasterizerDiscardEnable = vk.VK_FALSE, .polygonMode = vk.VK_POLYGON_MODE_FILL, .cullMode = vk.VK_CULL_MODE_NONE, .frontFace = vk.VK_FRONT_FACE_COUNTER_CLOCKWISE, .depthBiasEnable = vk.VK_FALSE, .depthBiasConstantFactor = 0, .depthBiasClamp = 0, .depthBiasSlopeFactor = 0, .lineWidth = 1 };
        const multisampling = vk.VkPipelineMultisampleStateCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, .pNext = null, .flags = 0, .rasterizationSamples = vk.VK_SAMPLE_COUNT_1_BIT, .sampleShadingEnable = vk.VK_FALSE, .minSampleShading = 1, .pSampleMask = null, .alphaToCoverageEnable = vk.VK_FALSE, .alphaToOneEnable = vk.VK_FALSE };
        const depth_stencil = vk.VkPipelineDepthStencilStateCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO, .pNext = null, .flags = 0, .depthTestEnable = vk.VK_TRUE, .depthWriteEnable = vk.VK_TRUE, .depthCompareOp = vk.VK_COMPARE_OP_LESS, .depthBoundsTestEnable = vk.VK_FALSE, .stencilTestEnable = vk.VK_FALSE, .front = std.mem.zeroes(vk.VkStencilOpState), .back = std.mem.zeroes(vk.VkStencilOpState), .minDepthBounds = 0, .maxDepthBounds = 1 };
        const blend_att = vk.VkPipelineColorBlendAttachmentState{ .blendEnable = vk.VK_FALSE, .srcColorBlendFactor = vk.VK_BLEND_FACTOR_ONE, .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ZERO, .colorBlendOp = vk.VK_BLEND_OP_ADD, .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE, .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ZERO, .alphaBlendOp = vk.VK_BLEND_OP_ADD, .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT | vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT };
        const color_blending = vk.VkPipelineColorBlendStateCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .pNext = null, .flags = 0, .logicOpEnable = vk.VK_FALSE, .logicOp = 0, .attachmentCount = 1, .pAttachments = &blend_att, .blendConstants = .{ 0, 0, 0, 0 } };

        const push_ranges = [_]vk.VkPushConstantRange{
            .{ .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT, .offset = 0, .size = 64 },
            .{ .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT, .offset = 64, .size = @sizeOf(PushConstants) - 64 },
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

        std.log.info("Item drop pipeline created", .{});
    }
};
