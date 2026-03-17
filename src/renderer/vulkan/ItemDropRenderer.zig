const std = @import("std");
const vk = @import("../../platform/volk.zig");
const ShaderCompiler = @import("ShaderCompiler.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const tracy = @import("../../platform/tracy.zig");
const zlm = @import("zlm");
const GameState = @import("../../GameState.zig");
const Entity = GameState.Entity;
const gpu_alloc_mod = @import("../../allocators/GpuAllocator.zig");
const GpuAllocator = gpu_alloc_mod.GpuAllocator;
const BufferAllocation = gpu_alloc_mod.BufferAllocation;

const CUBE_VERTICES = 36;

const CubeVertex = extern struct {
    pos: [3]f32,
    normal: [3]f32,
};

const PushConstants = extern struct {
    mvp: [16]f32,
    color: [4]f32,
    ambient_light: [3]f32,
    _pad: f32 = 0,
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

        try self.createResources(ctx, gpu_alloc);
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

        for (1..gs.entities.count) |i| {
            if (gs.entities.kind[i] != .item_drop) continue;

            const pos = gs.entities.render_pos[i];
            const age_f: f32 = @floatFromInt(gs.entities.age_ticks[i]);
            const spin = age_f * 0.05; // Gentle spin

            // Build model matrix: translate to pos, rotate around Y, scale to 0.25
            const scale: f32 = 0.25;
            const cos_s = @cos(spin);
            const sin_s = @sin(spin);

            // Model = translate * rotateY * scale
            const model = zlm.Mat4{ .m = .{
                cos_s * scale,  0,              sin_s * scale,  0,
                0,              scale,          0,              0,
                -sin_s * scale, 0,              cos_s * scale,  0,
                pos[0],         pos[1],         pos[2],         1,
            } };

            const drop_mvp = zlm.Mat4.mul(mvp, model);
            const color = GameState.blockColor(gs.entities.item_block[i]);

            const pc = PushConstants{
                .mvp = drop_mvp.m,
                .color = color,
                .ambient_light = ambient_light,
            };

            vk.cmdPushConstants(
                command_buffer,
                self.pipeline_layout,
                vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT,
                0,
                @sizeOf(PushConstants),
                @ptrCast(&pc),
            );

            vk.cmdDraw(command_buffer, CUBE_VERTICES, 1, 0, 0);
        }
    }

    fn uploadCubeVertices(self: *ItemDropRenderer) void {
        const vertices: [*]CubeVertex = @ptrCast(@alignCast(self.vertex_alloc.mapped_ptr orelse return));

        // Unit cube centered at origin: [-0.5, 0.5]^3
        // 6 faces * 2 triangles * 3 vertices = 36 vertices
        const faces = [6]struct { normal: [3]f32, verts: [4][3]f32 }{
            // +Y (top)
            .{ .normal = .{ 0, 1, 0 }, .verts = .{ .{ -0.5, 0.5, -0.5 }, .{ -0.5, 0.5, 0.5 }, .{ 0.5, 0.5, 0.5 }, .{ 0.5, 0.5, -0.5 } } },
            // -Y (bottom)
            .{ .normal = .{ 0, -1, 0 }, .verts = .{ .{ -0.5, -0.5, 0.5 }, .{ -0.5, -0.5, -0.5 }, .{ 0.5, -0.5, -0.5 }, .{ 0.5, -0.5, 0.5 } } },
            // +Z (south)
            .{ .normal = .{ 0, 0, 1 }, .verts = .{ .{ -0.5, -0.5, 0.5 }, .{ 0.5, -0.5, 0.5 }, .{ 0.5, 0.5, 0.5 }, .{ -0.5, 0.5, 0.5 } } },
            // -Z (north)
            .{ .normal = .{ 0, 0, -1 }, .verts = .{ .{ 0.5, -0.5, -0.5 }, .{ -0.5, -0.5, -0.5 }, .{ -0.5, 0.5, -0.5 }, .{ 0.5, 0.5, -0.5 } } },
            // +X (east)
            .{ .normal = .{ 1, 0, 0 }, .verts = .{ .{ 0.5, -0.5, 0.5 }, .{ 0.5, -0.5, -0.5 }, .{ 0.5, 0.5, -0.5 }, .{ 0.5, 0.5, 0.5 } } },
            // -X (west)
            .{ .normal = .{ -1, 0, 0 }, .verts = .{ .{ -0.5, -0.5, -0.5 }, .{ -0.5, -0.5, 0.5 }, .{ -0.5, 0.5, 0.5 }, .{ -0.5, 0.5, -0.5 } } },
        };

        var vi: u32 = 0;
        for (faces) |face| {
            // Triangle 1: 0, 1, 2
            vertices[vi] = .{ .pos = face.verts[0], .normal = face.normal };
            vi += 1;
            vertices[vi] = .{ .pos = face.verts[1], .normal = face.normal };
            vi += 1;
            vertices[vi] = .{ .pos = face.verts[2], .normal = face.normal };
            vi += 1;
            // Triangle 2: 0, 2, 3
            vertices[vi] = .{ .pos = face.verts[0], .normal = face.normal };
            vi += 1;
            vertices[vi] = .{ .pos = face.verts[2], .normal = face.normal };
            vi += 1;
            vertices[vi] = .{ .pos = face.verts[3], .normal = face.normal };
            vi += 1;
        }
    }

    fn createResources(self: *ItemDropRenderer, ctx: *const VulkanContext, gpu_alloc: *GpuAllocator) !void {
        const buffer_size: vk.VkDeviceSize = CUBE_VERTICES * @sizeOf(CubeVertex);
        self.vertex_alloc = try gpu_alloc.createBuffer(
            buffer_size,
            vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            .host_visible,
        );

        // Descriptor set layout: one SSBO for the vertex data
        const binding = vk.VkDescriptorSetLayoutBinding{
            .binding = 0,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
            .pImmutableSamplers = null,
        };
        self.descriptor_set_layout = try vk.createDescriptorSetLayout(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .bindingCount = 1,
            .pBindings = &binding,
        }, null);

        // Descriptor pool
        const pool_size = vk.VkDescriptorPoolSize{
            .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
        };
        self.descriptor_pool = try vk.createDescriptorPool(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .maxSets = 1,
            .poolSizeCount = 1,
            .pPoolSizes = &pool_size,
        }, null);

        // Allocate descriptor set
        var set: vk.VkDescriptorSet = undefined;
        try vk.allocateDescriptorSets(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = self.descriptor_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &self.descriptor_set_layout,
        }, @ptrCast(&set));
        self.descriptor_set = set;

        // Write descriptor
        const buf_info = vk.VkDescriptorBufferInfo{
            .buffer = self.vertex_alloc.buffer,
            .offset = 0,
            .range = buffer_size,
        };
        vk.updateDescriptorSets(ctx.device, 1, &[_]vk.VkWriteDescriptorSet{.{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = self.descriptor_set,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = &buf_info,
            .pTexelBufferView = null,
        }}, 0, null);
    }

    fn createPipeline(self: *ItemDropRenderer, shader_compiler: *ShaderCompiler, ctx: *const VulkanContext, swapchain_format: vk.VkFormat) !void {
        const device = ctx.device;

        const vert_spirv = try shader_compiler.compile("item_drop.vert", .vertex);
        defer shader_compiler.allocator.free(vert_spirv);

        const frag_spirv = try shader_compiler.compile("item_drop.frag", .fragment);
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

        const push_range = vk.VkPushConstantRange{
            .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .offset = 0,
            .size = @sizeOf(PushConstants),
        };
        self.pipeline_layout = try vk.createPipelineLayout(device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .pNext = null, .flags = 0,
            .setLayoutCount = 1, .pSetLayouts = &self.descriptor_set_layout,
            .pushConstantRangeCount = 1, .pPushConstantRanges = &push_range,
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
