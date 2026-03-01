const std = @import("std");
const vk = @import("../platform/volk.zig");
const GpuMemoryPool = @import("GpuMemoryPool.zig").GpuMemoryPool;
const TlsfAllocator = @import("TlsfAllocator.zig").TlsfAllocator;
const VulkanContext = @import("../renderer/vulkan/VulkanContext.zig").VulkanContext;
const vk_utils = @import("../renderer/vulkan/vk_utils.zig");

pub const PoolKind = enum {
    device_local,
    host_visible,
    staging,
};

pub const BufferAllocation = struct {
    buffer: vk.VkBuffer,
    memory: vk.VkDeviceMemory,
    offset: vk.VkDeviceSize,
    size: vk.VkDeviceSize,
    pool_kind: PoolKind,
    tlsf_offset: u32,
    mapped_ptr: ?[*]u8,
};

const DEVICE_LOCAL_SIZE: vk.VkDeviceSize = 32 * 1024 * 1024; // 32MB
const HOST_VISIBLE_SIZE: vk.VkDeviceSize = 4 * 1024 * 1024; // 4MB
const STAGING_SIZE: vk.VkDeviceSize = 4 * 1024 * 1024; // 4MB

pub const GpuAllocator = struct {
    allocator: std.mem.Allocator,
    device: vk.VkDevice,
    physical_device: vk.VkPhysicalDevice,
    device_local_pool: *GpuMemoryPool,
    host_visible_pool: *GpuMemoryPool,
    staging_pool: *GpuMemoryPool,

    pub fn init(allocator: std.mem.Allocator, ctx: *const VulkanContext) !*GpuAllocator {
        const device_local_type = try findMemoryTypeIndex(
            ctx.physical_device,
            0xFFFFFFFF,
            vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        );
        const host_visible_type = try findMemoryTypeIndex(
            ctx.physical_device,
            0xFFFFFFFF,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );

        const device_local_pool = try GpuMemoryPool.init(
            allocator,
            ctx.device,
            DEVICE_LOCAL_SIZE,
            device_local_type,
            false,
        );
        errdefer device_local_pool.deinit(ctx.device);

        const host_visible_pool = try GpuMemoryPool.init(
            allocator,
            ctx.device,
            HOST_VISIBLE_SIZE,
            host_visible_type,
            true,
        );
        errdefer host_visible_pool.deinit(ctx.device);

        const staging_pool = try GpuMemoryPool.init(
            allocator,
            ctx.device,
            STAGING_SIZE,
            host_visible_type,
            true,
        );
        errdefer staging_pool.deinit(ctx.device);

        const self = try allocator.create(GpuAllocator);
        self.* = .{
            .allocator = allocator,
            .device = ctx.device,
            .physical_device = ctx.physical_device,
            .device_local_pool = device_local_pool,
            .host_visible_pool = host_visible_pool,
            .staging_pool = staging_pool,
        };

        std.log.info("GpuAllocator: 3 pools ({:.1} MB device-local, {:.1} MB host-visible, {:.1} MB staging)", .{
            @as(f64, @floatFromInt(DEVICE_LOCAL_SIZE)) / (1024.0 * 1024.0),
            @as(f64, @floatFromInt(HOST_VISIBLE_SIZE)) / (1024.0 * 1024.0),
            @as(f64, @floatFromInt(STAGING_SIZE)) / (1024.0 * 1024.0),
        });

        return self;
    }

    pub fn deinit(self: *GpuAllocator) void {
        self.staging_pool.deinit(self.device);
        self.host_visible_pool.deinit(self.device);
        self.device_local_pool.deinit(self.device);
        self.allocator.destroy(self);
    }

    pub fn createBuffer(
        self: *GpuAllocator,
        size: vk.VkDeviceSize,
        usage: c_uint,
        pool_kind: PoolKind,
    ) !BufferAllocation {
        const pool = self.getPool(pool_kind);

        // Create the buffer to query alignment requirements
        const buffer_info = vk.VkBufferCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = size,
            .usage = usage,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };

        const buffer = try vk.createBuffer(self.device, &buffer_info, null);
        errdefer vk.destroyBuffer(self.device, buffer, null);

        var mem_req: vk.VkMemoryRequirements = undefined;
        vk.getBufferMemoryRequirements(self.device, buffer, &mem_req);

        const alignment: u32 = @intCast(mem_req.alignment);
        const alloc_size: u32 = @intCast(mem_req.size);

        const tlsf_alloc = pool.alloc(alloc_size, alignment) orelse {
            std.log.err("GpuAllocator: pool {s} full (requested {}, alignment {}, largest free {})", .{
                @tagName(pool_kind), alloc_size, alignment, pool.largestFree(),
            });
            return error.OutOfMemory;
        };
        errdefer pool.free(tlsf_alloc.offset);

        const offset: vk.VkDeviceSize = @intCast(tlsf_alloc.offset);
        try vk.bindBufferMemory(self.device, buffer, pool.memory, offset);

        const mapped_ptr = pool.getMappedSlice(tlsf_alloc.offset, alloc_size);

        return .{
            .buffer = buffer,
            .memory = pool.memory,
            .offset = offset,
            .size = size,
            .pool_kind = pool_kind,
            .tlsf_offset = tlsf_alloc.offset,
            .mapped_ptr = mapped_ptr,
        };
    }

    pub fn destroyBuffer(self: *GpuAllocator, alloc: BufferAllocation) void {
        vk.destroyBuffer(self.device, alloc.buffer, null);
        self.getPool(alloc.pool_kind).free(alloc.tlsf_offset);
    }

    fn getPool(self: *GpuAllocator, kind: PoolKind) *GpuMemoryPool {
        return switch (kind) {
            .device_local => self.device_local_pool,
            .host_visible => self.host_visible_pool,
            .staging => self.staging_pool,
        };
    }

    fn findMemoryTypeIndex(physical_device: vk.VkPhysicalDevice, type_filter: u32, properties: c_uint) !u32 {
        var mem_properties: vk.VkPhysicalDeviceMemoryProperties = undefined;
        vk.getPhysicalDeviceMemoryProperties(physical_device, &mem_properties);

        for (0..mem_properties.memoryTypeCount) |i| {
            const type_bit = @as(u32, 1) << (std.math.cast(u5, i) orelse unreachable);
            const has_type = (type_filter & type_bit) != 0;
            const has_props = (mem_properties.memoryTypes[i].propertyFlags & properties) == properties;
            if (has_type and has_props) {
                return std.math.cast(u32, i) orelse unreachable;
            }
        }
        return error.NoSuitableMemoryType;
    }
};
