// GpuBuffer - Abstract buffer representation for GPU memory
// Inspired by Minecraft's com.mojang.blaze3d.buffers.GpuBuffer

const std = @import("std");
const volk = @import("volk");
const vk = volk.c;

/// Buffer usage flags (can be combined with |)
pub const Usage = packed struct(u16) {
    /// Buffer can be mapped for CPU read
    map_read: bool = false,
    /// Buffer can be mapped for CPU write
    map_write: bool = false,
    /// Hint for client-side storage
    client_storage: bool = false,
    /// Buffer can be a copy destination
    copy_dst: bool = false,
    /// Buffer can be a copy source
    copy_src: bool = false,
    /// Buffer can be used as vertex buffer
    vertex: bool = false,
    /// Buffer can be used as index buffer
    index: bool = false,
    /// Buffer can be used as uniform buffer
    uniform: bool = false,
    /// Buffer can be used for staging transfers
    staging: bool = false,
    _padding: u7 = 0,

    pub const VERTEX = Usage{ .vertex = true };
    pub const INDEX = Usage{ .index = true };
    pub const UNIFORM = Usage{ .uniform = true };
    pub const STAGING = Usage{ .staging = true, .map_write = true, .copy_src = true };
    pub const VERTEX_STAGING = Usage{ .vertex = true, .map_write = true };
    pub const INDEX_STAGING = Usage{ .index = true, .map_write = true };
    pub const UNIFORM_MAPPED = Usage{ .uniform = true, .map_write = true };

    pub fn toVkUsage(self: Usage) vk.VkBufferUsageFlags {
        var flags: vk.VkBufferUsageFlags = 0;
        if (self.vertex) flags |= vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT;
        if (self.index) flags |= vk.VK_BUFFER_USAGE_INDEX_BUFFER_BIT;
        if (self.uniform) flags |= vk.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
        if (self.copy_src) flags |= vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
        if (self.copy_dst) flags |= vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT;
        return flags;
    }

    pub fn toVkMemoryProperties(self: Usage) vk.VkMemoryPropertyFlags {
        if (self.map_read or self.map_write) {
            return vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        }
        return vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
    }
};

/// A slice/view into a GpuBuffer
pub const GpuBufferSlice = struct {
    buffer: *GpuBuffer,
    offset: u64,
    length: u64,

    pub fn getHandle(self: GpuBufferSlice) vk.VkBuffer {
        return self.buffer.handle;
    }
};

/// Abstract GPU buffer with lifecycle management
pub const GpuBuffer = struct {
    const Self = @This();

    handle: vk.VkBuffer,
    memory: vk.VkDeviceMemory,
    size: u64,
    usage: Usage,
    mapped_ptr: ?*anyopaque,
    closed: bool,

    // Reference to device for cleanup (stored as opaque to avoid circular dependency)
    device: vk.VkDevice,
    label: ?[]const u8,

    pub fn init(
        handle: vk.VkBuffer,
        memory: vk.VkDeviceMemory,
        size: u64,
        usage: Usage,
        device: vk.VkDevice,
        label: ?[]const u8,
    ) Self {
        return .{
            .handle = handle,
            .memory = memory,
            .size = size,
            .usage = usage,
            .mapped_ptr = null,
            .closed = false,
            .device = device,
            .label = label,
        };
    }

    /// Get a slice of the entire buffer
    pub fn slice(self: *Self) GpuBufferSlice {
        return .{
            .buffer = self,
            .offset = 0,
            .length = self.size,
        };
    }

    /// Get a slice of a portion of the buffer
    pub fn sliceRange(self: *Self, offset: u64, length: u64) !GpuBufferSlice {
        if (offset + length > self.size) {
            return error.SliceOutOfBounds;
        }
        return .{
            .buffer = self,
            .offset = offset,
            .length = length,
        };
    }

    /// Map buffer memory for CPU access
    pub fn map(self: *Self) !*anyopaque {
        if (self.closed) return error.BufferClosed;
        if (self.mapped_ptr) |ptr| return ptr;

        const vkMapMemory = vk.vkMapMemory orelse return error.VulkanFunctionNotLoaded;

        var data: ?*anyopaque = null;
        if (vkMapMemory(self.device, self.memory, 0, self.size, 0, &data) != vk.VK_SUCCESS) {
            return error.MemoryMapFailed;
        }

        self.mapped_ptr = data;
        return data.?;
    }

    /// Unmap buffer memory
    pub fn unmap(self: *Self) void {
        if (self.mapped_ptr == null) return;

        const vkUnmapMemory = vk.vkUnmapMemory orelse return;
        vkUnmapMemory(self.device, self.memory);
        self.mapped_ptr = null;
    }

    /// Write data to a mapped buffer
    pub fn writeData(self: *Self, comptime T: type, data: []const T) !void {
        const byte_size = @sizeOf(T) * data.len;
        if (byte_size > self.size) return error.DataTooLarge;

        const ptr = try self.map();
        const dest: [*]T = @ptrCast(@alignCast(ptr));
        @memcpy(dest[0..data.len], data);
    }

    /// Write raw bytes to a mapped buffer
    pub fn writeBytes(self: *Self, data: []const u8) !void {
        if (data.len > self.size) return error.DataTooLarge;

        const ptr = try self.map();
        const dest: [*]u8 = @ptrCast(ptr);
        @memcpy(dest[0..data.len], data);
    }

    /// Check if buffer is closed
    pub fn isClosed(self: *const Self) bool {
        return self.closed;
    }

    /// Close and release buffer resources
    pub fn close(self: *Self) void {
        if (self.closed) return;

        self.unmap();

        const vkDestroyBuffer = vk.vkDestroyBuffer orelse return;
        const vkFreeMemory = vk.vkFreeMemory orelse return;

        if (self.handle != null) {
            vkDestroyBuffer(self.device, self.handle, null);
        }
        if (self.memory != null) {
            vkFreeMemory(self.device, self.memory, null);
        }

        self.closed = true;
        self.handle = null;
        self.memory = null;
    }

    /// Alias for close() to match Zig conventions
    pub fn deinit(self: *Self) void {
        self.close();
    }
};

/// Simple value-type wrapper for paired VkBuffer + VkDeviceMemory fields
/// Use this to consolidate the many buffer/memory field pairs in RenderSystem
pub const ManagedBuffer = struct {
    handle: vk.VkBuffer = null,
    memory: vk.VkDeviceMemory = null,
    mapped: ?*anyopaque = null,

    pub fn isValid(self: ManagedBuffer) bool {
        return self.handle != null;
    }

    /// Destroy buffer and memory resources
    pub fn destroy(self: *ManagedBuffer, device: vk.VkDevice) void {
        const vkDestroyBuffer = vk.vkDestroyBuffer orelse return;
        const vkFreeMemory = vk.vkFreeMemory orelse return;
        const vkUnmapMemory = vk.vkUnmapMemory orelse return;

        // Unmap if mapped
        if (self.mapped != null) {
            vkUnmapMemory(device, self.memory);
            self.mapped = null;
        }

        if (self.handle != null) {
            vkDestroyBuffer(device, self.handle, null);
            self.handle = null;
        }
        if (self.memory != null) {
            vkFreeMemory(device, self.memory, null);
            self.memory = null;
        }
    }

    /// Create from raw Vulkan handles
    pub fn fromRaw(handle: vk.VkBuffer, memory: vk.VkDeviceMemory) ManagedBuffer {
        return .{
            .handle = handle,
            .memory = memory,
            .mapped = null,
        };
    }

    /// Create from raw Vulkan handles with mapped pointer
    pub fn fromMapped(handle: vk.VkBuffer, memory: vk.VkDeviceMemory, mapped: *anyopaque) ManagedBuffer {
        return .{
            .handle = handle,
            .memory = memory,
            .mapped = mapped,
        };
    }
};

/// Index type for index buffers
pub const IndexType = enum {
    u16,
    u32,

    pub fn toVk(self: IndexType) c_uint {
        return switch (self) {
            .u16 => vk.VK_INDEX_TYPE_UINT16,
            .u32 => vk.VK_INDEX_TYPE_UINT32,
        };
    }

    pub fn byteSize(self: IndexType) usize {
        return switch (self) {
            .u16 => 2,
            .u32 => 4,
        };
    }

    /// Choose the smallest index type that can represent the given vertex count
    pub fn least(vertex_count: u32) IndexType {
        return if (vertex_count <= 65535) .u16 else .u32;
    }
};
