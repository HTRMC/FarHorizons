const std = @import("std");
const vk = @import("../../platform/volk.zig");
const c = @import("../../platform/c.zig").c;
const ShaderCompiler = @import("ShaderCompiler.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const vk_utils = @import("vk_utils.zig");
const types = @import("types.zig");
const LineVertex = types.LineVertex;
const tracy = @import("../../platform/tracy.zig");

const DEBUG_LINE_MAX_VERTICES = 16384;

pub const DebugLines = struct {
    pipeline: vk.VkPipeline,
    pipeline_layout: vk.VkPipelineLayout,
    compute_pipeline: vk.VkPipeline,
    compute_pipeline_layout: vk.VkPipelineLayout,
    descriptor_set_layout: vk.VkDescriptorSetLayout,
    descriptor_pool: vk.VkDescriptorPool,
    descriptor_set: vk.VkDescriptorSet,
    compute_descriptor_set_layout: vk.VkDescriptorSetLayout,
    compute_descriptor_pool: vk.VkDescriptorPool,
    compute_descriptor_set: vk.VkDescriptorSet,
    vertex_buffer: vk.VkBuffer,
    vertex_buffer_memory: vk.VkDeviceMemory,
    indirect_buffer: vk.VkBuffer,
    indirect_buffer_memory: vk.VkDeviceMemory,
    count_buffer: vk.VkBuffer,
    count_buffer_memory: vk.VkDeviceMemory,
    vertex_count: u32,

    pub fn init(shader_compiler: *ShaderCompiler, ctx: *const VulkanContext, swapchain_format: vk.VkFormat) !DebugLines {
        const tz = tracy.zone(@src(), "DebugLines.init");
        defer tz.end();

        var self = DebugLines{
            .pipeline = null,
            .pipeline_layout = null,
            .compute_pipeline = null,
            .compute_pipeline_layout = null,
            .descriptor_set_layout = null,
            .descriptor_pool = null,
            .descriptor_set = null,
            .compute_descriptor_set_layout = null,
            .compute_descriptor_pool = null,
            .compute_descriptor_set = null,
            .vertex_buffer = null,
            .vertex_buffer_memory = null,
            .indirect_buffer = null,
            .indirect_buffer_memory = null,
            .count_buffer = null,
            .count_buffer_memory = null,
            .vertex_count = 0,
        };

        try self.createResources(ctx);
        try self.createPipeline(shader_compiler, ctx.device, swapchain_format);
        try self.createComputePipeline(shader_compiler, ctx);

        return self;
    }

    pub fn deinit(self: *DebugLines, device: vk.VkDevice) void {
        vk.destroyPipeline(device, self.compute_pipeline, null);
        vk.destroyPipelineLayout(device, self.compute_pipeline_layout, null);
        vk.destroyDescriptorPool(device, self.compute_descriptor_pool, null);
        vk.destroyDescriptorSetLayout(device, self.compute_descriptor_set_layout, null);
        vk.destroyPipeline(device, self.pipeline, null);
        vk.destroyPipelineLayout(device, self.pipeline_layout, null);
        vk.destroyDescriptorPool(device, self.descriptor_pool, null);
        vk.destroyDescriptorSetLayout(device, self.descriptor_set_layout, null);
        vk.destroyBuffer(device, self.vertex_buffer, null);
        vk.freeMemory(device, self.vertex_buffer_memory, null);
        vk.destroyBuffer(device, self.indirect_buffer, null);
        vk.freeMemory(device, self.indirect_buffer_memory, null);
        vk.destroyBuffer(device, self.count_buffer, null);
        vk.freeMemory(device, self.count_buffer_memory, null);
    }

    fn createResources(self: *DebugLines, ctx: *const VulkanContext) !void {
        const tz = tracy.zone(@src(), "createDebugLineResources");
        defer tz.end();

        // Vertex SSBO (host-visible for CPU writes)
        const vertex_buffer_size: vk.VkDeviceSize = DEBUG_LINE_MAX_VERTICES * @sizeOf(LineVertex);
        try vk_utils.createBuffer(
            ctx,
            vertex_buffer_size,
            vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &self.vertex_buffer,
            &self.vertex_buffer_memory,
        );

        // Indirect draw buffer (device-local, written by compute)
        try vk_utils.createBuffer(
            ctx,
            @sizeOf(vk.VkDrawIndirectCommand),
            vk.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT | vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            &self.indirect_buffer,
            &self.indirect_buffer_memory,
        );

        // Count buffer (host-visible, always 1)
        try vk_utils.createBuffer(
            ctx,
            @sizeOf(u32),
            vk.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &self.count_buffer,
            &self.count_buffer_memory,
        );
        {
            var data: ?*anyopaque = null;
            try vk.mapMemory(ctx.device, self.count_buffer_memory, 0, @sizeOf(u32), 0, &data);
            const count_ptr: *u32 = @ptrCast(@alignCast(data));
            count_ptr.* = 1;
            vk.unmapMemory(ctx.device, self.count_buffer_memory);
        }

        // Graphics descriptor set (binding 0 = vertex SSBO)
        {
            const binding = vk.VkDescriptorSetLayoutBinding{
                .binding = 0,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
                .pImmutableSamplers = null,
            };

            const layout_info = vk.VkDescriptorSetLayoutCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .bindingCount = 1,
                .pBindings = &binding,
            };

            self.descriptor_set_layout = try vk.createDescriptorSetLayout(ctx.device, &layout_info, null);

            const pool_size = vk.VkDescriptorPoolSize{
                .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1,
            };

            const pool_info = vk.VkDescriptorPoolCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .maxSets = 1,
                .poolSizeCount = 1,
                .pPoolSizes = &pool_size,
            };

            self.descriptor_pool = try vk.createDescriptorPool(ctx.device, &pool_info, null);

            const alloc_info = vk.VkDescriptorSetAllocateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
                .pNext = null,
                .descriptorPool = self.descriptor_pool,
                .descriptorSetCount = 1,
                .pSetLayouts = &self.descriptor_set_layout,
            };

            var sets: [1]vk.VkDescriptorSet = undefined;
            try vk.allocateDescriptorSets(ctx.device, &alloc_info, &sets);
            self.descriptor_set = sets[0];

            const buffer_info = vk.VkDescriptorBufferInfo{
                .buffer = self.vertex_buffer,
                .offset = 0,
                .range = vertex_buffer_size,
            };

            const write = vk.VkWriteDescriptorSet{
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
            };

            vk.updateDescriptorSets(ctx.device, 1, &[_]vk.VkWriteDescriptorSet{write}, 0, null);
        }

        // Compute descriptor set (binding 0 = indirect draw command SSBO)
        {
            const binding = vk.VkDescriptorSetLayoutBinding{
                .binding = 0,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_COMPUTE_BIT,
                .pImmutableSamplers = null,
            };

            const layout_info = vk.VkDescriptorSetLayoutCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .bindingCount = 1,
                .pBindings = &binding,
            };

            self.compute_descriptor_set_layout = try vk.createDescriptorSetLayout(ctx.device, &layout_info, null);

            const pool_size = vk.VkDescriptorPoolSize{
                .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1,
            };

            const pool_info = vk.VkDescriptorPoolCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .maxSets = 1,
                .poolSizeCount = 1,
                .pPoolSizes = &pool_size,
            };

            self.compute_descriptor_pool = try vk.createDescriptorPool(ctx.device, &pool_info, null);

            const alloc_info = vk.VkDescriptorSetAllocateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
                .pNext = null,
                .descriptorPool = self.compute_descriptor_pool,
                .descriptorSetCount = 1,
                .pSetLayouts = &self.compute_descriptor_set_layout,
            };

            var sets: [1]vk.VkDescriptorSet = undefined;
            try vk.allocateDescriptorSets(ctx.device, &alloc_info, &sets);
            self.compute_descriptor_set = sets[0];

            const buffer_info = vk.VkDescriptorBufferInfo{
                .buffer = self.indirect_buffer,
                .offset = 0,
                .range = @sizeOf(vk.VkDrawIndirectCommand),
            };

            const write = vk.VkWriteDescriptorSet{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = self.compute_descriptor_set,
                .dstBinding = 0,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .pImageInfo = null,
                .pBufferInfo = &buffer_info,
                .pTexelBufferView = null,
            };

            vk.updateDescriptorSets(ctx.device, 1, &[_]vk.VkWriteDescriptorSet{write}, 0, null);
        }

        // Fill vertex buffer with chunk outlines
        self.generateChunkOutlines(ctx.device);

        std.log.info("Debug line resources created ({} vertices)", .{self.vertex_count});
    }

    fn generateChunkOutlines(self: *DebugLines, device: vk.VkDevice) void {
        const tz = tracy.zone(@src(), "generateChunkOutlines");
        defer tz.end();

        var data: ?*anyopaque = null;
        vk.mapMemory(device, self.vertex_buffer_memory, 0, DEBUG_LINE_MAX_VERTICES * @sizeOf(LineVertex), 0, &data) catch return;
        const vertices: [*]LineVertex = @ptrCast(@alignCast(data));

        var count: u32 = 0;

        // World axis lines (64 units each, from origin)
        // X axis - red
        vertices[count] = .{ .px = 0.0, .py = 0.0, .pz = 0.0, .r = 1.0, .g = 0.0, .b = 0.0, .a = 1.0 };
        count += 1;
        vertices[count] = .{ .px = 64.0, .py = 0.0, .pz = 0.0, .r = 1.0, .g = 0.0, .b = 0.0, .a = 1.0 };
        count += 1;
        // Y axis - green
        vertices[count] = .{ .px = 0.0, .py = 0.0, .pz = 0.0, .r = 0.0, .g = 1.0, .b = 0.0, .a = 1.0 };
        count += 1;
        vertices[count] = .{ .px = 0.0, .py = 64.0, .pz = 0.0, .r = 0.0, .g = 1.0, .b = 0.0, .a = 1.0 };
        count += 1;
        // Z axis - blue
        vertices[count] = .{ .px = 0.0, .py = 0.0, .pz = 0.0, .r = 0.0, .g = 0.0, .b = 1.0, .a = 1.0 };
        count += 1;
        vertices[count] = .{ .px = 0.0, .py = 0.0, .pz = 64.0, .r = 0.0, .g = 0.0, .b = 1.0, .a = 1.0 };
        count += 1;

        vk.unmapMemory(device, self.vertex_buffer_memory);
        self.vertex_count = count;
    }

    fn createPipeline(self: *DebugLines, shader_compiler: *ShaderCompiler, device: vk.VkDevice, swapchain_format: vk.VkFormat) !void {
        const tz = tracy.zone(@src(), "createDebugLinePipeline");
        defer tz.end();

        const vert_spirv = try shader_compiler.compile("debug_line.vert", .vertex);
        defer shader_compiler.allocator.free(vert_spirv);

        const frag_spirv = try shader_compiler.compile("debug_line.frag", .fragment);
        defer shader_compiler.allocator.free(frag_spirv);

        const vert_module_info = vk.VkShaderModuleCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = vert_spirv.len,
            .pCode = @ptrCast(@alignCast(vert_spirv.ptr)),
        };

        const frag_module_info = vk.VkShaderModuleCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = frag_spirv.len,
            .pCode = @ptrCast(@alignCast(frag_spirv.ptr)),
        };

        const vert_module = try vk.createShaderModule(device, &vert_module_info, null);
        defer vk.destroyShaderModule(device, vert_module, null);

        const frag_module = try vk.createShaderModule(device, &frag_module_info, null);
        defer vk.destroyShaderModule(device, frag_module, null);

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
            .topology = vk.VK_PRIMITIVE_TOPOLOGY_LINE_LIST,
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
            .depthTestEnable = vk.VK_TRUE,
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
            .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ZERO,
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
            .size = 64, // sizeof(mat4)
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

        self.pipeline_layout = try vk.createPipelineLayout(device, &pipeline_layout_info, null);

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
        try vk.createGraphicsPipelines(device, null, 1, &[_]vk.VkGraphicsPipelineCreateInfo{pipeline_info}, null, &pipelines);
        self.pipeline = pipelines[0];

        std.log.info("Debug line graphics pipeline created", .{});
    }

    fn createComputePipeline(self: *DebugLines, shader_compiler: *ShaderCompiler, ctx: *const VulkanContext) !void {
        const tz = tracy.zone(@src(), "createDebugLineComputePipeline");
        defer tz.end();

        const comp_spirv = try shader_compiler.compile("debug_line_indirect.comp", .compute);
        defer shader_compiler.allocator.free(comp_spirv);

        const comp_module_info = vk.VkShaderModuleCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = comp_spirv.len,
            .pCode = @ptrCast(@alignCast(comp_spirv.ptr)),
        };

        const comp_module = try vk.createShaderModule(ctx.device, &comp_module_info, null);
        defer vk.destroyShaderModule(ctx.device, comp_module, null);

        const push_constant_range = vk.VkPushConstantRange{
            .stageFlags = vk.VK_SHADER_STAGE_COMPUTE_BIT,
            .offset = 0,
            .size = @sizeOf(u32),
        };

        const compute_layout_info = vk.VkPipelineLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 1,
            .pSetLayouts = &self.compute_descriptor_set_layout,
            .pushConstantRangeCount = 1,
            .pPushConstantRanges = &push_constant_range,
        };

        self.compute_pipeline_layout = try vk.createPipelineLayout(ctx.device, &compute_layout_info, null);

        const compute_stage_info = vk.VkPipelineShaderStageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = vk.VK_SHADER_STAGE_COMPUTE_BIT,
            .module = comp_module,
            .pName = "main",
            .pSpecializationInfo = null,
        };

        const compute_pipeline_info = vk.VkComputePipelineCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = compute_stage_info,
            .layout = self.compute_pipeline_layout,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };

        var pipelines: [1]vk.VkPipeline = undefined;
        try vk.createComputePipelines(ctx.device, null, 1, &[_]vk.VkComputePipelineCreateInfo{compute_pipeline_info}, null, &pipelines);
        self.compute_pipeline = pipelines[0];

        std.log.info("Debug line compute pipeline created", .{});
    }
};
