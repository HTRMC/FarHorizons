const std = @import("std");
const vk = @import("../../platform/volk.zig");
const ShaderCompiler = @import("ShaderCompiler.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const zlm = @import("zlm");
const GameState = @import("../../GameState.zig");

pub const BREAK_STAGE_COUNT = 10;
pub const BREAK_TEX_BASE: u32 = 58; // first break texture index in array

const PushConstants = extern struct {
    mvp: [16]f32, // 64 bytes
    tex_layer: i32, // 4 bytes (offset 64)
    _pad: [3]i32 = .{ 0, 0, 0 },
};

pub const BreakRenderer = struct {
    pipeline: vk.VkPipeline,
    pipeline_layout: vk.VkPipelineLayout,
    descriptor_set_layout: vk.VkDescriptorSetLayout,
    descriptor_pool: vk.VkDescriptorPool,
    descriptor_set: vk.VkDescriptorSet,

    pub fn init(
        shader_compiler: *ShaderCompiler,
        ctx: *const VulkanContext,
        swapchain_format: vk.VkFormat,
        block_tex_view: vk.VkImageView,
        block_tex_sampler: vk.VkSampler,
    ) !BreakRenderer {
        var self = BreakRenderer{
            .pipeline = null,
            .pipeline_layout = null,
            .descriptor_set_layout = null,
            .descriptor_pool = null,
            .descriptor_set = null,
        };

        try self.createDescriptorSet(ctx, block_tex_view, block_tex_sampler);
        try self.createPipeline(shader_compiler, ctx, swapchain_format);

        std.log.info("Break overlay renderer initialized", .{});
        return self;
    }

    pub fn deinit(self: *BreakRenderer, device: vk.VkDevice) void {
        vk.destroyPipeline(device, self.pipeline, null);
        vk.destroyPipelineLayout(device, self.pipeline_layout, null);
        vk.destroyDescriptorPool(device, self.descriptor_pool, null);
        vk.destroyDescriptorSetLayout(device, self.descriptor_set_layout, null);
    }

    pub fn recordDraw(
        self: *const BreakRenderer,
        command_buffer: vk.VkCommandBuffer,
        game_state: *const GameState,
        vp: zlm.Mat4,
    ) void {
        if (game_state.combat.break_progress <= 0 or game_state.game_mode == .creative) return;
        const bp = game_state.combat.breaking_pos orelse return;

        // Compute break stage (0-9)
        const stage: u32 = @intFromFloat(@min(game_state.combat.break_progress * BREAK_STAGE_COUNT, BREAK_STAGE_COUNT - 1));
        const tex_layer: i32 = @intCast(BREAK_TEX_BASE + stage);

        // Model matrix: translate to block position with slight expansion to avoid z-fighting
        const bx: f32 = @floatFromInt(bp[0]);
        const by: f32 = @floatFromInt(bp[1]);
        const bz: f32 = @floatFromInt(bp[2]);
        const e: f32 = 0.002; // expansion to prevent z-fighting
        const model = zlm.Mat4{ .m = .{
            1.0 + e * 2, 0,           0,           0,
            0,           1.0 + e * 2, 0,           0,
            0,           0,           1.0 + e * 2, 0,
            bx - e,      by - e,      bz - e,      1,
        } };

        const mvp = zlm.Mat4.mul(vp, model);

        vk.cmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);
        vk.cmdBindDescriptorSets(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline_layout, 0, 1, &[_]vk.VkDescriptorSet{self.descriptor_set}, 0, null);

        const pc = PushConstants{
            .mvp = mvp.m,
            .tex_layer = tex_layer,
        };
        vk.cmdPushConstants(command_buffer, self.pipeline_layout, vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(PushConstants), @ptrCast(&pc));
        vk.cmdDraw(command_buffer, 36, 1, 0, 0); // 6 faces × 6 vertices
    }

    fn createDescriptorSet(self: *BreakRenderer, ctx: *const VulkanContext, block_tex_view: vk.VkImageView, block_tex_sampler: vk.VkSampler) !void {
        const bindings = [_]vk.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT, .pImmutableSamplers = null },
        };
        self.descriptor_set_layout = try vk.createDescriptorSetLayout(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .pNext = null, .flags = 0,
            .bindingCount = 1, .pBindings = &bindings,
        }, null);

        const pool_sizes = [_]vk.VkDescriptorPoolSize{
            .{ .type = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1 },
        };
        self.descriptor_pool = try vk.createDescriptorPool(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .pNext = null, .flags = 0,
            .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &pool_sizes,
        }, null);

        var desc_set: vk.VkDescriptorSet = undefined;
        try vk.allocateDescriptorSets(ctx.device, &.{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .pNext = null,
            .descriptorPool = self.descriptor_pool, .descriptorSetCount = 1,
            .pSetLayouts = &self.descriptor_set_layout,
        }, @ptrCast(&desc_set));
        self.descriptor_set = desc_set;

        const image_info = vk.VkDescriptorImageInfo{
            .sampler = block_tex_sampler,
            .imageView = block_tex_view,
            .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        vk.updateDescriptorSets(ctx.device, 1, &[_]vk.VkWriteDescriptorSet{.{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .pNext = null,
            .dstSet = self.descriptor_set, .dstBinding = 0, .dstArrayElement = 0,
            .descriptorCount = 1, .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &image_info, .pBufferInfo = null, .pTexelBufferView = null,
        }}, 0, null);
    }

    fn createPipeline(self: *BreakRenderer, shader_compiler: *ShaderCompiler, ctx: *const VulkanContext, swapchain_format: vk.VkFormat) !void {
        const device = ctx.device;

        const vert_spirv = try shader_compiler.compile("break_overlay.vert", .vertex);
        defer shader_compiler.allocator.free(vert_spirv);
        const frag_spirv = try shader_compiler.compile("break_overlay.frag", .fragment);
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
        // Depth test yes, depth write no (overlay on existing geometry)
        const depth_stencil = vk.VkPipelineDepthStencilStateCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO, .pNext = null, .flags = 0, .depthTestEnable = vk.VK_TRUE, .depthWriteEnable = vk.VK_FALSE, .depthCompareOp = vk.VK_COMPARE_OP_LESS_OR_EQUAL, .depthBoundsTestEnable = vk.VK_FALSE, .stencilTestEnable = vk.VK_FALSE, .front = std.mem.zeroes(vk.VkStencilOpState), .back = std.mem.zeroes(vk.VkStencilOpState), .minDepthBounds = 0, .maxDepthBounds = 1 };
        // Alpha blending: overlay darkens the block
        const blend_att = vk.VkPipelineColorBlendAttachmentState{
            .blendEnable = vk.VK_TRUE,
            .srcColorBlendFactor = vk.VK_BLEND_FACTOR_SRC_ALPHA,
            .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .colorBlendOp = vk.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ZERO,
            .alphaBlendOp = vk.VK_BLEND_OP_ADD,
            .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT | vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT,
        };
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
    }
};
