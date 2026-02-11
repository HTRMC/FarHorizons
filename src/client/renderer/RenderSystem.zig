const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const volk = @import("volk");
const vk = volk.c;
const shared = @import("Shared");
const Logger = shared.Logger;

const enable_validation = builtin.mode == .Debug;
const platform = @import("Platform");
const ShaderManager = @import("ShaderManager.zig").ShaderManager;
const stb_image = @import("stb_image");

const GpuBuffer = @import("GpuBuffer.zig");
const ManagedBuffer = GpuBuffer.ManagedBuffer;
const GpuDevice = @import("GpuDevice.zig").GpuDevice;
const RenderPass = @import("RenderPass.zig");
const RenderPipelines = @import("RenderPipelines.zig");
const DescriptorPoolBuilder = @import("descriptor/DescriptorPoolBuilder.zig").DescriptorPoolBuilder;
const DescriptorSetManager = @import("descriptor/DescriptorSetManager.zig").DescriptorSetManager;
const DescriptorSetLayoutBuilder = @import("pipeline/DescriptorSetLayoutBuilder.zig").DescriptorSetLayoutBuilder;
const VulkanPipelineFactory = @import("pipeline/VulkanPipelineFactory.zig").VulkanPipelineFactory;
const ImageViewHelper = @import("resource/ImageViewHelper.zig").ImageViewHelper;
const TextureLoader = @import("resource/TextureLoader.zig").TextureLoader;
const GPUDrivenTypes = @import("GPUDrivenTypes.zig");
const ComputePipeline = @import("ComputePipeline.zig");
const StagingRing = @import("buffer/StagingRing.zig");

const MAX_FRAMES_IN_FLIGHT = 2;

pub const UniformBufferObject = extern struct {
    model: [16]f32,
    view: [16]f32,
    proj: [16]f32,
};

pub const Vertex = extern struct {
    pos: [3]f32,
    color: [3]f32,
    uv: [2]f32,
    tex_index: u32,

    pub fn getBindingDescription() vk.VkVertexInputBindingDescription {
        return .{
            .binding = 0,
            .stride = @sizeOf(Vertex),
            .inputRate = vk.VK_VERTEX_INPUT_RATE_VERTEX,
        };
    }

    pub fn getAttributeDescriptions() [4]vk.VkVertexInputAttributeDescription {
        return .{
            .{
                .binding = 0,
                .location = 0,
                .format = vk.VK_FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(Vertex, "pos"),
            },
            .{
                .binding = 0,
                .location = 1,
                .format = vk.VK_FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(Vertex, "color"),
            },
            .{
                .binding = 0,
                .location = 2,
                .format = vk.VK_FORMAT_R32G32_SFLOAT,
                .offset = @offsetOf(Vertex, "uv"),
            },
            .{
                .binding = 0,
                .location = 3,
                .format = vk.VK_FORMAT_R32_UINT,
                .offset = @offsetOf(Vertex, "tex_index"),
            },
        };
    }
};

/// Compact vertex format for chunk meshes (12 bytes vs 36 bytes)
/// Position encoded as A2B10G10R10_UNORM (chunk-local [0,1] via (pos+2)/20)
/// AO encoded as 2-bit index in alpha bits of position word
/// UV as R16G16_UNORM, tex_index as low 8 bits of a u32
pub const CompactVertex = extern struct {
    /// Packed position (10 bits each XYZ) + AO index (2 bits) as A2B10G10R10_UNORM
    pos_ao: u32,
    /// Packed UV coordinates as R16G16_UNORM
    uv: u32,
    /// Texture index in low 8 bits, upper 24 bits reserved
    data: u32,

    /// Position encoding range: chunk-local positions mapped to [0, 1] via (pos + 2.0) / 20.0
    /// This covers the range [-2, 18] which handles 0..15 block positions plus model overhang
    const POS_BIAS = 2.0;
    const POS_RANGE = 20.0;

    /// AO brightness lookup table (must match AmbientOcclusion.AO_BRIGHTNESS)
    pub const AO_TABLE: [4]f32 = .{ 0.2, 0.5, 0.8, 1.0 };

    /// Convert AO float to 2-bit index
    pub fn aoToIndex(ao: f32) u2 {
        // Threshold-based: 0.2->0, 0.5->1, 0.8->2, 1.0->3
        if (ao > 0.9) return 3;
        if (ao > 0.65) return 2;
        if (ao > 0.35) return 1;
        return 0;
    }

    /// Pack a vertex from world-space position (chunk-local), AO, UV, and tex_index
    /// pos_x/y/z should be chunk-local (no world offset added)
    pub fn pack(pos_x: f32, pos_y: f32, pos_z: f32, ao: f32, u_coord: f32, v_coord: f32, tex_index: u32) CompactVertex {
        // Quantize position to 10-bit unorm
        const qx: u32 = @intFromFloat(std.math.clamp((pos_x + POS_BIAS) / POS_RANGE, 0.0, 1.0) * 1023.0 + 0.5);
        const qy: u32 = @intFromFloat(std.math.clamp((pos_y + POS_BIAS) / POS_RANGE, 0.0, 1.0) * 1023.0 + 0.5);
        const qz: u32 = @intFromFloat(std.math.clamp((pos_z + POS_BIAS) / POS_RANGE, 0.0, 1.0) * 1023.0 + 0.5);
        const ao_idx: u32 = @intCast(aoToIndex(ao));

        // A2B10G10R10: bits [0:9]=R(x), [10:19]=G(y), [20:29]=B(z), [30:31]=A(ao)
        const pos_ao_packed: u32 = qx | (qy << 10) | (qz << 20) | (ao_idx << 30);

        // UV as 16-bit unorm
        const qu: u32 = @intFromFloat(std.math.clamp(u_coord, 0.0, 1.0) * 65535.0 + 0.5);
        const qv: u32 = @intFromFloat(std.math.clamp(v_coord, 0.0, 1.0) * 65535.0 + 0.5);
        const uv_packed: u32 = qu | (qv << 16);

        return .{
            .pos_ao = pos_ao_packed,
            .uv = uv_packed,
            .data = tex_index & 0xFF,
        };
    }

    pub fn getBindingDescription() vk.VkVertexInputBindingDescription {
        return .{
            .binding = 0,
            .stride = @sizeOf(CompactVertex),
            .inputRate = vk.VK_VERTEX_INPUT_RATE_VERTEX,
        };
    }

    pub fn getAttributeDescriptions() [3]vk.VkVertexInputAttributeDescription {
        return .{
            .{
                .binding = 0,
                .location = 0,
                .format = vk.VK_FORMAT_A2B10G10R10_UNORM_PACK32,
                .offset = @offsetOf(CompactVertex, "pos_ao"),
            },
            .{
                .binding = 0,
                .location = 1,
                .format = vk.VK_FORMAT_R16G16_UNORM,
                .offset = @offsetOf(CompactVertex, "uv"),
            },
            .{
                .binding = 0,
                .location = 2,
                .format = vk.VK_FORMAT_R32_UINT,
                .offset = @offsetOf(CompactVertex, "data"),
            },
        };
    }

    comptime {
        std.debug.assert(@sizeOf(CompactVertex) == 12);
    }
};

/// Vertex format for hotbar block icons (isometric 3D preview)
pub const IconVertex = extern struct {
    pos: [3]f32,      // NDC position (pre-transformed)
    uv: [2]f32,       // Texture coordinates
    tex_index: u32,   // Texture array layer
    tint: f32,        // Brightness tint (0.0-1.0)

    pub fn getBindingDescription() vk.VkVertexInputBindingDescription {
        return .{
            .binding = 0,
            .stride = @sizeOf(IconVertex),
            .inputRate = vk.VK_VERTEX_INPUT_RATE_VERTEX,
        };
    }

    pub fn getAttributeDescriptions() [4]vk.VkVertexInputAttributeDescription {
        return .{
            .{
                .binding = 0,
                .location = 0,
                .format = vk.VK_FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(IconVertex, "pos"),
            },
            .{
                .binding = 0,
                .location = 1,
                .format = vk.VK_FORMAT_R32G32_SFLOAT,
                .offset = @offsetOf(IconVertex, "uv"),
            },
            .{
                .binding = 0,
                .location = 2,
                .format = vk.VK_FORMAT_R32_UINT,
                .offset = @offsetOf(IconVertex, "tex_index"),
            },
            .{
                .binding = 0,
                .location = 3,
                .format = vk.VK_FORMAT_R32_SFLOAT,
                .offset = @offsetOf(IconVertex, "tint"),
            },
        };
    }
};

pub const RenderSystem = struct {
    const Self = @This();
    const logger = Logger.scoped(Self);
    const DeferredBuffer = struct { handle: vk.VkBuffer, memory: vk.VkDeviceMemory, ready_at: u64 };

    instance: vk.VkInstance = null,
    debug_messenger: vk.VkDebugUtilsMessengerEXT = null,
    surface: vk.VkSurfaceKHR = null,
    physical_device: vk.VkPhysicalDevice = null,
    device: vk.VkDevice = null,

    graphics_queue: vk.VkQueue = null,
    present_queue: vk.VkQueue = null,
    transfer_queue: vk.VkQueue = null,
    graphics_family: u32 = 0,
    present_family: u32 = 0,
    transfer_family: u32 = 0,
    has_dedicated_transfer: bool = false,

    /// Upload timeline semaphore reference (set by ChunkManager after UploadThread init)
    upload_timeline_ref: ?vk.VkSemaphore = null,
    /// Latest upload timeline value to wait on (set each frame by ChunkManager)
    last_upload_timeline_value: u64 = 0,

    swapchain: vk.VkSwapchainKHR = null,
    swapchain_images: []vk.VkImage = &.{},
    swapchain_image_views: []vk.VkImageView = &.{},
    swapchain_format: vk.VkFormat = vk.VK_FORMAT_UNDEFINED,
    swapchain_extent: vk.VkExtent2D = .{ .width = 0, .height = 0 },

    depth_image: vk.VkImage = null,
    depth_image_memory: vk.VkDeviceMemory = null,
    depth_image_view: vk.VkImageView = null,
    depth_format: vk.VkFormat = vk.VK_FORMAT_UNDEFINED,

    render_pass: vk.VkRenderPass = null,
    framebuffers: []vk.VkFramebuffer = &.{},

    pipeline_layout: vk.VkPipelineLayout = null,
    graphics_pipeline: vk.VkPipeline = null,

    // Layer-specific pipelines: [solid, cutout, translucent]
    layer_pipelines: [3]vk.VkPipeline = .{ null, null, null },

    indirect_buffer: ManagedBuffer = .{},
    indirect_buffer_capacity: u32 = 0,

    ui_pipeline_layout: vk.VkPipelineLayout = null,
    ui_pipeline: vk.VkPipeline = null,
    hotbar_pipeline: vk.VkPipeline = null, // Separate pipeline with alpha blending for hotbar
    ui_descriptor_set_layout: vk.VkDescriptorSetLayout = null,
    ui_descriptor_pool: vk.VkDescriptorPool = null,
    ui_descriptor_sets: [MAX_FRAMES_IN_FLIGHT]vk.VkDescriptorSet = .{null} ** MAX_FRAMES_IN_FLIGHT,
    crosshair_buffer: ManagedBuffer = .{},
    crosshair_texture: vk.VkImage = null,
    crosshair_texture_memory: vk.VkDeviceMemory = null,
    crosshair_texture_view: vk.VkImageView = null,
    crosshair_sampler: vk.VkSampler = null,

    // Hotbar UI resources
    hotbar_texture: vk.VkImage = null,
    hotbar_texture_memory: vk.VkDeviceMemory = null,
    hotbar_texture_view: vk.VkImageView = null,
    hotbar_sampler: vk.VkSampler = null,
    hotbar_buffer: ManagedBuffer = .{},

    hotbar_selection_texture: vk.VkImage = null,
    hotbar_selection_texture_memory: vk.VkDeviceMemory = null,
    hotbar_selection_texture_view: vk.VkImageView = null,
    hotbar_selection_sampler: vk.VkSampler = null,
    hotbar_selection_buffer: ManagedBuffer = .{},

    hotbar_descriptor_sets: [MAX_FRAMES_IN_FLIGHT]vk.VkDescriptorSet = .{null} ** MAX_FRAMES_IN_FLIGHT,
    hotbar_selection_descriptor_sets: [MAX_FRAMES_IN_FLIGHT]vk.VkDescriptorSet = .{null} ** MAX_FRAMES_IN_FLIGHT,
    hotbar_selected_slot: u8 = 0,

    // Hotbar block icon rendering
    hotbar_icon_pipeline: vk.VkPipeline = null,
    hotbar_icon_pipeline_layout: vk.VkPipelineLayout = null,
    hotbar_icon_buffer: ManagedBuffer = .{},
    hotbar_icon_vertex_count: u32 = 0,
    hotbar_icon_descriptor_sets: [MAX_FRAMES_IN_FLIGHT]vk.VkDescriptorSet = .{null} ** MAX_FRAMES_IN_FLIGHT,
    hotbar_icon_texture_indices: [9]?[6]u32 = .{null} ** 9, // Stored for recreation on resize

    line_pipeline_layout: vk.VkPipelineLayout = null,
    line_pipeline: vk.VkPipeline = null,
    line_buffer: ManagedBuffer = .{},
    line_vertex_count: u32 = 0,

    entity_pipeline_layout: vk.VkPipelineLayout = null,
    entity_pipeline: vk.VkPipeline = null,
    bindless_entity_descriptor_set_layout: vk.VkDescriptorSetLayout = null,
    bindless_entity_descriptor_set: vk.VkDescriptorSet = null,

    vertex_buffer: vk.VkBuffer = null,
    vertex_buffer_memory: vk.VkDeviceMemory = null,
    index_buffer: vk.VkBuffer = null,
    index_buffer_memory: vk.VkDeviceMemory = null,
    index_count: u32 = 0,

    uniform_buffers: [MAX_FRAMES_IN_FLIGHT]vk.VkBuffer = .{null} ** MAX_FRAMES_IN_FLIGHT,
    uniform_buffers_memory: [MAX_FRAMES_IN_FLIGHT]vk.VkDeviceMemory = .{null} ** MAX_FRAMES_IN_FLIGHT,
    uniform_buffers_mapped: [MAX_FRAMES_IN_FLIGHT]?*anyopaque = .{null} ** MAX_FRAMES_IN_FLIGHT,

    /// Set externally by TextureManager
    texture_image_view: vk.VkImageView = null,
    texture_sampler: vk.VkSampler = null,

    descriptor_set_layout: vk.VkDescriptorSetLayout = null,
    descriptor_pool: vk.VkDescriptorPool = null,
    descriptor_sets: [MAX_FRAMES_IN_FLIGHT]vk.VkDescriptorSet = .{null} ** MAX_FRAMES_IN_FLIGHT,

    entity_descriptor_pool: vk.VkDescriptorPool = null,
    entity_descriptor_sets: [MAX_FRAMES_IN_FLIGHT]vk.VkDescriptorSet = .{null} ** MAX_FRAMES_IN_FLIGHT,

    baby_entity_descriptor_sets: [MAX_FRAMES_IN_FLIGHT]vk.VkDescriptorSet = .{null} ** MAX_FRAMES_IN_FLIGHT,

    command_pool: vk.VkCommandPool = null,
    command_buffers: []vk.VkCommandBuffer = &.{},

    image_available_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.VkSemaphore = .{null} ** MAX_FRAMES_IN_FLIGHT,
    render_finished_semaphores: []vk.VkSemaphore = &.{}, // Per swapchain image, indexed by image_index
    in_flight_fences: [MAX_FRAMES_IN_FLIGHT]vk.VkFence = .{null} ** MAX_FRAMES_IN_FLIGHT,
    current_frame: u32 = 0,

    // Timeline semaphore GC
    gpu_timeline: vk.VkSemaphore = null,
    timeline_value: u64 = 0,
    last_submitted_value: u64 = 0,

    gc_queue: std.ArrayListUnmanaged(DeferredBuffer) = .{},

    allocator: std.mem.Allocator = undefined,
    io: Io = undefined,
    gpu_device: ?GpuDevice = null,
    window: ?*platform.Window = null,
    shader_manager: ?ShaderManager = null,

    // GPU-driven rendering buffers (Phase 1)
    /// GPU buffer containing ChunkGPUData for all loaded chunks
    chunk_metadata_buffer: ManagedBuffer = .{},
    /// Visibility flags per chunk (u32 per chunk, stores frameId when visible)
    visibility_buffer: ManagedBuffer = .{},
    /// Atomic counters for draw command counts
    draw_count_buffer: ManagedBuffer = .{},
    /// GPU-generated draw commands (written by cmdgen.comp)
    gpu_draw_buffer: ManagedBuffer = .{},
    /// Host-visible staging buffer for metadata uploads (persists across frames)
    metadata_staging_buffer: ManagedBuffer = .{},
    /// Current write offset in metadata staging buffer
    metadata_staging_offset: u64 = 0,
    /// Maps chunk slot ID to chunk metadata index
    chunk_slot_allocator: ?GPUDrivenTypes.SlotAllocator = null,

    /// Callback for pre-render GPU uploads (called with command buffer before render pass)
    pre_render_callback: ?*const fn (vk.VkCommandBuffer, ?*anyopaque) void = null,
    pre_render_callback_ctx: ?*anyopaque = null,

    // GPU-driven compute pipelines (Phase 2)
    compute_descriptor_set_layout: vk.VkDescriptorSetLayout = null,
    compute_pipeline_layout: vk.VkPipelineLayout = null,
    compute_descriptor_pool: vk.VkDescriptorPool = null,
    compute_descriptor_set: vk.VkDescriptorSet = null,
    prep_pipeline: vk.VkPipeline = null,
    cmdgen_pipeline: vk.VkPipeline = null,

    pub fn init(allocator: std.mem.Allocator, io: Io) Self {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn initBackend(self: *Self, window: *platform.Window) !void {
        self.window = window;

        // Initialize shader manager (enable runtime compilation for shader pack support)
        // Set to false if you want to disable runtime shader compilation
        const enable_runtime_shaders = true;
        self.shader_manager = ShaderManager.init(self.allocator, self.io, enable_runtime_shaders) catch |err| blk: {
            logger.warn("Failed to initialize shader manager with runtime compilation: {}", .{err});
            // Fall back to embedded shaders only
            break :blk ShaderManager.init(self.allocator, self.io, false) catch null;
        };

        if (!platform.isVulkanSupported()) {
            logger.err("Vulkan is not supported on this system", .{});
            return error.VulkanNotSupported;
        }

        volk.init() catch {
            logger.err("Failed to initialize Vulkan loader", .{});
            return error.VulkanLoaderFailed;
        };

        const vk_version = volk.getInstanceVersion();
        logger.info("Vulkan version: {}.{}.{}", .{
            (vk_version >> 22) & 0x7F,
            (vk_version >> 12) & 0x3FF,
            vk_version & 0xFFF,
        });

        try self.createInstance();
        try self.createSurface();
        try self.pickPhysicalDevice();
        try self.createLogicalDevice();
        try self.createSwapchain(null);
        try self.createImageViews();
        try self.createDepthResources();
        try self.createRenderPass();
        try self.createDescriptorSetLayout();
        try self.createGraphicsPipeline();
        try self.createUIDescriptorSetLayout();
        try self.createUIPipeline();
        try self.createLinePipeline();
        try self.createHotbarIconPipeline();
        // Entity pipeline created separately via initEntityPipeline() after bindless resources are set
        try self.createFramebuffers();
        try self.createCommandPool();

        // Initialize GPU device abstraction
        self.gpu_device = GpuDevice.init(
            self.device,
            self.physical_device,
            self.command_pool,
            self.graphics_queue,
            self.allocator,
        );

        try self.loadCrosshairTexture();
        try self.loadHotbarTextures();
        try self.createUIDescriptorPool();
        try self.createUIDescriptorSets();
        try self.createHotbarDescriptorSets();
        try self.createHotbarIconDescriptorSets();
        try self.createCrosshairBuffer();
        try self.createHotbarBuffer();
        try self.createHotbarSelectionBuffer();
        // Note: Vertex/Index buffers are created by uploadMesh() with actual geometry
        try self.createUniformBuffers();
        try self.createIndirectBuffer();
        try self.createGPUDrivenBuffers();
        try self.createComputePipelines();
        // Note: Texture resources and descriptor sets are created after TextureManager is initialized
        // See initializeTextures() which must be called after setting texture resources
        try self.createCommandBuffers();
        try self.createSyncObjects();

        logger.info("Vulkan renderer initialized", .{});
    }

    /// Wait for the GPU to finish all submitted work.
    /// Call before destroying any Vulkan resources outside of RenderSystem.
    pub fn waitIdle(self: *Self) void {
        if (self.device) |device| {
            if (vk.vkDeviceWaitIdle) |wait| {
                _ = wait(device);
            }
        }
    }

    pub fn shutdown(self: *Self) void {
        self.waitIdle();
        self.flushAllGarbage();

        // Shutdown shader manager
        if (self.shader_manager) |*sm| {
            sm.deinit();
            self.shader_manager = null;
        }

        self.destroySyncObjects();
        self.destroyCommandPool();
        self.destroyDescriptorPool();
        // Note: texture_image_view and texture_sampler are owned by TextureManager
        self.destroyUniformBuffers();
        self.destroyIndirectBuffer();
        self.destroyComputePipelines();
        self.destroyGPUDrivenBuffers();
        self.destroyBuffers();
        self.destroyFramebuffers();
        self.destroyPipeline();
        self.destroyDescriptorSetLayout();
        self.destroyRenderPass();
        self.destroyDepthResources();
        self.destroyImageViews();
        self.destroySwapchain();
        self.destroyDevice();
        self.destroySurface();
        self.destroyDebugMessenger();
        self.destroyInstance();

        logger.info("Render system shut down", .{});
    }

    /// Load a shader pack from a directory path
    /// This will compile the shaders and recreate the graphics pipeline
    pub fn loadShaderPack(self: *Self, pack_path: []const u8) !void {
        if (self.shader_manager) |*sm| {
            try sm.loadShaderPack(pack_path);
            try self.recreateGraphicsPipeline();
            logger.info("Loaded shader pack: {s}", .{pack_path});
        } else {
            logger.err("Shader manager not initialized", .{});
            return error.ShaderManagerNotInitialized;
        }
    }

    /// Unload current shader pack and return to default shaders
    pub fn unloadShaderPack(self: *Self) !void {
        if (self.shader_manager) |*sm| {
            sm.unloadShaderPack();
            try self.recreateGraphicsPipeline();
            logger.info("Unloaded shader pack, using default shaders", .{});
        }
    }

    /// Recreate the graphics pipeline (used after shader changes)
    fn recreateGraphicsPipeline(self: *Self) !void {
        const vkDeviceWaitIdle = vk.vkDeviceWaitIdle orelse return error.VulkanFunctionNotLoaded;
        const vkDestroyPipeline = vk.vkDestroyPipeline orelse return error.VulkanFunctionNotLoaded;
        const vkDestroyPipelineLayout = vk.vkDestroyPipelineLayout orelse return error.VulkanFunctionNotLoaded;

        // Wait for GPU to finish
        _ = vkDeviceWaitIdle(self.device);

        // Destroy old pipelines
        if (self.graphics_pipeline) |pipeline| {
            vkDestroyPipeline(self.device, pipeline, null);
            self.graphics_pipeline = null;
        }
        // Destroy layer-specific pipelines
        for (&self.layer_pipelines) |*pipeline| {
            if (pipeline.*) |p| {
                vkDestroyPipeline(self.device, p, null);
                pipeline.* = null;
            }
        }
        if (self.pipeline_layout) |layout| {
            vkDestroyPipelineLayout(self.device, layout, null);
            self.pipeline_layout = null;
        }

        // Create new pipeline with new shaders
        try self.createGraphicsPipeline();
    }

    /// Check if runtime shader compilation is available
    pub fn isRuntimeShaderCompilationEnabled(self: *const Self) bool {
        if (self.shader_manager) |sm| {
            return sm.isRuntimeCompilationEnabled();
        }
        return false;
    }

    /// Set texture resources from TextureManager and create descriptor sets
    pub fn setTextureResources(self: *Self, image_view: vk.VkImageView, sampler: vk.VkSampler) !void {
        self.texture_image_view = image_view;
        self.texture_sampler = sampler;

        // Now we can create descriptor pool and sets
        try self.createDescriptorPool();
        try self.createDescriptorSets();

        // Update hotbar icon descriptor sets to point to block texture array
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            DescriptorSetManager.updateSampler(
                self.device,
                self.hotbar_icon_descriptor_sets[i],
                0,
                image_view,
                sampler,
            );
        }

        logger.info("Texture resources set and descriptors created", .{});
    }

    /// Set entity texture resources and create entity descriptors
    pub fn setEntityTextureResources(self: *Self, image_view: vk.VkImageView, sampler: vk.VkSampler) !void {
        // Create entity descriptor pool and sets
        try self.createEntityDescriptorPool();
        try self.createEntityDescriptorSets(image_view, sampler);

        logger.info("Entity texture resources set and descriptors created", .{});
    }

    /// Set baby entity texture resources (call after setEntityTextureResources)
    /// DEPRECATED: Use setBindlessEntityResources for bindless texture support
    pub fn setBabyEntityTextureResources(self: *Self, image_view: vk.VkImageView, sampler: vk.VkSampler) !void {
        try self.createBabyEntityDescriptorSets(image_view, sampler);
        logger.info("Baby entity texture resources set and descriptors created", .{});
    }

    /// Set a callback to be invoked before each render pass with the command buffer
    /// Used for GPU-driven rendering metadata uploads
    pub fn setPreRenderCallback(
        self: *Self,
        callback: ?*const fn (vk.VkCommandBuffer, ?*anyopaque) void,
        ctx: ?*anyopaque,
    ) void {
        self.pre_render_callback = callback;
        self.pre_render_callback_ctx = ctx;
    }

    /// Set bindless entity texture resources from EntityTextureManager
    /// This must be called before initEntityPipeline
    pub fn setBindlessEntityResources(
        self: *Self,
        descriptor_set_layout: vk.VkDescriptorSetLayout,
        descriptor_set: vk.VkDescriptorSet,
    ) void {
        self.bindless_entity_descriptor_set_layout = descriptor_set_layout;
        self.bindless_entity_descriptor_set = descriptor_set;

        // Update the UBO binding in the bindless descriptor set to use our uniform buffer
        // Use uniform_buffers[0] - since the data is updated in-place before each frame,
        // binding to the buffer handle works for all frames
        const vkUpdateDescriptorSets = vk.vkUpdateDescriptorSets orelse return;

        const buffer_info = vk.VkDescriptorBufferInfo{
            .buffer = self.uniform_buffers[0],
            .offset = 0,
            .range = @sizeOf(UniformBufferObject),
        };

        const ubo_write = vk.VkWriteDescriptorSet{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = descriptor_set,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = &buffer_info,
            .pTexelBufferView = null,
        };

        vkUpdateDescriptorSets(self.device, 1, &ubo_write, 0, null);

        logger.info("Bindless entity resources set", .{});
    }

    /// Initialize the entity pipeline (call after setBindlessEntityResources)
    pub fn initEntityPipeline(self: *Self) !void {
        try self.createEntityPipeline();
        logger.info("Entity pipeline initialized", .{});
    }

    /// Get Vulkan device (for TextureManager)
    pub fn getDevice(self: *const Self) vk.VkDevice {
        return self.device;
    }

    /// Get Vulkan physical device (for TextureManager)
    pub fn getPhysicalDevice(self: *const Self) vk.VkPhysicalDevice {
        return self.physical_device;
    }

    /// Get command pool (for TextureManager)
    pub fn getCommandPool(self: *const Self) vk.VkCommandPool {
        return self.command_pool;
    }

    /// Get graphics queue (for TextureManager)
    pub fn getGraphicsQueue(self: *const Self) vk.VkQueue {
        return self.graphics_queue;
    }

    /// Get graphics queue family index (for command pool creation)
    pub fn getGraphicsFamily(self: *const Self) u32 {
        return self.graphics_family;
    }

    /// Get the transfer queue (dedicated DMA or graphics queue fallback)
    pub fn getTransferQueue(self: *const Self) vk.VkQueue {
        return self.transfer_queue;
    }

    /// Get the transfer queue family index
    pub fn getTransferFamily(self: *const Self) u32 {
        return self.transfer_family;
    }

    /// Whether a dedicated transfer queue exists (separate from graphics)
    pub fn hasDedicatedTransfer(self: *const Self) bool {
        return self.has_dedicated_transfer;
    }

    /// Set upload timeline semaphore reference (called after UploadThread init)
    pub fn setUploadTimeline(self: *Self, sem: vk.VkSemaphore) void {
        self.upload_timeline_ref = sem;
    }

    /// Set latest upload timeline value to wait on (called each frame)
    pub fn setLastUploadTimelineValue(self: *Self, v: u64) void {
        self.last_upload_timeline_value = v;
    }

    /// Get the GPU device abstraction for resource creation
    pub fn getGpuDevice(self: *Self) ?*GpuDevice {
        if (self.gpu_device) |*dev| {
            return dev;
        }
        return null;
    }

    // ============================================================
    // Frame Management Helpers (DRY)
    // ============================================================

    /// Context for a frame being rendered
    pub const FrameContext = struct {
        image_index: u32,
        command_buffer: vk.VkCommandBuffer,
        fence: vk.VkFence,
        current_frame: u32,
    };

    /// Begin a new frame - handles fence wait and image acquisition
    /// Returns null if swapchain needs recreation
    fn beginFrame(self: *Self) !?FrameContext {
        const vkWaitForFences = vk.vkWaitForFences orelse return error.VulkanFunctionNotLoaded;
        const vkResetFences = vk.vkResetFences orelse return error.VulkanFunctionNotLoaded;
        const vkAcquireNextImageKHR = vk.vkAcquireNextImageKHR orelse return error.VulkanFunctionNotLoaded;

        const fence = self.in_flight_fences[self.current_frame];
        _ = vkWaitForFences(self.device, 1, &fence, vk.VK_TRUE, std.math.maxInt(u64));

        self.collectGarbage();

        // Reset metadata staging offset for new frame
        self.metadata_staging_offset = 0;

        var image_index: u32 = 0;
        const acquire_result = vkAcquireNextImageKHR(
            self.device,
            self.swapchain,
            std.math.maxInt(u64),
            self.image_available_semaphores[self.current_frame],
            null,
            &image_index,
        );

        if (acquire_result == vk.VK_ERROR_OUT_OF_DATE_KHR) {
            try self.recreateSwapchain();
            return null;
        } else if (acquire_result != vk.VK_SUCCESS and acquire_result != vk.VK_SUBOPTIMAL_KHR) {
            return error.SwapchainAcquireFailed;
        }

        _ = vkResetFences(self.device, 1, &fence);

        return FrameContext{
            .image_index = image_index,
            .command_buffer = self.command_buffers[self.current_frame],
            .fence = fence,
            .current_frame = self.current_frame,
        };
    }

    /// End frame - handles submission and presentation
    fn endFrame(self: *Self, ctx: FrameContext) !void {
        const vkQueueSubmit = vk.vkQueueSubmit orelse return error.VulkanFunctionNotLoaded;
        const vkQueuePresentKHR = vk.vkQueuePresentKHR orelse return error.VulkanFunctionNotLoaded;

        // Determine if we need to wait on the upload timeline (dedicated transfer queue only)
        const need_upload_wait = self.has_dedicated_transfer and
            self.upload_timeline_ref != null and
            self.last_upload_timeline_value > 0;

        // Build wait semaphore arrays dynamically based on upload timeline
        var wait_semaphores: [2]vk.VkSemaphore = undefined;
        var wait_stages: [2]vk.VkPipelineStageFlags = undefined;
        var wait_values: [2]u64 = undefined;
        var wait_count: u32 = 1;

        // Always wait on image available (binary semaphore)
        wait_semaphores[0] = self.image_available_semaphores[ctx.current_frame];
        wait_stages[0] = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        wait_values[0] = 0; // binary semaphore, value ignored

        if (need_upload_wait) {
            // Wait on upload timeline at vertex input stage (transfers must complete before vertex reads)
            wait_semaphores[1] = self.upload_timeline_ref.?;
            wait_stages[1] = vk.VK_PIPELINE_STAGE_VERTEX_INPUT_BIT;
            wait_values[1] = self.last_upload_timeline_value;
            wait_count = 2;
        }

        const signal_semaphores = [_]vk.VkSemaphore{ self.render_finished_semaphores[ctx.image_index], self.gpu_timeline.? };
        const cmd_buffers = [_]vk.VkCommandBuffer{ctx.command_buffer};

        // Timeline semaphore: increment before submit so the signaled value tracks this frame
        self.timeline_value += 1;
        const signal_values = [_]u64{ 0, self.timeline_value }; // binary (ignored), timeline
        var timeline_info = vk.VkTimelineSemaphoreSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreValueCount = wait_count,
            .pWaitSemaphoreValues = &wait_values,
            .signalSemaphoreValueCount = 2,
            .pSignalSemaphoreValues = &signal_values,
        };

        const submit_info = vk.VkSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = &timeline_info,
            .waitSemaphoreCount = wait_count,
            .pWaitSemaphores = &wait_semaphores,
            .pWaitDstStageMask = &wait_stages,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd_buffers,
            .signalSemaphoreCount = 2,
            .pSignalSemaphores = &signal_semaphores,
        };

        if (vkQueueSubmit(self.graphics_queue, 1, &submit_info, ctx.fence) != vk.VK_SUCCESS) {
            return error.QueueSubmitFailed;
        }
        self.last_submitted_value = self.timeline_value;

        const swapchains = [_]vk.VkSwapchainKHR{self.swapchain};
        var image_index = ctx.image_index;
        const present_semaphores = [_]vk.VkSemaphore{self.render_finished_semaphores[ctx.image_index]};
        const present_info = vk.VkPresentInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &present_semaphores,
            .swapchainCount = 1,
            .pSwapchains = &swapchains,
            .pImageIndices = &image_index,
            .pResults = null,
        };

        const present_result = vkQueuePresentKHR(self.present_queue, &present_info);

        if (present_result == vk.VK_ERROR_OUT_OF_DATE_KHR or present_result == vk.VK_SUBOPTIMAL_KHR or self.window.?.wasResized()) {
            try self.recreateSwapchain();
        } else if (present_result != vk.VK_SUCCESS) {
            return error.PresentFailed;
        }

        self.current_frame = (self.current_frame + 1) % MAX_FRAMES_IN_FLIGHT;
    }

    /// Poll the timeline semaphore and destroy buffers the GPU has finished with
    fn collectGarbage(self: *Self) void {
        const vkGetSemaphoreCounterValue = vk.vkGetSemaphoreCounterValue orelse return;
        const vkDestroyBuffer = vk.vkDestroyBuffer orelse return;
        const vkFreeMemory = vk.vkFreeMemory orelse return;

        const timeline = self.gpu_timeline orelse return;
        var completed: u64 = 0;
        if (vkGetSemaphoreCounterValue(self.device, timeline, &completed) != vk.VK_SUCCESS) return;

        var i: usize = 0;
        while (i < self.gc_queue.items.len) {
            if (self.gc_queue.items[i].ready_at <= completed) {
                if (self.gc_queue.items[i].handle) |h| vkDestroyBuffer(self.device, h, null);
                if (self.gc_queue.items[i].memory) |m| vkFreeMemory(self.device, m, null);
                _ = self.gc_queue.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Schedule a buffer+memory pair for deferred destruction after the GPU finishes the current frame
    pub fn retireBuffer(self: *Self, handle: vk.VkBuffer, memory: vk.VkDeviceMemory) void {
        if (handle == null and memory == null) return;

        self.gc_queue.append(self.allocator, .{
            .handle = handle,
            .memory = memory,
            .ready_at = self.last_submitted_value,
        }) catch {
            // Allocation failed - destroy immediately as last resort
            logger.warn("GC queue append failed, destroying immediately", .{});
            if (vk.vkDestroyBuffer) |destroy| if (handle) |h| destroy(self.device, h, null);
            if (vk.vkFreeMemory) |free| if (memory) |m| free(self.device, m, null);
        };
    }

    /// Destroy all remaining GC entries unconditionally (call after vkDeviceWaitIdle)
    fn flushAllGarbage(self: *Self) void {
        const vkDestroyBuffer = vk.vkDestroyBuffer orelse return;
        const vkFreeMemory = vk.vkFreeMemory orelse return;

        for (self.gc_queue.items) |entry| {
            if (entry.handle) |h| vkDestroyBuffer(self.device, h, null);
            if (entry.memory) |m| vkFreeMemory(self.device, m, null);
        }
        self.gc_queue.clearAndFree(self.allocator);
    }

    /// Draw parameters for unified command recording
    pub const DrawParams = struct {
        /// Multi-chunk draw commands
        draw_commands: ?[]const ChunkDrawCommand = null,
        /// Staging copies to execute before rendering
        staging_copies: []const StagingCopy = &.{},
        /// Entity vertex buffer (for mob rendering)
        entity_vertex_buffer: ?vk.VkBuffer = null,
        /// Entity index buffer
        entity_index_buffer: ?vk.VkBuffer = null,
        /// Entity index count (total)
        entity_index_count: u32 = 0,
        /// Adult cow index count (drawn with adult texture)
        adult_index_count: u32 = 0,
        /// Baby cow index start offset
        baby_index_start: u32 = 0,
        /// Baby cow index count (drawn with baby texture)
        baby_index_count: u32 = 0,
        /// Array of vertex buffers for multi-arena rendering (index = arena)
        vertex_buffers: ?[]const vk.VkBuffer = null,
        /// Array of index buffers for multi-arena rendering (index = arena)
        index_buffers: ?[]const vk.VkBuffer = null,
    };

    /// Unified command buffer recording
    fn recordRenderCommands(self: *Self, command_buffer: vk.VkCommandBuffer, image_index: u32, params: DrawParams) !void {
        const vkResetCommandBuffer = vk.vkResetCommandBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkBeginCommandBuffer = vk.vkBeginCommandBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkCmdBeginRenderPass = vk.vkCmdBeginRenderPass orelse return error.VulkanFunctionNotLoaded;
        const vkCmdBindPipeline = vk.vkCmdBindPipeline orelse return error.VulkanFunctionNotLoaded;
        const vkCmdBindDescriptorSets = vk.vkCmdBindDescriptorSets orelse return error.VulkanFunctionNotLoaded;
        const vkCmdBindVertexBuffers = vk.vkCmdBindVertexBuffers orelse return error.VulkanFunctionNotLoaded;
        const vkCmdBindIndexBuffer = vk.vkCmdBindIndexBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkCmdSetViewport = vk.vkCmdSetViewport orelse return error.VulkanFunctionNotLoaded;
        const vkCmdSetScissor = vk.vkCmdSetScissor orelse return error.VulkanFunctionNotLoaded;
        const vkCmdDrawIndexed = vk.vkCmdDrawIndexed orelse return error.VulkanFunctionNotLoaded;
        const vkCmdEndRenderPass = vk.vkCmdEndRenderPass orelse return error.VulkanFunctionNotLoaded;
        const vkEndCommandBuffer = vk.vkEndCommandBuffer orelse return error.VulkanFunctionNotLoaded;

        _ = vkResetCommandBuffer(command_buffer, 0);

        const begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = 0,
            .pInheritanceInfo = null,
        };

        if (vkBeginCommandBuffer(command_buffer, &begin_info) != vk.VK_SUCCESS) {
            return error.CommandBufferBeginFailed;
        }

        // Record staging buffer copies before render pass
        if (params.staging_copies.len > 0) {
            try self.recordStagingCopies(command_buffer, params.staging_copies);
        }

        // Pre-render callback for additional GPU uploads (e.g., chunk metadata)
        if (self.pre_render_callback) |callback| {
            callback(command_buffer, self.pre_render_callback_ctx);
        }

        const clear_values = [_]vk.VkClearValue{
            .{ .color = .{ .float32 = .{ 0.0, 0.0, 0.0, 1.0 } } },
            .{ .depthStencil = .{ .depth = 1.0, .stencil = 0 } },
        };

        const render_pass_info = vk.VkRenderPassBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .pNext = null,
            .renderPass = self.render_pass,
            .framebuffer = self.framebuffers[image_index],
            .renderArea = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = self.swapchain_extent,
            },
            .clearValueCount = clear_values.len,
            .pClearValues = &clear_values,
        };

        vkCmdBeginRenderPass(command_buffer, &render_pass_info, vk.VK_SUBPASS_CONTENTS_INLINE);

        // Set viewport and scissor
        const viewport = vk.VkViewport{
            .x = 0.0,
            .y = 0.0,
            .width = @floatFromInt(self.swapchain_extent.width),
            .height = @floatFromInt(self.swapchain_extent.height),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };
        vkCmdSetViewport(command_buffer, 0, 1, &viewport);

        const scissor = vk.VkRect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swapchain_extent,
        };
        vkCmdSetScissor(command_buffer, 0, 1, &scissor);

        // Bind descriptor set
        const descriptor_sets = [_]vk.VkDescriptorSet{self.descriptor_sets[self.current_frame]};
        vkCmdBindDescriptorSets(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline_layout, 0, 1, &descriptor_sets, 0, null);

        // Draw geometry using indirect drawing with layer-specific pipelines
        if (params.draw_commands) |commands| {
            if (commands.len > 0) {
                if (params.vertex_buffers) |vb_array| {
                    if (params.index_buffers) |ib_array| {
                        const vkCmdDrawIndexedIndirect = vk.vkCmdDrawIndexedIndirect orelse return error.VulkanFunctionNotLoaded;

                        // Write all commands to indirect buffer
                        const indirect_cmds: [*]IndirectDrawCommand = @ptrCast(@alignCast(self.indirect_buffer.mapped.?));
                        for (commands, 0..) |cmd, i| {
                            indirect_cmds[i] = IndirectDrawCommand{
                                .index_count = cmd.index_count,
                                .instance_count = 1,
                                .first_index = @intCast(cmd.index_offset / 4),
                                .vertex_offset = @intCast(cmd.vertex_offset / @sizeOf(Vertex)),
                                .first_instance = 0,
                            };
                        }

                        // Issue batched indirect draws
                        var batch_start: u32 = 0;
                        var current_vertex_arena: u16 = 0xFFFF;
                        var current_index_arena: u16 = 0xFFFF;
                        var current_layer: u8 = 0xFF;

                        for (commands, 0..) |cmd, i| {
                            const need_state_change = cmd.render_layer != current_layer or
                                cmd.vertex_arena != current_vertex_arena or
                                cmd.index_arena != current_index_arena;

                            if (need_state_change) {
                                // Flush previous batch if any
                                const batch_count = @as(u32, @intCast(i)) - batch_start;
                                if (batch_count > 0 and current_layer != 0xFF) {
                                    const indirect_offset = @as(u64, batch_start) * @sizeOf(IndirectDrawCommand);
                                    vkCmdDrawIndexedIndirect(
                                        command_buffer,
                                        self.indirect_buffer.handle,
                                        indirect_offset,
                                        batch_count,
                                        @sizeOf(IndirectDrawCommand),
                                    );
                                }

                                // Update state for new batch
                                batch_start = @intCast(i);

                                // Bind pipeline if layer changed
                                if (cmd.render_layer != current_layer) {
                                    current_layer = cmd.render_layer;
                                    const pipeline = self.layer_pipelines[current_layer];
                                    vkCmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
                                }

                                // Bind buffers if arena changed
                                if (cmd.vertex_arena != current_vertex_arena or cmd.index_arena != current_index_arena) {
                                    current_vertex_arena = cmd.vertex_arena;
                                    current_index_arena = cmd.index_arena;

                                    if (current_vertex_arena < vb_array.len and current_index_arena < ib_array.len) {
                                        const arena_vb = [_]vk.VkBuffer{vb_array[current_vertex_arena]};
                                        const offsets = [_]vk.VkDeviceSize{0};
                                        vkCmdBindVertexBuffers(command_buffer, 0, 1, &arena_vb, &offsets);
                                        vkCmdBindIndexBuffer(command_buffer, ib_array[current_index_arena], 0, vk.VK_INDEX_TYPE_UINT32);
                                    }
                                }
                            }
                        }

                        // Flush final batch
                        const final_batch_count = @as(u32, @intCast(commands.len)) - batch_start;
                        if (final_batch_count > 0 and current_layer != 0xFF) {
                            const indirect_offset = @as(u64, batch_start) * @sizeOf(IndirectDrawCommand);
                            vkCmdDrawIndexedIndirect(
                                command_buffer,
                                self.indirect_buffer.handle,
                                indirect_offset,
                                final_batch_count,
                                @sizeOf(IndirectDrawCommand),
                            );
                        }
                    }
                }
            }
        }

        // Draw entities (mobs) using bindless textures
        if (params.entity_vertex_buffer != null and params.entity_index_buffer != null and params.entity_index_count > 0) {
            if (self.entity_pipeline) |entity_pipeline| {
                vkCmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, entity_pipeline);

                const entity_vertex_buffers = [_]vk.VkBuffer{params.entity_vertex_buffer.?};
                const entity_offsets = [_]vk.VkDeviceSize{0};
                vkCmdBindVertexBuffers(command_buffer, 0, 1, &entity_vertex_buffers, &entity_offsets);
                vkCmdBindIndexBuffer(command_buffer, params.entity_index_buffer.?, 0, vk.VK_INDEX_TYPE_UINT32);

                // Bind bindless entity descriptor set (contains all entity textures)
                if (self.bindless_entity_descriptor_set != null) {
                    const bindless_sets = [_]vk.VkDescriptorSet{self.bindless_entity_descriptor_set};
                    vkCmdBindDescriptorSets(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.entity_pipeline_layout, 0, 1, &bindless_sets, 0, null);
                    // Single draw call for all entities - texture index is per-vertex
                    vkCmdDrawIndexed(command_buffer, params.entity_index_count, 1, 0, 0, 0);
                } else {
                    // Fallback to old per-texture descriptor sets
                    // Draw adult cows with adult texture
                    if (params.adult_index_count > 0) {
                        if (self.entity_descriptor_sets[self.current_frame] != null) {
                            const entity_descriptor_sets_arr = [_]vk.VkDescriptorSet{self.entity_descriptor_sets[self.current_frame]};
                            vkCmdBindDescriptorSets(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.entity_pipeline_layout, 0, 1, &entity_descriptor_sets_arr, 0, null);
                        }
                        vkCmdDrawIndexed(command_buffer, params.adult_index_count, 1, 0, 0, 0);
                    }

                    // Draw baby cows with baby texture
                    if (params.baby_index_count > 0) {
                        if (self.baby_entity_descriptor_sets[self.current_frame] != null) {
                            const baby_descriptor_sets_arr = [_]vk.VkDescriptorSet{self.baby_entity_descriptor_sets[self.current_frame]};
                            vkCmdBindDescriptorSets(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.entity_pipeline_layout, 0, 1, &baby_descriptor_sets_arr, 0, null);
                        }
                        vkCmdDrawIndexed(command_buffer, params.baby_index_count, 1, params.baby_index_start, 0, 0);
                    }
                }

                // Switch back to main graphics pipeline for subsequent drawing
                vkCmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.graphics_pipeline);
            }
        }

        // Draw block outline (lines)
        try self.drawBlockOutline(command_buffer, &descriptor_sets);

        // Draw hotbar (UI overlay)
        try self.drawHotbar(command_buffer);

        // Draw crosshair (UI overlay - on top of hotbar)
        try self.drawCrosshair(command_buffer);

        vkCmdEndRenderPass(command_buffer);

        if (vkEndCommandBuffer(command_buffer) != vk.VK_SUCCESS) {
            return error.CommandBufferEndFailed;
        }
    }

    /// Record staging buffer copy commands
    fn recordStagingCopies(self: *Self, command_buffer: vk.VkCommandBuffer, staging_copies: []const StagingCopy) !void {
        const vkCmdCopyBuffer = vk.vkCmdCopyBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkCmdPipelineBarrier = vk.vkCmdPipelineBarrier orelse return error.VulkanFunctionNotLoaded;

        _ = self;

        for (staging_copies) |copy| {
            const region = vk.VkBufferCopy{
                .srcOffset = copy.src_offset,
                .dstOffset = copy.dst_offset,
                .size = copy.size,
            };
            vkCmdCopyBuffer(command_buffer, copy.src_buffer, copy.dst_buffer, 1, &region);
        }

        // Memory barrier: transfer writes must complete before vertex/index reads
        const barrier = vk.VkMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = vk.VK_ACCESS_VERTEX_ATTRIBUTE_READ_BIT | vk.VK_ACCESS_INDEX_READ_BIT,
        };
        vkCmdPipelineBarrier(
            command_buffer,
            vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            vk.VK_PIPELINE_STAGE_VERTEX_INPUT_BIT,
            0,
            1,
            &barrier,
            0,
            null,
            0,
            null,
        );
    }

    /// Draw block outline (lines) - extracted for DRY
    fn drawBlockOutline(self: *Self, command_buffer: vk.VkCommandBuffer, descriptor_sets: []const vk.VkDescriptorSet) !void {
        if (self.line_pipeline == null or !self.line_buffer.isValid() or self.line_vertex_count == 0) return;

        const vkCmdBindPipeline = vk.vkCmdBindPipeline orelse return error.VulkanFunctionNotLoaded;
        const vkCmdBindDescriptorSets = vk.vkCmdBindDescriptorSets orelse return error.VulkanFunctionNotLoaded;
        const vkCmdBindVertexBuffers = vk.vkCmdBindVertexBuffers orelse return error.VulkanFunctionNotLoaded;
        const vkCmdDraw = vk.vkCmdDraw orelse return error.VulkanFunctionNotLoaded;
        const vkCmdSetLineWidth = vk.vkCmdSetLineWidth orelse return error.VulkanFunctionNotLoaded;

        vkCmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.line_pipeline);
        vkCmdBindDescriptorSets(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.line_pipeline_layout, 0, 1, descriptor_sets.ptr, 0, null);

        const line_vertex_buffers = [_]vk.VkBuffer{self.line_buffer.handle};
        const line_offsets = [_]vk.VkDeviceSize{0};
        vkCmdBindVertexBuffers(command_buffer, 0, 1, &line_vertex_buffers, &line_offsets);

        vkCmdSetLineWidth(command_buffer, 1.0);
        vkCmdDraw(command_buffer, self.line_vertex_count, 1, 0, 0);
    }

    /// Draw crosshair UI - extracted for DRY
    fn drawCrosshair(self: *Self, command_buffer: vk.VkCommandBuffer) !void {
        if (self.ui_pipeline == null or !self.crosshair_buffer.isValid()) return;

        const vkCmdBindPipeline = vk.vkCmdBindPipeline orelse return error.VulkanFunctionNotLoaded;
        const vkCmdBindDescriptorSets = vk.vkCmdBindDescriptorSets orelse return error.VulkanFunctionNotLoaded;
        const vkCmdBindVertexBuffers = vk.vkCmdBindVertexBuffers orelse return error.VulkanFunctionNotLoaded;
        const vkCmdDraw = vk.vkCmdDraw orelse return error.VulkanFunctionNotLoaded;

        vkCmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.ui_pipeline);

        const ui_descriptor_sets = [_]vk.VkDescriptorSet{self.ui_descriptor_sets[self.current_frame]};
        vkCmdBindDescriptorSets(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.ui_pipeline_layout, 0, 1, &ui_descriptor_sets, 0, null);

        const ui_vertex_buffers = [_]vk.VkBuffer{self.crosshair_buffer.handle};
        const ui_offsets = [_]vk.VkDeviceSize{0};
        vkCmdBindVertexBuffers(command_buffer, 0, 1, &ui_vertex_buffers, &ui_offsets);

        vkCmdDraw(command_buffer, 6, 1, 0, 0);
    }

    /// Draw hotbar UI
    fn drawHotbar(self: *Self, command_buffer: vk.VkCommandBuffer) !void {
        if (self.hotbar_pipeline == null or !self.hotbar_buffer.isValid()) return;

        const vkCmdBindPipeline = vk.vkCmdBindPipeline orelse return error.VulkanFunctionNotLoaded;
        const vkCmdBindDescriptorSets = vk.vkCmdBindDescriptorSets orelse return error.VulkanFunctionNotLoaded;
        const vkCmdBindVertexBuffers = vk.vkCmdBindVertexBuffers orelse return error.VulkanFunctionNotLoaded;
        const vkCmdDraw = vk.vkCmdDraw orelse return error.VulkanFunctionNotLoaded;

        vkCmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.hotbar_pipeline);

        const offsets = [_]vk.VkDeviceSize{0};

        // Draw main hotbar
        const hotbar_sets = [_]vk.VkDescriptorSet{self.hotbar_descriptor_sets[self.current_frame]};
        vkCmdBindDescriptorSets(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.ui_pipeline_layout, 0, 1, &hotbar_sets, 0, null);

        const hotbar_buffers = [_]vk.VkBuffer{self.hotbar_buffer.handle};
        vkCmdBindVertexBuffers(command_buffer, 0, 1, &hotbar_buffers, &offsets);
        vkCmdDraw(command_buffer, 6, 1, 0, 0);

        // Draw selection indicator
        if (self.hotbar_selection_buffer.isValid()) {
            const selection_sets = [_]vk.VkDescriptorSet{self.hotbar_selection_descriptor_sets[self.current_frame]};
            vkCmdBindDescriptorSets(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.ui_pipeline_layout, 0, 1, &selection_sets, 0, null);

            const selection_buffers = [_]vk.VkBuffer{self.hotbar_selection_buffer.handle};
            vkCmdBindVertexBuffers(command_buffer, 0, 1, &selection_buffers, &offsets);
            vkCmdDraw(command_buffer, 6, 1, 0, 0);
        }

        // Draw block icons on top of hotbar
        try self.drawHotbarIcons(command_buffer);
    }

    fn drawHotbarIcons(self: *Self, command_buffer: vk.VkCommandBuffer) !void {
        if (self.hotbar_icon_pipeline == null or !self.hotbar_icon_buffer.isValid() or self.hotbar_icon_vertex_count == 0) return;

        const vkCmdBindPipeline = vk.vkCmdBindPipeline orelse return error.VulkanFunctionNotLoaded;
        const vkCmdBindDescriptorSets = vk.vkCmdBindDescriptorSets orelse return error.VulkanFunctionNotLoaded;
        const vkCmdBindVertexBuffers = vk.vkCmdBindVertexBuffers orelse return error.VulkanFunctionNotLoaded;
        const vkCmdDraw = vk.vkCmdDraw orelse return error.VulkanFunctionNotLoaded;

        vkCmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.hotbar_icon_pipeline);

        const icon_sets = [_]vk.VkDescriptorSet{self.hotbar_icon_descriptor_sets[self.current_frame]};
        vkCmdBindDescriptorSets(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.hotbar_icon_pipeline_layout, 0, 1, &icon_sets, 0, null);

        const icon_buffers = [_]vk.VkBuffer{self.hotbar_icon_buffer.handle};
        const offsets = [_]vk.VkDeviceSize{0};
        vkCmdBindVertexBuffers(command_buffer, 0, 1, &icon_buffers, &offsets);

        vkCmdDraw(command_buffer, self.hotbar_icon_vertex_count, 1, 0, 0);
    }

    /// Update hotbar icons with isometric 3D block previews
    /// texture_indices should contain texture array indices for each slot (null for empty slots)
    /// Face order: [top, bottom, north, south, west, east]
    pub fn updateHotbarIcons(self: *Self, texture_indices: [9]?[6]u32) !void {
        // Store texture indices for recreation on resize
        self.hotbar_icon_texture_indices = texture_indices;
        try self.rebuildHotbarIconBuffer();
    }

    /// Rebuild the hotbar icon vertex buffer using actual 3D cube geometry
    fn rebuildHotbarIconBuffer(self: *Self) !void {
        var gpu = self.gpu_device orelse return error.GpuDeviceNotInitialized;

        const screen_height: f32 = @floatFromInt(self.swapchain_extent.height);
        const screen_width: f32 = @floatFromInt(self.swapchain_extent.width);

        // GUI scale calculation (same as hotbar)
        const gui_scale: f32 = if (screen_height < 480) 1.0 else if (screen_height < 720) 2.0 else if (screen_height < 1080) 2.0 else 3.0;

        // Hotbar dimensions from Minecraft spec
        const hotbar_width_pixels: f32 = 182.0 * gui_scale;
        const hotbar_height_pixels: f32 = 22.0 * gui_scale;
        const slot_spacing_pixels: f32 = 20.0 * gui_scale;
        const first_slot_offset_pixels: f32 = 3.0 * gui_scale;

        // Hotbar position (bottom center) in NDC
        const hotbar_left_ndc: f32 = -hotbar_width_pixels / screen_width;
        const hotbar_bottom_ndc: f32 = 1.0;
        const hotbar_top_ndc: f32 = hotbar_bottom_ndc - (hotbar_height_pixels / screen_height * 2.0);

        // Minecraft isometric view: rotate -45° around Y, then -30° around X
        // This gives the classic front-right-top view
        const angle_y: f32 = -std.math.pi / 4.0; // -45 degrees (turn right side toward us)
        const angle_x: f32 = -std.math.pi / 6.0; // -30 degrees (tilt top toward us)
        const cos_y: f32 = @cos(angle_y);
        const sin_y: f32 = @sin(angle_y);
        const cos_x: f32 = @cos(angle_x);
        const sin_x: f32 = @sin(angle_x);

        // Combined rotation matrix (X * Y rotation)
        // First rotate around Y, then around X
        // Only need the first two rows for orthographic projection to 2D
        const r00: f32 = cos_y;
        const r01: f32 = 0;
        const r02: f32 = sin_y;
        const r10: f32 = sin_x * sin_y;
        const r11: f32 = cos_x;
        const r12: f32 = -sin_x * cos_y;

        // Scale to fit in slot (in pixels, then convert to NDC)
        const cube_size_pixels: f32 = 10.0 * gui_scale;
        const scale_x: f32 = cube_size_pixels * 2.0 / screen_width;
        const scale_y: f32 = cube_size_pixels * 2.0 / screen_height;

        // Helper function to transform a 3D point to 2D NDC
        const transform = struct {
            fn apply(
                x: f32,
                y: f32,
                z: f32,
                m00: f32,
                m01: f32,
                m02: f32,
                m10: f32,
                m11: f32,
                m12: f32,
                sx: f32,
                sy: f32,
                tx: f32,
                ty: f32,
            ) [2]f32 {
                // Apply rotation
                const rx = m00 * x + m01 * y + m02 * z;
                const ry = m10 * x + m11 * y + m12 * z;
                // Scale and translate (ignore Z for orthographic)
                // Negate Y for Vulkan coordinate system (Y+ is down)
                return .{ rx * sx + tx, -ry * sy + ty };
            }
        };

        // Collect vertices for all non-empty slots
        // Each cube has 3 visible faces * 2 triangles * 3 vertices = 18 vertices
        var vertices: [9 * 18]IconVertex = undefined;
        var vertex_count: u32 = 0;

        // Unit cube vertices (centered at origin, size 1x1x1)
        // Defined as corners: -0.5 to 0.5 on each axis
        const cube_verts = [8][3]f32{
            .{ -0.5, -0.5, -0.5 }, // 0: left-bottom-back
            .{ 0.5, -0.5, -0.5 }, // 1: right-bottom-back
            .{ 0.5, 0.5, -0.5 }, // 2: right-top-back
            .{ -0.5, 0.5, -0.5 }, // 3: left-top-back
            .{ -0.5, -0.5, 0.5 }, // 4: left-bottom-front
            .{ 0.5, -0.5, 0.5 }, // 5: right-bottom-front
            .{ 0.5, 0.5, 0.5 }, // 6: right-top-front
            .{ -0.5, 0.5, 0.5 }, // 7: left-top-front
        };

        // Face definitions: vertex indices and UV coords for each face
        // Format: [v0, v1, v2, v3] forming a quad (two triangles)
        // Only render the 3 visible faces for isometric view (no depth buffer needed)
        const Face = struct {
            verts: [4]u8, // Vertex indices
            uvs: [4][2]f32, // UV coordinates
            tex_slot: u8, // Which texture slot to use
            tint: f32, // Brightness
        };

        // Minecraft face shading values
        const top_tint: f32 = 1.0;
        const left_tint: f32 = 0.8; // Left visible face
        const right_tint: f32 = 0.6; // Right visible face

        // Only the 3 visible faces for isometric view (-45° Y, -30° X rotation)
        // Looking from front-left-top, we see: Top, West (X-), North (Z-)
        const faces = [3]Face{
            // Top (Y+) - texture slot 0
            .{ .verts = .{ 3, 2, 6, 7 }, .uvs = .{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } }, .tex_slot = 0, .tint = top_tint },
            // West (X-) - texture slot 4 - left face in isometric view
            .{ .verts = .{ 3, 7, 4, 0 }, .uvs = .{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } }, .tex_slot = 4, .tint = left_tint },
            // North (Z-) - texture slot 2 - right face in isometric view
            .{ .verts = .{ 2, 3, 0, 1 }, .uvs = .{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } }, .tex_slot = 2, .tint = right_tint },
        };

        for (0..9) |slot_idx| {
            const tex_opt = self.hotbar_icon_texture_indices[slot_idx];
            if (tex_opt == null) continue;
            const tex = tex_opt.?;

            // Calculate slot center position in NDC
            // Slot centers: first slot at offset 3, then every 20 pixels, center at +10
            const slot_x_pixels = first_slot_offset_pixels + @as(f32, @floatFromInt(slot_idx)) * slot_spacing_pixels + slot_spacing_pixels / 2.0;
            // Adjust X position to account for visual center shift after isometric rotation
            const icon_offset_x: f32 = -2.0 * gui_scale; // Shift left to center visually
            const slot_center_x: f32 = hotbar_left_ndc + ((slot_x_pixels + icon_offset_x) / screen_width * 2.0);
            const slot_center_y: f32 = (hotbar_top_ndc + hotbar_bottom_ndc) / 2.0;

            // Generate vertices for each face
            for (faces) |face| {
                const tex_idx = tex[face.tex_slot];

                // Get the 4 corner vertices transformed to 2D
                var corners: [4][2]f32 = undefined;
                for (0..4) |i| {
                    const vi = face.verts[i];
                    const v = cube_verts[vi];
                    corners[i] = transform.apply(
                        v[0],
                        v[1],
                        v[2],
                        r00,
                        r01,
                        r02,
                        r10,
                        r11,
                        r12,
                        scale_x,
                        scale_y,
                        slot_center_x,
                        slot_center_y,
                    );
                }

                // Triangle 1: v0, v2, v1 (swapped for Vulkan winding after Y negate)
                vertices[vertex_count] = .{
                    .pos = .{ corners[0][0], corners[0][1], 0.0 },
                    .uv = face.uvs[0],
                    .tex_index = tex_idx,
                    .tint = face.tint,
                };
                vertex_count += 1;
                vertices[vertex_count] = .{
                    .pos = .{ corners[2][0], corners[2][1], 0.0 },
                    .uv = face.uvs[2],
                    .tex_index = tex_idx,
                    .tint = face.tint,
                };
                vertex_count += 1;
                vertices[vertex_count] = .{
                    .pos = .{ corners[1][0], corners[1][1], 0.0 },
                    .uv = face.uvs[1],
                    .tex_index = tex_idx,
                    .tint = face.tint,
                };
                vertex_count += 1;

                // Triangle 2: v0, v3, v2 (swapped for Vulkan winding after Y negate)
                vertices[vertex_count] = .{
                    .pos = .{ corners[0][0], corners[0][1], 0.0 },
                    .uv = face.uvs[0],
                    .tex_index = tex_idx,
                    .tint = face.tint,
                };
                vertex_count += 1;
                vertices[vertex_count] = .{
                    .pos = .{ corners[3][0], corners[3][1], 0.0 },
                    .uv = face.uvs[3],
                    .tex_index = tex_idx,
                    .tint = face.tint,
                };
                vertex_count += 1;
                vertices[vertex_count] = .{
                    .pos = .{ corners[2][0], corners[2][1], 0.0 },
                    .uv = face.uvs[2],
                    .tex_index = tex_idx,
                    .tint = face.tint,
                };
                vertex_count += 1;
            }
        }

        // Retire old buffer (deferred destruction after GPU finishes)
        if (self.hotbar_icon_buffer.isValid()) {
            self.retireBuffer(self.hotbar_icon_buffer.handle, self.hotbar_icon_buffer.memory);
            self.hotbar_icon_buffer = .{};
        }

        if (vertex_count == 0) {
            self.hotbar_icon_vertex_count = 0;
            return;
        }

        // Create new buffer with icon vertices
        const result = try gpu.createBufferWithDataRaw(
            IconVertex,
            vertices[0..vertex_count],
            vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        );

        self.hotbar_icon_buffer = ManagedBuffer.fromRaw(result.handle, result.memory);
        self.hotbar_icon_vertex_count = vertex_count;
    }

    // ============================================================
    // Public Draw Methods (now using unified helpers)
    // ============================================================

    pub fn drawFrame(self: *Self) !void {
        const ctx = try self.beginFrame() orelse return;
        try self.recordRenderCommands(ctx.command_buffer, ctx.image_index, .{});
        try self.endFrame(ctx);
    }

    /// Update the uniform buffer with MVP matrices for the current frame
    pub fn updateMVP(self: *Self, model: [16]f32, view: [16]f32, proj: [16]f32) void {
        const ubo = UniformBufferObject{
            .model = model,
            .view = view,
            .proj = proj,
        };

        // Update the current frame's buffer (for main rendering)
        if (self.uniform_buffers_mapped[self.current_frame]) |mapped| {
            const dest: *UniformBufferObject = @ptrCast(@alignCast(mapped));
            dest.* = ubo;
        }

        // Also update uniform_buffers[0] for bindless entity rendering
        // The bindless entity descriptor set is bound to uniform_buffers[0]
        if (self.current_frame != 0) {
            if (self.uniform_buffers_mapped[0]) |mapped| {
                const dest: *UniformBufferObject = @ptrCast(@alignCast(mapped));
                dest.* = ubo;
            }
        }
    }

    /// Upload line vertices for block outline rendering
    /// Vertices should be pairs of points defining line segments
    pub fn uploadLineVertices(self: *Self, vertices: []const LineVertex) !void {
        if (vertices.len == 0) {
            self.line_vertex_count = 0;
            return;
        }

        var gpu = self.gpu_device orelse return error.GpuDeviceNotInitialized;

        // Retire old buffer (deferred destruction after GPU finishes)
        if (self.line_buffer.isValid()) {
            self.retireBuffer(self.line_buffer.handle, self.line_buffer.memory);
            self.line_buffer = .{};
        }

        // Create new buffer with data
        const result = try gpu.createBufferWithDataRaw(
            LineVertex,
            vertices,
            vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        );

        self.line_buffer = ManagedBuffer.fromRaw(result.handle, result.memory);
        self.line_vertex_count = @intCast(vertices.len);
    }

    /// Clear line vertices (no outline to render)
    pub fn clearLineVertices(self: *Self) void {
        self.line_vertex_count = 0;
    }

    /// Get the current swapchain aspect ratio
    pub fn getAspectRatio(self: *const Self) f32 {
        if (self.swapchain_extent.height == 0) return 1.0;
        return @as(f32, @floatFromInt(self.swapchain_extent.width)) / @as(f32, @floatFromInt(self.swapchain_extent.height));
    }

    /// Get the current frame fence for staging synchronization
    pub fn getCurrentFrameFence(self: *const Self) vk.VkFence {
        return self.in_flight_fences[self.current_frame];
    }

    /// Get the current frame index
    pub fn getCurrentFrame(self: *const Self) u32 {
        return self.current_frame;
    }

    /// Get the current command buffer for recording additional commands
    pub fn getCurrentCommandBuffer(self: *const Self) vk.VkCommandBuffer {
        return self.command_buffers[self.current_frame];
    }

    /// Draw command for multi-chunk rendering
    pub const ChunkDrawCommand = struct {
        /// Offset into the vertex buffer (in bytes)
        vertex_offset: u64,
        /// Offset into the index buffer (in bytes)
        index_offset: u64,
        /// Number of indices to draw
        index_count: u32,
        /// Base vertex offset (added to each index)
        vertex_base: i32 = 0,
        /// Vertex buffer arena index (for multi-buffer rendering)
        vertex_arena: u16 = 0,
        /// Index buffer arena index (for multi-buffer rendering)
        index_arena: u16 = 0,
        /// Render layer (0=solid, 1=cutout, 2=translucent)
        render_layer: u8 = 0,
    };

    /// Staging copy info for buffer uploads
    /// Aliased from StagingRing.PendingCopy to ensure single source of truth
    pub const StagingCopy = StagingRing.PendingCopy;

    /// Indirect draw command matching VkDrawIndexedIndirectCommand layout
    pub const IndirectDrawCommand = extern struct {
        index_count: u32,
        instance_count: u32,
        first_index: u32,
        vertex_offset: i32,
        first_instance: u32,
    };

    /// Batch of indirect draw commands sharing the same pipeline and buffers
    pub const IndirectDrawBatch = struct {
        /// Index into indirect buffer where this batch starts
        offset: u32,
        /// Number of draw commands in this batch
        count: u32,
        /// Render layer (determines pipeline)
        render_layer: u8,
        /// Vertex buffer arena for this batch
        vertex_arena: u16,
        /// Index buffer arena for this batch
        index_arena: u16,
    };

    /// Draw frame with multiple chunks from arena buffers
    /// staging_copies: optional slice of pending staging copies to commit before rendering
    pub fn drawFrameMultiChunk(
        self: *Self,
        vertex_buffer: vk.VkBuffer,
        index_buffer: vk.VkBuffer,
        draw_commands: []const ChunkDrawCommand,
        staging_buffer: ?vk.VkBuffer,
        staging_copies: []const StagingCopy,
        entity_vertex_buffer: ?vk.VkBuffer,
        entity_index_buffer: ?vk.VkBuffer,
        entity_index_count: u32,
        adult_index_count: u32,
        baby_index_start: u32,
        baby_index_count: u32,
    ) !void {
        _ = staging_buffer;
        _ = vertex_buffer;
        _ = index_buffer;

        const ctx = try self.beginFrame() orelse return;
        try self.recordRenderCommands(ctx.command_buffer, ctx.image_index, .{
            .draw_commands = draw_commands,
            .staging_copies = staging_copies,
            .entity_vertex_buffer = entity_vertex_buffer,
            .entity_index_buffer = entity_index_buffer,
            .entity_index_count = entity_index_count,
            .adult_index_count = adult_index_count,
            .baby_index_start = baby_index_start,
            .baby_index_count = baby_index_count,
        });
        try self.endFrame(ctx);
    }

    /// Draw frame with multiple chunks from multiple arena buffers
    pub fn drawFrameMultiArena(
        self: *Self,
        vertex_buffers: []const vk.VkBuffer,
        index_buffers: []const vk.VkBuffer,
        draw_commands: []const ChunkDrawCommand,
        staging_copies: []const StagingCopy,
        entity_vertex_buffer: ?vk.VkBuffer,
        entity_index_buffer: ?vk.VkBuffer,
        entity_index_count: u32,
        adult_index_count: u32,
        baby_index_start: u32,
        baby_index_count: u32,
    ) !void {
        const ctx = try self.beginFrame() orelse return;
        try self.recordRenderCommands(ctx.command_buffer, ctx.image_index, .{
            .draw_commands = draw_commands,
            .staging_copies = staging_copies,
            .entity_vertex_buffer = entity_vertex_buffer,
            .entity_index_buffer = entity_index_buffer,
            .entity_index_count = entity_index_count,
            .adult_index_count = adult_index_count,
            .baby_index_start = baby_index_start,
            .baby_index_count = baby_index_count,
            .vertex_buffers = vertex_buffers,
            .index_buffers = index_buffers,
        });
        try self.endFrame(ctx);
    }

    /// Draw a frame using GPU-driven rendering (compute cull + indirect draws)
    /// This is the new rendering path that uses GPU frustum culling
    pub fn drawFrameGPUDriven(
        self: *Self,
        chunk_count: u32,
        view_proj: [16]f32,
        vertex_buffers: []const vk.VkBuffer,
        index_buffers: []const vk.VkBuffer,
        staging_copies: []const StagingCopy,
        entity_vb: ?vk.VkBuffer,
        entity_ib: ?vk.VkBuffer,
        adult_index_count: u32,
        baby_index_count: u32,
    ) !void {
        const ctx = try self.beginFrame() orelse return;

        const vkResetCommandBuffer = vk.vkResetCommandBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkBeginCommandBuffer = vk.vkBeginCommandBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkCmdBeginRenderPass = vk.vkCmdBeginRenderPass orelse return error.VulkanFunctionNotLoaded;
        const vkCmdEndRenderPass = vk.vkCmdEndRenderPass orelse return error.VulkanFunctionNotLoaded;
        const vkEndCommandBuffer = vk.vkEndCommandBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkCmdBindPipeline = vk.vkCmdBindPipeline orelse return error.VulkanFunctionNotLoaded;
        const vkCmdBindDescriptorSets = vk.vkCmdBindDescriptorSets orelse return error.VulkanFunctionNotLoaded;
        const vkCmdSetViewport = vk.vkCmdSetViewport orelse return error.VulkanFunctionNotLoaded;
        const vkCmdSetScissor = vk.vkCmdSetScissor orelse return error.VulkanFunctionNotLoaded;
        const vkCmdBindVertexBuffers = vk.vkCmdBindVertexBuffers orelse return error.VulkanFunctionNotLoaded;
        const vkCmdBindIndexBuffer = vk.vkCmdBindIndexBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkCmdDrawIndexed = vk.vkCmdDrawIndexed orelse return error.VulkanFunctionNotLoaded;

        const command_buffer = ctx.command_buffer;

        _ = vkResetCommandBuffer(command_buffer, 0);

        const begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = 0,
            .pInheritanceInfo = null,
        };
        if (vkBeginCommandBuffer(command_buffer, &begin_info) != vk.VK_SUCCESS) {
            return error.CommandBufferBeginFailed;
        }

        // Record staging buffer copies
        if (staging_copies.len > 0) {
            try self.recordStagingCopies(command_buffer, staging_copies);
        }

        // Pre-render callback (metadata uploads)
        if (self.pre_render_callback) |callback| {
            callback(command_buffer, self.pre_render_callback_ctx);
        }

        // Memory barrier: metadata buffer copies must complete before compute shader reads
        const vkCmdPipelineBarrier = vk.vkCmdPipelineBarrier orelse return error.VulkanFunctionNotLoaded;
        const transfer_to_compute_barrier = vk.VkMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT,
        };
        vkCmdPipelineBarrier(
            command_buffer,
            vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            0,
            1,
            &transfer_to_compute_barrier,
            0,
            null,
            0,
            null,
        );

        // GPU-driven compute pass (frustum cull + command generation)
        self.recordGPUDrivenCommands(command_buffer, chunk_count, view_proj);

        // Begin render pass
        const clear_values = [_]vk.VkClearValue{
            .{ .color = .{ .float32 = .{ 0.0, 0.0, 0.0, 1.0 } } },
            .{ .depthStencil = .{ .depth = 1.0, .stencil = 0 } },
        };
        const render_pass_info = vk.VkRenderPassBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .pNext = null,
            .renderPass = self.render_pass,
            .framebuffer = self.framebuffers[ctx.image_index],
            .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.swapchain_extent },
            .clearValueCount = clear_values.len,
            .pClearValues = &clear_values,
        };
        vkCmdBeginRenderPass(command_buffer, &render_pass_info, vk.VK_SUBPASS_CONTENTS_INLINE);

        // Set viewport and scissor
        const viewport = vk.VkViewport{
            .x = 0.0,
            .y = 0.0,
            .width = @floatFromInt(self.swapchain_extent.width),
            .height = @floatFromInt(self.swapchain_extent.height),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };
        vkCmdSetViewport(command_buffer, 0, 1, &viewport);

        const scissor = vk.VkRect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swapchain_extent,
        };
        vkCmdSetScissor(command_buffer, 0, 1, &scissor);

        // Bind descriptor set
        const descriptor_sets = [_]vk.VkDescriptorSet{self.descriptor_sets[self.current_frame]};
        vkCmdBindDescriptorSets(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline_layout, 0, 1, &descriptor_sets, 0, null);

        // Bind buffers and issue GPU-driven draws for each layer
        if (vertex_buffers.len > 0 and index_buffers.len > 0) {
            const zero_offset: u64 = 0;
            vkCmdBindVertexBuffers(command_buffer, 0, 1, &vertex_buffers[0], &zero_offset);
            vkCmdBindIndexBuffer(command_buffer, index_buffers[0], 0, vk.VK_INDEX_TYPE_UINT32);

            // Solid layer
            vkCmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.layer_pipelines[0]);
            self.issueGPUDrivenDrawsForLayer(command_buffer, 0);

            // Cutout layer
            vkCmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.layer_pipelines[1]);
            self.issueGPUDrivenDrawsForLayer(command_buffer, 1);

            // Translucent layer
            vkCmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.layer_pipelines[2]);
            self.issueGPUDrivenDrawsForLayer(command_buffer, 2);
        }

        // Entity rendering
        if (entity_vb != null and entity_ib != null and (adult_index_count > 0 or baby_index_count > 0)) {
            if (self.entity_pipeline != null and self.bindless_entity_descriptor_set != null) {
                vkCmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.entity_pipeline.?);

                // Bind bindless entity descriptor set (contains UBO + all entity textures)
                const bindless_sets = [_]vk.VkDescriptorSet{self.bindless_entity_descriptor_set.?};
                vkCmdBindDescriptorSets(
                    command_buffer,
                    vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
                    self.entity_pipeline_layout.?,
                    0,
                    1,
                    &bindless_sets,
                    0,
                    null,
                );

                const zero_offset: u64 = 0;
                vkCmdBindVertexBuffers(command_buffer, 0, 1, &entity_vb.?, &zero_offset);
                vkCmdBindIndexBuffer(command_buffer, entity_ib.?, 0, vk.VK_INDEX_TYPE_UINT32);

                // Single draw call for all entities - texture index is per-vertex
                const total_index_count = adult_index_count + baby_index_count;
                if (total_index_count > 0) {
                    vkCmdDrawIndexed(command_buffer, total_index_count, 1, 0, 0, 0);
                }
            }
        }

        // Line rendering (block outline)
        try self.drawBlockOutline(command_buffer, &descriptor_sets);

        // Draw hotbar (UI overlay)
        try self.drawHotbar(command_buffer);

        // Draw crosshair (UI overlay - on top of hotbar)
        try self.drawCrosshair(command_buffer);

        vkCmdEndRenderPass(command_buffer);

        if (vkEndCommandBuffer(command_buffer) != vk.VK_SUCCESS) {
            return error.CommandBufferEndFailed;
        }

        try self.endFrame(ctx);
    }

    /// Upload new mesh data (vertices and indices)
    /// Retires old buffers via timeline semaphore GC instead of stalling the GPU.
    pub fn uploadMesh(self: *Self, vertices: []const Vertex, indices: []const u16) !void {
        var gpu = self.gpu_device orelse return error.GpuDeviceNotInitialized;

        // Retire old buffers via timeline semaphore GC (non-blocking)
        if (self.vertex_buffer != null or self.vertex_buffer_memory != null) {
            self.retireBuffer(self.vertex_buffer, self.vertex_buffer_memory);
            self.vertex_buffer = null;
            self.vertex_buffer_memory = null;
        }
        if (self.index_buffer != null or self.index_buffer_memory != null) {
            self.retireBuffer(self.index_buffer, self.index_buffer_memory);
            self.index_buffer = null;
            self.index_buffer_memory = null;
        }

        // Create new buffers (HOST_VISIBLE, no GPU stall needed)
        const vertex_result = try gpu.createBufferWithDataRaw(Vertex, vertices, vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        self.vertex_buffer = vertex_result.handle;
        self.vertex_buffer_memory = vertex_result.memory;

        const index_result = try gpu.createBufferWithDataRaw(u16, indices, vk.VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
        self.index_buffer = index_result.handle;
        self.index_buffer_memory = index_result.memory;

        self.index_count = @intCast(indices.len);
        logger.info("Mesh uploaded: {d} vertices, {d} indices", .{ vertices.len, indices.len });
    }

    fn recreateSwapchain(self: *Self) !void {
        const vkDeviceWaitIdle = vk.vkDeviceWaitIdle orelse return error.VulkanFunctionNotLoaded;

        // Wait for window to have non-zero size (handles minimization)
        self.window.?.waitIfMinimized();

        _ = vkDeviceWaitIdle(self.device);

        // Cleanup old swapchain resources (keep old swapchain handle for driver reuse)
        self.destroyFramebuffers();
        self.destroyDepthResources();
        self.destroyImageViews();
        const old_swapchain = self.swapchain;
        if (self.swapchain_images.len > 0) {
            self.allocator.free(self.swapchain_images);
            self.swapchain_images = &.{};
        }

        // Recreate (passing old handle so driver can reuse memory)
        try self.createSwapchain(old_swapchain);
        // Old swapchain is retired now that the new one is created
        if (old_swapchain) |old| {
            if (vk.vkDestroySwapchainKHR) |destroy| destroy(self.device, old, null);
        }
        try self.createImageViews();
        try self.createDepthResources();
        try self.createFramebuffers();

        // Recreate per-image semaphores if swapchain image count changed
        try self.recreateRenderFinishedSemaphores();

        // Recreate UI buffers with new screen dimensions
        self.crosshair_buffer.destroy(self.device);
        try self.createCrosshairBuffer();

        self.hotbar_buffer.destroy(self.device);
        try self.createHotbarBuffer();
        self.writeHotbarSelectionVertices(self.hotbar_selected_slot);

        // Rebuild hotbar icons with new screen dimensions
        self.rebuildHotbarIconBuffer() catch |err| {
            logger.warn("Failed to rebuild hotbar icons: {}", .{err});
        };

        logger.info("Swapchain recreated: {}x{}", .{ self.swapchain_extent.width, self.swapchain_extent.height });
    }

    const validation_layer = "VK_LAYER_KHRONOS_validation";

    fn createInstance(self: *Self) !void {
        const ext_info = platform.getRequiredVulkanExtensions() orelse {
            logger.err("Failed to get required Vulkan extensions", .{});
            return error.VulkanExtensionsFailed;
        };

        logger.info("Required extensions: {}", .{ext_info.count});

        // Check for validation layer support in debug builds
        const validation_available = if (enable_validation) blk: {
            const vkEnumerateInstanceLayerProperties = vk.vkEnumerateInstanceLayerProperties orelse break :blk false;
            var layer_count: u32 = 0;
            if (vkEnumerateInstanceLayerProperties(&layer_count, null) != vk.VK_SUCCESS) break :blk false;

            const layers = self.allocator.alloc(vk.VkLayerProperties, layer_count) catch break :blk false;
            defer self.allocator.free(layers);
            if (vkEnumerateInstanceLayerProperties(&layer_count, layers.ptr) != vk.VK_SUCCESS) break :blk false;

            var found = false;
            for (layers[0..layer_count]) |layer| {
                const name: [*:0]const u8 = @ptrCast(&layer.layerName);
                if (std.mem.orderZ(u8, name, validation_layer) == .eq) {
                    found = true;
                    break;
                }
            }
            break :blk found;
        } else false;

        if (enable_validation and !validation_available) {
            logger.warn("Validation layer not available - install Vulkan SDK for debug diagnostics", .{});
        }
        if (validation_available) {
            logger.info("Vulkan validation layer enabled", .{});
        }

        // Build extension list (add VK_EXT_debug_utils if validation is active)
        const validation_layers = [_][*c]const u8{validation_layer};
        const debug_utils_ext = vk.VK_EXT_DEBUG_UTILS_EXTENSION_NAME;
        var ext_count = ext_info.count;
        var extensions_buf: [32][*c]const u8 = undefined;
        for (0..ext_info.count) |i| {
            extensions_buf[i] = ext_info.extensions[i];
        }
        if (validation_available) {
            extensions_buf[ext_count] = debug_utils_ext;
            ext_count += 1;
        }

        const app_info = vk.VkApplicationInfo{
            .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pNext = null,
            .pApplicationName = "FarHorizons",
            .applicationVersion = vk.VK_MAKE_VERSION(0, 0, 1),
            .pEngineName = "FarHorizons Engine",
            .engineVersion = vk.VK_MAKE_VERSION(0, 0, 1),
            .apiVersion = vk.VK_API_VERSION_1_2,
        };

        const create_info = vk.VkInstanceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .pApplicationInfo = &app_info,
            .enabledLayerCount = if (validation_available) 1 else 0,
            .ppEnabledLayerNames = if (validation_available) &validation_layers else null,
            .enabledExtensionCount = ext_count,
            .ppEnabledExtensionNames = &extensions_buf,
        };

        const vkCreateInstance = vk.vkCreateInstance orelse return error.VulkanFunctionNotLoaded;
        if (vkCreateInstance(&create_info, null, &self.instance) != vk.VK_SUCCESS) {
            return error.VulkanInstanceFailed;
        }

        volk.loadInstance(self.instance);

        // Set up debug messenger
        if (validation_available) {
            self.setupDebugMessenger();
        }

        logger.info("Vulkan instance created", .{});
    }

    fn vulkanDebugCallback(
        severity: vk.VkDebugUtilsMessageSeverityFlagBitsEXT,
        _: vk.VkDebugUtilsMessageTypeFlagsEXT,
        callback_data: [*c]const vk.VkDebugUtilsMessengerCallbackDataEXT,
        _: ?*anyopaque,
    ) callconv(.c) vk.VkBool32 {
        const msg: [*:0]const u8 = if (callback_data != null and callback_data.*.pMessage != null)
            callback_data.*.pMessage
        else
            "unknown";

        if (severity >= vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) {
            logger.err("Validation: {s}", .{msg});
        } else if (severity >= vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) {
            logger.warn("Validation: {s}", .{msg});
        } else {
            logger.info("Validation: {s}", .{msg});
        }
        return vk.VK_FALSE;
    }

    fn setupDebugMessenger(self: *Self) void {
        const vkCreateDebugUtilsMessengerEXT = vk.vkCreateDebugUtilsMessengerEXT orelse return;

        const create_info = vk.VkDebugUtilsMessengerCreateInfoEXT{
            .sType = vk.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            .pNext = null,
            .flags = 0,
            .messageSeverity = vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
            .messageType = vk.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                vk.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                vk.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
            .pfnUserCallback = &vulkanDebugCallback,
            .pUserData = null,
        };

        if (vkCreateDebugUtilsMessengerEXT(self.instance, &create_info, null, &self.debug_messenger) != vk.VK_SUCCESS) {
            logger.warn("Failed to create debug messenger", .{});
        }
    }

    fn createSurface(self: *Self) !void {
        const surface = try self.window.?.createSurface(@ptrCast(self.instance));
        self.surface = @ptrCast(surface);
    }

    fn pickPhysicalDevice(self: *Self) !void {
        const vkEnumeratePhysicalDevices = vk.vkEnumeratePhysicalDevices orelse return error.VulkanFunctionNotLoaded;

        var device_count: u32 = 0;
        _ = vkEnumeratePhysicalDevices(self.instance, &device_count, null);

        if (device_count == 0) {
            logger.err("No Vulkan-capable GPUs found", .{});
            return error.NoVulkanDevices;
        }

        const devices = try self.allocator.alloc(vk.VkPhysicalDevice, device_count);
        defer self.allocator.free(devices);
        _ = vkEnumeratePhysicalDevices(self.instance, &device_count, devices.ptr);

        for (devices) |device| {
            if (try self.isDeviceSuitable(device)) {
                self.physical_device = device;
                break;
            }
        }

        if (self.physical_device == null) {
            logger.err("No suitable GPU found", .{});
            return error.NoSuitableDevice;
        }

        // Log device name
        const vkGetPhysicalDeviceProperties = vk.vkGetPhysicalDeviceProperties orelse return error.VulkanFunctionNotLoaded;
        var props: vk.VkPhysicalDeviceProperties = undefined;
        vkGetPhysicalDeviceProperties(self.physical_device, &props);
        const name_slice = std.mem.sliceTo(&props.deviceName, 0);
        logger.info("Selected GPU: {s}", .{name_slice});

        if (!self.has_dedicated_transfer) {
            logger.warn("GPU '{s}' has no dedicated transfer queue — chunk uploads will share the graphics queue. " ++
                "Performance may be degraded. A discrete NVIDIA or AMD GPU is recommended.", .{name_slice});
        }
    }

    fn isDeviceSuitable(self: *Self, device: vk.VkPhysicalDevice) !bool {
        const families = try self.findQueueFamilies(device);
        if (families.graphics == null or families.present == null) return false;

        self.graphics_family = families.graphics.?;
        self.present_family = families.present.?;
        self.transfer_family = families.transfer orelse self.graphics_family;
        self.has_dedicated_transfer = families.transfer != null;

        // Check swapchain support
        const vkEnumerateDeviceExtensionProperties = vk.vkEnumerateDeviceExtensionProperties orelse return error.VulkanFunctionNotLoaded;
        var ext_count: u32 = 0;
        _ = vkEnumerateDeviceExtensionProperties(device, null, &ext_count, null);

        const extensions = try self.allocator.alloc(vk.VkExtensionProperties, ext_count);
        defer self.allocator.free(extensions);
        _ = vkEnumerateDeviceExtensionProperties(device, null, &ext_count, extensions.ptr);

        var has_swapchain = false;
        for (extensions) |ext| {
            const name = std.mem.sliceTo(&ext.extensionName, 0);
            if (std.mem.eql(u8, name, "VK_KHR_swapchain")) {
                has_swapchain = true;
                break;
            }
        }

        return has_swapchain;
    }

    fn findQueueFamilies(self: *Self, device: vk.VkPhysicalDevice) !struct { graphics: ?u32, present: ?u32, transfer: ?u32 } {
        const vkGetPhysicalDeviceQueueFamilyProperties = vk.vkGetPhysicalDeviceQueueFamilyProperties orelse return error.VulkanFunctionNotLoaded;
        const vkGetPhysicalDeviceSurfaceSupportKHR = vk.vkGetPhysicalDeviceSurfaceSupportKHR orelse return error.VulkanFunctionNotLoaded;

        var queue_family_count: u32 = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, null);

        const queue_families = try self.allocator.alloc(vk.VkQueueFamilyProperties, queue_family_count);
        defer self.allocator.free(queue_families);
        vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, queue_families.ptr);

        var graphics: ?u32 = null;
        var present: ?u32 = null;
        var transfer: ?u32 = null;

        for (queue_families, 0..) |family, i| {
            const idx: u32 = @intCast(i);

            if ((family.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT) != 0) {
                graphics = idx;
            }

            var present_support: vk.VkBool32 = vk.VK_FALSE;
            _ = vkGetPhysicalDeviceSurfaceSupportKHR(device, idx, self.surface, &present_support);
            if (present_support == vk.VK_TRUE) {
                present = idx;
            }

            // Look for dedicated transfer queue (has TRANSFER but not GRAPHICS)
            if ((family.queueFlags & vk.VK_QUEUE_TRANSFER_BIT) != 0 and
                (family.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT) == 0)
            {
                transfer = idx;
            }
        }

        return .{ .graphics = graphics, .present = present, .transfer = transfer };
    }

    fn createLogicalDevice(self: *Self) !void {
        const vkCreateDevice = vk.vkCreateDevice orelse return error.VulkanFunctionNotLoaded;
        const vkGetDeviceQueue = vk.vkGetDeviceQueue orelse return error.VulkanFunctionNotLoaded;

        const queue_priority: f32 = 1.0;
        var queue_create_infos: [3]vk.VkDeviceQueueCreateInfo = undefined;
        var queue_count: u32 = 1;

        queue_create_infos[0] = .{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = self.graphics_family,
            .queueCount = 1,
            .pQueuePriorities = &queue_priority,
        };

        if (self.graphics_family != self.present_family) {
            queue_create_infos[queue_count] = .{
                .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .queueFamilyIndex = self.present_family,
                .queueCount = 1,
                .pQueuePriorities = &queue_priority,
            };
            queue_count += 1;
        }

        // Add dedicated transfer queue if it's a unique family
        if (self.has_dedicated_transfer and
            self.transfer_family != self.graphics_family and
            self.transfer_family != self.present_family)
        {
            queue_create_infos[queue_count] = .{
                .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .queueFamilyIndex = self.transfer_family,
                .queueCount = 1,
                .pQueuePriorities = &queue_priority,
            };
            queue_count += 1;
        }

        const device_extensions = [_][*:0]const u8{"VK_KHR_swapchain"};

        // Enable Vulkan 1.2 features (includes promoted descriptor indexing features)
        // Cannot use VkPhysicalDeviceDescriptorIndexingFeatures alongside this - they conflict
        var vulkan12_features = std.mem.zeroes(vk.VkPhysicalDeviceVulkan12Features);
        vulkan12_features.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES;
        vulkan12_features.drawIndirectCount = vk.VK_TRUE;
        vulkan12_features.shaderSampledImageArrayNonUniformIndexing = vk.VK_TRUE;
        vulkan12_features.runtimeDescriptorArray = vk.VK_TRUE;
        vulkan12_features.descriptorBindingPartiallyBound = vk.VK_TRUE;
        vulkan12_features.descriptorBindingVariableDescriptorCount = vk.VK_TRUE;
        vulkan12_features.descriptorBindingSampledImageUpdateAfterBind = vk.VK_TRUE;
        vulkan12_features.timelineSemaphore = vk.VK_TRUE;

        var device_features2 = std.mem.zeroes(vk.VkPhysicalDeviceFeatures2);
        device_features2.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
        device_features2.pNext = &vulkan12_features;

        const create_info = vk.VkDeviceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = &device_features2,
            .flags = 0,
            .queueCreateInfoCount = queue_count,
            .pQueueCreateInfos = &queue_create_infos,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = device_extensions.len,
            .ppEnabledExtensionNames = &device_extensions,
            .pEnabledFeatures = null, // Using pNext chain instead
        };

        if (vkCreateDevice(self.physical_device, &create_info, null, &self.device) != vk.VK_SUCCESS) {
            return error.DeviceCreationFailed;
        }

        volk.loadDevice(self.device);

        vkGetDeviceQueue(self.device, self.graphics_family, 0, &self.graphics_queue);
        vkGetDeviceQueue(self.device, self.present_family, 0, &self.present_queue);

        if (self.has_dedicated_transfer) {
            vkGetDeviceQueue(self.device, self.transfer_family, 0, &self.transfer_queue);
            logger.info("Logical device created with dedicated transfer queue (family {})", .{self.transfer_family});
        } else {
            self.transfer_queue = self.graphics_queue;
            logger.info("Logical device created (no dedicated transfer queue, using graphics queue)", .{});
        }
    }

    fn createSwapchain(self: *Self, old_swapchain: vk.VkSwapchainKHR) !void {
        const vkGetPhysicalDeviceSurfaceCapabilitiesKHR = vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR orelse return error.VulkanFunctionNotLoaded;
        const vkGetPhysicalDeviceSurfaceFormatsKHR = vk.vkGetPhysicalDeviceSurfaceFormatsKHR orelse return error.VulkanFunctionNotLoaded;
        const vkGetPhysicalDeviceSurfacePresentModesKHR = vk.vkGetPhysicalDeviceSurfacePresentModesKHR orelse return error.VulkanFunctionNotLoaded;
        const vkCreateSwapchainKHR = vk.vkCreateSwapchainKHR orelse return error.VulkanFunctionNotLoaded;
        const vkGetSwapchainImagesKHR = vk.vkGetSwapchainImagesKHR orelse return error.VulkanFunctionNotLoaded;

        const window = self.window.?;

        var capabilities: vk.VkSurfaceCapabilitiesKHR = undefined;
        if (vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, self.surface, &capabilities) != vk.VK_SUCCESS) {
            return error.SurfaceCapabilitiesQueryFailed;
        }

        // Choose format
        var format_count: u32 = 0;
        if (vkGetPhysicalDeviceSurfaceFormatsKHR(self.physical_device, self.surface, &format_count, null) != vk.VK_SUCCESS) {
            return error.SurfaceFormatsQueryFailed;
        }
        const formats = try self.allocator.alloc(vk.VkSurfaceFormatKHR, format_count);
        defer self.allocator.free(formats);
        if (vkGetPhysicalDeviceSurfaceFormatsKHR(self.physical_device, self.surface, &format_count, formats.ptr) != vk.VK_SUCCESS) {
            return error.SurfaceFormatsQueryFailed;
        }

        var chosen_format = formats[0];
        for (formats) |format| {
            if (format.format == vk.VK_FORMAT_B8G8R8A8_SRGB and format.colorSpace == vk.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
                chosen_format = format;
                break;
            }
        }

        // Choose present mode (prefer mailbox, fallback to FIFO)
        var mode_count: u32 = 0;
        if (vkGetPhysicalDeviceSurfacePresentModesKHR(self.physical_device, self.surface, &mode_count, null) != vk.VK_SUCCESS) {
            return error.PresentModesQueryFailed;
        }
        const modes = try self.allocator.alloc(vk.VkPresentModeKHR, mode_count);
        defer self.allocator.free(modes);
        if (vkGetPhysicalDeviceSurfacePresentModesKHR(self.physical_device, self.surface, &mode_count, modes.ptr) != vk.VK_SUCCESS) {
            return error.PresentModesQueryFailed;
        }

        var chosen_mode: vk.VkPresentModeKHR = vk.VK_PRESENT_MODE_FIFO_KHR;
        for (modes) |mode| {
            if (mode == vk.VK_PRESENT_MODE_MAILBOX_KHR) {
                chosen_mode = mode;
                break;
            }
        }

        // Choose extent
        var extent: vk.VkExtent2D = undefined;
        if (capabilities.currentExtent.width != 0xFFFFFFFF) {
            extent = capabilities.currentExtent;
        } else {
            extent = .{
                .width = std.math.clamp(window.getFramebufferWidth(), capabilities.minImageExtent.width, capabilities.maxImageExtent.width),
                .height = std.math.clamp(window.getFramebufferHeight(), capabilities.minImageExtent.height, capabilities.maxImageExtent.height),
            };
        }

        var image_count = capabilities.minImageCount + 1;
        if (capabilities.maxImageCount > 0 and image_count > capabilities.maxImageCount) {
            image_count = capabilities.maxImageCount;
        }

        var create_info = vk.VkSwapchainCreateInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .pNext = null,
            .flags = 0,
            .surface = self.surface,
            .minImageCount = image_count,
            .imageFormat = chosen_format.format,
            .imageColorSpace = chosen_format.colorSpace,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            .imageUsage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .imageSharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .preTransform = capabilities.currentTransform,
            .compositeAlpha = vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = chosen_mode,
            .clipped = vk.VK_TRUE,
            .oldSwapchain = old_swapchain,
        };

        const queue_family_indices = [_]u32{ self.graphics_family, self.present_family };
        if (self.graphics_family != self.present_family) {
            create_info.imageSharingMode = vk.VK_SHARING_MODE_CONCURRENT;
            create_info.queueFamilyIndexCount = 2;
            create_info.pQueueFamilyIndices = &queue_family_indices;
        }

        if (vkCreateSwapchainKHR(self.device, &create_info, null, &self.swapchain) != vk.VK_SUCCESS) {
            return error.SwapchainCreationFailed;
        }

        self.swapchain_format = chosen_format.format;
        self.swapchain_extent = extent;

        // Get swapchain images
        var actual_image_count: u32 = 0;
        if (vkGetSwapchainImagesKHR(self.device, self.swapchain, &actual_image_count, null) != vk.VK_SUCCESS) {
            return error.SwapchainImagesQueryFailed;
        }
        self.swapchain_images = try self.allocator.alloc(vk.VkImage, actual_image_count);
        if (vkGetSwapchainImagesKHR(self.device, self.swapchain, &actual_image_count, self.swapchain_images.ptr) != vk.VK_SUCCESS) {
            return error.SwapchainImagesQueryFailed;
        }

        logger.info("Swapchain created: {}x{}, {} images", .{ extent.width, extent.height, actual_image_count });
    }

    fn createImageViews(self: *Self) !void {
        self.swapchain_image_views = try self.allocator.alloc(vk.VkImageView, self.swapchain_images.len);
        @memset(self.swapchain_image_views, null);
        errdefer self.destroyImageViews();

        for (self.swapchain_images, 0..) |image, i| {
            self.swapchain_image_views[i] = try ImageViewHelper.createColor2D(
                self.device,
                image,
                self.swapchain_format,
            );
        }

        logger.info("Image views created", .{});
    }

    fn createDepthResources(self: *Self) !void {
        const vkCreateImage = vk.vkCreateImage orelse return error.VulkanFunctionNotLoaded;
        const vkGetImageMemoryRequirements = vk.vkGetImageMemoryRequirements orelse return error.VulkanFunctionNotLoaded;
        const vkAllocateMemory = vk.vkAllocateMemory orelse return error.VulkanFunctionNotLoaded;
        const vkBindImageMemory = vk.vkBindImageMemory orelse return error.VulkanFunctionNotLoaded;

        self.depth_format = try self.findDepthFormat();

        const image_info = vk.VkImageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = vk.VK_IMAGE_TYPE_2D,
            .format = self.depth_format,
            .extent = .{
                .width = self.swapchain_extent.width,
                .height = self.swapchain_extent.height,
                .depth = 1,
            },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
            .usage = vk.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        };

        if (vkCreateImage(self.device, &image_info, null, &self.depth_image) != vk.VK_SUCCESS) {
            return error.DepthImageCreationFailed;
        }
        errdefer {
            if (vk.vkDestroyImage) |destroy| destroy(self.device, self.depth_image, null);
            self.depth_image = null;
        }

        var mem_requirements: vk.VkMemoryRequirements = undefined;
        vkGetImageMemoryRequirements(self.device, self.depth_image, &mem_requirements);

        const mem_type = try self.findMemoryType(
            mem_requirements.memoryTypeBits,
            vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        );

        const alloc_info = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = mem_requirements.size,
            .memoryTypeIndex = mem_type,
        };

        if (vkAllocateMemory(self.device, &alloc_info, null, &self.depth_image_memory) != vk.VK_SUCCESS) {
            return error.DepthMemoryAllocationFailed;
        }
        errdefer {
            if (vk.vkFreeMemory) |free| free(self.device, self.depth_image_memory, null);
            self.depth_image_memory = null;
        }

        if (vkBindImageMemory(self.device, self.depth_image, self.depth_image_memory, 0) != vk.VK_SUCCESS) {
            return error.DepthImageMemoryBindFailed;
        }

        // Create depth image view using helper
        self.depth_image_view = try ImageViewHelper.createDepth2D(
            self.device,
            self.depth_image,
            self.depth_format,
        );

        logger.info("Depth resources created", .{});
    }

    fn findDepthFormat(self: *Self) !vk.VkFormat {
        const vkGetPhysicalDeviceFormatProperties = vk.vkGetPhysicalDeviceFormatProperties orelse return error.VulkanFunctionNotLoaded;

        const candidates = [_]vk.VkFormat{
            vk.VK_FORMAT_D32_SFLOAT,
            vk.VK_FORMAT_D32_SFLOAT_S8_UINT,
            vk.VK_FORMAT_D24_UNORM_S8_UINT,
        };

        for (candidates) |format| {
            var props: vk.VkFormatProperties = undefined;
            vkGetPhysicalDeviceFormatProperties(self.physical_device, format, &props);

            if ((props.optimalTilingFeatures & vk.VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT) != 0) {
                return format;
            }
        }

        return error.NoSupportedDepthFormat;
    }

    fn createRenderPass(self: *Self) !void {
        const vkCreateRenderPass = vk.vkCreateRenderPass orelse return error.VulkanFunctionNotLoaded;

        const color_attachment = vk.VkAttachmentDescription{
            .flags = 0,
            .format = self.swapchain_format,
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        };

        const depth_attachment = vk.VkAttachmentDescription{
            .flags = 0,
            .format = self.depth_format,
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .stencilLoadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = vk.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        };

        const attachments = [_]vk.VkAttachmentDescription{ color_attachment, depth_attachment };

        const color_attachment_ref = vk.VkAttachmentReference{
            .attachment = 0,
            .layout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };

        const depth_attachment_ref = vk.VkAttachmentReference{
            .attachment = 1,
            .layout = vk.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        };

        const subpass = vk.VkSubpassDescription{
            .flags = 0,
            .pipelineBindPoint = vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            .inputAttachmentCount = 0,
            .pInputAttachments = null,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_attachment_ref,
            .pResolveAttachments = null,
            .pDepthStencilAttachment = &depth_attachment_ref,
            .preserveAttachmentCount = 0,
            .pPreserveAttachments = null,
        };

        const dependency = vk.VkSubpassDependency{
            .srcSubpass = vk.VK_SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | vk.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
            .dstStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | vk.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
            .srcAccessMask = 0,
            .dstAccessMask = vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | vk.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
            .dependencyFlags = 0,
        };

        const render_pass_info = vk.VkRenderPassCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .attachmentCount = attachments.len,
            .pAttachments = &attachments,
            .subpassCount = 1,
            .pSubpasses = &subpass,
            .dependencyCount = 1,
            .pDependencies = &dependency,
        };

        if (vkCreateRenderPass(self.device, &render_pass_info, null, &self.render_pass) != vk.VK_SUCCESS) {
            return error.RenderPassCreationFailed;
        }

        logger.info("Render pass created", .{});
    }

    fn createDescriptorSetLayout(self: *Self) !void {
        // Binding 0: Uniform buffer (MVP matrices)
        // Binding 1: Combined image sampler (texture)
        // Binding 2: Storage buffer (chunk metadata for vertex shader position decode)
        self.descriptor_set_layout = try DescriptorSetLayoutBuilder.init()
            .withUniformBuffer(0, vk.VK_SHADER_STAGE_VERTEX_BIT)
            .withSampler(1, vk.VK_SHADER_STAGE_FRAGMENT_BIT)
            .withStorageBuffer(2, vk.VK_SHADER_STAGE_VERTEX_BIT)
            .build(self.device);

        logger.info("Descriptor set layout created", .{});
    }

    fn createGraphicsPipeline(self: *Self) !void {
        const vkCreateShaderModule = vk.vkCreateShaderModule orelse return error.VulkanFunctionNotLoaded;
        const vkDestroyShaderModule = vk.vkDestroyShaderModule orelse return error.VulkanFunctionNotLoaded;
        const vkCreatePipelineLayout = vk.vkCreatePipelineLayout orelse return error.VulkanFunctionNotLoaded;
        const vkCreateGraphicsPipelines = vk.vkCreateGraphicsPipelines orelse return error.VulkanFunctionNotLoaded;

        // Get SPIR-V shaders from ShaderManager (runtime-compiled with #fh_import support)
        const vert_shader_code = if (self.shader_manager) |*sm|
            sm.getDefaultVertexShader() orelse return error.ShaderNotAvailable
        else
            return error.ShaderManagerNotInitialized;

        const frag_shader_code = if (self.shader_manager) |*sm|
            sm.getDefaultFragmentShader() orelse return error.ShaderNotAvailable
        else
            return error.ShaderManagerNotInitialized;

        const vert_module = try self.createShaderModule(vkCreateShaderModule, vert_shader_code);
        defer vkDestroyShaderModule(self.device, vert_module, null);

        const frag_module = try self.createShaderModule(vkCreateShaderModule, frag_shader_code);
        defer vkDestroyShaderModule(self.device, frag_module, null);

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

        const dynamic_states = [_]vk.VkDynamicState{ vk.VK_DYNAMIC_STATE_VIEWPORT, vk.VK_DYNAMIC_STATE_SCISSOR };
        const dynamic_state = vk.VkPipelineDynamicStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .dynamicStateCount = dynamic_states.len,
            .pDynamicStates = &dynamic_states,
        };

        const binding_description = CompactVertex.getBindingDescription();
        const attribute_descriptions = CompactVertex.getAttributeDescriptions();

        const vertex_input_info = vk.VkPipelineVertexInputStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .vertexBindingDescriptionCount = 1,
            .pVertexBindingDescriptions = &binding_description,
            .vertexAttributeDescriptionCount = attribute_descriptions.len,
            .pVertexAttributeDescriptions = &attribute_descriptions,
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
            .logicOp = vk.VK_LOGIC_OP_COPY,
            .attachmentCount = 1,
            .pAttachments = &color_blend_attachment,
            .blendConstants = .{ 0.0, 0.0, 0.0, 0.0 },
        };

        const descriptor_set_layouts = [_]vk.VkDescriptorSetLayout{self.descriptor_set_layout};
        const pipeline_layout_info = vk.VkPipelineLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 1,
            .pSetLayouts = &descriptor_set_layouts,
            .pushConstantRangeCount = 0,
            .pPushConstantRanges = null,
        };

        if (vkCreatePipelineLayout(self.device, &pipeline_layout_info, null, &self.pipeline_layout) != vk.VK_SUCCESS) {
            return error.PipelineLayoutCreationFailed;
        }

        const pipeline_info = vk.VkGraphicsPipelineCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stageCount = shader_stages.len,
            .pStages = &shader_stages,
            .pVertexInputState = &vertex_input_info,
            .pInputAssemblyState = &input_assembly,
            .pTessellationState = null,
            .pViewportState = &viewport_state,
            .pRasterizationState = &rasterizer,
            .pMultisampleState = &multisampling,
            .pDepthStencilState = &depth_stencil,
            .pColorBlendState = &color_blending,
            .pDynamicState = &dynamic_state,
            .layout = self.pipeline_layout,
            .renderPass = self.render_pass,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };

        if (vkCreateGraphicsPipelines(self.device, null, 1, &pipeline_info, null, &self.graphics_pipeline) != vk.VK_SUCCESS) {
            return error.PipelineCreationFailed;
        }

        logger.info("Graphics pipeline created", .{});

        // Create layer-specific pipelines
        try self.createLayerPipelines(vkCreateShaderModule, vkDestroyShaderModule, vkCreateGraphicsPipelines);
    }

    /// Create layer-specific pipelines for optimized rendering
    fn createLayerPipelines(
        self: *Self,
        vkCreateShaderModule: @TypeOf(vk.vkCreateShaderModule.?),
        vkDestroyShaderModule: @TypeOf(vk.vkDestroyShaderModule.?),
        vkCreateGraphicsPipelines: @TypeOf(vk.vkCreateGraphicsPipelines.?),
    ) !void {
        const sm = &(self.shader_manager orelse return error.ShaderManagerNotInitialized);

        // Get vertex shader (shared across all layer pipelines)
        const vert_shader_code = sm.getDefaultVertexShader() orelse return error.ShaderNotAvailable;
        const vert_module = try self.createShaderModule(vkCreateShaderModule, vert_shader_code);
        defer vkDestroyShaderModule(self.device, vert_module, null);

        // Common pipeline state
        const dynamic_states = [_]vk.VkDynamicState{ vk.VK_DYNAMIC_STATE_VIEWPORT, vk.VK_DYNAMIC_STATE_SCISSOR };
        const dynamic_state = vk.VkPipelineDynamicStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .dynamicStateCount = dynamic_states.len,
            .pDynamicStates = &dynamic_states,
        };

        const binding_description = CompactVertex.getBindingDescription();
        const attribute_descriptions = CompactVertex.getAttributeDescriptions();

        const vertex_input_info = vk.VkPipelineVertexInputStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .vertexBindingDescriptionCount = 1,
            .pVertexBindingDescriptions = &binding_description,
            .vertexAttributeDescriptionCount = attribute_descriptions.len,
            .pVertexAttributeDescriptions = &attribute_descriptions,
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

        // Depth stencil for solid/cutout (depth write ON)
        const depth_stencil_write = vk.VkPipelineDepthStencilStateCreateInfo{
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

        // Depth stencil for translucent (depth write OFF)
        const depth_stencil_no_write = vk.VkPipelineDepthStencilStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthTestEnable = vk.VK_TRUE,
            .depthWriteEnable = vk.VK_FALSE, // Don't write depth for translucent
            .depthCompareOp = vk.VK_COMPARE_OP_LESS,
            .depthBoundsTestEnable = vk.VK_FALSE,
            .stencilTestEnable = vk.VK_FALSE,
            .front = std.mem.zeroes(vk.VkStencilOpState),
            .back = std.mem.zeroes(vk.VkStencilOpState),
            .minDepthBounds = 0.0,
            .maxDepthBounds = 1.0,
        };

        // Color blend for solid/cutout (no blending)
        const color_blend_attachment_opaque = vk.VkPipelineColorBlendAttachmentState{
            .blendEnable = vk.VK_FALSE,
            .srcColorBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ZERO,
            .colorBlendOp = vk.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ZERO,
            .alphaBlendOp = vk.VK_BLEND_OP_ADD,
            .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT | vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT,
        };

        // Color blend for translucent (alpha blending)
        const color_blend_attachment_blend = vk.VkPipelineColorBlendAttachmentState{
            .blendEnable = vk.VK_TRUE,
            .srcColorBlendFactor = vk.VK_BLEND_FACTOR_SRC_ALPHA,
            .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .colorBlendOp = vk.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ZERO,
            .alphaBlendOp = vk.VK_BLEND_OP_ADD,
            .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT | vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT,
        };

        const color_blending_opaque = vk.VkPipelineColorBlendStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .logicOpEnable = vk.VK_FALSE,
            .logicOp = vk.VK_LOGIC_OP_COPY,
            .attachmentCount = 1,
            .pAttachments = &color_blend_attachment_opaque,
            .blendConstants = .{ 0.0, 0.0, 0.0, 0.0 },
        };

        const color_blending_blend = vk.VkPipelineColorBlendStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .logicOpEnable = vk.VK_FALSE,
            .logicOp = vk.VK_LOGIC_OP_COPY,
            .attachmentCount = 1,
            .pAttachments = &color_blend_attachment_blend,
            .blendConstants = .{ 0.0, 0.0, 0.0, 0.0 },
        };

        // === SOLID PIPELINE ===
        if (sm.getSolidFragmentShader()) |solid_frag_code| {
            const solid_frag_module = try self.createShaderModule(vkCreateShaderModule, solid_frag_code);
            defer vkDestroyShaderModule(self.device, solid_frag_module, null);

            const solid_stages = [_]vk.VkPipelineShaderStageCreateInfo{
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
                    .module = solid_frag_module,
                    .pName = "main",
                    .pSpecializationInfo = null,
                },
            };

            const solid_pipeline_info = vk.VkGraphicsPipelineCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stageCount = solid_stages.len,
                .pStages = &solid_stages,
                .pVertexInputState = &vertex_input_info,
                .pInputAssemblyState = &input_assembly,
                .pTessellationState = null,
                .pViewportState = &viewport_state,
                .pRasterizationState = &rasterizer,
                .pMultisampleState = &multisampling,
                .pDepthStencilState = &depth_stencil_write,
                .pColorBlendState = &color_blending_opaque,
                .pDynamicState = &dynamic_state,
                .layout = self.pipeline_layout,
                .renderPass = self.render_pass,
                .subpass = 0,
                .basePipelineHandle = null,
                .basePipelineIndex = -1,
            };

            if (vkCreateGraphicsPipelines(self.device, null, 1, &solid_pipeline_info, null, &self.layer_pipelines[0]) != vk.VK_SUCCESS) {
                return error.PipelineCreationFailed;
            }
            logger.info("Solid pipeline created", .{});
        }

        // === CUTOUT PIPELINE ===
        if (sm.getCutoutFragmentShader()) |cutout_frag_code| {
            const cutout_frag_module = try self.createShaderModule(vkCreateShaderModule, cutout_frag_code);
            defer vkDestroyShaderModule(self.device, cutout_frag_module, null);

            const cutout_stages = [_]vk.VkPipelineShaderStageCreateInfo{
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
                    .module = cutout_frag_module,
                    .pName = "main",
                    .pSpecializationInfo = null,
                },
            };

            const cutout_pipeline_info = vk.VkGraphicsPipelineCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stageCount = cutout_stages.len,
                .pStages = &cutout_stages,
                .pVertexInputState = &vertex_input_info,
                .pInputAssemblyState = &input_assembly,
                .pTessellationState = null,
                .pViewportState = &viewport_state,
                .pRasterizationState = &rasterizer,
                .pMultisampleState = &multisampling,
                .pDepthStencilState = &depth_stencil_write,
                .pColorBlendState = &color_blending_opaque,
                .pDynamicState = &dynamic_state,
                .layout = self.pipeline_layout,
                .renderPass = self.render_pass,
                .subpass = 0,
                .basePipelineHandle = null,
                .basePipelineIndex = -1,
            };

            if (vkCreateGraphicsPipelines(self.device, null, 1, &cutout_pipeline_info, null, &self.layer_pipelines[1]) != vk.VK_SUCCESS) {
                return error.PipelineCreationFailed;
            }
            logger.info("Cutout pipeline created", .{});
        }

        // === TRANSLUCENT PIPELINE ===
        if (sm.getTranslucentFragmentShader()) |translucent_frag_code| {
            const translucent_frag_module = try self.createShaderModule(vkCreateShaderModule, translucent_frag_code);
            defer vkDestroyShaderModule(self.device, translucent_frag_module, null);

            const translucent_stages = [_]vk.VkPipelineShaderStageCreateInfo{
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
                    .module = translucent_frag_module,
                    .pName = "main",
                    .pSpecializationInfo = null,
                },
            };

            const translucent_pipeline_info = vk.VkGraphicsPipelineCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stageCount = translucent_stages.len,
                .pStages = &translucent_stages,
                .pVertexInputState = &vertex_input_info,
                .pInputAssemblyState = &input_assembly,
                .pTessellationState = null,
                .pViewportState = &viewport_state,
                .pRasterizationState = &rasterizer,
                .pMultisampleState = &multisampling,
                .pDepthStencilState = &depth_stencil_no_write,
                .pColorBlendState = &color_blending_blend,
                .pDynamicState = &dynamic_state,
                .layout = self.pipeline_layout,
                .renderPass = self.render_pass,
                .subpass = 0,
                .basePipelineHandle = null,
                .basePipelineIndex = -1,
            };

            if (vkCreateGraphicsPipelines(self.device, null, 1, &translucent_pipeline_info, null, &self.layer_pipelines[2]) != vk.VK_SUCCESS) {
                return error.PipelineCreationFailed;
            }
            logger.info("Translucent pipeline created", .{});
        }
    }

    fn createUIDescriptorSetLayout(self: *Self) !void {
        // Single combined image sampler for UI texture
        self.ui_descriptor_set_layout = try DescriptorSetLayoutBuilder.init()
            .withSampler(0, vk.VK_SHADER_STAGE_FRAGMENT_BIT)
            .build(self.device);

        logger.info("UI descriptor set layout created", .{});
    }

    /// UI Vertex for crosshair/HUD (2D position + UV)
    pub const UIVertex = extern struct {
        pos: [2]f32,
        uv: [2]f32,

        pub fn getBindingDescription() vk.VkVertexInputBindingDescription {
            return .{
                .binding = 0,
                .stride = @sizeOf(UIVertex),
                .inputRate = vk.VK_VERTEX_INPUT_RATE_VERTEX,
            };
        }

        pub fn getAttributeDescriptions() [2]vk.VkVertexInputAttributeDescription {
            return .{
                .{
                    .binding = 0,
                    .location = 0,
                    .format = vk.VK_FORMAT_R32G32_SFLOAT,
                    .offset = @offsetOf(UIVertex, "pos"),
                },
                .{
                    .binding = 0,
                    .location = 1,
                    .format = vk.VK_FORMAT_R32G32_SFLOAT,
                    .offset = @offsetOf(UIVertex, "uv"),
                },
            };
        }
    };

    /// Line Vertex for block outline rendering (3D position + color)
    pub const LineVertex = extern struct {
        pos: [3]f32,
        color: [4]f32,

        pub fn getBindingDescription() vk.VkVertexInputBindingDescription {
            return .{
                .binding = 0,
                .stride = @sizeOf(LineVertex),
                .inputRate = vk.VK_VERTEX_INPUT_RATE_VERTEX,
            };
        }

        pub fn getAttributeDescriptions() [2]vk.VkVertexInputAttributeDescription {
            return .{
                .{
                    .binding = 0,
                    .location = 0,
                    .format = vk.VK_FORMAT_R32G32B32_SFLOAT,
                    .offset = @offsetOf(LineVertex, "pos"),
                },
                .{
                    .binding = 0,
                    .location = 1,
                    .format = vk.VK_FORMAT_R32G32B32A32_SFLOAT,
                    .offset = @offsetOf(LineVertex, "color"),
                },
            };
        }
    };

    fn createUIPipeline(self: *Self) !void {
        const sm = &(self.shader_manager orelse return error.ShaderManagerNotInitialized);

        // Get UI shaders from ShaderManager
        const vert_shader_code = sm.getUIVertexShader() orelse return error.ShaderNotAvailable;
        const frag_shader_code = sm.getUIFragmentShader() orelse return error.ShaderNotAvailable;

        // Invert blend mode for crosshair (like Minecraft)
        // result = src * (1 - dst) + dst * (1 - src) = inverts background where crosshair is drawn
        const invert_blend = vk.VkPipelineColorBlendAttachmentState{
            .blendEnable = vk.VK_TRUE,
            .srcColorBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR,
            .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR,
            .colorBlendOp = vk.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ZERO,
            .alphaBlendOp = vk.VK_BLEND_OP_ADD,
            .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT | vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT,
        };

        var factory = VulkanPipelineFactory.init(self.device, self.render_pass);
        const result = try factory.create(.{
            .config = RenderPipelines.Pipelines.UI,
            .vertex_format = .ui_2d,
            .descriptor_set_layout = self.ui_descriptor_set_layout,
            .vertex_shader_code = vert_shader_code,
            .fragment_shader_code = frag_shader_code,
            .custom_blend = invert_blend,
        });

        self.ui_pipeline = result.pipeline;
        self.ui_pipeline_layout = result.layout;

        logger.info("UI pipeline created", .{});

        // Create separate hotbar pipeline with standard alpha blending
        const alpha_blend = vk.VkPipelineColorBlendAttachmentState{
            .blendEnable = vk.VK_TRUE,
            .srcColorBlendFactor = vk.VK_BLEND_FACTOR_SRC_ALPHA,
            .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .colorBlendOp = vk.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .alphaBlendOp = vk.VK_BLEND_OP_ADD,
            .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT | vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT,
        };

        var hotbar_factory = VulkanPipelineFactory.init(self.device, self.render_pass);
        const hotbar_result = try hotbar_factory.create(.{
            .config = RenderPipelines.Pipelines.UI,
            .vertex_format = .ui_2d,
            .descriptor_set_layout = self.ui_descriptor_set_layout,
            .vertex_shader_code = vert_shader_code,
            .fragment_shader_code = frag_shader_code,
            .custom_blend = alpha_blend,
        });

        self.hotbar_pipeline = hotbar_result.pipeline;
        // Destroy the duplicate layout - identical to ui_pipeline_layout which is already stored
        if (vk.vkDestroyPipelineLayout) |destroy| {
            destroy(self.device, hotbar_result.layout, null);
        }

        logger.info("Hotbar pipeline created", .{});
    }

    fn createLinePipeline(self: *Self) !void {
        const sm = &(self.shader_manager orelse return error.ShaderManagerNotInitialized);

        // Get line shaders from ShaderManager
        const vert_shader_code = sm.getLineVertexShader() orelse return error.ShaderNotAvailable;
        const frag_shader_code = sm.getLineFragmentShader() orelse return error.ShaderNotAvailable;

        // Extra dynamic state for line width
        const extra_dynamic_states = [_]vk.VkDynamicState{vk.VK_DYNAMIC_STATE_LINE_WIDTH};

        var factory = VulkanPipelineFactory.init(self.device, self.render_pass);
        const result = try factory.create(.{
            .config = RenderPipelines.Pipelines.LINES,
            .vertex_format = .line_3d,
            .descriptor_set_layout = self.descriptor_set_layout,
            .vertex_shader_code = vert_shader_code,
            .fragment_shader_code = frag_shader_code,
            .extra_dynamic_states = &extra_dynamic_states,
        });

        self.line_pipeline = result.pipeline;
        self.line_pipeline_layout = result.layout;

        logger.info("Line pipeline created", .{});
    }

    fn createHotbarIconPipeline(self: *Self) !void {
        const sm = &(self.shader_manager orelse return error.ShaderManagerNotInitialized);

        // Get hotbar icon shaders from ShaderManager
        const vert_shader_code = sm.getHotbarIconVertSpv() orelse return error.ShaderNotAvailable;
        const frag_shader_code = sm.getHotbarIconFragSpv() orelse return error.ShaderNotAvailable;

        // Standard alpha blending for block icons
        const alpha_blend = vk.VkPipelineColorBlendAttachmentState{
            .blendEnable = vk.VK_TRUE,
            .srcColorBlendFactor = vk.VK_BLEND_FACTOR_SRC_ALPHA,
            .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .colorBlendOp = vk.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .alphaBlendOp = vk.VK_BLEND_OP_ADD,
            .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT | vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT,
        };

        var factory = VulkanPipelineFactory.init(self.device, self.render_pass);
        const result = try factory.create(.{
            .config = RenderPipelines.Pipelines.UI,
            .vertex_format = .icon_3d,
            .descriptor_set_layout = self.ui_descriptor_set_layout,
            .vertex_shader_code = vert_shader_code,
            .fragment_shader_code = frag_shader_code,
            .custom_blend = alpha_blend,
        });

        self.hotbar_icon_pipeline = result.pipeline;
        self.hotbar_icon_pipeline_layout = result.layout;

        logger.info("Hotbar icon pipeline created", .{});
    }

    fn createEntityPipeline(self: *Self) !void {
        // Use bindless descriptor set layout if available, otherwise fall back to regular
        const layout_to_use = if (self.bindless_entity_descriptor_set_layout != null)
            self.bindless_entity_descriptor_set_layout
        else
            self.descriptor_set_layout;

        // Get entity shaders from ShaderManager
        const vert_shader_code = if (self.shader_manager) |*sm|
            sm.getEntityVertSpv() orelse return error.ShaderNotAvailable
        else
            return error.ShaderManagerNotInitialized;

        const frag_shader_code = if (self.shader_manager) |*sm|
            sm.getEntityFragSpv() orelse return error.ShaderNotAvailable
        else
            return error.ShaderManagerNotInitialized;

        // Use VulkanPipelineFactory to create the pipeline
        var factory = VulkanPipelineFactory.init(self.device, self.render_pass);
        const result = try factory.create(.{
            .config = RenderPipelines.Pipelines.ENTITY_SOLID,
            .vertex_format = .standard_3d,
            .descriptor_set_layout = layout_to_use,
            .vertex_shader_code = vert_shader_code,
            .fragment_shader_code = frag_shader_code,
        });

        self.entity_pipeline = result.pipeline;
        self.entity_pipeline_layout = result.layout;

        logger.info("Entity pipeline created", .{});
    }

    fn loadCrosshairTexture(self: *Self) !void {
        const gpu = if (self.gpu_device) |*g| g else return error.GpuDeviceNotInitialized;

        const texture = try TextureLoader.load(
            gpu,
            "assets/farhorizons/textures/gui/crosshair.png",
            .{
                .filter = .nearest,
                .address_mode = .clamp_to_edge,
                .format = .rgba8_unorm,
            },
        );

        self.crosshair_texture = texture.image;
        self.crosshair_texture_memory = texture.memory;
        self.crosshair_texture_view = texture.view;
        self.crosshair_sampler = texture.sampler;

        logger.info("Crosshair texture loaded ({}x{})", .{ texture.width, texture.height });
    }

    fn loadHotbarTextures(self: *Self) !void {
        const gpu = if (self.gpu_device) |*g| g else return error.GpuDeviceNotInitialized;

        // Load main hotbar texture
        const hotbar_tex = try TextureLoader.load(
            gpu,
            "assets/farhorizons/textures/gui/sprites/hud/hotbar.png",
            .{
                .filter = .nearest,
                .address_mode = .clamp_to_edge,
                .format = .rgba8_unorm,
            },
        );

        self.hotbar_texture = hotbar_tex.image;
        self.hotbar_texture_memory = hotbar_tex.memory;
        self.hotbar_texture_view = hotbar_tex.view;
        self.hotbar_sampler = hotbar_tex.sampler;

        logger.info("Hotbar texture loaded ({}x{})", .{ hotbar_tex.width, hotbar_tex.height });

        // Load selection texture
        const selection_tex = try TextureLoader.load(
            gpu,
            "assets/farhorizons/textures/gui/sprites/hud/hotbar_selection.png",
            .{
                .filter = .nearest,
                .address_mode = .clamp_to_edge,
                .format = .rgba8_unorm,
            },
        );

        self.hotbar_selection_texture = selection_tex.image;
        self.hotbar_selection_texture_memory = selection_tex.memory;
        self.hotbar_selection_texture_view = selection_tex.view;
        self.hotbar_selection_sampler = selection_tex.sampler;

        logger.info("Hotbar selection texture loaded ({}x{})", .{ selection_tex.width, selection_tex.height });
    }

    fn createUIDescriptorPool(self: *Self) !void {
        // Need sets for: crosshair (2) + hotbar (2) + selection (2) + icons (2) = 8 sets
        self.ui_descriptor_pool = try DescriptorPoolBuilder.init()
            .withSamplers(MAX_FRAMES_IN_FLIGHT * 4)
            .withMaxSets(MAX_FRAMES_IN_FLIGHT * 4)
            .build(self.device);

        logger.info("UI descriptor pool created", .{});
    }

    fn createUIDescriptorSets(self: *Self) !void {
        try DescriptorSetManager.allocateSets(
            self.device,
            self.ui_descriptor_pool,
            self.ui_descriptor_set_layout,
            MAX_FRAMES_IN_FLIGHT,
            &self.ui_descriptor_sets,
        );

        // Update descriptor sets to point to crosshair texture
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            DescriptorSetManager.updateSampler(
                self.device,
                self.ui_descriptor_sets[i],
                0,
                self.crosshair_texture_view,
                self.crosshair_sampler,
            );
        }

        logger.info("UI descriptor sets created", .{});
    }

    fn createHotbarIconDescriptorSets(self: *Self) !void {
        try DescriptorSetManager.allocateSets(
            self.device,
            self.ui_descriptor_pool,
            self.ui_descriptor_set_layout,
            MAX_FRAMES_IN_FLIGHT,
            &self.hotbar_icon_descriptor_sets,
        );

        // Note: These will be updated with block texture array in setTextureResources
        logger.info("Hotbar icon descriptor sets allocated", .{});
    }

    fn createCrosshairBuffer(self: *Self) !void {
        var gpu = self.gpu_device orelse return error.GpuDeviceNotInitialized;

        // Crosshair is rendered as a textured quad
        // Minecraft uses GUI scale - at scale 2, each texture pixel = 2 screen pixels
        const screen_height: f32 = @floatFromInt(self.swapchain_extent.height);
        const screen_width: f32 = @floatFromInt(self.swapchain_extent.width);

        // Calculate appropriate GUI scale based on screen height (like Minecraft)
        const gui_scale: f32 = if (screen_height < 480) 1.0 else if (screen_height < 720) 2.0 else if (screen_height < 1080) 2.0 else 3.0;

        // Crosshair size in screen pixels, convert to NDC
        const crosshair_pixels: f32 = 15.0 * gui_scale;
        const half_size_y: f32 = crosshair_pixels / screen_height;
        const half_size_x: f32 = crosshair_pixels / screen_width;

        // 6 vertices for 2 triangles (textured quad)
        const vertices = [_]UIVertex{
            .{ .pos = .{ -half_size_x, -half_size_y }, .uv = .{ 0.0, 0.0 } },
            .{ .pos = .{ half_size_x, -half_size_y }, .uv = .{ 1.0, 0.0 } },
            .{ .pos = .{ half_size_x, half_size_y }, .uv = .{ 1.0, 1.0 } },
            .{ .pos = .{ -half_size_x, -half_size_y }, .uv = .{ 0.0, 0.0 } },
            .{ .pos = .{ half_size_x, half_size_y }, .uv = .{ 1.0, 1.0 } },
            .{ .pos = .{ -half_size_x, half_size_y }, .uv = .{ 0.0, 1.0 } },
        };

        const result = try gpu.createBufferWithDataRaw(UIVertex, &vertices, vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        self.crosshair_buffer = ManagedBuffer.fromRaw(result.handle, result.memory);

        logger.info("Crosshair buffer created", .{});
    }

    fn createHotbarBuffer(self: *Self) !void {
        var gpu = self.gpu_device orelse return error.GpuDeviceNotInitialized;

        const screen_height: f32 = @floatFromInt(self.swapchain_extent.height);
        const screen_width: f32 = @floatFromInt(self.swapchain_extent.width);

        // GUI scale calculation (same as crosshair)
        const gui_scale: f32 = if (screen_height < 480) 1.0 else if (screen_height < 720) 2.0 else if (screen_height < 1080) 2.0 else 3.0;

        // Hotbar dimensions from Minecraft spec: 182x22 pixels
        const hotbar_width_pixels: f32 = 182.0 * gui_scale;
        const hotbar_height_pixels: f32 = 22.0 * gui_scale;

        // Convert to NDC (centered horizontally, at bottom of screen)
        // In Vulkan: Y=-1 is TOP, Y=+1 is BOTTOM
        const half_width_ndc: f32 = hotbar_width_pixels / screen_width;
        const height_ndc: f32 = (hotbar_height_pixels / screen_height) * 2.0;

        // Position: bottom of screen (Y = +1 in Vulkan NDC), centered (X = 0)
        const bottom_y: f32 = 1.0;
        const top_y: f32 = bottom_y - height_ndc;
        const left_x: f32 = -half_width_ndc;
        const right_x: f32 = half_width_ndc;

        const vertices = [_]UIVertex{
            .{ .pos = .{ left_x, top_y }, .uv = .{ 0.0, 0.0 } },
            .{ .pos = .{ right_x, top_y }, .uv = .{ 1.0, 0.0 } },
            .{ .pos = .{ right_x, bottom_y }, .uv = .{ 1.0, 1.0 } },
            .{ .pos = .{ left_x, top_y }, .uv = .{ 0.0, 0.0 } },
            .{ .pos = .{ right_x, bottom_y }, .uv = .{ 1.0, 1.0 } },
            .{ .pos = .{ left_x, bottom_y }, .uv = .{ 0.0, 1.0 } },
        };

        const result = try gpu.createBufferWithDataRaw(UIVertex, &vertices, vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        self.hotbar_buffer = ManagedBuffer.fromRaw(result.handle, result.memory);

        logger.info("Hotbar buffer created", .{});
    }

    fn createHotbarSelectionBuffer(self: *Self) !void {
        var gpu = self.gpu_device orelse return error.GpuDeviceNotInitialized;

        // Create a persistently mapped buffer for the selection indicator
        const buffer_size = @sizeOf(UIVertex) * 6;
        const result = try gpu.createMappedBufferRaw(buffer_size, vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        self.hotbar_selection_buffer = .{
            .handle = result.handle,
            .memory = result.memory,
            .mapped = result.mapped,
        };

        // Initialize with slot 0
        self.writeHotbarSelectionVertices(0);
    }

    fn writeHotbarSelectionVertices(self: *Self, selected_slot: u8) void {
        const screen_height: f32 = @floatFromInt(self.swapchain_extent.height);
        const screen_width: f32 = @floatFromInt(self.swapchain_extent.width);

        const gui_scale: f32 = if (screen_height < 480) 1.0 else if (screen_height < 720) 2.0 else if (screen_height < 1080) 2.0 else 3.0;

        // Selection box dimensions: 24x23 pixels
        const selection_width_pixels: f32 = 24.0 * gui_scale;
        const selection_height_pixels: f32 = 23.0 * gui_scale;

        // Selection position calculation (from Minecraft):
        // x = screenCenter - 91 - 1 + (selectedSlot * 20)
        // The selection box is centered on each slot
        const slot_offset_from_center: f32 = (-91.0 - 1.0 + (@as(f32, @floatFromInt(selected_slot)) * 20.0) + 12.0) * gui_scale;

        // Convert to NDC
        // In Vulkan: Y=-1 is TOP, Y=+1 is BOTTOM
        const selection_center_x: f32 = (slot_offset_from_center * 2.0) / screen_width;
        const half_width_ndc: f32 = selection_width_pixels / screen_width;
        const height_ndc: f32 = (selection_height_pixels / screen_height) * 2.0;

        // Y position: selection aligns with hotbar bottom
        const bottom_y: f32 = 1.0;
        const top_y: f32 = bottom_y - height_ndc;
        const left_x: f32 = selection_center_x - half_width_ndc;
        const right_x: f32 = selection_center_x + half_width_ndc;

        const vertices = [_]UIVertex{
            .{ .pos = .{ left_x, top_y }, .uv = .{ 0.0, 0.0 } },
            .{ .pos = .{ right_x, top_y }, .uv = .{ 1.0, 0.0 } },
            .{ .pos = .{ right_x, bottom_y }, .uv = .{ 1.0, 1.0 } },
            .{ .pos = .{ left_x, top_y }, .uv = .{ 0.0, 0.0 } },
            .{ .pos = .{ right_x, bottom_y }, .uv = .{ 1.0, 1.0 } },
            .{ .pos = .{ left_x, bottom_y }, .uv = .{ 0.0, 1.0 } },
        };

        // Write directly to mapped memory (no sync needed - host coherent)
        if (self.hotbar_selection_buffer.mapped) |mapped| {
            const dest: [*]UIVertex = @ptrCast(@alignCast(mapped));
            @memcpy(dest[0..6], &vertices);
        }
    }

    fn createHotbarDescriptorSets(self: *Self) !void {
        // Allocate sets for hotbar
        try DescriptorSetManager.allocateSets(
            self.device,
            self.ui_descriptor_pool,
            self.ui_descriptor_set_layout,
            MAX_FRAMES_IN_FLIGHT,
            &self.hotbar_descriptor_sets,
        );

        // Allocate sets for selection
        try DescriptorSetManager.allocateSets(
            self.device,
            self.ui_descriptor_pool,
            self.ui_descriptor_set_layout,
            MAX_FRAMES_IN_FLIGHT,
            &self.hotbar_selection_descriptor_sets,
        );

        // Update hotbar descriptor sets
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            DescriptorSetManager.updateSampler(
                self.device,
                self.hotbar_descriptor_sets[i],
                0,
                self.hotbar_texture_view,
                self.hotbar_sampler,
            );

            DescriptorSetManager.updateSampler(
                self.device,
                self.hotbar_selection_descriptor_sets[i],
                0,
                self.hotbar_selection_texture_view,
                self.hotbar_selection_sampler,
            );
        }

        logger.info("Hotbar descriptor sets created", .{});
    }

    /// Update hotbar selection position
    pub fn setHotbarSelection(self: *Self, slot: u8) void {
        if (slot != self.hotbar_selected_slot and slot < 9) {
            self.hotbar_selected_slot = slot;
            self.writeHotbarSelectionVertices(slot);
        }
    }

    fn createShaderModule(self: *Self, vkCreateShaderModule: anytype, code: []const u8) !vk.VkShaderModule {
        const create_info = vk.VkShaderModuleCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = code.len,
            .pCode = @ptrCast(@alignCast(code.ptr)),
        };

        var shader_module: vk.VkShaderModule = null;
        if (vkCreateShaderModule(self.device, &create_info, null, &shader_module) != vk.VK_SUCCESS) {
            return error.ShaderModuleCreationFailed;
        }
        return shader_module;
    }

    fn createFramebuffers(self: *Self) !void {
        const vkCreateFramebuffer = vk.vkCreateFramebuffer orelse return error.VulkanFunctionNotLoaded;

        self.framebuffers = try self.allocator.alloc(vk.VkFramebuffer, self.swapchain_image_views.len);

        for (self.swapchain_image_views, 0..) |image_view, i| {
            const attachments = [_]vk.VkImageView{ image_view, self.depth_image_view };

            const framebuffer_info = vk.VkFramebufferCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .renderPass = self.render_pass,
                .attachmentCount = attachments.len,
                .pAttachments = &attachments,
                .width = self.swapchain_extent.width,
                .height = self.swapchain_extent.height,
                .layers = 1,
            };

            if (vkCreateFramebuffer(self.device, &framebuffer_info, null, &self.framebuffers[i]) != vk.VK_SUCCESS) {
                return error.FramebufferCreationFailed;
            }
        }

        logger.info("Framebuffers created", .{});
    }

    fn createCommandPool(self: *Self) !void {
        const vkCreateCommandPool = vk.vkCreateCommandPool orelse return error.VulkanFunctionNotLoaded;

        const pool_info = vk.VkCommandPoolCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = self.graphics_family,
        };

        if (vkCreateCommandPool(self.device, &pool_info, null, &self.command_pool) != vk.VK_SUCCESS) {
            return error.CommandPoolCreationFailed;
        }

        logger.info("Command pool created", .{});
    }

    // Note: Vertex/Index buffers are created dynamically by uploadMesh()

    fn createUniformBuffers(self: *Self) !void {
        var gpu = self.gpu_device orelse return error.GpuDeviceNotInitialized;
        const buffer_size: u64 = @sizeOf(UniformBufferObject);

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            const result = try gpu.createMappedBufferRaw(buffer_size, vk.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT);
            self.uniform_buffers[i] = result.handle;
            self.uniform_buffers_memory[i] = result.memory;
            self.uniform_buffers_mapped[i] = result.mapped;
        }

        logger.info("Uniform buffers created", .{});
    }

    /// Create indirect draw buffer for batched draw commands
    fn createIndirectBuffer(self: *Self) !void {
        var gpu = self.gpu_device orelse return error.GpuDeviceNotInitialized;

        // Initial capacity for draw commands (need enough for large view distances)
        // With view_distance=16, vertical=8: ~18,500 chunks, potentially multiple commands each
        const initial_capacity: u32 = 65536;
        const buffer_size: u64 = @as(u64, initial_capacity) * @sizeOf(IndirectDrawCommand);

        const result = try gpu.createMappedBufferRaw(buffer_size, vk.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT);
        self.indirect_buffer = ManagedBuffer.fromMapped(result.handle, result.memory, result.mapped.?);
        self.indirect_buffer_capacity = initial_capacity;

        logger.info("Indirect draw buffer created with capacity for {} commands", .{initial_capacity});
    }

    /// Destroy indirect draw buffer
    fn destroyIndirectBuffer(self: *Self) void {
        self.indirect_buffer.destroy(self.device);
        self.indirect_buffer_capacity = 0;
    }

    /// Create GPU-driven rendering buffers (Phase 1 infrastructure)
    fn createGPUDrivenBuffers(self: *Self) !void {
        var gpu = self.gpu_device orelse return error.GpuDeviceNotInitialized;

        const device_local = vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;

        // Chunk metadata buffer: stores ChunkGPUData for all chunks
        const metadata_size = GPUDrivenTypes.getChunkMetadataBufferSize();
        const metadata_result = try gpu.createBufferRaw(
            metadata_size,
            vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            device_local,
        );
        self.chunk_metadata_buffer = ManagedBuffer.fromRaw(metadata_result.handle, metadata_result.memory);

        // Zero the metadata buffer so uninitialized slots have indexCount=0
        // This is critical - compute shader reads ALL slots up to high water mark
        try self.zeroBuffer(self.chunk_metadata_buffer.handle, metadata_size);

        // Visibility buffer: u32 per chunk for occlusion culling (Phase 6)
        const visibility_size = GPUDrivenTypes.getVisibilityBufferSize();
        const visibility_result = try gpu.createBufferRaw(
            visibility_size,
            vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            device_local,
        );
        self.visibility_buffer = ManagedBuffer.fromRaw(visibility_result.handle, visibility_result.memory);

        // Draw count buffer: atomic counters for dispatch and draw counts
        // Needs INDIRECT_BUFFER for vkCmdDispatchIndirect
        const count_size = GPUDrivenTypes.getDrawCountBufferSize();
        const count_result = try gpu.createBufferRaw(
            count_size,
            vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | vk.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT | vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            device_local,
        );
        self.draw_count_buffer = ManagedBuffer.fromRaw(count_result.handle, count_result.memory);

        // GPU draw buffer: generated draw commands
        // Needs INDIRECT_BUFFER for vkCmdDrawIndexedIndirectCount
        const draw_size = GPUDrivenTypes.getGPUDrawBufferSize();
        const draw_result = try gpu.createBufferRaw(
            draw_size,
            vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | vk.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT,
            device_local,
        );
        self.gpu_draw_buffer = ManagedBuffer.fromRaw(draw_result.handle, draw_result.memory);

        // Slot allocator for chunk GPU indices
        self.chunk_slot_allocator = GPUDrivenTypes.SlotAllocator.init(self.allocator, GPUDrivenTypes.MAX_CHUNKS);

        // Metadata staging buffer: host-visible for CPU writes, persists across frames
        // Size for up to 16K metadata uploads per frame (handles large view distances)
        const staging_size: u64 = 16384 * @sizeOf(GPUDrivenTypes.ChunkGPUData);
        const host_visible = vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        const staging_result = try gpu.createBufferRaw(
            staging_size,
            vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            host_visible,
        );

        // Map the staging buffer persistently
        const vkMapMemory = vk.vkMapMemory orelse return error.VulkanFunctionNotLoaded;
        var mapped: ?*anyopaque = null;
        if (vkMapMemory(self.device, staging_result.memory, 0, staging_size, 0, &mapped) != vk.VK_SUCCESS) {
            return error.MemoryMapFailed;
        }
        self.metadata_staging_buffer = ManagedBuffer.fromMapped(staging_result.handle, staging_result.memory, mapped.?);
        self.metadata_staging_offset = 0;

        logger.info("GPU-driven buffers created: metadata={d:.2}MB, visibility={d:.2}MB, draw_count={d}B, draw_cmds={d:.2}MB, staging={d:.2}KB", .{
            @as(f64, @floatFromInt(metadata_size)) / (1024.0 * 1024.0),
            @as(f64, @floatFromInt(visibility_size)) / (1024.0 * 1024.0),
            count_size,
            @as(f64, @floatFromInt(draw_size)) / (1024.0 * 1024.0),
            @as(f64, @floatFromInt(staging_size)) / 1024.0,
        });
    }

    /// Destroy GPU-driven rendering buffers
    fn destroyGPUDrivenBuffers(self: *Self) void {
        if (self.chunk_slot_allocator) |*allocator| {
            allocator.deinit();
            self.chunk_slot_allocator = null;
        }
        self.metadata_staging_buffer.destroy(self.device);
        self.gpu_draw_buffer.destroy(self.device);
        self.draw_count_buffer.destroy(self.device);
        self.visibility_buffer.destroy(self.device);
        self.chunk_metadata_buffer.destroy(self.device);
    }

    /// Create compute pipelines for GPU-driven rendering (Phase 2)
    fn createComputePipelines(self: *Self) !void {
        const vkCreateDescriptorPool = vk.vkCreateDescriptorPool orelse return error.VulkanFunctionNotLoaded;
        const vkAllocateDescriptorSets = vk.vkAllocateDescriptorSets orelse return error.VulkanFunctionNotLoaded;

        // Create descriptor set layout for compute shaders
        // Bindings: 0=chunks, 1=counts, 2=solid_cmds, 3=cutout_cmds, 4=translucent_cmds
        const bindings = [_]vk.VkDescriptorSetLayoutBinding{
            ComputePipeline.storageBufferBinding(0, vk.VK_SHADER_STAGE_COMPUTE_BIT), // ChunkMetadata
            ComputePipeline.storageBufferBinding(1, vk.VK_SHADER_STAGE_COMPUTE_BIT), // DrawCounts
            ComputePipeline.storageBufferBinding(2, vk.VK_SHADER_STAGE_COMPUTE_BIT), // SolidCommands
            ComputePipeline.storageBufferBinding(3, vk.VK_SHADER_STAGE_COMPUTE_BIT), // CutoutCommands
            ComputePipeline.storageBufferBinding(4, vk.VK_SHADER_STAGE_COMPUTE_BIT), // TranslucentCommands
        };
        self.compute_descriptor_set_layout = try ComputePipeline.createDescriptorSetLayout(self.device, &bindings);

        // Push constant range for prep.comp (just chunkCount)
        // and cmdgen.comp (viewProj matrix + chunkCount + vertexStride)
        const push_constant_ranges = [_]vk.VkPushConstantRange{
            .{
                .stageFlags = vk.VK_SHADER_STAGE_COMPUTE_BIT,
                .offset = 0,
                .size = 64 + 4 + 4, // mat4 (64) + chunkCount (4) + vertexStride (4)
            },
        };
        const layouts = [_]vk.VkDescriptorSetLayout{self.compute_descriptor_set_layout};
        self.compute_pipeline_layout = try ComputePipeline.createPipelineLayout(self.device, &layouts, &push_constant_ranges);

        // Create descriptor pool
        const pool_sizes = [_]vk.VkDescriptorPoolSize{
            .{ .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 5 },
        };
        const pool_info = vk.VkDescriptorPoolCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .maxSets = 1,
            .poolSizeCount = pool_sizes.len,
            .pPoolSizes = &pool_sizes,
        };
        if (vkCreateDescriptorPool(self.device, &pool_info, null, &self.compute_descriptor_pool) != vk.VK_SUCCESS) {
            return error.DescriptorPoolCreationFailed;
        }

        // Allocate descriptor set
        const alloc_info = vk.VkDescriptorSetAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = self.compute_descriptor_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &layouts,
        };
        if (vkAllocateDescriptorSets(self.device, &alloc_info, @ptrCast(&self.compute_descriptor_set)) != vk.VK_SUCCESS) {
            return error.DescriptorSetAllocationFailed;
        }

        // Update descriptor set with buffer bindings
        try self.updateComputeDescriptorSet();

        // Compile and create compute pipelines
        var sm = self.shader_manager orelse return error.ShaderManagerNotInitialized;
        const vkCreateShaderModule = vk.vkCreateShaderModule orelse return error.VulkanFunctionNotLoaded;

        const prep_spirv = try sm.compileShaderFile("assets/farhorizons/shaders/prep.comp");
        defer self.allocator.free(prep_spirv);
        const prep_module = try self.createShaderModule(vkCreateShaderModule, prep_spirv);
        defer if (vk.vkDestroyShaderModule) |destroy| destroy(self.device, prep_module, null);

        self.prep_pipeline = try ComputePipeline.create(self.device, .{
            .shader_module = prep_module,
            .pipeline_layout = self.compute_pipeline_layout,
        });

        const cmdgen_spirv = try sm.compileShaderFile("assets/farhorizons/shaders/cmdgen.comp");
        defer self.allocator.free(cmdgen_spirv);
        const cmdgen_module = try self.createShaderModule(vkCreateShaderModule, cmdgen_spirv);
        defer if (vk.vkDestroyShaderModule) |destroy| destroy(self.device, cmdgen_module, null);

        self.cmdgen_pipeline = try ComputePipeline.create(self.device, .{
            .shader_module = cmdgen_module,
            .pipeline_layout = self.compute_pipeline_layout,
        });

        logger.info("GPU-driven compute pipelines created", .{});
    }

    /// Update compute descriptor set with current buffer bindings
    fn updateComputeDescriptorSet(self: *Self) !void {
        const vkUpdateDescriptorSets = vk.vkUpdateDescriptorSets orelse return error.VulkanFunctionNotLoaded;

        const buffer_infos = [_]vk.VkDescriptorBufferInfo{
            .{ .buffer = self.chunk_metadata_buffer.handle, .offset = 0, .range = vk.VK_WHOLE_SIZE },
            .{ .buffer = self.draw_count_buffer.handle, .offset = 0, .range = vk.VK_WHOLE_SIZE },
            .{ .buffer = self.gpu_draw_buffer.handle, .offset = 0, .range = vk.VK_WHOLE_SIZE },
            .{ .buffer = self.gpu_draw_buffer.handle, .offset = GPUDrivenTypes.MAX_DRAWS_PER_LAYER * @sizeOf(GPUDrivenTypes.IndirectDrawCommand), .range = vk.VK_WHOLE_SIZE },
            .{ .buffer = self.gpu_draw_buffer.handle, .offset = 2 * GPUDrivenTypes.MAX_DRAWS_PER_LAYER * @sizeOf(GPUDrivenTypes.IndirectDrawCommand), .range = vk.VK_WHOLE_SIZE },
        };

        var writes: [5]vk.VkWriteDescriptorSet = undefined;
        for (0..5) |i| {
            writes[i] = .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = self.compute_descriptor_set,
                .dstBinding = @intCast(i),
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .pImageInfo = null,
                .pBufferInfo = &buffer_infos[i],
                .pTexelBufferView = null,
            };
        }

        vkUpdateDescriptorSets(self.device, 5, &writes, 0, null);
    }

    /// Destroy compute pipelines
    fn destroyComputePipelines(self: *Self) void {
        const vkDestroyPipeline = vk.vkDestroyPipeline orelse return;
        const vkDestroyPipelineLayout = vk.vkDestroyPipelineLayout orelse return;
        const vkDestroyDescriptorSetLayout = vk.vkDestroyDescriptorSetLayout orelse return;
        const vkDestroyDescriptorPool = vk.vkDestroyDescriptorPool orelse return;

        if (self.cmdgen_pipeline) |p| vkDestroyPipeline(self.device, p, null);
        if (self.prep_pipeline) |p| vkDestroyPipeline(self.device, p, null);
        if (self.compute_descriptor_pool) |p| vkDestroyDescriptorPool(self.device, p, null);
        if (self.compute_pipeline_layout) |l| vkDestroyPipelineLayout(self.device, l, null);
        if (self.compute_descriptor_set_layout) |l| vkDestroyDescriptorSetLayout(self.device, l, null);

        self.cmdgen_pipeline = null;
        self.prep_pipeline = null;
        self.compute_descriptor_set = null;
        self.compute_descriptor_pool = null;
        self.compute_pipeline_layout = null;
        self.compute_descriptor_set_layout = null;
    }

    // ============================================================================
    // GPU-Driven Rendering: Public Chunk Management API
    // ============================================================================

    /// Allocate a GPU slot for a chunk's metadata
    /// Returns INVALID_SLOT if no slots available
    pub fn allocateChunkSlot(self: *Self) u32 {
        if (self.chunk_slot_allocator) |*allocator| {
            return allocator.alloc();
        }
        return GPUDrivenTypes.SlotAllocator.INVALID_SLOT;
    }

    /// Free a chunk's GPU slot for reuse
    pub fn freeChunkSlot(self: *Self, slot: u32) void {
        if (self.chunk_slot_allocator) |*allocator| {
            allocator.free(slot);
        }
    }

    /// Advance the slot allocator's frame counter and process deferred frees
    /// Call this at the start of each frame, synchronized with ChunkBufferManager.beginFrame
    pub fn advanceSlotAllocatorFrame(self: *Self) void {
        if (self.chunk_slot_allocator) |*allocator| {
            allocator.beginFrame();
        }
    }

    /// Upload chunk metadata to the GPU buffer at the given slot
    /// Note: This stages the upload; actual transfer happens during frame commit
    /// Upload chunk metadata to the GPU buffer at the given slot
    /// Uses persistent staging buffer - data is written and copy command recorded
    pub fn uploadChunkMetadata(
        self: *Self,
        slot: u32,
        data: GPUDrivenTypes.ChunkGPUData,
        cmd_buffer: vk.VkCommandBuffer,
    ) !void {
        if (slot == GPUDrivenTypes.SlotAllocator.INVALID_SLOT) return;
        if (slot >= GPUDrivenTypes.MAX_CHUNKS) return;
        if (!self.metadata_staging_buffer.isValid()) return error.StagingBufferNotInitialized;

        const data_size = @sizeOf(GPUDrivenTypes.ChunkGPUData);
        const max_staging_size: u64 = 16384 * data_size;

        // Check if we have room in staging buffer (wraps around each frame)
        if (self.metadata_staging_offset + data_size > max_staging_size) {
            // Reset to beginning - previous frame's data is no longer needed
            self.metadata_staging_offset = 0;
        }

        // Write data to staging buffer
        const staging_ptr: [*]u8 = @ptrCast(self.metadata_staging_buffer.mapped.?);
        const dest: *GPUDrivenTypes.ChunkGPUData = @ptrCast(@alignCast(staging_ptr + self.metadata_staging_offset));
        dest.* = data;

        // Record copy command from staging to device-local buffer
        const dst_offset = @as(u64, slot) * data_size;
        const copy_region = vk.VkBufferCopy{
            .srcOffset = self.metadata_staging_offset,
            .dstOffset = dst_offset,
            .size = data_size,
        };

        const vkCmdCopyBuffer = vk.vkCmdCopyBuffer orelse return error.VulkanFunctionNotLoaded;
        vkCmdCopyBuffer(cmd_buffer, self.metadata_staging_buffer.handle, self.chunk_metadata_buffer.handle, 1, &copy_region);

        // Advance staging offset for next upload
        self.metadata_staging_offset += data_size;
    }

    /// Reset metadata staging buffer offset (call at start of frame)
    pub fn resetMetadataStagingOffset(self: *Self) void {
        self.metadata_staging_offset = 0;
    }

    /// Get the number of allocated chunk slots (for dispatch sizing)
    pub fn getActiveChunkSlotCount(self: *const Self) u32 {
        if (self.chunk_slot_allocator) |allocator| {
            return allocator.getAllocatedCount();
        }
        return 0;
    }

    /// Get the high-water mark of chunk slots (maximum ever allocated)
    pub fn getChunkSlotHighWaterMark(self: *const Self) u32 {
        if (self.chunk_slot_allocator) |allocator| {
            return allocator.getHighWaterMark();
        }
        return 0;
    }

    /// Record GPU-driven rendering commands (compute cull + indirect draws)
    /// This replaces the CPU-driven draw loop when GPU-driven rendering is enabled
    pub fn recordGPUDrivenCommands(
        self: *Self,
        cmd_buffer: vk.VkCommandBuffer,
        chunk_count: u32,
        view_proj: [16]f32,
    ) void {
        if (self.prep_pipeline == null or self.cmdgen_pipeline == null) return;
        if (chunk_count == 0) return;

        const vkCmdBindPipeline = vk.vkCmdBindPipeline orelse return;
        const vkCmdBindDescriptorSets = vk.vkCmdBindDescriptorSets orelse return;
        const vkCmdPushConstants = vk.vkCmdPushConstants orelse return;
        const vkCmdDispatch = vk.vkCmdDispatch orelse return;
        const vkCmdDispatchIndirect = vk.vkCmdDispatchIndirect orelse return;

        // Bind compute descriptor set
        const descriptor_sets = [_]vk.VkDescriptorSet{self.compute_descriptor_set};
        vkCmdBindDescriptorSets(
            cmd_buffer,
            vk.VK_PIPELINE_BIND_POINT_COMPUTE,
            self.compute_pipeline_layout,
            0,
            1,
            &descriptor_sets,
            0,
            null,
        );

        // === PREP PASS: Zero counters and set dispatch size ===
        vkCmdBindPipeline(cmd_buffer, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.prep_pipeline.?);

        // Push constant for prep shader (just chunk count)
        const prep_push = extern struct { chunk_count: u32 }{ .chunk_count = chunk_count };
        vkCmdPushConstants(
            cmd_buffer,
            self.compute_pipeline_layout,
            vk.VK_SHADER_STAGE_COMPUTE_BIT,
            0,
            @sizeOf(@TypeOf(prep_push)),
            &prep_push,
        );

        vkCmdDispatch(cmd_buffer, 1, 1, 1);

        // Memory barrier: prep writes -> cmdgen reads
        ComputePipeline.insertComputeBarrier(cmd_buffer);

        // === COMMAND GENERATION PASS: Frustum cull and generate draw commands ===
        vkCmdBindPipeline(cmd_buffer, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.cmdgen_pipeline.?);

        // Push constants for cmdgen shader (viewProj + chunkCount + vertexStride)
        const CmdgenPush = extern struct {
            view_proj: [16]f32,
            chunk_count: u32,
            vertex_stride: u32,
        };
        const cmdgen_push = CmdgenPush{
            .view_proj = view_proj,
            .chunk_count = chunk_count,
            .vertex_stride = @sizeOf(CompactVertex),
        };
        vkCmdPushConstants(
            cmd_buffer,
            self.compute_pipeline_layout,
            vk.VK_SHADER_STAGE_COMPUTE_BIT,
            0,
            @sizeOf(CmdgenPush),
            &cmdgen_push,
        );

        // Indirect dispatch - size determined by prep.comp
        vkCmdDispatchIndirect(cmd_buffer, self.draw_count_buffer.handle, 0);

        // Memory barrier: cmdgen writes -> draw reads
        ComputePipeline.insertComputeToDrawBarrier(cmd_buffer);
    }

    /// Issue GPU-driven draw calls using vkCmdDrawIndexedIndirectCount
    /// Call after recordGPUDrivenCommands and after binding vertex/index buffers
    pub fn issueGPUDrivenDrawsForLayer(
        self: *Self,
        cmd_buffer: vk.VkCommandBuffer,
        layer: u32,
    ) void {
        const vkCmdDrawIndexedIndirectCount = vk.vkCmdDrawIndexedIndirectCount orelse return;

        const max_draws = GPUDrivenTypes.MAX_DRAWS_PER_LAYER;
        const cmd_stride = @sizeOf(GPUDrivenTypes.IndirectDrawCommand);

        const count_offsets = [3]usize{
            @offsetOf(GPUDrivenTypes.DrawCountData, "solid_count"),
            @offsetOf(GPUDrivenTypes.DrawCountData, "cutout_count"),
            @offsetOf(GPUDrivenTypes.DrawCountData, "translucent_count"),
        };

        const cmd_offset = layer * max_draws * cmd_stride;

        vkCmdDrawIndexedIndirectCount(
            cmd_buffer,
            self.gpu_draw_buffer.handle,
            cmd_offset,
            self.draw_count_buffer.handle,
            count_offsets[layer],
            max_draws,
            cmd_stride,
        );
    }

    // Note: Texture creation/destruction is now handled by TextureManager

    fn createDescriptorPool(self: *Self) !void {
        self.descriptor_pool = try DescriptorPoolBuilder.init()
            .withUniformBuffers(MAX_FRAMES_IN_FLIGHT)
            .withSamplers(MAX_FRAMES_IN_FLIGHT)
            .withStorageBuffers(MAX_FRAMES_IN_FLIGHT)
            .withMaxSets(MAX_FRAMES_IN_FLIGHT)
            .build(self.device);

        logger.info("Descriptor pool created", .{});
    }

    fn createDescriptorSets(self: *Self) !void {
        try DescriptorSetManager.allocateSets(
            self.device,
            self.descriptor_pool,
            self.descriptor_set_layout,
            MAX_FRAMES_IN_FLIGHT,
            &self.descriptor_sets,
        );

        // Configure each descriptor set to point to its uniform buffer, texture, and chunk metadata
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            DescriptorSetManager.updateUniformBufferAndSampler(
                self.device,
                self.descriptor_sets[i],
                0, // buffer binding
                self.uniform_buffers[i],
                @sizeOf(UniformBufferObject),
                1, // sampler binding
                self.texture_image_view,
                self.texture_sampler,
            );

            // Binding 2: chunk metadata SSBO for vertex shader position decode
            DescriptorSetManager.updateStorageBuffer(
                self.device,
                self.descriptor_sets[i],
                2,
                self.chunk_metadata_buffer.handle,
                vk.VK_WHOLE_SIZE,
            );
        }

        logger.info("Descriptor sets created", .{});
    }

    fn createEntityDescriptorPool(self: *Self) !void {
        // Allocate enough for both adult and baby entity descriptor sets
        self.entity_descriptor_pool = try DescriptorPoolBuilder.init()
            .withUniformBuffers(MAX_FRAMES_IN_FLIGHT * 2) // Adult + Baby
            .withSamplers(MAX_FRAMES_IN_FLIGHT * 2) // Adult + Baby
            .withMaxSets(MAX_FRAMES_IN_FLIGHT * 2) // Adult + Baby
            .build(self.device);

        logger.info("Entity descriptor pool created", .{});
    }

    fn createEntityDescriptorSets(self: *Self, texture_view: vk.VkImageView, texture_sampler: vk.VkSampler) !void {
        try DescriptorSetManager.allocateSets(
            self.device,
            self.entity_descriptor_pool,
            self.descriptor_set_layout,
            MAX_FRAMES_IN_FLIGHT,
            &self.entity_descriptor_sets,
        );

        // Configure each descriptor set to point to its uniform buffer and entity texture
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            DescriptorSetManager.updateUniformBufferAndSampler(
                self.device,
                self.entity_descriptor_sets[i],
                0, // buffer binding
                self.uniform_buffers[i],
                @sizeOf(UniformBufferObject),
                1, // sampler binding
                texture_view,
                texture_sampler,
            );
        }

        logger.info("Entity descriptor sets created", .{});
    }

    fn createBabyEntityDescriptorSets(self: *Self, texture_view: vk.VkImageView, texture_sampler: vk.VkSampler) !void {
        try DescriptorSetManager.allocateSets(
            self.device,
            self.entity_descriptor_pool,
            self.descriptor_set_layout,
            MAX_FRAMES_IN_FLIGHT,
            &self.baby_entity_descriptor_sets,
        );

        // Configure each descriptor set to point to its uniform buffer and baby entity texture
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            DescriptorSetManager.updateUniformBufferAndSampler(
                self.device,
                self.baby_entity_descriptor_sets[i],
                0, // buffer binding
                self.uniform_buffers[i],
                @sizeOf(UniformBufferObject),
                1, // sampler binding
                texture_view,
                texture_sampler,
            );
        }

        logger.info("Baby entity descriptor sets created", .{});
    }

    fn findMemoryType(self: *Self, type_filter: u32, properties: vk.VkMemoryPropertyFlags) !u32 {
        const vkGetPhysicalDeviceMemoryProperties = vk.vkGetPhysicalDeviceMemoryProperties orelse return error.VulkanFunctionNotLoaded;

        var mem_properties: vk.VkPhysicalDeviceMemoryProperties = undefined;
        vkGetPhysicalDeviceMemoryProperties(self.physical_device, &mem_properties);

        for (0..mem_properties.memoryTypeCount) |i| {
            const idx: u5 = @intCast(i);
            if ((type_filter & (@as(u32, 1) << idx)) != 0 and
                (mem_properties.memoryTypes[i].propertyFlags & properties) == properties)
            {
                return @intCast(i);
            }
        }

        return error.NoSuitableMemoryType;
    }

    /// Zero a GPU buffer using vkCmdFillBuffer (one-time command with fence sync)
    fn zeroBuffer(self: *Self, buffer: vk.VkBuffer, size: u64) !void {
        const vkAllocateCommandBuffers = vk.vkAllocateCommandBuffers orelse return error.VulkanFunctionNotLoaded;
        const vkBeginCommandBuffer = vk.vkBeginCommandBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkCmdFillBuffer = vk.vkCmdFillBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkEndCommandBuffer = vk.vkEndCommandBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkQueueSubmit = vk.vkQueueSubmit orelse return error.VulkanFunctionNotLoaded;
        const vkCreateFence = vk.vkCreateFence orelse return error.VulkanFunctionNotLoaded;
        const vkWaitForFences = vk.vkWaitForFences orelse return error.VulkanFunctionNotLoaded;
        const vkDestroyFence = vk.vkDestroyFence orelse return error.VulkanFunctionNotLoaded;
        const vkFreeCommandBuffers = vk.vkFreeCommandBuffers orelse return error.VulkanFunctionNotLoaded;

        // Allocate one-time command buffer
        var cmd_buffer: vk.VkCommandBuffer = null;
        const alloc_info = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        if (vkAllocateCommandBuffers(self.device, &alloc_info, &cmd_buffer) != vk.VK_SUCCESS) {
            return error.CommandBufferAllocationFailed;
        }
        defer vkFreeCommandBuffers(self.device, self.command_pool, 1, &cmd_buffer);

        // Begin recording
        const begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };
        if (vkBeginCommandBuffer(cmd_buffer, &begin_info) != vk.VK_SUCCESS) {
            return error.CommandBufferBeginFailed;
        }

        // Fill buffer with zeros
        vkCmdFillBuffer(cmd_buffer, buffer, 0, size, 0);

        // End recording
        if (vkEndCommandBuffer(cmd_buffer) != vk.VK_SUCCESS) {
            return error.CommandBufferEndFailed;
        }

        // Submit with fence (no queue stall)
        var fence: vk.VkFence = null;
        const fence_info = vk.VkFenceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
        };
        if (vkCreateFence(self.device, &fence_info, null, &fence) != vk.VK_SUCCESS) {
            return error.FenceCreationFailed;
        }
        defer vkDestroyFence(self.device, fence, null);

        const submit_info = vk.VkSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = null,
            .pWaitDstStageMask = null,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd_buffer,
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = null,
        };
        if (vkQueueSubmit(self.graphics_queue, 1, &submit_info, fence) != vk.VK_SUCCESS) {
            return error.QueueSubmitFailed;
        }
        _ = vkWaitForFences(self.device, 1, &fence, vk.VK_TRUE, std.math.maxInt(u64));
    }

    fn createCommandBuffers(self: *Self) !void {
        const vkAllocateCommandBuffers = vk.vkAllocateCommandBuffers orelse return error.VulkanFunctionNotLoaded;

        self.command_buffers = try self.allocator.alloc(vk.VkCommandBuffer, MAX_FRAMES_IN_FLIGHT);

        const alloc_info = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = MAX_FRAMES_IN_FLIGHT,
        };

        if (vkAllocateCommandBuffers(self.device, &alloc_info, self.command_buffers.ptr) != vk.VK_SUCCESS) {
            return error.CommandBufferAllocationFailed;
        }

        logger.info("Command buffers allocated", .{});
    }

    fn createSyncObjects(self: *Self) !void {
        const vkCreateSemaphore = vk.vkCreateSemaphore orelse return error.VulkanFunctionNotLoaded;
        const vkCreateFence = vk.vkCreateFence orelse return error.VulkanFunctionNotLoaded;

        const semaphore_info = vk.VkSemaphoreCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
        };

        const fence_info = vk.VkFenceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .pNext = null,
            .flags = vk.VK_FENCE_CREATE_SIGNALED_BIT,
        };

        // Per-frame-in-flight: image available semaphores and fences
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            if (vkCreateSemaphore(self.device, &semaphore_info, null, &self.image_available_semaphores[i]) != vk.VK_SUCCESS or
                vkCreateFence(self.device, &fence_info, null, &self.in_flight_fences[i]) != vk.VK_SUCCESS)
            {
                return error.SyncObjectCreationFailed;
            }
        }

        // Per-swapchain-image: render finished semaphores (indexed by image_index)
        // Prevents reuse while the presentation engine still holds the semaphore
        self.render_finished_semaphores = try self.allocator.alloc(vk.VkSemaphore, self.swapchain_images.len);
        @memset(self.render_finished_semaphores, null);
        for (0..self.swapchain_images.len) |i| {
            if (vkCreateSemaphore(self.device, &semaphore_info, null, &self.render_finished_semaphores[i]) != vk.VK_SUCCESS) {
                return error.SyncObjectCreationFailed;
            }
        }

        // Timeline semaphore for GC tracking
        var timeline_type_info = vk.VkSemaphoreTypeCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO,
            .pNext = null,
            .semaphoreType = vk.VK_SEMAPHORE_TYPE_TIMELINE,
            .initialValue = 0,
        };
        const timeline_sem_info = vk.VkSemaphoreCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = &timeline_type_info,
            .flags = 0,
        };
        if (vkCreateSemaphore(self.device, &timeline_sem_info, null, &self.gpu_timeline) != vk.VK_SUCCESS) {
            return error.SyncObjectCreationFailed;
        }
        self.timeline_value = 0;
        self.last_submitted_value = 0;

        logger.info("Sync objects created", .{});
    }

    fn destroySyncObjects(self: *Self) void {
        const vkDestroySemaphore = vk.vkDestroySemaphore orelse return;
        const vkDestroyFence = vk.vkDestroyFence orelse return;

        if (self.gpu_timeline) |t| vkDestroySemaphore(self.device, t, null);
        self.gpu_timeline = null;

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            if (self.image_available_semaphores[i]) |s| vkDestroySemaphore(self.device, s, null);
            if (self.in_flight_fences[i]) |f| vkDestroyFence(self.device, f, null);
        }
        for (self.render_finished_semaphores) |s| {
            if (s) |sem| vkDestroySemaphore(self.device, sem, null);
        }
        if (self.render_finished_semaphores.len > 0) {
            self.allocator.free(self.render_finished_semaphores);
            self.render_finished_semaphores = &.{};
        }
    }

    fn recreateRenderFinishedSemaphores(self: *Self) !void {
        const vkCreateSemaphore = vk.vkCreateSemaphore orelse return error.VulkanFunctionNotLoaded;
        const vkDestroySemaphore = vk.vkDestroySemaphore orelse return error.VulkanFunctionNotLoaded;

        // Destroy old semaphores
        for (self.render_finished_semaphores) |s| {
            if (s) |sem| vkDestroySemaphore(self.device, sem, null);
        }
        if (self.render_finished_semaphores.len != self.swapchain_images.len) {
            if (self.render_finished_semaphores.len > 0) {
                self.allocator.free(self.render_finished_semaphores);
            }
            self.render_finished_semaphores = try self.allocator.alloc(vk.VkSemaphore, self.swapchain_images.len);
        }
        @memset(self.render_finished_semaphores, null);

        const semaphore_info = vk.VkSemaphoreCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
        };
        for (0..self.swapchain_images.len) |i| {
            if (vkCreateSemaphore(self.device, &semaphore_info, null, &self.render_finished_semaphores[i]) != vk.VK_SUCCESS) {
                return error.SyncObjectCreationFailed;
            }
        }
    }

    fn destroyCommandPool(self: *Self) void {
        if (self.command_buffers.len > 0) {
            self.allocator.free(self.command_buffers);
            self.command_buffers = &.{};
        }
        if (self.command_pool) |pool| {
            if (vk.vkDestroyCommandPool) |destroy| destroy(self.device, pool, null);
            self.command_pool = null;
        }
    }

    fn destroyDescriptorPool(self: *Self) void {
        if (self.descriptor_pool) |pool| {
            if (vk.vkDestroyDescriptorPool) |destroy| destroy(self.device, pool, null);
            self.descriptor_pool = null;
        }
    }

    fn destroyUniformBuffers(self: *Self) void {
        const vkDestroyBuffer = vk.vkDestroyBuffer orelse return;
        const vkFreeMemory = vk.vkFreeMemory orelse return;

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            if (self.uniform_buffers[i]) |buf| {
                vkDestroyBuffer(self.device, buf, null);
                self.uniform_buffers[i] = null;
            }
            if (self.uniform_buffers_memory[i]) |mem| {
                vkFreeMemory(self.device, mem, null);
                self.uniform_buffers_memory[i] = null;
            }
            self.uniform_buffers_mapped[i] = null;
        }
    }

    fn destroyBuffers(self: *Self) void {
        const vkDestroyBuffer = vk.vkDestroyBuffer orelse return;
        const vkFreeMemory = vk.vkFreeMemory orelse return;

        if (self.index_buffer) |buf| {
            vkDestroyBuffer(self.device, buf, null);
            self.index_buffer = null;
        }
        if (self.index_buffer_memory) |mem| {
            vkFreeMemory(self.device, mem, null);
            self.index_buffer_memory = null;
        }
        if (self.vertex_buffer) |buf| {
            vkDestroyBuffer(self.device, buf, null);
            self.vertex_buffer = null;
        }
        if (self.vertex_buffer_memory) |mem| {
            vkFreeMemory(self.device, mem, null);
            self.vertex_buffer_memory = null;
        }
    }

    fn destroyFramebuffers(self: *Self) void {
        const vkDestroyFramebuffer = vk.vkDestroyFramebuffer orelse return;
        for (self.framebuffers) |fb| {
            if (fb) |f| vkDestroyFramebuffer(self.device, f, null);
        }
        if (self.framebuffers.len > 0) {
            self.allocator.free(self.framebuffers);
            self.framebuffers = &.{};
        }
    }

    fn destroyPipeline(self: *Self) void {
        if (self.graphics_pipeline) |p| {
            if (vk.vkDestroyPipeline) |destroy| destroy(self.device, p, null);
            self.graphics_pipeline = null;
        }
        // Destroy layer-specific pipelines
        for (&self.layer_pipelines) |*pipeline| {
            if (pipeline.*) |p| {
                if (vk.vkDestroyPipeline) |destroy| destroy(self.device, p, null);
                pipeline.* = null;
            }
        }
        if (self.pipeline_layout) |l| {
            if (vk.vkDestroyPipelineLayout) |destroy| destroy(self.device, l, null);
            self.pipeline_layout = null;
        }
        // Destroy UI pipeline
        if (self.ui_pipeline) |p| {
            if (vk.vkDestroyPipeline) |destroy| destroy(self.device, p, null);
            self.ui_pipeline = null;
        }
        // Destroy hotbar pipeline
        if (self.hotbar_pipeline) |p| {
            if (vk.vkDestroyPipeline) |destroy| destroy(self.device, p, null);
            self.hotbar_pipeline = null;
        }
        // Destroy hotbar icon pipeline and buffer
        if (self.hotbar_icon_pipeline) |p| {
            if (vk.vkDestroyPipeline) |destroy| destroy(self.device, p, null);
            self.hotbar_icon_pipeline = null;
        }
        if (self.hotbar_icon_pipeline_layout) |l| {
            if (vk.vkDestroyPipelineLayout) |destroy| destroy(self.device, l, null);
            self.hotbar_icon_pipeline_layout = null;
        }
        self.hotbar_icon_buffer.destroy(self.device);
        if (self.ui_pipeline_layout) |l| {
            if (vk.vkDestroyPipelineLayout) |destroy| destroy(self.device, l, null);
            self.ui_pipeline_layout = null;
        }
        // Destroy crosshair buffer
        self.crosshair_buffer.destroy(self.device);
        // Destroy crosshair texture resources
        if (self.crosshair_sampler) |s| {
            if (vk.vkDestroySampler) |destroy| destroy(self.device, s, null);
            self.crosshair_sampler = null;
        }
        if (self.crosshair_texture_view) |v| {
            if (vk.vkDestroyImageView) |destroy| destroy(self.device, v, null);
            self.crosshair_texture_view = null;
        }
        if (self.crosshair_texture) |img| {
            if (vk.vkDestroyImage) |destroy| destroy(self.device, img, null);
            self.crosshair_texture = null;
        }
        if (self.crosshair_texture_memory) |m| {
            if (vk.vkFreeMemory) |free| free(self.device, m, null);
            self.crosshair_texture_memory = null;
        }
        // Destroy hotbar buffers
        self.hotbar_buffer.destroy(self.device);
        self.hotbar_selection_buffer.destroy(self.device);
        // Destroy hotbar texture resources
        if (self.hotbar_sampler) |s| {
            if (vk.vkDestroySampler) |destroy| destroy(self.device, s, null);
            self.hotbar_sampler = null;
        }
        if (self.hotbar_texture_view) |v| {
            if (vk.vkDestroyImageView) |destroy| destroy(self.device, v, null);
            self.hotbar_texture_view = null;
        }
        if (self.hotbar_texture) |img| {
            if (vk.vkDestroyImage) |destroy| destroy(self.device, img, null);
            self.hotbar_texture = null;
        }
        if (self.hotbar_texture_memory) |m| {
            if (vk.vkFreeMemory) |free| free(self.device, m, null);
            self.hotbar_texture_memory = null;
        }
        // Destroy hotbar selection texture resources
        if (self.hotbar_selection_sampler) |s| {
            if (vk.vkDestroySampler) |destroy| destroy(self.device, s, null);
            self.hotbar_selection_sampler = null;
        }
        if (self.hotbar_selection_texture_view) |v| {
            if (vk.vkDestroyImageView) |destroy| destroy(self.device, v, null);
            self.hotbar_selection_texture_view = null;
        }
        if (self.hotbar_selection_texture) |img| {
            if (vk.vkDestroyImage) |destroy| destroy(self.device, img, null);
            self.hotbar_selection_texture = null;
        }
        if (self.hotbar_selection_texture_memory) |m| {
            if (vk.vkFreeMemory) |free| free(self.device, m, null);
            self.hotbar_selection_texture_memory = null;
        }
        // Destroy UI descriptor pool (sets are freed automatically)
        if (self.ui_descriptor_pool) |pool| {
            if (vk.vkDestroyDescriptorPool) |destroy| destroy(self.device, pool, null);
            self.ui_descriptor_pool = null;
        }
        // Destroy UI descriptor set layout
        if (self.ui_descriptor_set_layout) |layout| {
            if (vk.vkDestroyDescriptorSetLayout) |destroy| destroy(self.device, layout, null);
            self.ui_descriptor_set_layout = null;
        }
        // Destroy line pipeline
        if (self.line_pipeline) |p| {
            if (vk.vkDestroyPipeline) |destroy| destroy(self.device, p, null);
            self.line_pipeline = null;
        }
        if (self.line_pipeline_layout) |l| {
            if (vk.vkDestroyPipelineLayout) |destroy| destroy(self.device, l, null);
            self.line_pipeline_layout = null;
        }
        // Destroy line buffer
        self.line_buffer.destroy(self.device);
        // Destroy entity pipeline and layout
        if (self.entity_pipeline) |p| {
            if (vk.vkDestroyPipeline) |destroy| destroy(self.device, p, null);
            self.entity_pipeline = null;
        }
        if (self.entity_pipeline_layout) |l| {
            if (vk.vkDestroyPipelineLayout) |destroy| destroy(self.device, l, null);
            self.entity_pipeline_layout = null;
        }
    }

    fn destroyDescriptorSetLayout(self: *Self) void {
        if (self.descriptor_set_layout) |layout| {
            if (vk.vkDestroyDescriptorSetLayout) |destroy| destroy(self.device, layout, null);
            self.descriptor_set_layout = null;
        }
    }

    fn destroyRenderPass(self: *Self) void {
        if (self.render_pass) |rp| {
            if (vk.vkDestroyRenderPass) |destroy| destroy(self.device, rp, null);
            self.render_pass = null;
        }
    }

    fn destroyDepthResources(self: *Self) void {
        const vkDestroyImageView = vk.vkDestroyImageView orelse return;
        const vkDestroyImage = vk.vkDestroyImage orelse return;
        const vkFreeMemory = vk.vkFreeMemory orelse return;

        if (self.depth_image_view) |view| {
            vkDestroyImageView(self.device, view, null);
            self.depth_image_view = null;
        }
        if (self.depth_image) |image| {
            vkDestroyImage(self.device, image, null);
            self.depth_image = null;
        }
        if (self.depth_image_memory) |mem| {
            vkFreeMemory(self.device, mem, null);
            self.depth_image_memory = null;
        }
    }

    fn destroyImageViews(self: *Self) void {
        const vkDestroyImageView = vk.vkDestroyImageView orelse return;
        for (self.swapchain_image_views) |iv| {
            if (iv) |v| vkDestroyImageView(self.device, v, null);
        }
        if (self.swapchain_image_views.len > 0) {
            self.allocator.free(self.swapchain_image_views);
            self.swapchain_image_views = &.{};
        }
    }

    fn destroySwapchain(self: *Self) void {
        if (self.swapchain_images.len > 0) {
            self.allocator.free(self.swapchain_images);
            self.swapchain_images = &.{};
        }
        if (self.swapchain) |sc| {
            if (vk.vkDestroySwapchainKHR) |destroy| destroy(self.device, sc, null);
            self.swapchain = null;
        }
    }

    fn destroyDevice(self: *Self) void {
        if (self.device) |d| {
            if (vk.vkDestroyDevice) |destroy| destroy(d, null);
            self.device = null;
        }
    }

    fn destroySurface(self: *Self) void {
        if (self.surface) |s| {
            if (vk.vkDestroySurfaceKHR) |destroy| destroy(self.instance, s, null);
            self.surface = null;
        }
    }

    fn destroyDebugMessenger(self: *Self) void {
        if (self.debug_messenger) |messenger| {
            if (vk.vkDestroyDebugUtilsMessengerEXT) |destroy| destroy(self.instance, messenger, null);
            self.debug_messenger = null;
        }
    }

    fn destroyInstance(self: *Self) void {
        if (self.instance) |i| {
            if (vk.vkDestroyInstance) |destroy| destroy(i, null);
            self.instance = null;
        }
    }

    pub fn getInstance(self: *const Self) vk.VkInstance {
        return self.instance;
    }

    pub fn getEntityPipeline(self: *const Self) vk.VkPipeline {
        return self.entity_pipeline;
    }
};
