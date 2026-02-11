const std = @import("std");
const shared = @import("Shared");
const renderer = @import("Renderer");
const volk = @import("volk");
const vk = volk.c;
const ecs = @import("ecs");

const CowModel = @import("models/CowModel.zig").CowModel;
const BabyCowModel = @import("models/BabyCowModel.zig").BabyCowModel;
const mb = @import("models/ModelBuilder.zig");
const MeshWriter = mb.MeshWriter;
const Vertex = renderer.Vertex;
const GpuDevice = renderer.GpuDevice;
const TextureLoader = renderer.TextureLoader;
const Logger = shared.Logger;
const Mat4 = shared.Mat4;
const stb_image = @import("stb_image");

pub const EntityRenderer = struct {
    const Self = @This();
    const logger = Logger.scoped(Self);
    // 3 slots = MAX_FRAMES_IN_FLIGHT + 1, ensures GPU is done with a slot before CPU overwrites it
    const ENTITY_BUFFER_SLOTS = 3;
    const INITIAL_VERTEX_CAPACITY = 4096;
    const INITIAL_INDEX_CAPACITY = 8192;

    allocator: std.mem.Allocator,
    gpu_device: *GpuDevice,
    asset_directory: []const u8,

    // Cow models (adult and baby)
    cow_model: CowModel,
    baby_cow_model: BabyCowModel,

    // Triple-buffered persistently-mapped GPU buffers (one per slot, rotated each frame)
    vertex_buffers: [ENTITY_BUFFER_SLOTS]vk.VkBuffer = .{null} ** ENTITY_BUFFER_SLOTS,
    vertex_buffer_memories: [ENTITY_BUFFER_SLOTS]vk.VkDeviceMemory = .{null} ** ENTITY_BUFFER_SLOTS,
    vertex_buffer_mapped: [ENTITY_BUFFER_SLOTS]?[*]Vertex = .{null} ** ENTITY_BUFFER_SLOTS,
    vertex_buffer_capacity: [ENTITY_BUFFER_SLOTS]u32 = .{0} ** ENTITY_BUFFER_SLOTS,

    index_buffers: [ENTITY_BUFFER_SLOTS]vk.VkBuffer = .{null} ** ENTITY_BUFFER_SLOTS,
    index_buffer_memories: [ENTITY_BUFFER_SLOTS]vk.VkDeviceMemory = .{null} ** ENTITY_BUFFER_SLOTS,
    index_buffer_mapped: [ENTITY_BUFFER_SLOTS]?[*]u32 = .{null} ** ENTITY_BUFFER_SLOTS,
    index_buffer_capacity: [ENTITY_BUFFER_SLOTS]u32 = .{0} ** ENTITY_BUFFER_SLOTS,

    current_slot: u32 = ENTITY_BUFFER_SLOTS - 1,

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
    }

    fn destroyBuffers(self: *Self) void {
        for (0..ENTITY_BUFFER_SLOTS) |i| {
            if (self.vertex_buffers[i] != null) {
                self.gpu_device.destroyMappedBufferRaw(.{
                    .handle = self.vertex_buffers[i],
                    .memory = self.vertex_buffer_memories[i],
                    .mapped = if (self.vertex_buffer_mapped[i]) |p| @ptrCast(p) else null,
                });
                self.vertex_buffers[i] = null;
                self.vertex_buffer_memories[i] = null;
                self.vertex_buffer_mapped[i] = null;
                self.vertex_buffer_capacity[i] = 0;
            }
            if (self.index_buffers[i] != null) {
                self.gpu_device.destroyMappedBufferRaw(.{
                    .handle = self.index_buffers[i],
                    .memory = self.index_buffer_memories[i],
                    .mapped = if (self.index_buffer_mapped[i]) |p| @ptrCast(p) else null,
                });
                self.index_buffers[i] = null;
                self.index_buffer_memories[i] = null;
                self.index_buffer_mapped[i] = null;
                self.index_buffer_capacity[i] = 0;
            }
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

    /// Update entity meshes from ECS World and write directly to GPU buffers
    /// Three-pass zero-allocation design: count, ensure capacity, generate directly into mapped GPU memory
    pub fn updateFromECS(self: *Self, world: *ecs.World, partial_tick: f32) !void {
        // Advance to next buffer slot (triple-buffered to avoid write-before-fence-wait race)
        self.current_slot = (self.current_slot + 1) % ENTITY_BUFFER_SLOTS;

        // Pass 1: Count entities
        var adult_count: u32 = 0;
        var baby_count: u32 = 0;
        {
            var entity_iter = world.entities.iterator();
            while (entity_iter.next()) |id| {
                const render_data = world.getComponent(ecs.RenderData, id) orelse continue;
                if (render_data.entity_type != .cow and render_data.entity_type != .mooshroom) continue;
                if (world.getComponent(ecs.Transform, id) == null) continue;
                if (render_data.is_baby) {
                    baby_count += 1;
                } else {
                    adult_count += 1;
                }
            }
        }

        const total_verts = adult_count * self.cow_model.getVertexCount() + baby_count * self.baby_cow_model.getVertexCount();
        const total_indices = adult_count * self.cow_model.getIndexCount() + baby_count * self.baby_cow_model.getIndexCount();

        if (total_verts == 0) {
            self.vertex_count = 0;
            self.index_count = 0;
            self.adult_index_count = 0;
            self.baby_index_start = 0;
            self.baby_index_count = 0;
            return;
        }

        const slot = self.current_slot;

        // Pass 2: Ensure GPU buffer capacity + create MeshWriter pointing to mapped memory
        try self.ensureBufferCapacity(slot, total_verts, total_indices);

        var writer = MeshWriter{
            .vertices = self.vertex_buffer_mapped[slot].?,
            .indices = self.index_buffer_mapped[slot].?,
        };

        // Pass 3: Generate meshes directly into GPU memory

        // Adult cows first
        {
            var entity_iter = world.entities.iterator();
            while (entity_iter.next()) |id| {
                const render_data = world.getComponent(ecs.RenderData, id) orelse continue;
                if (render_data.entity_type != .cow and render_data.entity_type != .mooshroom) continue;
                if (render_data.is_baby) continue;

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

                const base_vertex = writer.getBaseVertex();

                self.cow_model.generateMeshDirect(walk_anim, walk_speed, head_pitch, head_yaw, &writer);

                // Post-process in-place: world transform, tex_index, hurt color
                // Note: indices are already absolute (renderDirect writes base_vertex-relative indices)
                for (writer.vertices[base_vertex..writer.vertex_count]) |*vert| {
                    const x = vert.pos[0];
                    const y = vert.pos[1];
                    const z = vert.pos[2];
                    vert.pos = .{
                        m.data[0] * x + m.data[4] * y + m.data[8] * z + m.data[12],
                        m.data[1] * x + m.data[5] * y + m.data[9] * z + m.data[13],
                        m.data[2] * x + m.data[6] * y + m.data[10] * z + m.data[14],
                    };
                    if (self.use_bindless) vert.tex_index = self.cow_tex_index;
                    if (is_hurt) vert.color = .{ 1.0, 0.4, 0.4 };
                }
            }
        }

        // Record where adult indices end
        self.adult_index_count = writer.index_count;
        self.baby_index_start = self.adult_index_count;

        // Baby cows
        {
            var entity_iter = world.entities.iterator();
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

                const base_vertex = writer.getBaseVertex();

                self.baby_cow_model.generateMeshDirect(walk_anim, walk_speed, head_pitch, head_yaw, &writer);

                // Post-process in-place: world transform, tex_index, hurt color
                // Note: indices are already absolute (renderDirect writes base_vertex-relative indices)
                for (writer.vertices[base_vertex..writer.vertex_count]) |*vert| {
                    const x = vert.pos[0];
                    const y = vert.pos[1];
                    const z = vert.pos[2];
                    vert.pos = .{
                        m.data[0] * x + m.data[4] * y + m.data[8] * z + m.data[12],
                        m.data[1] * x + m.data[5] * y + m.data[9] * z + m.data[13],
                        m.data[2] * x + m.data[6] * y + m.data[10] * z + m.data[14],
                    };
                    if (self.use_bindless) vert.tex_index = self.baby_cow_tex_index;
                    if (is_hurt) vert.color = .{ 1.0, 0.4, 0.4 };
                }
            }
        }

        self.baby_index_count = writer.index_count - self.baby_index_start;
        self.vertex_count = writer.vertex_count;
        self.index_count = writer.index_count;
    }

    /// Ensure buffer slot has enough capacity, creating or growing if needed
    fn ensureBufferCapacity(self: *Self, slot: u32, vertex_count: u32, index_count: u32) !void {
        if (self.vertex_buffer_capacity[slot] < vertex_count) {
            // Destroy old buffer if it exists
            if (self.vertex_buffers[slot] != null) {
                self.gpu_device.destroyMappedBufferRaw(.{
                    .handle = self.vertex_buffers[slot],
                    .memory = self.vertex_buffer_memories[slot],
                    .mapped = if (self.vertex_buffer_mapped[slot]) |p| @ptrCast(p) else null,
                });
                self.vertex_buffers[slot] = null;
                self.vertex_buffer_memories[slot] = null;
                self.vertex_buffer_mapped[slot] = null;
                self.vertex_buffer_capacity[slot] = 0;
            }

            const new_capacity = @max(vertex_count, @max(INITIAL_VERTEX_CAPACITY, self.vertex_buffer_capacity[slot] * 2));
            const size: u64 = @sizeOf(Vertex) * @as(u64, new_capacity);
            const result = try self.gpu_device.createMappedBufferRaw(size, vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);

            self.vertex_buffers[slot] = result.handle;
            self.vertex_buffer_memories[slot] = result.memory;
            self.vertex_buffer_mapped[slot] = @ptrCast(@alignCast(result.mapped.?));
            self.vertex_buffer_capacity[slot] = new_capacity;
        }

        if (self.index_buffer_capacity[slot] < index_count) {
            if (self.index_buffers[slot] != null) {
                self.gpu_device.destroyMappedBufferRaw(.{
                    .handle = self.index_buffers[slot],
                    .memory = self.index_buffer_memories[slot],
                    .mapped = if (self.index_buffer_mapped[slot]) |p| @ptrCast(p) else null,
                });
                self.index_buffers[slot] = null;
                self.index_buffer_memories[slot] = null;
                self.index_buffer_mapped[slot] = null;
                self.index_buffer_capacity[slot] = 0;
            }

            const new_capacity = @max(index_count, @max(INITIAL_INDEX_CAPACITY, self.index_buffer_capacity[slot] * 2));
            const size: u64 = @sizeOf(u32) * @as(u64, new_capacity);
            const result = try self.gpu_device.createMappedBufferRaw(size, vk.VK_BUFFER_USAGE_INDEX_BUFFER_BIT);

            self.index_buffers[slot] = result.handle;
            self.index_buffer_memories[slot] = result.memory;
            self.index_buffer_mapped[slot] = @ptrCast(@alignCast(result.mapped.?));
            self.index_buffer_capacity[slot] = new_capacity;
        }
    }

    /// Record draw commands into command buffer (draws all entities with a single texture)
    /// DEPRECATED: Use recordAdultDrawCommands/recordBabyDrawCommands for proper texture separation
    pub fn recordDrawCommands(self: *const Self, command_buffer: vk.VkCommandBuffer) void {
        const vb = self.vertex_buffers[self.current_slot];
        const ib = self.index_buffers[self.current_slot];
        if (self.index_count == 0 or vb == null) return;

        const vkCmdBindVertexBuffers = vk.vkCmdBindVertexBuffers orelse return;
        const vkCmdBindIndexBuffer = vk.vkCmdBindIndexBuffer orelse return;
        const vkCmdDrawIndexed = vk.vkCmdDrawIndexed orelse return;

        const bufs = [_]vk.VkBuffer{vb};
        const offsets = [_]vk.VkDeviceSize{0};
        vkCmdBindVertexBuffers(command_buffer, 0, 1, &bufs, &offsets);
        vkCmdBindIndexBuffer(command_buffer, ib, 0, vk.VK_INDEX_TYPE_UINT32);
        vkCmdDrawIndexed(command_buffer, self.index_count, 1, 0, 0, 0);
    }

    /// Record draw commands for adult cows only (use with adult cow texture)
    pub fn recordAdultDrawCommands(self: *const Self, command_buffer: vk.VkCommandBuffer) void {
        const vb = self.vertex_buffers[self.current_slot];
        const ib = self.index_buffers[self.current_slot];
        if (self.adult_index_count == 0 or vb == null) return;

        const vkCmdBindVertexBuffers = vk.vkCmdBindVertexBuffers orelse return;
        const vkCmdBindIndexBuffer = vk.vkCmdBindIndexBuffer orelse return;
        const vkCmdDrawIndexed = vk.vkCmdDrawIndexed orelse return;

        const bufs = [_]vk.VkBuffer{vb};
        const offsets = [_]vk.VkDeviceSize{0};
        vkCmdBindVertexBuffers(command_buffer, 0, 1, &bufs, &offsets);
        vkCmdBindIndexBuffer(command_buffer, ib, 0, vk.VK_INDEX_TYPE_UINT32);
        vkCmdDrawIndexed(command_buffer, self.adult_index_count, 1, 0, 0, 0);
    }

    /// Record draw commands for baby cows only (use with baby cow texture)
    pub fn recordBabyDrawCommands(self: *const Self, command_buffer: vk.VkCommandBuffer) void {
        const vb = self.vertex_buffers[self.current_slot];
        const ib = self.index_buffers[self.current_slot];
        if (self.baby_index_count == 0 or vb == null) return;

        const vkCmdBindVertexBuffers = vk.vkCmdBindVertexBuffers orelse return;
        const vkCmdBindIndexBuffer = vk.vkCmdBindIndexBuffer orelse return;
        const vkCmdDrawIndexed = vk.vkCmdDrawIndexed orelse return;

        const bufs = [_]vk.VkBuffer{vb};
        const offsets = [_]vk.VkDeviceSize{0};
        vkCmdBindVertexBuffers(command_buffer, 0, 1, &bufs, &offsets);
        vkCmdBindIndexBuffer(command_buffer, ib, 0, vk.VK_INDEX_TYPE_UINT32);
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

    /// Get vertex buffer for external rendering (returns current slot's buffer)
    pub fn getVertexBuffer(self: *const Self) ?vk.VkBuffer {
        return self.vertex_buffers[self.current_slot];
    }

    /// Get index buffer for external rendering (returns current slot's buffer)
    pub fn getIndexBuffer(self: *const Self) ?vk.VkBuffer {
        return self.index_buffers[self.current_slot];
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