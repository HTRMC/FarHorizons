const std = @import("std");
const vk = @import("../../platform/volk.zig");
const c = @import("../../platform/c.zig").c;
const ShaderCompiler = @import("ShaderCompiler.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const vk_utils = @import("vk_utils.zig");
const tracy = @import("../../platform/tracy.zig");
const zlm = @import("zlm");
const gpu_alloc_mod = @import("../../allocators/GpuAllocator.zig");
const GpuAllocator = gpu_alloc_mod.GpuAllocator;
const BufferAllocation = gpu_alloc_mod.BufferAllocation;

pub const EntityVertex = extern struct {
    px: f32,
    py: f32,
    pz: f32,
    nx: f32,
    ny: f32,
    nz: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

const MAX_VERTICES = 4096;

pub const EntityRenderer = struct {
    pipeline: vk.VkPipeline, // No depth test (inventory overlay)
    pipeline_depth: vk.VkPipeline, // With depth test (world rendering)
    pipeline_layout: vk.VkPipelineLayout,
    descriptor_set_layout: vk.VkDescriptorSetLayout,
    descriptor_pool: vk.VkDescriptorPool,
    descriptor_set: vk.VkDescriptorSet,
    vertex_alloc: BufferAllocation,
    gpu_alloc: *GpuAllocator,
    vertex_count: u32 = 0,
    visible: bool = false,
    // Viewport rectangle in pixel coords (set by UI layout)
    viewport_x: f32 = 0,
    viewport_y: f32 = 0,
    viewport_w: f32 = 0,
    viewport_h: f32 = 0,
    rotation_y: f32 = 0.4, // Model Y rotation (radians)
    // Third person world rendering
    world_visible: bool = false,
    world_pos: [3]f32 = .{ 0, 0, 0 },

    pub fn init(shader_compiler: *ShaderCompiler, ctx: *const VulkanContext, swapchain_format: vk.VkFormat, gpu_alloc: *GpuAllocator) !EntityRenderer {
        const tz = tracy.zone(@src(), "EntityRenderer.init");
        defer tz.end();

        var self = EntityRenderer{
            .pipeline = null,
            .pipeline_depth = null,
            .pipeline_layout = null,
            .descriptor_set_layout = null,
            .descriptor_pool = null,
            .descriptor_set = null,
            .vertex_alloc = undefined,
            .gpu_alloc = gpu_alloc,
        };

        try self.createResources(ctx, gpu_alloc);
        try self.createPipeline(shader_compiler, ctx, swapchain_format);
        self.generatePlayerModel();

        return self;
    }

    pub fn deinit(self: *EntityRenderer, device: vk.VkDevice) void {
        vk.destroyPipeline(device, self.pipeline_depth, null);
        vk.destroyPipeline(device, self.pipeline, null);
        vk.destroyPipelineLayout(device, self.pipeline_layout, null);
        vk.destroyDescriptorPool(device, self.descriptor_pool, null);
        vk.destroyDescriptorSetLayout(device, self.descriptor_set_layout, null);
        self.gpu_alloc.destroyBuffer(self.vertex_alloc);
    }

    pub fn recordDraw(self: *const EntityRenderer, command_buffer: vk.VkCommandBuffer, screen_width: f32, screen_height: f32, ui_scale: f32) void {
        if (!self.visible or self.vertex_count == 0) return;
        if (self.viewport_w <= 0 or self.viewport_h <= 0) return;

        // Save and set viewport/scissor to the player panel area (in actual pixel coords)
        const vp_x = self.viewport_x * ui_scale;
        const vp_y = self.viewport_y * ui_scale;
        const vp_w = self.viewport_w * ui_scale;
        const vp_h = self.viewport_h * ui_scale;

        const viewport = vk.VkViewport{
            .x = vp_x,
            .y = vp_y,
            .width = vp_w,
            .height = vp_h,
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };
        vk.cmdSetViewport(command_buffer, 0, 1, &[_]vk.VkViewport{viewport});

        const scissor = vk.VkRect2D{
            .offset = .{
                .x = @intFromFloat(@max(vp_x, 0)),
                .y = @intFromFloat(@max(vp_y, 0)),
            },
            .extent = .{
                .width = @intFromFloat(@max(vp_w, 1)),
                .height = @intFromFloat(@max(vp_h, 1)),
            },
        };
        vk.cmdSetScissor(command_buffer, 0, 1, &[_]vk.VkRect2D{scissor});

        // Build MVP: perspective projection + view looking at model center
        const aspect = vp_w / @max(vp_h, 1.0);
        const proj = zlm.Mat4.perspective(std.math.degreesToRadians(30.0), aspect, 0.1, 100.0);
        const eye = zlm.Vec3.init(
            @sin(self.rotation_y) * 4.5,
            1.0,
            @cos(self.rotation_y) * 4.5,
        );
        const view = zlm.Mat4.lookAt(eye, zlm.Vec3.init(0.0, 0.2, 0.0), zlm.Vec3.init(0.0, 1.0, 0.0));
        const mvp = zlm.Mat4.mul(proj, view);

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
            @sizeOf(zlm.Mat4),
            &mvp.m,
        );
        vk.cmdDraw(command_buffer, self.vertex_count, 1, 0, 0);

        // Restore full-screen viewport/scissor
        const full_viewport = vk.VkViewport{
            .x = 0.0,
            .y = 0.0,
            .width = screen_width,
            .height = screen_height,
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };
        vk.cmdSetViewport(command_buffer, 0, 1, &[_]vk.VkViewport{full_viewport});

        const full_scissor = vk.VkRect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{
                .width = @intFromFloat(screen_width),
                .height = @intFromFloat(screen_height),
            },
        };
        vk.cmdSetScissor(command_buffer, 0, 1, &[_]vk.VkRect2D{full_scissor});
    }

    /// Draw the player model in world space (third person).
    /// Uses the depth-enabled pipeline. view_proj is the camera's VP matrix.
    pub fn recordDrawWorld(self: *const EntityRenderer, command_buffer: vk.VkCommandBuffer, view_proj: zlm.Mat4) void {
        if (!self.world_visible or self.vertex_count == 0) return;

        // Model matrix: translate to player's feet position
        const model = zlm.Mat4{
            .m = .{
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                self.world_pos[0], self.world_pos[1], self.world_pos[2], 1,
            },
        };
        const mvp = zlm.Mat4.mul(view_proj, model);

        vk.cmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline_depth);
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
            @sizeOf(zlm.Mat4),
            &mvp.m,
        );
        vk.cmdDraw(command_buffer, self.vertex_count, 1, 0, 0);
    }

    // ============================================================
    // Player model generation — blocky humanoid
    // ============================================================

    fn generatePlayerModel(self: *EntityRenderer) void {
        const vertices: [*]EntityVertex = @ptrCast(@alignCast(self.vertex_alloc.mapped_ptr orelse return));
        var count: u32 = 0;

        // Generated from Player.fh.blockymodel (16 boxes, 1.8m tall)
        // Pelvis
        count = addBox(vertices, count, -0.3018, 0.6251, -0.1940, 0.6036, 0.2587, 0.3880, .{ 0.30, 0.30, 0.50, 1.0 });
        // Belly
        count = addBox(vertices, count, -0.3018, 0.8838, -0.1940, 0.6036, 0.2371, 0.3880, .{ 0.30, 0.30, 0.50, 1.0 });
        // Chest
        count = addBox(vertices, count, -0.3018, 0.9593, -0.1940, 0.6036, 0.4743, 0.3880, .{ 0.35, 0.35, 0.55, 1.0 });
        // Head
        count = addBox(vertices, count, -0.3449, 1.1964, -0.3880, 0.6898, 0.6036, 0.6467, .{ 0.65, 0.55, 0.45, 1.0 });
        // R-Arm
        count = addBox(vertices, count, -0.5605, 0.7312, -0.1940, 0.2587, 0.4311, 0.2587, .{ 0.35, 0.35, 0.55, 1.0 });
        // R-Forearm
        count = addBox(vertices, count, -0.5497, 0.5625, -0.1927, 0.2587, 0.3449, 0.2587, .{ 0.60, 0.50, 0.40, 1.0 });
        // R-Hand
        count = addBox(vertices, count, -0.5821, 0.5016, -0.2129, 0.3018, 0.2587, 0.3018, .{ 0.65, 0.55, 0.45, 1.0 });
        // L-Arm
        count = addBox(vertices, count, 0.3018, 0.7350, -0.1940, 0.2587, 0.4311, 0.2587, .{ 0.35, 0.35, 0.55, 1.0 });
        // L-Forearm
        count = addBox(vertices, count, 0.2479, 0.5625, -0.1927, 0.2587, 0.3449, 0.2587, .{ 0.60, 0.50, 0.40, 1.0 });
        // L-Hand
        count = addBox(vertices, count, 0.1941, 0.4978, -0.2129, 0.3018, 0.2587, 0.3018, .{ 0.65, 0.55, 0.45, 1.0 });
        // R-Thigh
        count = addBox(vertices, count, -0.3126, 0.2802, -0.1070, 0.3018, 0.4311, 0.2587, .{ 0.25, 0.25, 0.45, 1.0 });
        // R-Calf
        count = addBox(vertices, count, -0.3341, 0.0000, -0.1078, 0.3018, 0.5174, 0.2587, .{ 0.25, 0.25, 0.45, 1.0 });
        // R-Foot
        count = addBox(vertices, count, -0.3773, 0.1509, -0.1094, 0.3449, 0.1725, 0.4311, .{ 0.30, 0.30, 0.50, 1.0 });
        // L-Thigh
        count = addBox(vertices, count, 0.0324, 0.2802, -0.1086, 0.3018, 0.4311, 0.2587, .{ 0.25, 0.25, 0.45, 1.0 });
        // L-Calf
        count = addBox(vertices, count, 0.0108, 0.0000, -0.1078, 0.3018, 0.5174, 0.2587, .{ 0.25, 0.25, 0.45, 1.0 });
        // L-Foot
        count = addBox(vertices, count, -0.0324, 0.1509, -0.1061, 0.3449, 0.1725, 0.4311, .{ 0.30, 0.30, 0.50, 1.0 });

        self.vertex_count = count;
        std.log.info("Entity renderer: player model generated ({} vertices)", .{count});
    }

    fn addBox(vertices: [*]EntityVertex, start: u32, x: f32, y: f32, z: f32, w: f32, h: f32, d: f32, color: [4]f32) u32 {
        var count = start;
        const x0 = x;
        const y0 = y;
        const z0 = z;
        const x1 = x + w;
        const y1 = y + h;
        const z1 = z + d;

        // Front face (z+)
        count = addQuad(vertices, count, x0, y0, z1, x1, y0, z1, x1, y1, z1, x0, y1, z1, 0, 0, 1, color);
        // Back face (z-)
        count = addQuad(vertices, count, x1, y0, z0, x0, y0, z0, x0, y1, z0, x1, y1, z0, 0, 0, -1, color);
        // Right face (x+)
        count = addQuad(vertices, count, x1, y0, z1, x1, y0, z0, x1, y1, z0, x1, y1, z1, 1, 0, 0, color);
        // Left face (x-)
        count = addQuad(vertices, count, x0, y0, z0, x0, y0, z1, x0, y1, z1, x0, y1, z0, -1, 0, 0, color);
        // Top face (y+)
        count = addQuad(vertices, count, x0, y1, z1, x1, y1, z1, x1, y1, z0, x0, y1, z0, 0, 1, 0, color);
        // Bottom face (y-)
        count = addQuad(vertices, count, x0, y0, z0, x1, y0, z0, x1, y0, z1, x0, y0, z1, 0, -1, 0, color);

        return count;
    }

    fn addQuad(
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
        color: [4]f32,
    ) u32 {
        const v = EntityVertex{
            .px = 0,
            .py = 0,
            .pz = 0,
            .nx = nx,
            .ny = ny,
            .nz = nz,
            .r = color[0],
            .g = color[1],
            .b = color[2],
            .a = color[3],
        };

        // Triangle 1: 0-1-2
        var v0 = v;
        v0.px = x0;
        v0.py = y0;
        v0.pz = z0;
        vertices[start] = v0;

        var v1 = v;
        v1.px = x1;
        v1.py = y1;
        v1.pz = z1;
        vertices[start + 1] = v1;

        var v2 = v;
        v2.px = x2;
        v2.py = y2;
        v2.pz = z2;
        vertices[start + 2] = v2;

        // Triangle 2: 0-2-3
        vertices[start + 3] = v0;

        var v3 = v;
        v3.px = x2;
        v3.py = y2;
        v3.pz = z2;
        vertices[start + 4] = v3;

        var v4 = v;
        v4.px = x3;
        v4.py = y3;
        v4.pz = z3;
        vertices[start + 5] = v4;

        return start + 6;
    }

    // ============================================================
    // Vulkan resources
    // ============================================================

    fn createResources(self: *EntityRenderer, ctx: *const VulkanContext, gpu_alloc: *GpuAllocator) !void {
        const vertex_buffer_size: vk.VkDeviceSize = MAX_VERTICES * @sizeOf(EntityVertex);
        self.vertex_alloc = try gpu_alloc.createBuffer(
            vertex_buffer_size,
            vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            .host_visible,
        );

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
            .buffer = self.vertex_alloc.buffer,
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

    fn createPipeline(self: *EntityRenderer, shader_compiler: *ShaderCompiler, ctx: *const VulkanContext, swapchain_format: vk.VkFormat) !void {
        const device = ctx.device;

        const vert_spirv = try shader_compiler.compile("entity.vert", .vertex);
        defer shader_compiler.allocator.free(vert_spirv);

        const frag_spirv = try shader_compiler.compile("entity.frag", .fragment);
        defer shader_compiler.allocator.free(frag_spirv);

        const vert_module = try vk.createShaderModule(device, &vk.VkShaderModuleCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = vert_spirv.len,
            .pCode = @ptrCast(@alignCast(vert_spirv.ptr)),
        }, null);
        defer vk.destroyShaderModule(device, vert_module, null);

        const frag_module = try vk.createShaderModule(device, &vk.VkShaderModuleCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = frag_spirv.len,
            .pCode = @ptrCast(@alignCast(frag_spirv.ptr)),
        }, null);
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
            .cullMode = vk.VK_CULL_MODE_BACK_BIT,
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
            .depthCompareOp = vk.VK_COMPARE_OP_LESS,
            .depthBoundsTestEnable = vk.VK_FALSE,
            .stencilTestEnable = vk.VK_FALSE,
            .front = std.mem.zeroes(vk.VkStencilOpState),
            .back = std.mem.zeroes(vk.VkStencilOpState),
            .minDepthBounds = 0.0,
            .maxDepthBounds = 1.0,
        };

        const color_blend_attachment = vk.VkPipelineColorBlendAttachmentState{
            .blendEnable = vk.VK_FALSE,
            .srcColorBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ZERO,
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

        // Depth-enabled variant (for world rendering)
        const depth_stencil_on = vk.VkPipelineDepthStencilStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthTestEnable = vk.VK_TRUE,
            .depthWriteEnable = vk.VK_TRUE,
            .depthCompareOp = vk.VK_COMPARE_OP_LESS,
            .depthBoundsTestEnable = vk.VK_FALSE,
            .stencilTestEnable = vk.VK_FALSE,
            .front = std.mem.zeroes(vk.VkStencilOpState),
            .back = std.mem.zeroes(vk.VkStencilOpState),
            .minDepthBounds = 0.0,
            .maxDepthBounds = 1.0,
        };

        const pipeline_infos = [2]vk.VkGraphicsPipelineCreateInfo{
            // [0] No depth (inventory overlay)
            .{
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
                .pDynamicState = @ptrCast(&dynamic_state_info),
                .layout = self.pipeline_layout,
                .renderPass = null,
                .subpass = 0,
                .basePipelineHandle = null,
                .basePipelineIndex = -1,
            },
            // [1] With depth (world third-person)
            .{
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
                .pDepthStencilState = &depth_stencil_on,
                .pColorBlendState = &color_blending,
                .pDynamicState = @ptrCast(&dynamic_state_info),
                .layout = self.pipeline_layout,
                .renderPass = null,
                .subpass = 0,
                .basePipelineHandle = null,
                .basePipelineIndex = -1,
            },
        };

        var pipelines: [2]vk.VkPipeline = undefined;
        try vk.createGraphicsPipelines(device, null, 2, &pipeline_infos, null, &pipelines);
        self.pipeline = pipelines[0];
        self.pipeline_depth = pipelines[1];

        std.log.info("Entity pipelines created", .{});
    }
};
