const std = @import("std");
const shared = @import("Shared");
const renderer = @import("Renderer");
const volk = @import("volk");
const vk = volk.c;

const Entity = @import("Entity.zig").Entity;
const EntityType = @import("Entity.zig").EntityType;
const EntityManager = @import("Entity.zig").EntityManager;
const CowModel = @import("models/CowModel.zig").CowModel;
const Vertex = renderer.Vertex;
const GpuDevice = renderer.GpuDevice;
const Logger = shared.Logger;
const Mat4 = shared.Mat4;

pub const EntityRenderer = struct {
    const Self = @This();
    const logger = Logger.init("EntityRenderer");

    allocator: std.mem.Allocator,
    gpu_device: *GpuDevice,

    // Cow model
    cow_model: CowModel,

    // GPU buffers for entity rendering
    vertex_buffer: vk.VkBuffer = null,
    vertex_buffer_memory: vk.VkDeviceMemory = null,
    index_buffer: vk.VkBuffer = null,
    index_buffer_memory: vk.VkDeviceMemory = null,

    // Current buffer sizes
    vertex_count: u32 = 0,
    index_count: u32 = 0,

    // Cached mesh data
    cached_vertices: ?[]Vertex = null,
    cached_indices: ?[]u32 = null,

    pub fn init(allocator: std.mem.Allocator, gpu_device: *GpuDevice) Self {
        return .{
            .allocator = allocator,
            .gpu_device = gpu_device,
            .cow_model = CowModel.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.destroyBuffers();
        self.cow_model.deinit();

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

    /// Update entity meshes and upload to GPU
    pub fn update(self: *Self, entity_manager: *EntityManager, partial_tick: f32) !void {
        // Collect all entity vertices/indices
        var all_vertices: std.ArrayList(Vertex) = .empty;
        defer all_vertices.deinit(self.allocator);
        var all_indices: std.ArrayList(u32) = .empty;
        defer all_indices.deinit(self.allocator);

        var iter = entity_manager.iterator();
        while (iter.next()) |entity| {
            const base_vertex: u32 = @intCast(all_vertices.items.len);

            // Generated mesh based on entity type
            switch (entity.entity_type) {
                .cow => {
                    const mesh = try self.cow_model.generateMesh(entity.walk_animation);
                    defer self.allocator.free(mesh.vertices);
                    defer self.allocator.free(mesh.indices);

                    // Transform vertices by entity model matrix
                    const m = entity.getModelMatrix(partial_tick);

                    for (mesh.vertices) |vert| {
                        var transformed = vert;
                        // Manual matrix * point multiplication (column-major)
                        const x = vert.pos[0];
                        const y = vert.pos[1];
                        const z = vert.pos[2];
                        transformed.pos = .{
                            m.data[0] * x + m.data[4] * y + m.data[8] * z + m.data[12],
                            m.data[1] * x + m.data[5] * y + m.data[9] * z + m.data[13],
                            m.data[2] * x + m.data[6] * y + m.data[10] * z + m.data[14],
                        };
                        try all_vertices.append(self.allocator, transformed);
                    }

                    for (mesh.indices) |idx| {
                        try all_indices.append(self.allocator, base_vertex + idx);
                    }
                },
                else => {
                    // Other entity types not implemented yet
                },
            }
        }

        if (all_vertices.items.len == 0) {
            self.vertex_count = 0;
            self.index_count = 0;
            return;
        }

        // Recreate buffers if size changed
        self.destroyBuffers();

        // Create vertex buffer
        const vertex_result = try self.gpu_device.createBufferWithDataRaw(
            Vertex,
            all_vertices.items,
            vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        );
        self.vertex_buffer = vertex_result.handle;
        self.vertex_buffer_memory = vertex_result.memory;

        // Create index buffer
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

    /// Record draw commands into command buffer
    /// Call this after binding the entity pipeline
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

    pub fn hasEntities(self: *const Self) bool {
        return self.index_count > 0;
    }

    /// Get vertex buffer for external rendering
    pub fn getVertexBuffer(self: *const Self) ?vk.VkBuffer {
        return self.vertex_buffer;
    }

    /// Get index buffer for external rendering
    pub fn getIndexBuffer(self: *const Self) ?vk.VkBuffer {
        return self.index_buffer;
    }

    /// Get index count for external rendering
    pub fn getIndexCount(self: *const Self) u32 {
        return self.index_count;
    }
};