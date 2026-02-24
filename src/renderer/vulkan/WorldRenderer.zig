const std = @import("std");
const vk = @import("../../platform/volk.zig");
const c = @import("../../platform/c.zig").c;
const ShaderCompiler = @import("ShaderCompiler.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const vk_utils = @import("vk_utils.zig");
const types = @import("types.zig");
const FaceData = types.FaceData;
const ChunkData = types.ChunkData;
const QuadModel = types.QuadModel;
const LightEntry = types.LightEntry;
const DrawCommand = types.DrawCommand;
const tracy = @import("../../platform/tracy.zig");
const zlm = @import("zlm");
const WorldState = @import("../../world/WorldState.zig");
pub const TextureManager = @import("TextureManager.zig").TextureManager;
const TlsfAllocator = @import("../../allocators/TlsfAllocator.zig").TlsfAllocator;

// Initial GPU heap capacities
const INITIAL_FACE_CAPACITY: u32 = 400_000; // ~3.2 MB at 8 bytes/face
const INITIAL_LIGHT_CAPACITY: u32 = 400_000; // ~6.4 MB at 16 bytes/entry (1:1 with faces)
const MAX_FACES_PER_DRAW: u32 = 16_384; // max faces per draw (16384*4=65536 verts, u16 index limit)
const MAX_INDIRECT_COMMANDS: u32 = WorldState.TOTAL_WORLD_CHUNKS * 6; // 96

pub const WorldRenderer = struct {
    texture_manager: TextureManager,
    pipeline_layout: vk.VkPipelineLayout,
    graphics_pipeline: vk.VkPipeline,
    overdraw_pipeline: vk.VkPipeline,

    // Indirect draw buffers (host-visible)
    indirect_buffer: vk.VkBuffer,
    indirect_buffer_memory: vk.VkDeviceMemory,
    indirect_count_buffer: vk.VkBuffer,
    indirect_count_buffer_memory: vk.VkDeviceMemory,

    // GPU heaps (device-local)
    face_buffer: vk.VkBuffer,
    face_buffer_memory: vk.VkDeviceMemory,
    light_buffer: vk.VkBuffer,
    light_buffer_memory: vk.VkDeviceMemory,
    model_buffer: vk.VkBuffer,
    model_buffer_memory: vk.VkDeviceMemory,
    static_index_buffer: vk.VkBuffer,
    static_index_buffer_memory: vk.VkDeviceMemory,

    // Chunk data SSBO (host-visible)
    chunk_data_buffer: vk.VkBuffer,
    chunk_data_buffer_memory: vk.VkDeviceMemory,

    // TLSF sub-allocators for face and light heaps
    face_tlsf: TlsfAllocator,
    light_tlsf: TlsfAllocator,

    // Per-chunk state
    chunk_face_alloc: [WorldState.TOTAL_WORLD_CHUNKS]?TlsfAllocator.Allocation,
    chunk_light_alloc: [WorldState.TOTAL_WORLD_CHUNKS]?TlsfAllocator.Allocation,
    chunk_data: [WorldState.TOTAL_WORLD_CHUNKS]ChunkData,

    // Draw count
    draw_count: u32,

    pub fn init(
        allocator: std.mem.Allocator,
        shader_compiler: *ShaderCompiler,
        ctx: *const VulkanContext,
        swapchain_format: vk.VkFormat,
    ) !WorldRenderer {
        const tz = tracy.zone(@src(), "WorldRenderer.init");
        defer tz.end();

        var texture_manager = try TextureManager.init(allocator, ctx);
        errdefer texture_manager.deinit(ctx.device);

        var self = WorldRenderer{
            .texture_manager = texture_manager,
            .pipeline_layout = null,
            .graphics_pipeline = null,
            .overdraw_pipeline = null,
            .indirect_buffer = null,
            .indirect_buffer_memory = null,
            .indirect_count_buffer = null,
            .indirect_count_buffer_memory = null,
            .face_buffer = null,
            .face_buffer_memory = null,
            .light_buffer = null,
            .light_buffer_memory = null,
            .model_buffer = null,
            .model_buffer_memory = null,
            .static_index_buffer = null,
            .static_index_buffer_memory = null,
            .chunk_data_buffer = null,
            .chunk_data_buffer_memory = null,
            .face_tlsf = TlsfAllocator.init(INITIAL_FACE_CAPACITY),
            .light_tlsf = TlsfAllocator.init(INITIAL_LIGHT_CAPACITY),
            .chunk_face_alloc = .{null} ** WorldState.TOTAL_WORLD_CHUNKS,
            .chunk_light_alloc = .{null} ** WorldState.TOTAL_WORLD_CHUNKS,
            .chunk_data = .{std.mem.zeroes(ChunkData)} ** WorldState.TOTAL_WORLD_CHUNKS,
            .draw_count = 0,
        };

        try self.createGraphicsPipeline(shader_compiler, ctx, swapchain_format, texture_manager.bindless_descriptor_set_layout);
        errdefer {
            vk.destroyPipeline(ctx.device, self.overdraw_pipeline, null);
            vk.destroyPipeline(ctx.device, self.graphics_pipeline, null);
            vk.destroyPipelineLayout(ctx.device, self.pipeline_layout, null);
        }

        try self.createIndirectBuffer(ctx);
        try self.createPersistentBuffers(ctx);

        return self;
    }

    pub fn deinit(self: *WorldRenderer, device: vk.VkDevice) void {
        const tz = tracy.zone(@src(), "WorldRenderer.deinit");
        defer tz.end();

        vk.destroyBuffer(device, self.indirect_buffer, null);
        vk.freeMemory(device, self.indirect_buffer_memory, null);
        vk.destroyBuffer(device, self.indirect_count_buffer, null);
        vk.freeMemory(device, self.indirect_count_buffer_memory, null);
        vk.destroyPipeline(device, self.overdraw_pipeline, null);
        vk.destroyPipeline(device, self.graphics_pipeline, null);
        vk.destroyPipelineLayout(device, self.pipeline_layout, null);
        vk.destroyBuffer(device, self.face_buffer, null);
        vk.freeMemory(device, self.face_buffer_memory, null);
        vk.destroyBuffer(device, self.light_buffer, null);
        vk.freeMemory(device, self.light_buffer_memory, null);
        vk.destroyBuffer(device, self.model_buffer, null);
        vk.freeMemory(device, self.model_buffer_memory, null);
        vk.destroyBuffer(device, self.static_index_buffer, null);
        vk.freeMemory(device, self.static_index_buffer_memory, null);
        vk.destroyBuffer(device, self.chunk_data_buffer, null);
        vk.freeMemory(device, self.chunk_data_buffer_memory, null);
        self.texture_manager.deinit(device);
    }

    /// Upload mesh data for a single chunk into the GPU heaps at its TLSF-assigned region.
    pub fn uploadChunkData(
        self: *WorldRenderer,
        ctx: *const VulkanContext,
        coord: WorldState.ChunkCoord,
        faces: []const FaceData,
        face_counts: [6]u32,
        total_face_count: u32,
        lights: []const LightEntry,
        light_count: u32,
    ) !void {
        const tz = tracy.zone(@src(), "uploadChunkData");
        defer tz.end();

        const slot = coord.flatIndex();

        // Free old allocations if this chunk was previously meshed
        if (self.chunk_face_alloc[slot]) |fa| {
            self.face_tlsf.free(fa.offset);
            self.chunk_face_alloc[slot] = null;
        }
        if (self.chunk_light_alloc[slot]) |la| {
            self.light_tlsf.free(la.offset);
            self.chunk_light_alloc[slot] = null;
        }

        // Empty chunk
        if (total_face_count == 0) {
            self.chunk_data[slot] = .{
                .position = coord.position(),
                .light_start = 0,
                .face_start = 0,
                .face_counts = .{ 0, 0, 0, 0, 0, 0 },
            };
            self.writeChunkData(ctx, slot);
            return;
        }

        // Allocate TLSF regions
        const fa = self.face_tlsf.alloc(total_face_count) orelse {
            std.log.err("TLSF face heap full (requested {}, largest free {})", .{
                total_face_count, self.face_tlsf.largestFree(),
            });
            return error.OutOfMemory;
        };
        errdefer self.face_tlsf.free(fa.offset);

        const la = if (light_count > 0)
            self.light_tlsf.alloc(light_count) orelse {
                std.log.err("TLSF light heap full (requested {}, largest free {})", .{
                    light_count, self.light_tlsf.largestFree(),
                });
                self.face_tlsf.free(fa.offset);
                return error.OutOfMemory;
            }
        else
            TlsfAllocator.Allocation{ .offset = 0, .size = 0 };

        self.chunk_face_alloc[slot] = fa;
        if (light_count > 0) self.chunk_light_alloc[slot] = la;

        // Stage face data
        {
            const fb_size: vk.VkDeviceSize = @intCast(@as(u64, total_face_count) * @sizeOf(FaceData));
            var staging_buffer: vk.VkBuffer = undefined;
            var staging_memory: vk.VkDeviceMemory = undefined;
            try vk_utils.createBuffer(
                ctx,
                fb_size,
                vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                &staging_buffer,
                &staging_memory,
            );
            defer {
                vk.destroyBuffer(ctx.device, staging_buffer, null);
                vk.freeMemory(ctx.device, staging_memory, null);
            }

            var data: ?*anyopaque = null;
            try vk.mapMemory(ctx.device, staging_memory, 0, fb_size, 0, &data);
            const dst: [*]FaceData = @ptrCast(@alignCast(data));
            @memcpy(dst[0..total_face_count], faces[0..total_face_count]);
            vk.unmapMemory(ctx.device, staging_memory);

            const dst_offset: vk.VkDeviceSize = @intCast(@as(u64, fa.offset) * @sizeOf(FaceData));
            try vk_utils.copyBufferRegion(ctx, staging_buffer, 0, self.face_buffer, dst_offset, fb_size);
        }

        // Stage light data
        if (light_count > 0) {
            const lb_size: vk.VkDeviceSize = @intCast(@as(u64, light_count) * @sizeOf(LightEntry));
            var staging_buffer: vk.VkBuffer = undefined;
            var staging_memory: vk.VkDeviceMemory = undefined;
            try vk_utils.createBuffer(
                ctx,
                lb_size,
                vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                &staging_buffer,
                &staging_memory,
            );
            defer {
                vk.destroyBuffer(ctx.device, staging_buffer, null);
                vk.freeMemory(ctx.device, staging_memory, null);
            }

            var data: ?*anyopaque = null;
            try vk.mapMemory(ctx.device, staging_memory, 0, lb_size, 0, &data);
            const dst: [*]LightEntry = @ptrCast(@alignCast(data));
            @memcpy(dst[0..light_count], lights[0..light_count]);
            vk.unmapMemory(ctx.device, staging_memory);

            const dst_offset: vk.VkDeviceSize = @intCast(@as(u64, la.offset) * @sizeOf(LightEntry));
            try vk_utils.copyBufferRegion(ctx, staging_buffer, 0, self.light_buffer, dst_offset, lb_size);
        }

        // Update CPU-side chunk data and write to GPU
        self.chunk_data[slot] = .{
            .position = coord.position(),
            .light_start = la.offset,
            .face_start = fa.offset,
            .face_counts = face_counts,
        };
        self.writeChunkData(ctx, slot);
    }

    fn writeChunkData(self: *WorldRenderer, ctx: *const VulkanContext, slot: usize) void {
        const offset: vk.VkDeviceSize = @intCast(slot * @sizeOf(ChunkData));
        var data: ?*anyopaque = null;
        vk.mapMemory(ctx.device, self.chunk_data_buffer_memory, offset, @sizeOf(ChunkData), 0, &data) catch return;
        const dst: *ChunkData = @ptrCast(@alignCast(data));
        dst.* = self.chunk_data[slot];
        vk.unmapMemory(ctx.device, self.chunk_data_buffer_memory);
    }

    /// Build indirect draw commands with CPU-side normal culling.
    /// Uses signed distance from camera to chunk AABB to determine which
    /// normal groups are potentially visible (Cubyz-style approach).
    pub fn buildIndirectCommands(self: *WorldRenderer, ctx: *const VulkanContext, camera_pos: zlm.Vec3) void {
        const tz = tracy.zone(@src(), "buildIndirectCommands");
        defer tz.end();

        const buffer_size: vk.VkDeviceSize = MAX_INDIRECT_COMMANDS * @sizeOf(DrawCommand);
        var data: ?*anyopaque = null;
        vk.mapMemory(ctx.device, self.indirect_buffer_memory, 0, buffer_size, 0, &data) catch return;
        const commands: [*]DrawCommand = @ptrCast(@alignCast(data));

        var command_count: u32 = 0;
        const cs: i32 = WorldState.CHUNK_SIZE;

        for (0..WorldState.TOTAL_WORLD_CHUNKS) |chunk_idx| {
            const cd = self.chunk_data[chunk_idx];

            // Check if chunk has any faces
            var total: u32 = 0;
            for (cd.face_counts) |fc| total += fc;
            if (total == 0) continue;

            // Signed distance from camera to chunk AABB.
            // When inside the chunk, all components clamp to 0 (all normals visible).
            // When outside, only the side the camera is on passes the check.
            const pd = aabbSignedDist(camera_pos.x, camera_pos.y, camera_pos.z, cd.position, cs);

            var normal_offset: u32 = 0;
            for (0..6) |normal_idx| {
                const fc = cd.face_counts[normal_idx];
                if (fc == 0) {
                    continue;
                }

                if (!isNormalVisible(normal_idx, pd)) {
                    normal_offset += fc;
                    continue;
                }

                commands[command_count] = .{
                    .index_count = fc * 6,
                    .instance_count = 1,
                    .first_index = 0,
                    .vertex_offset = @intCast((cd.face_start + normal_offset) * 4),
                    .first_instance = @intCast(chunk_idx),
                };
                command_count += 1;
                normal_offset += fc;
            }
        }

        vk.unmapMemory(ctx.device, self.indirect_buffer_memory);

        // Write command count
        var count_data: ?*anyopaque = null;
        vk.mapMemory(ctx.device, self.indirect_count_buffer_memory, 0, @sizeOf(u32), 0, &count_data) catch return;
        const count_ptr: *u32 = @ptrCast(@alignCast(count_data));
        count_ptr.* = command_count;
        vk.unmapMemory(ctx.device, self.indirect_count_buffer_memory);

        self.draw_count = command_count;
    }

    pub fn record(self: *const WorldRenderer, command_buffer: vk.VkCommandBuffer, mvp: *const [16]f32, overdraw_active: bool) void {
        if (self.draw_count == 0) return;

        const pipeline = if (overdraw_active) self.overdraw_pipeline else self.graphics_pipeline;
        vk.cmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);

        vk.cmdBindDescriptorSets(
            command_buffer,
            vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.pipeline_layout,
            0,
            1,
            &[_]vk.VkDescriptorSet{self.texture_manager.bindless_descriptor_set},
            0,
            null,
        );

        vk.cmdBindIndexBuffer(command_buffer, self.static_index_buffer, 0, vk.VK_INDEX_TYPE_UINT16);

        vk.cmdPushConstants(
            command_buffer,
            self.pipeline_layout,
            vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            0,
            @sizeOf(zlm.Mat4),
            mvp,
        );
        const contrast: f32 = 0.4;
        vk.cmdPushConstants(
            command_buffer,
            self.pipeline_layout,
            vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            @sizeOf(zlm.Mat4),
            @sizeOf(f32),
            @ptrCast(&contrast),
        );

        vk.cmdDrawIndexedIndirectCount(
            command_buffer,
            self.indirect_buffer,
            0,
            self.indirect_count_buffer,
            0,
            MAX_INDIRECT_COMMANDS,
            @sizeOf(vk.VkDrawIndexedIndirectCommand),
        );
    }

    fn createGraphicsPipeline(
        self: *WorldRenderer,
        shader_compiler: *ShaderCompiler,
        ctx: *const VulkanContext,
        swapchain_format: vk.VkFormat,
        bindless_descriptor_set_layout: vk.VkDescriptorSetLayout,
    ) !void {
        const device = ctx.device;
        const tz = tracy.zone(@src(), "createGraphicsPipeline");
        defer tz.end();

        const vert_spirv = try shader_compiler.compile("test.vert", .vertex);
        defer shader_compiler.allocator.free(vert_spirv);

        const frag_spirv = try shader_compiler.compile("test.frag", .fragment);
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

        const vert_stage_info = vk.VkPipelineShaderStageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = vk.VK_SHADER_STAGE_VERTEX_BIT,
            .module = vert_module,
            .pName = "main",
            .pSpecializationInfo = null,
        };

        const frag_stage_info = vk.VkPipelineShaderStageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .module = frag_module,
            .pName = "main",
            .pSpecializationInfo = null,
        };

        const shader_stages = [_]vk.VkPipelineShaderStageCreateInfo{ vert_stage_info, frag_stage_info };

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
            .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .offset = 0,
            .size = 68, // sizeof(mat4) + sizeof(float) for contrast
        };

        const pipeline_layout_info = vk.VkPipelineLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 1,
            .pSetLayouts = &bindless_descriptor_set_layout,
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

        const pipeline_infos = &[_]vk.VkGraphicsPipelineCreateInfo{pipeline_info};
        var pipelines: [1]vk.VkPipeline = undefined;
        try vk.createGraphicsPipelines(device, ctx.pipeline_cache, 1, pipeline_infos, null, &pipelines);
        self.graphics_pipeline = pipelines[0];

        // Create overdraw pipeline: no depth test, additive blending, flat fragment shader
        const overdraw_frag_spirv = try shader_compiler.compile("overdraw.frag", .fragment);
        defer shader_compiler.allocator.free(overdraw_frag_spirv);

        const overdraw_frag_module_info = vk.VkShaderModuleCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = overdraw_frag_spirv.len,
            .pCode = @ptrCast(@alignCast(overdraw_frag_spirv.ptr)),
        };

        const overdraw_frag_module = try vk.createShaderModule(device, &overdraw_frag_module_info, null);
        defer vk.destroyShaderModule(device, overdraw_frag_module, null);

        const overdraw_frag_stage = vk.VkPipelineShaderStageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .module = overdraw_frag_module,
            .pName = "main",
            .pSpecializationInfo = null,
        };

        const overdraw_shader_stages = [_]vk.VkPipelineShaderStageCreateInfo{ vert_stage_info, overdraw_frag_stage };

        const overdraw_depth_stencil = vk.VkPipelineDepthStencilStateCreateInfo{
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

        const overdraw_blend_attachment = vk.VkPipelineColorBlendAttachmentState{
            .blendEnable = vk.VK_TRUE,
            .srcColorBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .colorBlendOp = vk.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ZERO,
            .alphaBlendOp = vk.VK_BLEND_OP_ADD,
            .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT | vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT,
        };

        const overdraw_color_blending = vk.VkPipelineColorBlendStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .logicOpEnable = vk.VK_FALSE,
            .logicOp = 0,
            .attachmentCount = 1,
            .pAttachments = &overdraw_blend_attachment,
            .blendConstants = .{ 0.0, 0.0, 0.0, 0.0 },
        };

        const overdraw_pipeline_info = vk.VkGraphicsPipelineCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = &rendering_create_info,
            .flags = 0,
            .stageCount = 2,
            .pStages = &overdraw_shader_stages,
            .pVertexInputState = &vertex_input_info,
            .pInputAssemblyState = &input_assembly,
            .pTessellationState = null,
            .pViewportState = &viewport_state,
            .pRasterizationState = &rasterizer,
            .pMultisampleState = &multisampling,
            .pDepthStencilState = &overdraw_depth_stencil,
            .pColorBlendState = &overdraw_color_blending,
            .pDynamicState = &dynamic_state_info,
            .layout = self.pipeline_layout,
            .renderPass = null,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };

        const overdraw_pipeline_infos = &[_]vk.VkGraphicsPipelineCreateInfo{overdraw_pipeline_info};
        var overdraw_pipelines: [1]vk.VkPipeline = undefined;
        try vk.createGraphicsPipelines(device, ctx.pipeline_cache, 1, overdraw_pipeline_infos, null, &overdraw_pipelines);
        self.overdraw_pipeline = overdraw_pipelines[0];

        std.log.info("Graphics pipelines created", .{});
    }

    fn createIndirectBuffer(self: *WorldRenderer, ctx: *const VulkanContext) !void {
        const tz = tracy.zone(@src(), "createIndirectBuffer");
        defer tz.end();

        const buffer_size: vk.VkDeviceSize = MAX_INDIRECT_COMMANDS * @sizeOf(vk.VkDrawIndexedIndirectCommand);

        try vk_utils.createBuffer(
            ctx,
            buffer_size,
            vk.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT | vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &self.indirect_buffer,
            &self.indirect_buffer_memory,
        );

        // Zero-initialize
        var data: ?*anyopaque = null;
        try vk.mapMemory(ctx.device, self.indirect_buffer_memory, 0, buffer_size, 0, &data);
        const dst: [*]u8 = @ptrCast(data.?);
        @memset(dst[0..@intCast(buffer_size)], 0);
        vk.unmapMemory(ctx.device, self.indirect_buffer_memory);

        const count_buffer_size = @sizeOf(u32);
        const count_buffer_info = vk.VkBufferCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = count_buffer_size,
            .usage = vk.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT | vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };

        self.indirect_count_buffer = try vk.createBuffer(ctx.device, &count_buffer_info, null);

        var count_mem_requirements: vk.VkMemoryRequirements = undefined;
        vk.getBufferMemoryRequirements(ctx.device, self.indirect_count_buffer, &count_mem_requirements);

        const count_memory_type_index = try vk_utils.findMemoryType(
            ctx.physical_device,
            count_mem_requirements.memoryTypeBits,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );

        const count_alloc_info = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = count_mem_requirements.size,
            .memoryTypeIndex = count_memory_type_index,
        };

        self.indirect_count_buffer_memory = try vk.allocateMemory(ctx.device, &count_alloc_info, null);
        try vk.bindBufferMemory(ctx.device, self.indirect_count_buffer, self.indirect_count_buffer_memory, 0);

        // Initialize count to 0
        var count_data: ?*anyopaque = null;
        try vk.mapMemory(ctx.device, self.indirect_count_buffer_memory, 0, count_buffer_size, 0, &count_data);
        const count_ptr: *u32 = @ptrCast(@alignCast(count_data));
        count_ptr.* = 0;
        vk.unmapMemory(ctx.device, self.indirect_count_buffer_memory);

        std.log.info("Indirect draw buffers created (max {} draw commands)", .{MAX_INDIRECT_COMMANDS});
    }

    fn createPersistentBuffers(self: *WorldRenderer, ctx: *const VulkanContext) !void {
        const tz = tracy.zone(@src(), "createPersistentBuffers");
        defer tz.end();

        // Face buffer (device-local)
        const fb_capacity: vk.VkDeviceSize = @as(u64, INITIAL_FACE_CAPACITY) * @sizeOf(FaceData);
        try vk_utils.createBuffer(
            ctx,
            fb_capacity,
            vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT | vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            &self.face_buffer,
            &self.face_buffer_memory,
        );

        // Light buffer (device-local)
        const lb_capacity: vk.VkDeviceSize = @as(u64, INITIAL_LIGHT_CAPACITY) * @sizeOf(LightEntry);
        try vk_utils.createBuffer(
            ctx,
            lb_capacity,
            vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT | vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            &self.light_buffer,
            &self.light_buffer_memory,
        );

        // Model buffer (device-local, static) - 6 QuadModels built from face_vertices
        const model_size: vk.VkDeviceSize = 6 * @sizeOf(QuadModel);
        try vk_utils.createBuffer(
            ctx,
            model_size,
            vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT | vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            &self.model_buffer,
            &self.model_buffer_memory,
        );
        try self.uploadModelBuffer(ctx, model_size);

        // Static index buffer (device-local) - pattern {0,1,2,2,3,0} repeated, u16
        const index_count: u64 = @as(u64, MAX_FACES_PER_DRAW) * 6;
        const ib_capacity: vk.VkDeviceSize = index_count * @sizeOf(u16);
        try vk_utils.createBuffer(
            ctx,
            ib_capacity,
            vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT | vk.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
            vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            &self.static_index_buffer,
            &self.static_index_buffer_memory,
        );
        try self.uploadStaticIndexBuffer(ctx, ib_capacity);

        // Chunk data buffer (host-visible)
        const cd_capacity: vk.VkDeviceSize = WorldState.TOTAL_WORLD_CHUNKS * @sizeOf(ChunkData);
        try vk_utils.createBuffer(
            ctx,
            cd_capacity,
            vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &self.chunk_data_buffer,
            &self.chunk_data_buffer_memory,
        );

        // Update descriptors
        self.texture_manager.updateFaceDescriptor(ctx, self.face_buffer, fb_capacity);
        self.texture_manager.updateChunkDataDescriptor(ctx, self.chunk_data_buffer, cd_capacity);
        self.texture_manager.updateModelDescriptor(ctx, self.model_buffer, model_size);
        self.texture_manager.updateLightDescriptor(ctx, self.light_buffer, lb_capacity);

        std.log.info("Persistent mesh buffers created ({}F / {}L, {:.1} MB)", .{
            INITIAL_FACE_CAPACITY,
            INITIAL_LIGHT_CAPACITY,
            @as(f64, @floatFromInt(fb_capacity + lb_capacity + model_size + ib_capacity + cd_capacity)) / (1024.0 * 1024.0),
        });
    }

    fn uploadModelBuffer(self: *WorldRenderer, ctx: *const VulkanContext, model_size: vk.VkDeviceSize) !void {
        // Build 6 QuadModels from face_vertices and face_neighbor_offsets
        var models: [6]QuadModel = undefined;
        for (0..6) |face| {
            var corners: [12]f32 = undefined;
            var uvs: [8]f32 = undefined;
            for (0..4) |v| {
                const fv = WorldState.face_vertices[face][v];
                corners[v * 3 + 0] = fv.px;
                corners[v * 3 + 1] = fv.py;
                corners[v * 3 + 2] = fv.pz;
                uvs[v * 2 + 0] = fv.u;
                uvs[v * 2 + 1] = fv.v;
            }
            const fno = WorldState.face_neighbor_offsets[face];
            models[face] = .{
                .corners = corners,
                .uvs = uvs,
                .normal = .{
                    @floatFromInt(fno[0]),
                    @floatFromInt(fno[1]),
                    @floatFromInt(fno[2]),
                },
            };
        }

        var staging_buffer: vk.VkBuffer = undefined;
        var staging_memory: vk.VkDeviceMemory = undefined;
        try vk_utils.createBuffer(
            ctx,
            model_size,
            vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &staging_buffer,
            &staging_memory,
        );
        defer {
            vk.destroyBuffer(ctx.device, staging_buffer, null);
            vk.freeMemory(ctx.device, staging_memory, null);
        }

        var data: ?*anyopaque = null;
        try vk.mapMemory(ctx.device, staging_memory, 0, model_size, 0, &data);
        const dst: [*]QuadModel = @ptrCast(@alignCast(data));
        @memcpy(dst[0..6], &models);
        vk.unmapMemory(ctx.device, staging_memory);

        try vk_utils.copyBuffer(ctx, staging_buffer, self.model_buffer, model_size);
    }

    fn uploadStaticIndexBuffer(self: *WorldRenderer, ctx: *const VulkanContext, ib_capacity: vk.VkDeviceSize) !void {
        var staging_buffer: vk.VkBuffer = undefined;
        var staging_memory: vk.VkDeviceMemory = undefined;
        try vk_utils.createBuffer(
            ctx,
            ib_capacity,
            vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &staging_buffer,
            &staging_memory,
        );
        defer {
            vk.destroyBuffer(ctx.device, staging_buffer, null);
            vk.freeMemory(ctx.device, staging_memory, null);
        }

        var data: ?*anyopaque = null;
        try vk.mapMemory(ctx.device, staging_memory, 0, ib_capacity, 0, &data);
        const dst: [*]u16 = @ptrCast(@alignCast(data));

        const pattern = [6]u16{ 0, 1, 2, 2, 3, 0 };
        for (0..MAX_FACES_PER_DRAW) |face| {
            const base: u16 = @intCast(face * 4);
            for (0..6) |i| {
                dst[face * 6 + i] = base + pattern[i];
            }
        }

        vk.unmapMemory(ctx.device, staging_memory);
        try vk_utils.copyBuffer(ctx, staging_buffer, self.static_index_buffer, ib_capacity);
    }
};

/// Compute signed distance from a point to a chunk AABB.
/// Returns [3]i32 where each component is:
///   negative → point is before the chunk min on that axis
///   0        → point is inside the chunk on that axis
///   positive → point is past the chunk max on that axis
pub fn aabbSignedDist(cam_x: f32, cam_y: f32, cam_z: f32, chunk_pos: [3]i32, cs: i32) [3]i32 {
    var pd = [3]i32{
        @as(i32, @intFromFloat(@floor(cam_x))) - chunk_pos[0],
        @as(i32, @intFromFloat(@floor(cam_y))) - chunk_pos[1],
        @as(i32, @intFromFloat(@floor(cam_z))) - chunk_pos[2],
    };
    if (pd[0] > 0) pd[0] = @max(0, pd[0] - cs);
    if (pd[1] > 0) pd[1] = @max(0, pd[1] - cs);
    if (pd[2] > 0) pd[2] = @max(0, pd[2] - cs);
    return pd;
}

/// Check if a normal group is visible given the signed AABB distance.
/// Normal order: 0=+Z, 1=-Z, 2=-X, 3=+X, 4=+Y, 5=-Y
pub fn isNormalVisible(normal_idx: usize, pd: [3]i32) bool {
    return switch (normal_idx) {
        0 => pd[2] >= 0, // +Z: camera at or past chunk min Z
        1 => pd[2] <= 0, // -Z: camera at or before chunk max Z
        2 => pd[0] <= 0, // -X: camera at or before chunk max X
        3 => pd[0] >= 0, // +X: camera at or past chunk min X
        4 => pd[1] >= 0, // +Y: camera at or past chunk min Y
        5 => pd[1] <= 0, // -Y: camera at or before chunk max Y
        else => true,
    };
}

// --- Tests ---

const testing = std.testing;

fn shouldDraw(pos: [3]i32, cx: f32, cy: f32, cz: f32, n: usize) bool {
    const pd = aabbSignedDist(cx, cy, cz, pos, WorldState.CHUNK_SIZE);
    return isNormalVisible(n, pd);
}

test "aabbSignedDist: camera inside chunk → all zero" {
    const pd = aabbSignedDist(16, 2, 16, .{ 0, -16, 0 }, 32);
    try testing.expectEqual(@as(i32, 0), pd[0]);
    try testing.expectEqual(@as(i32, 0), pd[1]);
    try testing.expectEqual(@as(i32, 0), pd[2]);
}

test "aabbSignedDist: camera outside chunk" {
    // Camera at (40, -20, -5), chunk from (0,-16,0) to (32,16,32)
    const pd = aabbSignedDist(40, -20, -5, .{ 0, -16, 0 }, 32);
    try testing.expectEqual(@as(i32, 8), pd[0]); // 40 - 0 = 40, clamped: 40 - 32 = 8
    try testing.expectEqual(@as(i32, -4), pd[1]); // -20 - (-16) = -4, negative → no clamp
    try testing.expectEqual(@as(i32, -5), pd[2]); // -5 - 0 = -5, negative → no clamp
}

test "aabbSignedDist: camera at chunk boundary edges" {
    // At min corner
    const pd_min = aabbSignedDist(0, -16, 0, .{ 0, -16, 0 }, 32);
    try testing.expectEqual(@as(i32, 0), pd_min[0]);
    try testing.expectEqual(@as(i32, 0), pd_min[1]);
    try testing.expectEqual(@as(i32, 0), pd_min[2]);

    // At max corner (floor(32) = 32, 32 - 0 = 32, clamped: 32 - 32 = 0)
    const pd_max = aabbSignedDist(32, 16, 32, .{ 0, -16, 0 }, 32);
    try testing.expectEqual(@as(i32, 0), pd_max[0]);
    try testing.expectEqual(@as(i32, 0), pd_max[1]);
    try testing.expectEqual(@as(i32, 0), pd_max[2]);
}

test "camera inside chunk draws all normals" {
    const pos = [3]i32{ 0, -16, 0 };
    for (0..6) |n| {
        try testing.expect(shouldDraw(pos, 16, 2, 16, n));
    }
}

test "camera at chunk boundary (edge) draws all normals" {
    const pos = [3]i32{ 0, -16, 0 };
    // Min corner
    for (0..6) |n| {
        try testing.expect(shouldDraw(pos, 0, -16, 0, n));
    }
    // Max corner
    for (0..6) |n| {
        try testing.expect(shouldDraw(pos, 32, 16, 32, n));
    }
}

test "camera in front of chunk (+Z side)" {
    const pos = [3]i32{ 0, -16, 0 };
    // Camera at z=40, inside X and Y range
    try testing.expect(shouldDraw(pos, 16, 0, 40, 0)); // +Z: draw
    try testing.expect(!shouldDraw(pos, 16, 0, 40, 1)); // -Z: cull
    // Camera inside X/Y range → those normals all visible
    try testing.expect(shouldDraw(pos, 16, 0, 40, 2)); // -X: draw
    try testing.expect(shouldDraw(pos, 16, 0, 40, 3)); // +X: draw
    try testing.expect(shouldDraw(pos, 16, 0, 40, 4)); // +Y: draw
    try testing.expect(shouldDraw(pos, 16, 0, 40, 5)); // -Y: draw
}

test "camera behind chunk (-Z side)" {
    const pos = [3]i32{ 0, -16, 0 };
    try testing.expect(!shouldDraw(pos, 16, 0, -10, 0)); // +Z: cull
    try testing.expect(shouldDraw(pos, 16, 0, -10, 1)); // -Z: draw
}

test "camera above chunk draws top, culls bottom" {
    const pos = [3]i32{ 0, -16, 0 };
    try testing.expect(shouldDraw(pos, 16, 30, 16, 4)); // +Y: draw
    try testing.expect(!shouldDraw(pos, 16, 30, 16, 5)); // -Y: cull
}

test "camera below chunk draws bottom, culls top" {
    const pos = [3]i32{ 0, -16, 0 };
    try testing.expect(!shouldDraw(pos, 16, -30, 16, 4)); // +Y: cull
    try testing.expect(shouldDraw(pos, 16, -30, 16, 5)); // -Y: draw
}

test "camera just outside chunk boundary sees near faces" {
    const pos = [3]i32{ 0, -16, 0 };
    // Camera at x=-1 (just outside left)
    try testing.expect(shouldDraw(pos, -1, 0, 16, 2)); // -X: draw
    try testing.expect(!shouldDraw(pos, -1, 0, 16, 3)); // +X: cull
    // Camera at x=33 (just outside right)
    try testing.expect(shouldDraw(pos, 33, 0, 16, 3)); // +X: draw
    try testing.expect(!shouldDraw(pos, 33, 0, 16, 2)); // -X: cull
}

test "diagonal camera position" {
    const pos = [3]i32{ 0, -16, 0 };
    // Camera at upper-right-front corner
    try testing.expect(shouldDraw(pos, 40, 25, 40, 0)); // +Z: draw
    try testing.expect(shouldDraw(pos, 40, 25, 40, 3)); // +X: draw
    try testing.expect(shouldDraw(pos, 40, 25, 40, 4)); // +Y: draw
    try testing.expect(!shouldDraw(pos, 40, 25, 40, 1)); // -Z: cull
    try testing.expect(!shouldDraw(pos, 40, 25, 40, 2)); // -X: cull
    try testing.expect(!shouldDraw(pos, 40, 25, 40, 5)); // -Y: cull
}

test "camera directly above center - side faces all visible" {
    // This was the bug with the dot-product approach:
    // camera above center had dot=0 for side normals → incorrectly culled
    const pos = [3]i32{ 0, -16, 0 };
    // Camera at (16, 25, 16) - directly above center, inside X/Z range
    try testing.expect(shouldDraw(pos, 16, 25, 16, 0)); // +Z
    try testing.expect(shouldDraw(pos, 16, 25, 16, 1)); // -Z
    try testing.expect(shouldDraw(pos, 16, 25, 16, 2)); // -X
    try testing.expect(shouldDraw(pos, 16, 25, 16, 3)); // +X
    try testing.expect(shouldDraw(pos, 16, 25, 16, 4)); // +Y: draw
    try testing.expect(!shouldDraw(pos, 16, 25, 16, 5)); // -Y: cull
}

test "camera at chunk Z edge sees both Z normals" {
    // Camera at z=0, chunk from z=0 to z=32
    // The old dot-product approach culled +Z here (center-based), but
    // the camera IS at the chunk edge and can see blocks just inside.
    const pos = [3]i32{ 0, -16, 0 };
    try testing.expect(shouldDraw(pos, 16, 0, 0, 0)); // +Z: draw (camera at min Z edge)
    try testing.expect(shouldDraw(pos, 16, 0, 0, 1)); // -Z: draw (camera at min Z edge)
}

test "typical gameplay - standing on flat terrain" {
    // Camera at (0, 2, 0). Chunk (cx=2, cz=2) → pos (0, -16, 0)
    // Camera inside this chunk → all normals
    const pos_center = [3]i32{ 0, -16, 0 };
    for (0..6) |n| {
        try testing.expect(shouldDraw(pos_center, 0, 2, 0, n));
    }

    // Chunk to the right: pos (32, -16, 0). Camera x=0 < 32.
    const pos_right = [3]i32{ 32, -16, 0 };
    try testing.expect(!shouldDraw(pos_right, 0, 2, 0, 3)); // +X: cull
    try testing.expect(shouldDraw(pos_right, 0, 2, 0, 2)); // -X: draw
    // Camera y=2 is inside Y range → both Y normals visible
    try testing.expect(shouldDraw(pos_right, 0, 2, 0, 4)); // +Y: draw
    try testing.expect(shouldDraw(pos_right, 0, 2, 0, 5)); // -Y: draw
    // Camera z=0 is at chunk min Z → both Z normals visible
    try testing.expect(shouldDraw(pos_right, 0, 2, 0, 0)); // +Z: draw
    try testing.expect(shouldDraw(pos_right, 0, 2, 0, 1)); // -Z: draw
}
