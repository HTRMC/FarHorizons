const std = @import("std");
const vk = @import("../../platform/volk.zig");
const c = @import("../../platform/c.zig").c;
const ShaderCompiler = @import("ShaderCompiler.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const vk_utils = @import("vk_utils.zig");
const types = @import("types.zig");
const UiVertex = types.UiVertex;
const tracy = @import("../../platform/tracy.zig");

const MAX_QUADS = 4096;
const MAX_VERTICES = MAX_QUADS * 6;

pub const UiRenderer = struct {
    pipeline: vk.VkPipeline,
    pipeline_layout: vk.VkPipelineLayout,
    descriptor_set_layout: vk.VkDescriptorSetLayout,
    descriptor_pool: vk.VkDescriptorPool,
    descriptor_set: vk.VkDescriptorSet,
    vertex_buffer: vk.VkBuffer,
    vertex_buffer_memory: vk.VkDeviceMemory,
    vertex_count: u32,
    screen_width: f32,
    screen_height: f32,
    mapped_vertices: ?[*]UiVertex,
    clip_rect: [4]f32 = .{ -1e9, -1e9, 1e9, 1e9 },

    pub fn init(
        shader_compiler: *ShaderCompiler,
        ctx: *const VulkanContext,
        swapchain_format: vk.VkFormat,
    ) !UiRenderer {
        const tz = tracy.zone(@src(), "UiRenderer.init");
        defer tz.end();

        var self = UiRenderer{
            .pipeline = null,
            .pipeline_layout = null,
            .descriptor_set_layout = null,
            .descriptor_pool = null,
            .descriptor_set = null,
            .vertex_buffer = null,
            .vertex_buffer_memory = null,
            .vertex_count = 0,
            .screen_width = 800.0,
            .screen_height = 600.0,
            .mapped_vertices = null,
        };

        try self.createVertexBuffer(ctx);
        try self.createDescriptors(ctx);
        try self.createPipeline(shader_compiler, ctx, swapchain_format);

        std.log.info("UiRenderer initialized", .{});
        return self;
    }

    pub fn deinit(self: *UiRenderer, device: vk.VkDevice) void {
        vk.destroyPipeline(device, self.pipeline, null);
        vk.destroyPipelineLayout(device, self.pipeline_layout, null);
        vk.destroyDescriptorPool(device, self.descriptor_pool, null);
        vk.destroyDescriptorSetLayout(device, self.descriptor_set_layout, null);
        vk.destroyBuffer(device, self.vertex_buffer, null);
        vk.freeMemory(device, self.vertex_buffer_memory, null);
    }

    pub fn beginFrame(self: *UiRenderer, device: vk.VkDevice) void {
        var data: ?*anyopaque = null;
        vk.mapMemory(device, self.vertex_buffer_memory, 0, MAX_VERTICES * @sizeOf(UiVertex), 0, &data) catch return;
        self.mapped_vertices = @ptrCast(@alignCast(data));
        self.vertex_count = 0;
    }

    pub fn endFrame(self: *UiRenderer, device: vk.VkDevice) void {
        if (self.mapped_vertices != null) {
            vk.unmapMemory(device, self.vertex_buffer_memory);
            self.mapped_vertices = null;
        }
    }

    pub fn recordDraw(self: *const UiRenderer, command_buffer: vk.VkCommandBuffer) void {
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

    pub fn updateScreenSize(self: *UiRenderer, width: u32, height: u32) void {
        self.screen_width = @floatFromInt(width);
        self.screen_height = @floatFromInt(height);
    }

    // ── Clip rect ──

    pub fn setClipRect(self: *UiRenderer, x: f32, y: f32, w: f32, h: f32) void {
        self.clip_rect = .{ x, y, x + w, y + h };
    }

    pub fn clearClipRect(self: *UiRenderer) void {
        self.clip_rect = .{ -1e9, -1e9, 1e9, 1e9 };
    }

    // ── Drawing primitives ──

    /// Draw a solid-color rectangle.
    pub fn drawRect(self: *UiRenderer, x: f32, y: f32, w: f32, h: f32, color: [4]f32) void {
        if (w <= 0 or h <= 0 or color[3] < 0.01) return;
        const verts = self.mapped_vertices orelse return;
        if (self.vertex_count + 6 > MAX_VERTICES) return;

        const x0 = x;
        const y0 = y;
        const x1 = x + w;
        const y1 = y + h;

        // UV = (0,0) signals solid color in fragment shader
        const cr = self.clip_rect;
        verts[self.vertex_count + 0] = .{ .px = x0, .py = y0, .u = 0, .v = 0, .r = color[0], .g = color[1], .b = color[2], .a = color[3], .clip_min_x = cr[0], .clip_min_y = cr[1], .clip_max_x = cr[2], .clip_max_y = cr[3] };
        verts[self.vertex_count + 1] = .{ .px = x1, .py = y0, .u = 0, .v = 0, .r = color[0], .g = color[1], .b = color[2], .a = color[3], .clip_min_x = cr[0], .clip_min_y = cr[1], .clip_max_x = cr[2], .clip_max_y = cr[3] };
        verts[self.vertex_count + 2] = .{ .px = x0, .py = y1, .u = 0, .v = 0, .r = color[0], .g = color[1], .b = color[2], .a = color[3], .clip_min_x = cr[0], .clip_min_y = cr[1], .clip_max_x = cr[2], .clip_max_y = cr[3] };
        verts[self.vertex_count + 3] = .{ .px = x1, .py = y0, .u = 0, .v = 0, .r = color[0], .g = color[1], .b = color[2], .a = color[3], .clip_min_x = cr[0], .clip_min_y = cr[1], .clip_max_x = cr[2], .clip_max_y = cr[3] };
        verts[self.vertex_count + 4] = .{ .px = x1, .py = y1, .u = 0, .v = 0, .r = color[0], .g = color[1], .b = color[2], .a = color[3], .clip_min_x = cr[0], .clip_min_y = cr[1], .clip_max_x = cr[2], .clip_max_y = cr[3] };
        verts[self.vertex_count + 5] = .{ .px = x0, .py = y1, .u = 0, .v = 0, .r = color[0], .g = color[1], .b = color[2], .a = color[3], .clip_min_x = cr[0], .clip_min_y = cr[1], .clip_max_x = cr[2], .clip_max_y = cr[3] };

        self.vertex_count += 6;
    }

    /// Draw a rectangle outline (border).
    pub fn drawRectOutline(self: *UiRenderer, x: f32, y: f32, w: f32, h: f32, thickness: f32, color: [4]f32) void {
        if (thickness <= 0 or color[3] < 0.01) return;
        // Top edge
        self.drawRect(x, y, w, thickness, color);
        // Bottom edge
        self.drawRect(x, y + h - thickness, w, thickness, color);
        // Left edge
        self.drawRect(x, y + thickness, thickness, h - thickness * 2, color);
        // Right edge
        self.drawRect(x + w - thickness, y + thickness, thickness, h - thickness * 2, color);
    }

    // ── Vulkan setup ──

    fn createVertexBuffer(self: *UiRenderer, ctx: *const VulkanContext) !void {
        const buffer_size: vk.VkDeviceSize = MAX_VERTICES * @sizeOf(UiVertex);
        try vk_utils.createBuffer(
            ctx,
            buffer_size,
            vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &self.vertex_buffer,
            &self.vertex_buffer_memory,
        );
    }

    fn createDescriptors(self: *UiRenderer, ctx: *const VulkanContext) !void {
        // Single binding: vertex SSBO
        const bindings = [_]vk.VkDescriptorSetLayoutBinding{
            .{
                .binding = 0,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
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

        // Write binding 0: vertex SSBO
        const buffer_info = vk.VkDescriptorBufferInfo{
            .buffer = self.vertex_buffer,
            .offset = 0,
            .range = MAX_VERTICES * @sizeOf(UiVertex),
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
        };

        vk.updateDescriptorSets(ctx.device, writes.len, &writes, 0, null);
    }

    fn createPipeline(self: *UiRenderer, shader_compiler: *ShaderCompiler, ctx: *const VulkanContext, swapchain_format: vk.VkFormat) !void {
        const tz = tracy.zone(@src(), "UiRenderer.createPipeline");
        defer tz.end();

        const vert_spirv = try shader_compiler.compile("ui.vert", .vertex);
        defer shader_compiler.allocator.free(vert_spirv);

        const frag_spirv = try shader_compiler.compile("ui.frag", .fragment);
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

        // Depth test DISABLED — UI always on top of world
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
            .size = 64, // mat4
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

        std.log.info("UI rendering pipeline created", .{});
    }

    fn orthoMatrix(w: f32, h: f32) [16]f32 {
        // Maps (0,0) top-left -> (-1,-1), (w,h) bottom-right -> (1,1)
        return .{
            2.0 / w, 0.0,     0.0, 0.0,
            0.0,     2.0 / h, 0.0, 0.0,
            0.0,     0.0,     1.0, 0.0,
            -1.0,    -1.0,    0.0, 1.0,
        };
    }
};
