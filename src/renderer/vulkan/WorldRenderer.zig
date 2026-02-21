const std = @import("std");
const vk = @import("../../platform/volk.zig");
const c = @import("../../platform/c.zig").c;
const ShaderCompiler = @import("ShaderCompiler.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const vk_utils = @import("vk_utils.zig");
const types = @import("types.zig");
const GpuVertex = types.GpuVertex;
const DrawCommand = types.DrawCommand;
const tracy = @import("../../platform/tracy.zig");
const zlm = @import("zlm");
const WorldState = @import("../../world/WorldState.zig");
pub const TextureManager = @import("TextureManager.zig").TextureManager;
const TlsfAllocator = @import("../../allocators/TlsfAllocator.zig").TlsfAllocator;

// Initial GPU heap capacities (grown if needed, but these cover typical worlds)
const INITIAL_VERTEX_CAPACITY: u32 = 600_000; // ~16.8 MB at 28 bytes/vert
const INITIAL_INDEX_CAPACITY: u32 = 900_000; // ~3.6 MB at 4 bytes/index

pub const WorldRenderer = struct {
    texture_manager: TextureManager,
    pipeline_layout: vk.VkPipelineLayout,
    graphics_pipeline: vk.VkPipeline,

    // Indirect draw buffers (host-visible)
    indirect_buffer: vk.VkBuffer,
    indirect_buffer_memory: vk.VkDeviceMemory,
    indirect_count_buffer: vk.VkBuffer,
    indirect_count_buffer_memory: vk.VkDeviceMemory,

    // GPU heaps (device-local)
    vertex_buffer: vk.VkBuffer,
    vertex_buffer_memory: vk.VkDeviceMemory,
    index_buffer: vk.VkBuffer,
    index_buffer_memory: vk.VkDeviceMemory,

    // Chunk positions SSBO (host-visible)
    chunk_positions_buffer: vk.VkBuffer,
    chunk_positions_buffer_memory: vk.VkDeviceMemory,

    // TLSF sub-allocators for vertex and index heaps
    vertex_tlsf: TlsfAllocator,
    index_tlsf: TlsfAllocator,

    // Per-chunk state: TLSF allocation info (indexed by chunk flat index)
    chunk_vertex_alloc: [WorldState.TOTAL_WORLD_CHUNKS]?TlsfAllocator.Allocation,
    chunk_index_alloc: [WorldState.TOTAL_WORLD_CHUNKS]?TlsfAllocator.Allocation,

    // Draw count (number of non-empty chunks for indirect draw limit)
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
            .indirect_buffer = null,
            .indirect_buffer_memory = null,
            .indirect_count_buffer = null,
            .indirect_count_buffer_memory = null,
            .vertex_buffer = null,
            .vertex_buffer_memory = null,
            .index_buffer = null,
            .index_buffer_memory = null,
            .chunk_positions_buffer = null,
            .chunk_positions_buffer_memory = null,
            .vertex_tlsf = TlsfAllocator.init(INITIAL_VERTEX_CAPACITY),
            .index_tlsf = TlsfAllocator.init(INITIAL_INDEX_CAPACITY),
            .chunk_vertex_alloc = .{null} ** WorldState.TOTAL_WORLD_CHUNKS,
            .chunk_index_alloc = .{null} ** WorldState.TOTAL_WORLD_CHUNKS,
            .draw_count = 0,
        };

        try self.createGraphicsPipeline(shader_compiler, ctx, swapchain_format, texture_manager.bindless_descriptor_set_layout);
        errdefer {
            vk.destroyPipeline(ctx.device, self.graphics_pipeline, null);
            vk.destroyPipelineLayout(ctx.device, self.pipeline_layout, null);
        }

        try self.createIndirectBuffer(ctx);
        try self.createPersistentMeshBuffers(ctx);

        return self;
    }

    pub fn deinit(self: *WorldRenderer, device: vk.VkDevice) void {
        const tz = tracy.zone(@src(), "WorldRenderer.deinit");
        defer tz.end();

        vk.destroyBuffer(device, self.indirect_buffer, null);
        vk.freeMemory(device, self.indirect_buffer_memory, null);
        vk.destroyBuffer(device, self.indirect_count_buffer, null);
        vk.freeMemory(device, self.indirect_count_buffer_memory, null);
        vk.destroyPipeline(device, self.graphics_pipeline, null);
        vk.destroyPipelineLayout(device, self.pipeline_layout, null);
        vk.destroyBuffer(device, self.vertex_buffer, null);
        vk.freeMemory(device, self.vertex_buffer_memory, null);
        vk.destroyBuffer(device, self.index_buffer, null);
        vk.freeMemory(device, self.index_buffer_memory, null);
        vk.destroyBuffer(device, self.chunk_positions_buffer, null);
        vk.freeMemory(device, self.chunk_positions_buffer_memory, null);
        self.texture_manager.deinit(device);
    }

    /// Upload mesh data for a single chunk into the GPU heaps at its TLSF-assigned region.
    pub fn uploadChunkData(
        self: *WorldRenderer,
        ctx: *const VulkanContext,
        coord: WorldState.ChunkCoord,
        vertices: []const GpuVertex,
        indices: []const u32,
        vertex_count: u32,
        index_count: u32,
    ) !void {
        const tz = tracy.zone(@src(), "uploadChunkData");
        defer tz.end();

        const slot = coord.flatIndex();

        // Free old allocation if this chunk was previously meshed
        if (self.chunk_vertex_alloc[slot]) |va| {
            self.vertex_tlsf.free(va.offset);
            self.chunk_vertex_alloc[slot] = null;
        }
        if (self.chunk_index_alloc[slot]) |ia| {
            self.index_tlsf.free(ia.offset);
            self.chunk_index_alloc[slot] = null;
        }

        // Empty chunk: write a zero-count draw command
        if (vertex_count == 0 or index_count == 0) {
            self.writeDrawCommand(ctx, slot, .{
                .index_count = 0,
                .instance_count = 0,
                .first_index = 0,
                .vertex_offset = 0,
                .first_instance = 0,
            });
            self.writeChunkPosition(ctx, slot, coord.position());
            self.recomputeDrawCount(ctx);
            return;
        }

        // Allocate TLSF regions
        const va = self.vertex_tlsf.alloc(vertex_count) orelse {
            std.log.err("TLSF vertex heap full (requested {}, largest free {})", .{
                vertex_count, self.vertex_tlsf.largestFree(),
            });
            return error.OutOfMemory;
        };
        errdefer self.vertex_tlsf.free(va.offset);

        const ia = self.index_tlsf.alloc(index_count) orelse {
            std.log.err("TLSF index heap full (requested {}, largest free {})", .{
                index_count, self.index_tlsf.largestFree(),
            });
            self.vertex_tlsf.free(va.offset);
            return error.OutOfMemory;
        };

        self.chunk_vertex_alloc[slot] = va;
        self.chunk_index_alloc[slot] = ia;

        // Stage vertex data into GPU buffer at TLSF offset
        {
            const vb_size: vk.VkDeviceSize = @intCast(@as(u64, vertex_count) * @sizeOf(GpuVertex));
            var staging_buffer: vk.VkBuffer = undefined;
            var staging_memory: vk.VkDeviceMemory = undefined;
            try vk_utils.createBuffer(
                ctx,
                vb_size,
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
            try vk.mapMemory(ctx.device, staging_memory, 0, vb_size, 0, &data);
            const dst: [*]GpuVertex = @ptrCast(@alignCast(data));
            @memcpy(dst[0..vertex_count], vertices[0..vertex_count]);
            vk.unmapMemory(ctx.device, staging_memory);

            const dst_offset: vk.VkDeviceSize = @intCast(@as(u64, va.offset) * @sizeOf(GpuVertex));
            try vk_utils.copyBufferRegion(ctx, staging_buffer, 0, self.vertex_buffer, dst_offset, vb_size);
        }

        // Stage index data into GPU buffer at TLSF offset
        {
            const ib_size: vk.VkDeviceSize = @intCast(@as(u64, index_count) * @sizeOf(u32));
            var staging_buffer: vk.VkBuffer = undefined;
            var staging_memory: vk.VkDeviceMemory = undefined;
            try vk_utils.createBuffer(
                ctx,
                ib_size,
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
            try vk.mapMemory(ctx.device, staging_memory, 0, ib_size, 0, &data);
            const dst: [*]u32 = @ptrCast(@alignCast(data));
            @memcpy(dst[0..index_count], indices[0..index_count]);
            vk.unmapMemory(ctx.device, staging_memory);

            const dst_offset: vk.VkDeviceSize = @intCast(@as(u64, ia.offset) * @sizeOf(u32));
            try vk_utils.copyBufferRegion(ctx, staging_buffer, 0, self.index_buffer, dst_offset, ib_size);
        }

        // Update this chunk's draw command: indices start at ia.offset,
        // vertex_offset shifts chunk-local indices into the right vertex region
        self.writeDrawCommand(ctx, slot, .{
            .index_count = index_count,
            .instance_count = 1,
            .first_index = ia.offset,
            .vertex_offset = @intCast(va.offset),
            .first_instance = 0,
        });

        self.writeChunkPosition(ctx, slot, coord.position());
        self.recomputeDrawCount(ctx);
    }

    fn writeDrawCommand(self: *WorldRenderer, ctx: *const VulkanContext, slot: usize, cmd: DrawCommand) void {
        const offset: vk.VkDeviceSize = @intCast(slot * @sizeOf(DrawCommand));
        var data: ?*anyopaque = null;
        vk.mapMemory(ctx.device, self.indirect_buffer_memory, offset, @sizeOf(DrawCommand), 0, &data) catch return;
        const dst: *DrawCommand = @ptrCast(@alignCast(data));
        dst.* = cmd;
        vk.unmapMemory(ctx.device, self.indirect_buffer_memory);
    }

    fn writeChunkPosition(self: *WorldRenderer, ctx: *const VulkanContext, slot: usize, pos: [4]f32) void {
        const offset: vk.VkDeviceSize = @intCast(slot * @sizeOf([4]f32));
        var data: ?*anyopaque = null;
        vk.mapMemory(ctx.device, self.chunk_positions_buffer_memory, offset, @sizeOf([4]f32), 0, &data) catch return;
        const dst: *[4]f32 = @ptrCast(@alignCast(data));
        dst.* = pos;
        vk.unmapMemory(ctx.device, self.chunk_positions_buffer_memory);
    }

    fn recomputeDrawCount(self: *WorldRenderer, ctx: *const VulkanContext) void {
        // With fixed-slot indirect draws, draw_count = TOTAL_WORLD_CHUNKS.
        // Empty chunks have index_count=0 and instance_count=0, so the GPU skips them.
        self.draw_count = WorldState.TOTAL_WORLD_CHUNKS;

        var data: ?*anyopaque = null;
        vk.mapMemory(ctx.device, self.indirect_count_buffer_memory, 0, @sizeOf(u32), 0, &data) catch return;
        const count_ptr: *u32 = @ptrCast(@alignCast(data));
        count_ptr.* = self.draw_count;
        vk.unmapMemory(ctx.device, self.indirect_count_buffer_memory);
    }

    pub fn record(self: *const WorldRenderer, command_buffer: vk.VkCommandBuffer, mvp: *const [16]f32) void {
        if (self.draw_count == 0) return;

        vk.cmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.graphics_pipeline);

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

        vk.cmdBindIndexBuffer(command_buffer, self.index_buffer, 0, vk.VK_INDEX_TYPE_UINT32);

        vk.cmdPushConstants(
            command_buffer,
            self.pipeline_layout,
            vk.VK_SHADER_STAGE_VERTEX_BIT,
            0,
            @sizeOf(zlm.Mat4),
            mvp,
        );

        vk.cmdDrawIndexedIndirectCount(
            command_buffer,
            self.indirect_buffer,
            0,
            self.indirect_count_buffer,
            0,
            self.draw_count,
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
            .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
            .offset = 0,
            .size = 64, // sizeof(mat4)
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

        std.log.info("Graphics pipeline created", .{});
    }

    fn createIndirectBuffer(self: *WorldRenderer, ctx: *const VulkanContext) !void {
        const tz = tracy.zone(@src(), "createIndirectBuffer");
        defer tz.end();

        const buffer_size: vk.VkDeviceSize = WorldState.TOTAL_WORLD_CHUNKS * @sizeOf(vk.VkDrawIndexedIndirectCommand);

        try vk_utils.createBuffer(
            ctx,
            buffer_size,
            vk.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT | vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &self.indirect_buffer,
            &self.indirect_buffer_memory,
        );

        // Zero-initialize (all chunks start with index_count=0, instance_count=0)
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

        std.log.info("Indirect draw buffers created (max {} draw commands)", .{WorldState.TOTAL_WORLD_CHUNKS});
    }

    fn createPersistentMeshBuffers(self: *WorldRenderer, ctx: *const VulkanContext) !void {
        const tz = tracy.zone(@src(), "createPersistentMeshBuffers");
        defer tz.end();

        const vb_capacity: vk.VkDeviceSize = @as(u64, INITIAL_VERTEX_CAPACITY) * @sizeOf(GpuVertex);
        try vk_utils.createBuffer(
            ctx,
            vb_capacity,
            vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT | vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            &self.vertex_buffer,
            &self.vertex_buffer_memory,
        );

        const ib_capacity: vk.VkDeviceSize = @as(u64, INITIAL_INDEX_CAPACITY) * @sizeOf(u32);
        try vk_utils.createBuffer(
            ctx,
            ib_capacity,
            vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT | vk.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
            vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            &self.index_buffer,
            &self.index_buffer_memory,
        );

        const cp_capacity: vk.VkDeviceSize = WorldState.TOTAL_WORLD_CHUNKS * @sizeOf([4]f32);
        try vk_utils.createBuffer(
            ctx,
            cp_capacity,
            vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &self.chunk_positions_buffer,
            &self.chunk_positions_buffer_memory,
        );

        self.texture_manager.updateVertexDescriptor(ctx, self.vertex_buffer, vb_capacity);
        self.texture_manager.updateChunkPositions(ctx, self.chunk_positions_buffer, cp_capacity);

        std.log.info("Persistent mesh buffers created ({}V / {}I, {:.1} MB)", .{
            INITIAL_VERTEX_CAPACITY,
            INITIAL_INDEX_CAPACITY,
            @as(f64, @floatFromInt(vb_capacity + ib_capacity + cp_capacity)) / (1024.0 * 1024.0),
        });
    }
};
