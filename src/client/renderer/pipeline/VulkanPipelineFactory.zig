// VulkanPipelineFactory - Creates Vulkan pipelines from RenderPipelineConfig
//
// Converts RenderPipelineConfig to actual VkPipeline objects, eliminating
// repeated boilerplate pipeline creation code.

const std = @import("std");
const volk = @import("volk");
const vk = volk.c;
const RenderPipelines = @import("../RenderPipelines.zig");
const RenderPipelineConfig = RenderPipelines.RenderPipelineConfig;

pub const VulkanPipelineFactory = struct {
    const Self = @This();

    device: vk.VkDevice,
    render_pass: vk.VkRenderPass,

    /// Different vertex formats used in the renderer
    pub const VertexFormat = enum {
        /// Standard 3D vertex (pos, color, uv, tex_index)
        standard_3d,
        /// UI/2D vertex (pos, uv)
        ui_2d,
        /// Line vertex (pos, color)
        line_3d,
    };

    /// Parameters for creating a pipeline
    pub const CreateParams = struct {
        /// The pipeline configuration (from RenderPipelines)
        config: RenderPipelineConfig,
        /// Vertex format to use
        vertex_format: VertexFormat,
        /// Descriptor set layout for this pipeline
        descriptor_set_layout: vk.VkDescriptorSetLayout,
        /// Pre-compiled vertex shader SPIR-V code
        vertex_shader_code: []const u8,
        /// Pre-compiled fragment shader SPIR-V code
        fragment_shader_code: []const u8,
        /// Extra dynamic states beyond viewport and scissor
        extra_dynamic_states: []const vk.VkDynamicState = &.{},
        /// Custom color blend attachment (if null, uses config.toColorBlendAttachment())
        custom_blend: ?vk.VkPipelineColorBlendAttachmentState = null,
    };

    /// Result of pipeline creation
    pub const PipelineResult = struct {
        pipeline: vk.VkPipeline,
        layout: vk.VkPipelineLayout,

        pub fn destroy(self: *PipelineResult, device: vk.VkDevice) void {
            const vkDestroyPipeline = vk.vkDestroyPipeline orelse return;
            const vkDestroyPipelineLayout = vk.vkDestroyPipelineLayout orelse return;

            if (self.pipeline != null) {
                vkDestroyPipeline(device, self.pipeline, null);
                self.pipeline = null;
            }
            if (self.layout != null) {
                vkDestroyPipelineLayout(device, self.layout, null);
                self.layout = null;
            }
        }
    };

    pub fn init(device: vk.VkDevice, render_pass: vk.VkRenderPass) Self {
        return .{
            .device = device,
            .render_pass = render_pass,
        };
    }

    /// Create a graphics pipeline from the given parameters
    pub fn create(self: *Self, params: CreateParams) !PipelineResult {
        const vkCreateShaderModule = vk.vkCreateShaderModule orelse return error.VulkanFunctionNotLoaded;
        const vkDestroyShaderModule = vk.vkDestroyShaderModule orelse return error.VulkanFunctionNotLoaded;
        const vkCreatePipelineLayout = vk.vkCreatePipelineLayout orelse return error.VulkanFunctionNotLoaded;
        const vkCreateGraphicsPipelines = vk.vkCreateGraphicsPipelines orelse return error.VulkanFunctionNotLoaded;

        // Create shader modules
        const vert_module = try self.createShaderModule(vkCreateShaderModule, params.vertex_shader_code);
        defer vkDestroyShaderModule(self.device, vert_module, null);

        const frag_module = try self.createShaderModule(vkCreateShaderModule, params.fragment_shader_code);
        defer vkDestroyShaderModule(self.device, frag_module, null);

        // Shader stages
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

        // Dynamic states (always include viewport and scissor)
        var dynamic_states_arr: [8]vk.VkDynamicState = undefined;
        dynamic_states_arr[0] = vk.VK_DYNAMIC_STATE_VIEWPORT;
        dynamic_states_arr[1] = vk.VK_DYNAMIC_STATE_SCISSOR;
        var dynamic_state_count: u32 = 2;

        for (params.extra_dynamic_states) |state| {
            if (dynamic_state_count < dynamic_states_arr.len) {
                dynamic_states_arr[dynamic_state_count] = state;
                dynamic_state_count += 1;
            }
        }

        const dynamic_state = vk.VkPipelineDynamicStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .dynamicStateCount = dynamic_state_count,
            .pDynamicStates = &dynamic_states_arr,
        };

        // Vertex input state based on format
        var vertex_input_info = self.getVertexInputState(params.vertex_format);
        // Build the create info AFTER the struct is in its final location (not a return copy)
        const vertex_input_state = vertex_input_info.toCreateInfo();

        // Use config conversion methods
        const input_assembly = params.config.toInputAssemblyState();
        const rasterizer = params.config.toRasterizationState();
        const depth_stencil = params.config.toDepthStencilState();
        const color_blend_attachment = params.custom_blend orelse params.config.toColorBlendAttachment();

        // Standard viewport state (dynamic)
        const viewport_state = vk.VkPipelineViewportStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .viewportCount = 1,
            .pViewports = null,
            .scissorCount = 1,
            .pScissors = null,
        };

        // Standard multisampling (no MSAA)
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

        // Color blending state
        const color_blending = vk.VkPipelineColorBlendStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .logicOpEnable = vk.VK_FALSE,
            .logicOp = vk.VK_LOGIC_OP_COPY,
            .attachmentCount = 1,
            .pAttachments = &color_blend_attachment,
            .blendConstants = .{ 0.0, 0.0, 0.0, 0.0 },
        };

        // Create pipeline layout
        const descriptor_set_layouts = [_]vk.VkDescriptorSetLayout{params.descriptor_set_layout};
        const pipeline_layout_info = vk.VkPipelineLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 1,
            .pSetLayouts = &descriptor_set_layouts,
            .pushConstantRangeCount = 0,
            .pPushConstantRanges = null,
        };

        var result: PipelineResult = .{
            .pipeline = null,
            .layout = null,
        };

        if (vkCreatePipelineLayout(self.device, &pipeline_layout_info, null, &result.layout) != vk.VK_SUCCESS) {
            return error.PipelineLayoutCreationFailed;
        }
        errdefer if (vk.vkDestroyPipelineLayout) |vkDestroyPipelineLayout_fn| {
            vkDestroyPipelineLayout_fn(self.device, result.layout, null);
        };

        // Create graphics pipeline
        const pipeline_info = vk.VkGraphicsPipelineCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stageCount = shader_stages.len,
            .pStages = &shader_stages,
            .pVertexInputState = &vertex_input_state,
            .pInputAssemblyState = &input_assembly,
            .pTessellationState = null,
            .pViewportState = &viewport_state,
            .pRasterizationState = &rasterizer,
            .pMultisampleState = &multisampling,
            .pDepthStencilState = &depth_stencil,
            .pColorBlendState = &color_blending,
            .pDynamicState = &dynamic_state,
            .layout = result.layout,
            .renderPass = self.render_pass,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };

        if (vkCreateGraphicsPipelines(self.device, null, 1, &pipeline_info, null, &result.pipeline) != vk.VK_SUCCESS) {
            return error.PipelineCreationFailed;
        }

        return result;
    }

    /// Vertex input state with binding and attribute descriptions
    const VertexInputStateWithDescriptions = struct {
        binding: vk.VkVertexInputBindingDescription,
        // Maximum 4 attributes
        attributes: [4]vk.VkVertexInputAttributeDescription,
        attribute_count: u32,

        /// Build the VkPipelineVertexInputStateCreateInfo pointing to this struct's fields.
        /// MUST be called on the final location of the struct (not a temporary).
        fn toCreateInfo(self: *const VertexInputStateWithDescriptions) vk.VkPipelineVertexInputStateCreateInfo {
            return .{
                .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .vertexBindingDescriptionCount = 1,
                .pVertexBindingDescriptions = &self.binding,
                .vertexAttributeDescriptionCount = self.attribute_count,
                .pVertexAttributeDescriptions = &self.attributes,
            };
        }
    };

    fn getVertexInputState(self: *Self, format: VertexFormat) VertexInputStateWithDescriptions {
        _ = self;

        var result: VertexInputStateWithDescriptions = undefined;

        switch (format) {
            .standard_3d => {
                // Vertex: pos[3], color[3], uv[2], tex_index
                result.binding = .{
                    .binding = 0,
                    .stride = @sizeOf(f32) * 3 + @sizeOf(f32) * 3 + @sizeOf(f32) * 2 + @sizeOf(u32),
                    .inputRate = vk.VK_VERTEX_INPUT_RATE_VERTEX,
                };
                result.attributes = .{
                    .{ .binding = 0, .location = 0, .format = vk.VK_FORMAT_R32G32B32_SFLOAT, .offset = 0 },
                    .{ .binding = 0, .location = 1, .format = vk.VK_FORMAT_R32G32B32_SFLOAT, .offset = @sizeOf(f32) * 3 },
                    .{ .binding = 0, .location = 2, .format = vk.VK_FORMAT_R32G32_SFLOAT, .offset = @sizeOf(f32) * 6 },
                    .{ .binding = 0, .location = 3, .format = vk.VK_FORMAT_R32_UINT, .offset = @sizeOf(f32) * 8 },
                };
                result.attribute_count = 4;
            },
            .ui_2d => {
                // UIVertex: pos[2], uv[2]
                result.binding = .{
                    .binding = 0,
                    .stride = @sizeOf(f32) * 4,
                    .inputRate = vk.VK_VERTEX_INPUT_RATE_VERTEX,
                };
                result.attributes = .{
                    .{ .binding = 0, .location = 0, .format = vk.VK_FORMAT_R32G32_SFLOAT, .offset = 0 },
                    .{ .binding = 0, .location = 1, .format = vk.VK_FORMAT_R32G32_SFLOAT, .offset = @sizeOf(f32) * 2 },
                    undefined,
                    undefined,
                };
                result.attribute_count = 2;
            },
            .line_3d => {
                // LineVertex: pos[3], color[4]
                result.binding = .{
                    .binding = 0,
                    .stride = @sizeOf(f32) * 7,
                    .inputRate = vk.VK_VERTEX_INPUT_RATE_VERTEX,
                };
                result.attributes = .{
                    .{ .binding = 0, .location = 0, .format = vk.VK_FORMAT_R32G32B32_SFLOAT, .offset = 0 },
                    .{ .binding = 0, .location = 1, .format = vk.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = @sizeOf(f32) * 3 },
                    undefined,
                    undefined,
                };
                result.attribute_count = 2;
            },
        }

        return result;
    }

    fn createShaderModule(self: *Self, vkCreateShaderModule_fn: anytype, code: []const u8) !vk.VkShaderModule {
        const create_info = vk.VkShaderModuleCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = code.len,
            .pCode = @ptrCast(@alignCast(code.ptr)),
        };

        var shader_module: vk.VkShaderModule = null;
        if (vkCreateShaderModule_fn(self.device, &create_info, null, &shader_module) != vk.VK_SUCCESS) {
            return error.ShaderModuleCreationFailed;
        }
        return shader_module;
    }
};
