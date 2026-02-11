const std = @import("std");
const shared = @import("Shared");
const renderer = @import("Renderer");
const volk = @import("volk");
const vk = volk.c;
const ecs = @import("ecs");

const CowModel = @import("models/CowModel.zig").CowModel;
const BabyCowModel = @import("models/BabyCowModel.zig").BabyCowModel;
const Vertex = renderer.Vertex;
const GpuDevice = renderer.GpuDevice;
const TextureLoader = renderer.TextureLoader;
const Logger = shared.Logger;
const Mat4 = shared.Mat4;
const stb_image = @import("stb_image");

pub const EntityRenderer = struct {
    const Self = @This();
    const logger = Logger.scoped(Self);

    allocator: std.mem.Allocator,
    gpu_device: *GpuDevice,
    asset_directory: []const u8,

    // Cow models (adult and baby)
    cow_model: CowModel,
    baby_cow_model: BabyCowModel,

    // GPU buffers for entity rendering
    vertex_buffer: vk.VkBuffer = null,
    vertex_buffer_memory: vk.VkDeviceMemory = null,
    index_buffer: vk.VkBuffer = null,
    index_buffer_memory: vk.VkDeviceMemory = null,

    // Adult cow texture (legacy non-bindless)
    texture_image: vk.VkImage = null,
    texture_memory: vk.VkDeviceMemory = null,
    texture_view: vk.VkImageView = null,
    texture_sampler: vk.VkSampler = null,

    // Baby cow texture (legacy non-bindless)
    baby_texture_image: vk.VkImage = null,
    baby_texture_memory: vk.VkDeviceMemory = null,
    baby_texture_view: vk.VkImageView = null,
    baby_texture_sampler: vk.VkSampler = null,

    // Bindless texture indices
    use_bindless: bool = false,
    cow_tex_index: u32 = 0,
    baby_cow_tex_index: u32 = 0,

    // Current buffer sizes - separate tracking for adults and babies
    vertex_count: u32 = 0,
    index_count: u32 = 0,
    adult_index_count: u32 = 0,
    baby_index_start: u32 = 0,
    baby_index_count: u32 = 0,

    // Cached mesh data
    cached_vertices: ?[]Vertex = null,
    cached_indices: ?[]u32 = null,

    /// Legacy init that loads textures directly (non-bindless)
    pub fn init(allocator: std.mem.Allocator, gpu_device: *GpuDevice, asset_directory: []const u8) !Self {
        var self = Self{
            .allocator = allocator,
            .gpu_device = gpu_device,
            .asset_directory = asset_directory,
            .cow_model = CowModel.init(allocator),
            .baby_cow_model = BabyCowModel.init(allocator),
            .use_bindless = false,
        };

        // Load cow textures
        try self.loadCowTexture();
        try self.loadBabyCowTexture();

        return self;
    }

    /// Bindless init that uses texture indices from EntityTextureManager
    pub fn initBindless(allocator: std.mem.Allocator, gpu_device: *GpuDevice, cow_tex_index: u32, baby_cow_tex_index: u32) !Self {
        const self = Self{
            .allocator = allocator,
            .gpu_device = gpu_device,
            .asset_directory = "",
            .cow_model = CowModel.init(allocator),
            .baby_cow_model = BabyCowModel.init(allocator),
            .use_bindless = true,
            .cow_tex_index = cow_tex_index,
            .baby_cow_tex_index = baby_cow_tex_index,
        };

        logger.info("EntityRenderer initialized in bindless mode (cow={}, baby={})", .{ cow_tex_index, baby_cow_tex_index });
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.destroyBuffers();
        // Only destroy textures in non-bindless mode (bindless textures are managed by EntityTextureManager)
        if (!self.use_bindless) {
            self.destroyTexture();
        }
        self.cow_model.deinit();
        self.baby_cow_model.deinit();

        if (self.cached_vertices) |verts| {
            self.allocator.free(verts);
        }

        if (self.cached_indices) |inds| {
            self.allocator.free(inds);
        }
    }

    fn destroyBuffers(self: *Self) void {
        if (self.vertex_buffer != null) {
            self.gpu_device.destroyBufferRaw(.{
                .handle = self.vertex_buffer,
                .memory = self.vertex_buffer_memory,
            });
            self.vertex_buffer = null;
            self.vertex_buffer_memory = null;
        }
        if (self.index_buffer != null) {
            self.gpu_device.destroyBufferRaw(.{
                .handle = self.index_buffer,
                .memory = self.index_buffer_memory,
            });
            self.index_buffer = null;
            self.index_buffer_memory = null;
        }
    }

    fn destroyTexture(self: *Self) void {
        const vkDestroySampler = vk.vkDestroySampler orelse return;
        const vkDestroyImageView = vk.vkDestroyImageView orelse return;
        const vkDestroyImage = vk.vkDestroyImage orelse return;
        const vkFreeMemory = vk.vkFreeMemory orelse return;

        // Destroy adult cow texture
        if (self.texture_sampler != null) {
            vkDestroySampler(self.gpu_device.device, self.texture_sampler, null);
            self.texture_sampler = null;
        }
        if (self.texture_view != null) {
            vkDestroyImageView(self.gpu_device.device, self.texture_view, null);
            self.texture_view = null;
        }
        if (self.texture_image != null) {
            vkDestroyImage(self.gpu_device.device, self.texture_image, null);
            self.texture_image = null;
        }
        if (self.texture_memory != null) {
            vkFreeMemory(self.gpu_device.device, self.texture_memory, null);
            self.texture_memory = null;
        }

        // Destroy baby cow texture
        if (self.baby_texture_sampler != null) {
            vkDestroySampler(self.gpu_device.device, self.baby_texture_sampler, null);
            self.baby_texture_sampler = null;
        }
        if (self.baby_texture_view != null) {
            vkDestroyImageView(self.gpu_device.device, self.baby_texture_view, null);
            self.baby_texture_view = null;
        }
        if (self.baby_texture_image != null) {
            vkDestroyImage(self.gpu_device.device, self.baby_texture_image, null);
            self.baby_texture_image = null;
        }
        if (self.baby_texture_memory != null) {
            vkFreeMemory(self.gpu_device.device, self.baby_texture_memory, null);
            self.baby_texture_memory = null;
        }
    }

    fn loadCowTexture(self: *Self) !void {
        // Build path to cow texture
        const path_z = try std.fmt.allocPrintZ(
            self.allocator,
            "{s}/farhorizons/textures/entity/cow/cow.png",
            .{self.asset_directory},
        );
        defer self.allocator.free(path_z);

        logger.info("Loading cow texture from: {s}", .{path_z});

        const texture = try TextureLoader.load(
            self.gpu_device,
            path_z,
            .{
                .filter = .nearest,
                .address_mode = .repeat,
                .format = .rgba8_srgb,
            },
        );

        self.texture_image = texture.image;
        self.texture_memory = texture.memory;
        self.texture_view = texture.view;
        self.texture_sampler = texture.sampler;

        logger.info("Cow texture loaded successfully ({}x{})", .{ texture.width, texture.height });
    }

    fn loadBabyCowTexture(self: *Self) !void {
        // Build path to baby cow texture
        const path_z = try std.fmt.allocPrintZ(
            self.allocator,
            "{s}/farhorizons/textures/entity/cow/cow_baby.png",
            .{self.asset_directory},
        );
        defer self.allocator.free(path_z);

        logger.info("Loading baby cow texture from: {s}", .{path_z});

        const texture = try TextureLoader.load(
            self.gpu_device,
            path_z,
            .{
                .filter = .nearest,
                .address_mode = .repeat,
                .format = .rgba8_srgb,
            },
        );

        self.baby_texture_image = texture.image;
        self.baby_texture_memory = texture.memory;
        self.baby_texture_view = texture.view;
        self.baby_texture_sampler = texture.sampler;

        logger.info("Baby cow texture loaded successfully ({}x{})", .{ texture.width, texture.height });
    }

    /// Update entity meshes from ECS World and upload to GPU
    /// ECS version - uses Transform, Animation, HeadRotation, RenderData, Health components
    pub fn updateFromECS(self: *Self, world: *ecs.World, partial_tick: f32) !void {
        var all_vertices: std.ArrayList(Vertex) = .empty;
        defer all_vertices.deinit(self.allocator);
        var all_indices: std.ArrayList(u32) = .empty;
        defer all_indices.deinit(self.allocator);

        // First pass: adult cows
        var entity_iter = world.entities.iterator();
        while (entity_iter.next()) |id| {
            const render_data = world.getComponent(ecs.RenderData, id) orelse continue;
            if (render_data.entity_type != .cow and render_data.entity_type != .mooshroom) continue;
            if (render_data.is_baby) continue;

            const transform = world.getComponent(ecs.Transform, id) orelse continue;

            // Get animation data
            var walk_anim: f32 = 0;
            var walk_speed: f32 = 0;
            if (world.getComponent(ecs.Animation, id)) |anim| {
                walk_anim = anim.getInterpolatedWalkAnimation(partial_tick);
                walk_speed = anim.getInterpolatedWalkSpeed(partial_tick);
            }

            // Get head rotation
            var head_pitch: f32 = 0;
            var head_yaw: f32 = 0;
            if (world.getComponent(ecs.HeadRotation, id)) |head| {
                head_pitch = head.getInterpolatedPitch(partial_tick);
                head_yaw = head.getInterpolatedYaw(partial_tick);
            }

            // Get hurt state
            var is_hurt = false;
            if (world.getComponent(ecs.Health, id)) |health| {
                is_hurt = health.isHurt();
            }

            // Build model matrix
            const pos = transform.getInterpolatedPosition(partial_tick);
            const yaw = transform.getInterpolatedYaw(partial_tick);
            const yaw_rad = yaw * std.math.pi / 180.0;
            const rotation = Mat4.rotationY(yaw_rad);
            const translation = Mat4.translation(pos);
            const m = Mat4.multiply(translation, rotation);

            const base_vertex: u32 = @intCast(all_vertices.items.len);

            const mesh = try self.cow_model.generateMesh(walk_anim, walk_speed, head_pitch, head_yaw);
            defer self.allocator.free(mesh.vertices);
            defer self.allocator.free(mesh.indices);

            for (mesh.vertices) |vert| {
                var transformed = vert;
                const x = vert.pos[0];
                const y = vert.pos[1];
                const z = vert.pos[2];
                transformed.pos = .{
                    m.data[0] * x + m.data[4] * y + m.data[8] * z + m.data[12],
                    m.data[1] * x + m.data[5] * y + m.data[9] * z + m.data[13],
                    m.data[2] * x + m.data[6] * y + m.data[10] * z + m.data[14],
                };
                if (self.use_bindless) {
                    transformed.tex_index = self.cow_tex_index;
                }
                if (is_hurt) {
                    transformed.color = .{ 1.0, 0.4, 0.4 };
                }
                try all_vertices.append(self.allocator, transformed);
            }

            for (mesh.indices) |idx| {
                try all_indices.append(self.allocator, base_vertex + idx);
            }
        }

        // Record where adult indices end
        self.adult_index_count = @intCast(all_indices.items.len);
        self.baby_index_start = self.adult_index_count;

        // Second pass: baby cows
        entity_iter = world.entities.iterator();
        while (entity_iter.next()) |id| {
            const render_data = world.getComponent(ecs.RenderData, id) orelse continue;
            if (render_data.entity_type != .cow and render_data.entity_type != .mooshroom) continue;
            if (!render_data.is_baby) continue;

            const transform = world.getComponent(ecs.Transform, id) orelse continue;

            var walk_anim: f32 = 0;
            var walk_speed: f32 = 0;
            if (world.getComponent(ecs.Animation, id)) |anim| {
                walk_anim = anim.getInterpolatedWalkAnimation(partial_tick);
                walk_speed = anim.getInterpolatedWalkSpeed(partial_tick);
            }

            var head_pitch: f32 = 0;
            var head_yaw: f32 = 0;
            if (world.getComponent(ecs.HeadRotation, id)) |head| {
                head_pitch = head.getInterpolatedPitch(partial_tick);
                head_yaw = head.getInterpolatedYaw(partial_tick);
            }

            var is_hurt = false;
            if (world.getComponent(ecs.Health, id)) |health| {
                is_hurt = health.isHurt();
            }

            const pos = transform.getInterpolatedPosition(partial_tick);
            const yaw = transform.getInterpolatedYaw(partial_tick);
            const yaw_rad = yaw * std.math.pi / 180.0;
            const rotation = Mat4.rotationY(yaw_rad);
            const translation = Mat4.translation(pos);
            const m = Mat4.multiply(translation, rotation);

            const base_vertex: u32 = @intCast(all_vertices.items.len);

            const mesh = try self.baby_cow_model.generateMesh(walk_anim, walk_speed, head_pitch, head_yaw);
            defer self.allocator.free(mesh.vertices);
            defer self.allocator.free(mesh.indices);

            for (mesh.vertices) |vert| {
                var transformed = vert;
                const x = vert.pos[0];
                const y = vert.pos[1];
                const z = vert.pos[2];
                transformed.pos = .{
                    m.data[0] * x + m.data[4] * y + m.data[8] * z + m.data[12],
                    m.data[1] * x + m.data[5] * y + m.data[9] * z + m.data[13],
                    m.data[2] * x + m.data[6] * y + m.data[10] * z + m.data[14],
                };
                if (self.use_bindless) {
                    transformed.tex_index = self.baby_cow_tex_index;
                }
                if (is_hurt) {
                    transformed.color = .{ 1.0, 0.4, 0.4 };
                }
                try all_vertices.append(self.allocator, transformed);
            }

            for (mesh.indices) |idx| {
                try all_indices.append(self.allocator, base_vertex + idx);
            }
        }

        // Calculate baby index count
        const total_indices: u32 = @intCast(all_indices.items.len);
        self.baby_index_count = total_indices - self.baby_index_start;

        if (all_vertices.items.len == 0) {
            self.vertex_count = 0;
            self.index_count = 0;
            self.adult_index_count = 0;
            self.baby_index_start = 0;
            self.baby_index_count = 0;
            return;
        }

        // Old buffers are retired by the caller (FarHorizonsClient) before calling updateFromECS

        const vertex_result = try self.gpu_device.createBufferWithDataRaw(
            Vertex,
            all_vertices.items,
            vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        );
        self.vertex_buffer = vertex_result.handle;
        self.vertex_buffer_memory = vertex_result.memory;

        const index_result = try self.gpu_device.createBufferWithDataRaw(
            u32,
            all_indices.items,
            vk.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
        );
        self.index_buffer = index_result.handle;
        self.index_buffer_memory = index_result.memory;

        self.vertex_count = @intCast(all_vertices.items.len);
        self.index_count = @intCast(all_indices.items.len);
    }

    /// Record draw commands into command buffer (draws all entities with a single texture)
    /// DEPRECATED: Use recordAdultDrawCommands/recordBabyDrawCommands for proper texture separation
    pub fn recordDrawCommands(self: *const Self, command_buffer: vk.VkCommandBuffer) void {
        if (self.index_count == 0 or self.vertex_buffer == null) return;

        const vkCmdBindVertexBuffers = vk.vkCmdBindVertexBuffers orelse return;
        const vkCmdBindIndexBuffer = vk.vkCmdBindIndexBuffer orelse return;
        const vkCmdDrawIndexed = vk.vkCmdDrawIndexed orelse return;

        const vertex_buffers = [_]vk.VkBuffer{self.vertex_buffer};
        const offsets = [_]vk.VkDeviceSize{0};
        vkCmdBindVertexBuffers(command_buffer, 0, 1, &vertex_buffers, &offsets);
        vkCmdBindIndexBuffer(command_buffer, self.index_buffer, 0, vk.VK_INDEX_TYPE_UINT32);
        vkCmdDrawIndexed(command_buffer, self.index_count, 1, 0, 0, 0);
    }

    /// Record draw commands for adult cows only (use with adult cow texture)
    pub fn recordAdultDrawCommands(self: *const Self, command_buffer: vk.VkCommandBuffer) void {
        if (self.adult_index_count == 0 or self.vertex_buffer == null) return;

        const vkCmdBindVertexBuffers = vk.vkCmdBindVertexBuffers orelse return;
        const vkCmdBindIndexBuffer = vk.vkCmdBindIndexBuffer orelse return;
        const vkCmdDrawIndexed = vk.vkCmdDrawIndexed orelse return;

        const vertex_buffers = [_]vk.VkBuffer{self.vertex_buffer};
        const offsets = [_]vk.VkDeviceSize{0};
        vkCmdBindVertexBuffers(command_buffer, 0, 1, &vertex_buffers, &offsets);
        vkCmdBindIndexBuffer(command_buffer, self.index_buffer, 0, vk.VK_INDEX_TYPE_UINT32);
        vkCmdDrawIndexed(command_buffer, self.adult_index_count, 1, 0, 0, 0);
    }

    /// Record draw commands for baby cows only (use with baby cow texture)
    pub fn recordBabyDrawCommands(self: *const Self, command_buffer: vk.VkCommandBuffer) void {
        if (self.baby_index_count == 0 or self.vertex_buffer == null) return;

        const vkCmdBindVertexBuffers = vk.vkCmdBindVertexBuffers orelse return;
        const vkCmdBindIndexBuffer = vk.vkCmdBindIndexBuffer orelse return;
        const vkCmdDrawIndexed = vk.vkCmdDrawIndexed orelse return;

        const vertex_buffers = [_]vk.VkBuffer{self.vertex_buffer};
        const offsets = [_]vk.VkDeviceSize{0};
        vkCmdBindVertexBuffers(command_buffer, 0, 1, &vertex_buffers, &offsets);
        vkCmdBindIndexBuffer(command_buffer, self.index_buffer, 0, vk.VK_INDEX_TYPE_UINT32);
        vkCmdDrawIndexed(command_buffer, self.baby_index_count, 1, self.baby_index_start, 0, 0);
    }

    pub fn hasEntities(self: *const Self) bool {
        return self.index_count > 0;
    }

    pub fn hasAdultCows(self: *const Self) bool {
        return self.adult_index_count > 0;
    }

    pub fn hasBabyCows(self: *const Self) bool {
        return self.baby_index_count > 0;
    }

    /// Get vertex buffer for external rendering
    pub fn getVertexBuffer(self: *const Self) ?vk.VkBuffer {
        return self.vertex_buffer;
    }

    /// Get index buffer for external rendering
    pub fn getIndexBuffer(self: *const Self) ?vk.VkBuffer {
        return self.index_buffer;
    }

    /// Get index count for external rendering (total)
    pub fn getIndexCount(self: *const Self) u32 {
        return self.index_count;
    }

    /// Get adult cow index count
    pub fn getAdultIndexCount(self: *const Self) u32 {
        return self.adult_index_count;
    }

    /// Get baby cow index start offset
    pub fn getBabyIndexStart(self: *const Self) u32 {
        return self.baby_index_start;
    }

    /// Get baby cow index count
    pub fn getBabyIndexCount(self: *const Self) u32 {
        return self.baby_index_count;
    }

    /// Get adult cow texture view for binding
    pub fn getTextureView(self: *const Self) vk.VkImageView {
        return self.texture_view;
    }

    /// Get adult cow texture sampler for binding
    pub fn getTextureSampler(self: *const Self) vk.VkSampler {
        return self.texture_sampler;
    }

    /// Get baby cow texture view for binding
    pub fn getBabyTextureView(self: *const Self) vk.VkImageView {
        return self.baby_texture_view;
    }

    /// Get baby cow texture sampler for binding
    pub fn getBabyTextureSampler(self: *const Self) vk.VkSampler {
        return self.baby_texture_sampler;
    }
};