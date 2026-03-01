const std = @import("std");
const vk = @import("../platform/volk.zig");
const TlsfAllocator = @import("TlsfAllocator.zig").TlsfAllocator;

pub const GpuMemoryPool = struct {
    memory: vk.VkDeviceMemory,
    tlsf: *TlsfAllocator,
    size: vk.VkDeviceSize,
    mapped_ptr: ?[*]u8,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        device: vk.VkDevice,
        size: vk.VkDeviceSize,
        memory_type_index: u32,
        map: bool,
    ) !*GpuMemoryPool {
        const alloc_info = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = size,
            .memoryTypeIndex = memory_type_index,
        };

        const memory = try vk.allocateMemory(device, &alloc_info, null);
        errdefer vk.freeMemory(device, memory, null);

        var mapped_ptr: ?[*]u8 = null;
        if (map) {
            var data: ?*anyopaque = null;
            try vk.mapMemory(device, memory, 0, size, 0, &data);
            mapped_ptr = @ptrCast(data.?);
        }

        const tlsf = try allocator.create(TlsfAllocator);
        tlsf.* = TlsfAllocator.init(@intCast(size));

        const self = try allocator.create(GpuMemoryPool);
        self.* = .{
            .memory = memory,
            .tlsf = tlsf,
            .size = size,
            .mapped_ptr = mapped_ptr,
            .allocator = allocator,
        };
        return self;
    }

    pub fn deinit(self: *GpuMemoryPool, device: vk.VkDevice) void {
        if (self.mapped_ptr != null) {
            vk.unmapMemory(device, self.memory);
        }
        vk.freeMemory(device, self.memory, null);
        self.allocator.destroy(self.tlsf);
        self.allocator.destroy(self);
    }

    pub fn alloc(self: *GpuMemoryPool, size: u32, alignment: u32) ?TlsfAllocator.Allocation {
        return self.tlsf.allocAligned(size, alignment);
    }

    pub fn free(self: *GpuMemoryPool, offset: u32) void {
        self.tlsf.free(offset);
    }

    pub fn getMappedSlice(self: *const GpuMemoryPool, offset: u32, _: u32) ?[*]u8 {
        const ptr = self.mapped_ptr orelse return null;
        return ptr + offset;
    }

    pub fn totalFree(self: *const GpuMemoryPool) u32 {
        return self.tlsf.totalFree();
    }

    pub fn largestFree(self: *const GpuMemoryPool) u32 {
        return self.tlsf.largestFree();
    }
};
