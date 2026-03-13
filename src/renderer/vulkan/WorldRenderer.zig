const std = @import("std");
const vk = @import("../../platform/volk.zig");
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
const gpu_alloc_mod = @import("../../allocators/GpuAllocator.zig");
const GpuAllocator = gpu_alloc_mod.GpuAllocator;
const BufferAllocation = gpu_alloc_mod.BufferAllocation;

pub const INITIAL_FACE_CAPACITY: u32 = 128_000_000;
pub const INITIAL_LIGHT_CAPACITY: u32 = 48_000_000;
const ChunkMap = @import("../../world/ChunkMap.zig").ChunkMap;

const MAX_FACES_PER_DRAW: u32 = 16_384;
pub const TOTAL_RENDER_CHUNKS: u32 = 25_000;
const LAYER_COUNT = WorldState.LAYER_COUNT;
const MAX_INDIRECT_COMMANDS: u32 = TOTAL_RENDER_CHUNKS * 6;

pub const WorldRenderer = struct {
    texture_manager: TextureManager,
    gpu_alloc: *GpuAllocator,
    pipeline_layout: vk.VkPipelineLayout,
    graphics_pipeline: vk.VkPipeline,
    translucent_pipeline: vk.VkPipeline,
    overdraw_pipeline: vk.VkPipeline,

    indirect_alloc: BufferAllocation,
    indirect_count_alloc: BufferAllocation,

    face_alloc: BufferAllocation,
    light_alloc: BufferAllocation,
    model_alloc: BufferAllocation,
    static_index_alloc: BufferAllocation,

    chunk_data_alloc: BufferAllocation,

    face_tlsf: TlsfAllocator,
    light_tlsf: TlsfAllocator,

    chunk_face_alloc: [TOTAL_RENDER_CHUNKS]?TlsfAllocator.Allocation,
    chunk_light_alloc: [TOTAL_RENDER_CHUNKS]?TlsfAllocator.Allocation,
    chunk_data: [TOTAL_RENDER_CHUNKS]ChunkData,
    chunk_layer_counts: [TOTAL_RENDER_CHUNKS][LAYER_COUNT][6]u32,

    // Slot pool: maps ChunkKey → GPU slot index
    allocator: std.mem.Allocator,
    chunk_slot_map: std.AutoHashMap(WorldState.ChunkKey, u16),
    lod_slot_map: std.AutoHashMap(WorldState.ChunkKey, u16),
    free_slots: [TOTAL_RENDER_CHUNKS]u16,
    free_slot_count: u32,

    draw_counts: [LAYER_COUNT]u32,

    pub fn initInPlace(
        self: *WorldRenderer,
        allocator: std.mem.Allocator,
        shader_compiler: *ShaderCompiler,
        ctx: *const VulkanContext,
        swapchain_format: vk.VkFormat,
        gpu_alloc: *GpuAllocator,
    ) !void {
        const tz = tracy.zone(@src(), "WorldRenderer.init");
        defer tz.end();

        var texture_manager = try TextureManager.init(allocator, ctx);
        errdefer texture_manager.deinit(ctx.device);

        self.texture_manager = texture_manager;
        self.gpu_alloc = gpu_alloc;
        self.pipeline_layout = null;
        self.graphics_pipeline = null;
        self.translucent_pipeline = null;
        self.overdraw_pipeline = null;
        self.indirect_alloc = undefined;
        self.indirect_count_alloc = undefined;
        self.face_alloc = undefined;
        self.light_alloc = undefined;
        self.model_alloc = undefined;
        self.static_index_alloc = undefined;
        self.chunk_data_alloc = undefined;
        self.face_tlsf.initInPlace(allocator, INITIAL_FACE_CAPACITY);
        self.light_tlsf.initInPlace(allocator, INITIAL_LIGHT_CAPACITY);
        @memset(&self.chunk_face_alloc, null);
        @memset(&self.chunk_light_alloc, null);
        @memset(&self.chunk_data, ChunkData{
            .position = .{ 0, 0, 0 },
            .light_start = 0,
            .face_start = 0,
            .face_counts = .{ 0, 0, 0, 0, 0, 0 },
            .voxel_size = 1,
        });
        self.allocator = allocator;
        self.chunk_slot_map = std.AutoHashMap(WorldState.ChunkKey, u16).init(allocator);
        self.lod_slot_map = std.AutoHashMap(WorldState.ChunkKey, u16).init(allocator);
        // Initialize free slot stack (all slots available, highest first so lowest pops first)
        for (0..TOTAL_RENDER_CHUNKS) |i| {
            self.free_slots[i] = @intCast(TOTAL_RENDER_CHUNKS - 1 - i);
        }
        self.free_slot_count = TOTAL_RENDER_CHUNKS;
        @memset(&self.chunk_layer_counts, .{ .{ 0, 0, 0, 0, 0, 0 } } ** LAYER_COUNT);
        self.draw_counts = .{ 0, 0, 0 };

        try self.createGraphicsPipeline(shader_compiler, ctx, swapchain_format, texture_manager.bindless_descriptor_set_layout);
        errdefer {
            vk.destroyPipeline(ctx.device, self.overdraw_pipeline, null);
            vk.destroyPipeline(ctx.device, self.translucent_pipeline, null);
            vk.destroyPipeline(ctx.device, self.graphics_pipeline, null);
            vk.destroyPipelineLayout(ctx.device, self.pipeline_layout, null);
        }

        try self.createIndirectBuffer(ctx, gpu_alloc);
        try self.createPersistentBuffers(ctx, gpu_alloc);
    }

    pub fn deinit(self: *WorldRenderer, device: vk.VkDevice) void {
        const tz = tracy.zone(@src(), "WorldRenderer.deinit");
        defer tz.end();

        self.face_tlsf.deinit();
        self.light_tlsf.deinit();
        self.chunk_slot_map.deinit();
        self.lod_slot_map.deinit();
        self.gpu_alloc.destroyBuffer(self.indirect_alloc);
        self.gpu_alloc.destroyBuffer(self.indirect_count_alloc);
        vk.destroyPipeline(device, self.overdraw_pipeline, null);
        vk.destroyPipeline(device, self.translucent_pipeline, null);
        vk.destroyPipeline(device, self.graphics_pipeline, null);
        vk.destroyPipelineLayout(device, self.pipeline_layout, null);
        self.gpu_alloc.destroyBuffer(self.face_alloc);
        self.gpu_alloc.destroyBuffer(self.light_alloc);
        self.gpu_alloc.destroyBuffer(self.model_alloc);
        self.gpu_alloc.destroyBuffer(self.static_index_alloc);
        self.gpu_alloc.destroyBuffer(self.chunk_data_alloc);
        self.texture_manager.deinit(device);
    }

    /// Get or allocate a GPU slot for a chunk key. Returns null if no slots available.
    pub fn getOrAllocateSlot(self: *WorldRenderer, key: WorldState.ChunkKey) ?u16 {
        // Already has a slot?
        if (self.chunk_slot_map.get(key)) |slot| return slot;

        // Allocate from free list
        if (self.free_slot_count == 0) {
            std.log.warn("WorldRenderer: no free GPU slots for chunk ({},{},{})", .{ key.cx, key.cy, key.cz });
            return null;
        }
        self.free_slot_count -= 1;
        const slot = self.free_slots[self.free_slot_count];
        self.chunk_slot_map.put(key, slot) catch {
            // Put failed — return slot to free list
            self.free_slots[self.free_slot_count] = slot;
            self.free_slot_count += 1;
            return null;
        };
        return slot;
    }

    /// Release all GPU slots and reset TLSF allocators. Call after stopping the worker pipeline.
    pub fn clearAllSlots(self: *WorldRenderer) void {
        const empty_chunk = ChunkData{
            .position = .{ 0, 0, 0 },
            .light_start = 0,
            .face_start = 0,
            .face_counts = .{ 0, 0, 0, 0, 0, 0 },
            .voxel_size = 1,
        };

        var it = self.chunk_slot_map.iterator();
        while (it.next()) |entry| {
            const slot = entry.value_ptr.*;
            self.chunk_data[slot] = empty_chunk;
            self.writeChunkData(slot);
            self.chunk_face_alloc[slot] = null;
            self.chunk_light_alloc[slot] = null;
        }

        self.chunk_slot_map.clearRetainingCapacity();

        // Also clear LOD slots
        var lod_it = self.lod_slot_map.iterator();
        while (lod_it.next()) |lod_entry| {
            const lod_slot = lod_entry.value_ptr.*;
            self.chunk_data[lod_slot] = empty_chunk;
            self.writeChunkData(lod_slot);
            self.chunk_face_alloc[lod_slot] = null;
            self.chunk_light_alloc[lod_slot] = null;
        }
        self.lod_slot_map.clearRetainingCapacity();

        // Reset free slot stack (all slots available, highest first so lowest pops first)
        for (0..TOTAL_RENDER_CHUNKS) |i| {
            self.free_slots[i] = @intCast(TOTAL_RENDER_CHUNKS - 1 - i);
        }
        self.free_slot_count = TOTAL_RENDER_CHUNKS;

        // Reset TLSF allocators so the new world starts with a clean GPU heap
        self.face_tlsf.reset();
        self.light_tlsf.reset();
    }

    /// Release a GPU slot for a chunk key. TLSF allocs must be freed separately.
    pub fn releaseSlot(self: *WorldRenderer, key: WorldState.ChunkKey) void {
        const slot = self.chunk_slot_map.get(key) orelse return;
        // Clear chunk data
        self.chunk_data[slot] = .{
            .position = .{ 0, 0, 0 },
            .light_start = 0,
            .face_start = 0,
            .face_counts = .{ 0, 0, 0, 0, 0, 0 },
            .voxel_size = 1,
        };
        self.writeChunkData(slot);
        self.chunk_face_alloc[slot] = null;
        self.chunk_light_alloc[slot] = null;
        // Return slot to free list
        self.free_slots[self.free_slot_count] = slot;
        self.free_slot_count += 1;
        _ = self.chunk_slot_map.remove(key);
    }

    /// Get or allocate a GPU slot for a LOD chunk key (LOD-space coords).
    pub fn getOrAllocateLodSlot(self: *WorldRenderer, key: WorldState.ChunkKey) ?u16 {
        if (self.lod_slot_map.get(key)) |slot| return slot;
        if (self.free_slot_count == 0) {
            std.log.warn("WorldRenderer: no free GPU slots for LOD chunk ({},{},{})", .{ key.cx, key.cy, key.cz });
            return null;
        }
        self.free_slot_count -= 1;
        const slot = self.free_slots[self.free_slot_count];
        self.lod_slot_map.put(key, slot) catch {
            self.free_slots[self.free_slot_count] = slot;
            self.free_slot_count += 1;
            return null;
        };
        return slot;
    }

    /// Release a GPU slot for a LOD chunk key.
    pub fn releaseLodSlot(self: *WorldRenderer, key: WorldState.ChunkKey) void {
        const slot = self.lod_slot_map.get(key) orelse return;
        self.chunk_data[slot] = .{
            .position = .{ 0, 0, 0 },
            .light_start = 0,
            .face_start = 0,
            .face_counts = .{ 0, 0, 0, 0, 0, 0 },
            .voxel_size = 1,
        };
        self.writeChunkData(slot);
        self.chunk_face_alloc[slot] = null;
        self.chunk_light_alloc[slot] = null;
        self.free_slots[self.free_slot_count] = slot;
        self.free_slot_count += 1;
        _ = self.lod_slot_map.remove(key);
    }

    pub fn writeChunkData(self: *WorldRenderer, slot: usize) void {
        const base_ptr = self.chunk_data_alloc.mapped_ptr orelse return;
        const offset = slot * @sizeOf(ChunkData);
        const dst: *ChunkData = @ptrCast(@alignCast(base_ptr + offset));
        dst.* = self.chunk_data[slot];
    }

    pub fn buildIndirectCommands(self: *WorldRenderer, ctx: *const VulkanContext, camera_pos: zlm.Vec3) void {
        _ = ctx;
        const tz = tracy.zone(@src(), "buildIndirectCommands");
        defer tz.end();

        const commands: [*]DrawCommand = @ptrCast(@alignCast(self.indirect_alloc.mapped_ptr orelse return));

        var layer_counts: [LAYER_COUNT]u32 = .{ 0, 0, 0 };

        // Iterate both LOD0 and LOD slot maps
        const slot_maps = [_]*const std.AutoHashMap(WorldState.ChunkKey, u16){
            &self.chunk_slot_map,
            &self.lod_slot_map,
        };
        for (slot_maps) |slot_map| {
            var it = slot_map.iterator();
            while (it.next()) |entry| {
                const slot = entry.value_ptr.*;
                const cd = self.chunk_data[slot];

                var total: u32 = 0;
                for (cd.face_counts) |fc| total += fc;
                if (total == 0) continue;

                const cs: i32 = @as(i32, WorldState.CHUNK_SIZE) * @as(i32, @intCast(@max(1, cd.voxel_size)));
                const pd = aabbSignedDist(camera_pos.x, camera_pos.y, camera_pos.z, cd.position, cs);
                const lfc = self.chunk_layer_counts[slot];

                // Faces are stored: [layer0_n0..n5][layer1_n0..n5][layer2_n0..n5]
                var layer_offset: u32 = 0;
                for (0..LAYER_COUNT) |layer| {
                    var normal_offset: u32 = 0;
                    for (0..6) |normal_idx| {
                        const fc = lfc[layer][normal_idx];
                        if (fc > 0 and isNormalVisible(normal_idx, pd)) {
                            const cmd_idx = layer * MAX_INDIRECT_COMMANDS + layer_counts[layer];
                            commands[cmd_idx] = .{
                                .index_count = fc * 6,
                                .instance_count = 1,
                                .first_index = 0,
                                .vertex_offset = @intCast((cd.face_start + layer_offset + normal_offset) * 4),
                                .first_instance = @intCast(slot),
                            };
                            layer_counts[layer] += 1;
                        }
                        normal_offset += fc;
                    }
                    layer_offset += normal_offset;
                }
            }
        }

        const count_base: [*]u32 = @ptrCast(@alignCast(self.indirect_count_alloc.mapped_ptr orelse return));
        for (0..LAYER_COUNT) |l| {
            count_base[l] = layer_counts[l];
        }

        self.draw_counts = layer_counts;
    }

    pub fn record(self: *const WorldRenderer, command_buffer: vk.VkCommandBuffer, mvp: *const [16]f32, overdraw_active: bool, ambient_light: [3]f32, fog_color: [3]f32, fog_start: f32, fog_end: f32) void {
        var total_draws: u32 = 0;
        for (self.draw_counts) |dc| total_draws += dc;
        if (total_draws == 0) return;

        // Bind shared state
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

        vk.cmdBindIndexBuffer(command_buffer, self.static_index_alloc.buffer, 0, vk.VK_INDEX_TYPE_UINT16);

        vk.cmdPushConstants(
            command_buffer,
            self.pipeline_layout,
            vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            0,
            @sizeOf(zlm.Mat4),
            mvp,
        );
        const contrast: f32 = 0.25;
        vk.cmdPushConstants(
            command_buffer,
            self.pipeline_layout,
            vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            @sizeOf(zlm.Mat4),
            @sizeOf(f32),
            @ptrCast(&contrast),
        );
        vk.cmdPushConstants(
            command_buffer,
            self.pipeline_layout,
            vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            80,
            @sizeOf([3]f32),
            @ptrCast(&ambient_light),
        );

        // Fog parameters (offset 96: vec3 fogColor, 108: fogStart, 112: fogEnd)
        const FogPC = extern struct { color: [3]f32, start: f32, end: f32 };
        const fog_pc = FogPC{ .color = fog_color, .start = fog_start, .end = fog_end };
        vk.cmdPushConstants(
            command_buffer,
            self.pipeline_layout,
            vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            96,
            @sizeOf(FogPC),
            @ptrCast(&fog_pc),
        );

        const cmd_stride: u32 = @sizeOf(vk.VkDrawIndexedIndirectCommand);
        const count_stride: u32 = @sizeOf(u32);

        // Pass 1: Opaque (no blend, depth write)
        // Pass 2: Cutout (same pipeline as opaque for now)
        for (0..2) |layer| {
            if (self.draw_counts[layer] == 0) continue;
            const pipeline = if (overdraw_active) self.overdraw_pipeline else self.graphics_pipeline;
            vk.cmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
            vk.cmdDrawIndexedIndirectCount(
                command_buffer,
                self.indirect_alloc.buffer,
                @as(vk.VkDeviceSize, layer) * MAX_INDIRECT_COMMANDS * cmd_stride,
                self.indirect_count_alloc.buffer,
                @as(vk.VkDeviceSize, layer) * count_stride,
                MAX_INDIRECT_COMMANDS,
                cmd_stride,
            );
        }

        // Pass 3: Translucent (alpha blend, no depth write)
        if (self.draw_counts[2] > 0 and !overdraw_active) {
            vk.cmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.translucent_pipeline);
            vk.cmdDrawIndexedIndirectCount(
                command_buffer,
                self.indirect_alloc.buffer,
                @as(vk.VkDeviceSize, 2) * MAX_INDIRECT_COMMANDS * cmd_stride,
                self.indirect_count_alloc.buffer,
                @as(vk.VkDeviceSize, 2) * count_stride,
                MAX_INDIRECT_COMMANDS,
                cmd_stride,
            );
        }
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

        const vert_spirv = try shader_compiler.compile("terrain.vert", .vertex);
        defer shader_compiler.allocator.free(vert_spirv);

        const frag_spirv = try shader_compiler.compile("terrain.frag", .fragment);
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

        // Opaque: no blending
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
            .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .offset = 0,
            .size = 116,
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

        const dynamic_states = [_]vk.VkDynamicState{ vk.VK_DYNAMIC_STATE_VIEWPORT, vk.VK_DYNAMIC_STATE_SCISSOR };
        const dynamic_state_info = vk.VkPipelineDynamicStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
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

        // Translucent pipeline: alpha blend, depth test but no depth write
        const translucent_depth_stencil = vk.VkPipelineDepthStencilStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthTestEnable = vk.VK_TRUE,
            .depthWriteEnable = vk.VK_FALSE,
            .depthCompareOp = vk.VK_COMPARE_OP_LESS,
            .depthBoundsTestEnable = vk.VK_FALSE,
            .stencilTestEnable = vk.VK_FALSE,
            .front = std.mem.zeroes(vk.VkStencilOpState),
            .back = std.mem.zeroes(vk.VkStencilOpState),
            .minDepthBounds = 0.0,
            .maxDepthBounds = 1.0,
        };

        const translucent_blend_attachment = vk.VkPipelineColorBlendAttachmentState{
            .blendEnable = vk.VK_TRUE,
            .srcColorBlendFactor = vk.VK_BLEND_FACTOR_SRC_ALPHA,
            .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .colorBlendOp = vk.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ZERO,
            .alphaBlendOp = vk.VK_BLEND_OP_ADD,
            .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT | vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT,
        };

        const translucent_color_blending = vk.VkPipelineColorBlendStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .logicOpEnable = vk.VK_FALSE,
            .logicOp = 0,
            .attachmentCount = 1,
            .pAttachments = &translucent_blend_attachment,
            .blendConstants = .{ 0.0, 0.0, 0.0, 0.0 },
        };

        const translucent_pipeline_info = vk.VkGraphicsPipelineCreateInfo{
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
            .pDepthStencilState = &translucent_depth_stencil,
            .pColorBlendState = &translucent_color_blending,
            .pDynamicState = &dynamic_state_info,
            .layout = self.pipeline_layout,
            .renderPass = null,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };

        const translucent_pipeline_infos = &[_]vk.VkGraphicsPipelineCreateInfo{translucent_pipeline_info};
        var translucent_pipelines: [1]vk.VkPipeline = undefined;
        try vk.createGraphicsPipelines(device, ctx.pipeline_cache, 1, translucent_pipeline_infos, null, &translucent_pipelines);
        self.translucent_pipeline = translucent_pipelines[0];

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

    fn createIndirectBuffer(self: *WorldRenderer, ctx: *const VulkanContext, gpu_alloc: *GpuAllocator) !void {
        _ = ctx;
        const tz = tracy.zone(@src(), "createIndirectBuffer");
        defer tz.end();

        const buffer_size: vk.VkDeviceSize = @as(u64, MAX_INDIRECT_COMMANDS) * LAYER_COUNT * @sizeOf(vk.VkDrawIndexedIndirectCommand);

        self.indirect_alloc = try gpu_alloc.createBuffer(
            buffer_size,
            vk.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT | vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            .host_visible,
        );

        const dst: [*]u8 = self.indirect_alloc.mapped_ptr.?;
        @memset(dst[0..@intCast(buffer_size)], 0);

        self.indirect_count_alloc = try gpu_alloc.createBuffer(
            @sizeOf(u32) * LAYER_COUNT,
            vk.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT | vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            .host_visible,
        );

        const count_base: [*]u32 = @ptrCast(@alignCast(self.indirect_count_alloc.mapped_ptr.?));
        for (0..LAYER_COUNT) |l| count_base[l] = 0;

        std.log.info("Indirect draw buffers created (max {} draw commands per layer, {} layers)", .{ MAX_INDIRECT_COMMANDS, LAYER_COUNT });
    }

    fn createPersistentBuffers(self: *WorldRenderer, ctx: *const VulkanContext, gpu_alloc: *GpuAllocator) !void {
        const tz = tracy.zone(@src(), "createPersistentBuffers");
        defer tz.end();

        const fb_capacity: vk.VkDeviceSize = @as(u64, INITIAL_FACE_CAPACITY) * @sizeOf(FaceData);
        const lb_capacity: vk.VkDeviceSize = @as(u64, INITIAL_LIGHT_CAPACITY) * @sizeOf(LightEntry);
        const transfer_usage = vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT | vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;

        if (ctx.separate_transfer_family) {
            const families = [_]u32{ ctx.queue_family_index, ctx.transfer_queue_family };
            self.face_alloc = try gpu_alloc.createBufferConcurrent(fb_capacity, transfer_usage, .device_local, &families);
            self.light_alloc = try gpu_alloc.createBufferConcurrent(lb_capacity, transfer_usage, .device_local, &families);
        } else {
            self.face_alloc = try gpu_alloc.createBuffer(fb_capacity, transfer_usage, .device_local);
            self.light_alloc = try gpu_alloc.createBuffer(lb_capacity, transfer_usage, .device_local);
        }

        const model_size: vk.VkDeviceSize = WorldState.TOTAL_MODEL_COUNT * @sizeOf(QuadModel);
        self.model_alloc = try gpu_alloc.createBuffer(
            model_size,
            vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT | vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            .device_local,
        );
        try self.uploadModelBuffer(ctx, model_size);

        const index_count: u64 = @as(u64, MAX_FACES_PER_DRAW) * 6;
        const ib_capacity: vk.VkDeviceSize = index_count * @sizeOf(u16);
        self.static_index_alloc = try gpu_alloc.createBuffer(
            ib_capacity,
            vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT | vk.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
            .device_local,
        );
        try self.uploadStaticIndexBuffer(ctx, ib_capacity);

        const cd_capacity: vk.VkDeviceSize = TOTAL_RENDER_CHUNKS * @sizeOf(ChunkData);
        self.chunk_data_alloc = try gpu_alloc.createBuffer(
            cd_capacity,
            vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            .host_visible,
        );

        self.texture_manager.updateFaceDescriptor(ctx, self.face_alloc.buffer, fb_capacity);
        self.texture_manager.updateChunkDataDescriptor(ctx, self.chunk_data_alloc.buffer, cd_capacity);
        self.texture_manager.updateModelDescriptor(ctx, self.model_alloc.buffer, model_size);
        self.texture_manager.updateLightDescriptor(ctx, self.light_alloc.buffer, lb_capacity);

        std.log.info("Persistent mesh buffers created ({}F / {}L, {:.1} MB)", .{
            INITIAL_FACE_CAPACITY,
            INITIAL_LIGHT_CAPACITY,
            @as(f64, @floatFromInt(fb_capacity + lb_capacity + model_size + ib_capacity + cd_capacity)) / (1024.0 * 1024.0),
        });
    }

    fn uploadModelBuffer(self: *WorldRenderer, ctx: *const VulkanContext, model_size: vk.VkDeviceSize) !void {
        var models: [WorldState.TOTAL_MODEL_COUNT]QuadModel = undefined;

        // Standard full-cube face models (0-5)
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

        // Extra quad models for shaped blocks (6+)
        for (0..WorldState.EXTRA_MODEL_COUNT) |i| {
            const em = WorldState.extra_quad_models[i];
            var corners: [12]f32 = undefined;
            var uvs: [8]f32 = undefined;
            for (0..4) |v| {
                corners[v * 3 + 0] = em.corners[v][0];
                corners[v * 3 + 1] = em.corners[v][1];
                corners[v * 3 + 2] = em.corners[v][2];
                uvs[v * 2 + 0] = em.uvs[v][0];
                uvs[v * 2 + 1] = em.uvs[v][1];
            }
            models[6 + i] = .{
                .corners = corners,
                .uvs = uvs,
                .normal = em.normal,
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
        @memcpy(dst[0..WorldState.TOTAL_MODEL_COUNT], &models);
        vk.unmapMemory(ctx.device, staging_memory);

        try vk_utils.copyBuffer(ctx, staging_buffer, self.model_alloc.buffer, model_size);
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
        try vk_utils.copyBuffer(ctx, staging_buffer, self.static_index_alloc.buffer, ib_capacity);
    }
};

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

pub fn isNormalVisible(normal_idx: usize, pd: [3]i32) bool {
    return switch (normal_idx) {
        0 => pd[2] >= 0,
        1 => pd[2] <= 0,
        2 => pd[0] <= 0,
        3 => pd[0] >= 0,
        4 => pd[1] >= 0,
        5 => pd[1] <= 0,
        else => true,
    };
}


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
    const pd = aabbSignedDist(40, -20, -5, .{ 0, -16, 0 }, 32);
    try testing.expectEqual(@as(i32, 8), pd[0]);
    try testing.expectEqual(@as(i32, -4), pd[1]);
    try testing.expectEqual(@as(i32, -5), pd[2]);
}

test "aabbSignedDist: camera at chunk boundary edges" {
    const pd_min = aabbSignedDist(0, -16, 0, .{ 0, -16, 0 }, 32);
    try testing.expectEqual(@as(i32, 0), pd_min[0]);
    try testing.expectEqual(@as(i32, 0), pd_min[1]);
    try testing.expectEqual(@as(i32, 0), pd_min[2]);

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
    for (0..6) |n| {
        try testing.expect(shouldDraw(pos, 0, -16, 0, n));
    }
    for (0..6) |n| {
        try testing.expect(shouldDraw(pos, 32, 16, 32, n));
    }
}

test "camera in front of chunk (+Z side)" {
    const pos = [3]i32{ 0, -16, 0 };
    try testing.expect(shouldDraw(pos, 16, 0, 40, 0));
    try testing.expect(!shouldDraw(pos, 16, 0, 40, 1));
    try testing.expect(shouldDraw(pos, 16, 0, 40, 2));
    try testing.expect(shouldDraw(pos, 16, 0, 40, 3));
    try testing.expect(shouldDraw(pos, 16, 0, 40, 4));
    try testing.expect(shouldDraw(pos, 16, 0, 40, 5));
}

test "camera behind chunk (-Z side)" {
    const pos = [3]i32{ 0, -16, 0 };
    try testing.expect(!shouldDraw(pos, 16, 0, -10, 0));
    try testing.expect(shouldDraw(pos, 16, 0, -10, 1));
}

test "camera above chunk draws top, culls bottom" {
    const pos = [3]i32{ 0, -16, 0 };
    try testing.expect(shouldDraw(pos, 16, 30, 16, 4));
    try testing.expect(!shouldDraw(pos, 16, 30, 16, 5));
}

test "camera below chunk draws bottom, culls top" {
    const pos = [3]i32{ 0, -16, 0 };
    try testing.expect(!shouldDraw(pos, 16, -30, 16, 4));
    try testing.expect(shouldDraw(pos, 16, -30, 16, 5));
}

test "camera just outside chunk boundary sees near faces" {
    const pos = [3]i32{ 0, -16, 0 };
    try testing.expect(shouldDraw(pos, -1, 0, 16, 2));
    try testing.expect(!shouldDraw(pos, -1, 0, 16, 3));
    try testing.expect(shouldDraw(pos, 33, 0, 16, 3));
    try testing.expect(!shouldDraw(pos, 33, 0, 16, 2));
}

test "diagonal camera position" {
    const pos = [3]i32{ 0, -16, 0 };
    try testing.expect(shouldDraw(pos, 40, 25, 40, 0));
    try testing.expect(shouldDraw(pos, 40, 25, 40, 3));
    try testing.expect(shouldDraw(pos, 40, 25, 40, 4));
    try testing.expect(!shouldDraw(pos, 40, 25, 40, 1));
    try testing.expect(!shouldDraw(pos, 40, 25, 40, 2));
    try testing.expect(!shouldDraw(pos, 40, 25, 40, 5));
}

test "camera directly above center - side faces all visible" {
    const pos = [3]i32{ 0, -16, 0 };
    try testing.expect(shouldDraw(pos, 16, 25, 16, 0));
    try testing.expect(shouldDraw(pos, 16, 25, 16, 1));
    try testing.expect(shouldDraw(pos, 16, 25, 16, 2));
    try testing.expect(shouldDraw(pos, 16, 25, 16, 3));
    try testing.expect(shouldDraw(pos, 16, 25, 16, 4));
    try testing.expect(!shouldDraw(pos, 16, 25, 16, 5));
}

test "camera at chunk Z edge sees both Z normals" {
    const pos = [3]i32{ 0, -16, 0 };
    try testing.expect(shouldDraw(pos, 16, 0, 0, 0));
    try testing.expect(shouldDraw(pos, 16, 0, 0, 1));
}

test "typical gameplay - standing on flat terrain" {
    const pos_center = [3]i32{ 0, -16, 0 };
    for (0..6) |n| {
        try testing.expect(shouldDraw(pos_center, 0, 2, 0, n));
    }

    const pos_right = [3]i32{ 32, -16, 0 };
    try testing.expect(!shouldDraw(pos_right, 0, 2, 0, 3));
    try testing.expect(shouldDraw(pos_right, 0, 2, 0, 2));
    try testing.expect(shouldDraw(pos_right, 0, 2, 0, 4));
    try testing.expect(shouldDraw(pos_right, 0, 2, 0, 5));
    try testing.expect(shouldDraw(pos_right, 0, 2, 0, 0));
    try testing.expect(shouldDraw(pos_right, 0, 2, 0, 1));
}
