// DescriptorPoolBuilder - Fluent builder for Vulkan descriptor pools
//
// Replaces duplicate createDescriptorPool implementations with a unified builder pattern.

const volk = @import("volk");
const vk = volk.c;

pub const DescriptorPoolBuilder = struct {
    const Self = @This();

    uniform_buffers: u32 = 0,
    samplers: u32 = 0,
    storage_buffers: u32 = 0,
    max_sets: u32 = 1,

    pub fn init() Self {
        return .{};
    }

    pub fn withUniformBuffers(self: Self, count: u32) Self {
        var copy = self;
        copy.uniform_buffers = count;
        return copy;
    }

    pub fn withSamplers(self: Self, count: u32) Self {
        var copy = self;
        copy.samplers = count;
        return copy;
    }

    pub fn withStorageBuffers(self: Self, count: u32) Self {
        var copy = self;
        copy.storage_buffers = count;
        return copy;
    }

    pub fn withMaxSets(self: Self, count: u32) Self {
        var copy = self;
        copy.max_sets = count;
        return copy;
    }

    pub fn build(self: Self, device: vk.VkDevice) !vk.VkDescriptorPool {
        const vkCreateDescriptorPool = vk.vkCreateDescriptorPool orelse return error.VulkanFunctionNotLoaded;

        // Count how many pool sizes we need
        var pool_size_count: u32 = 0;
        if (self.uniform_buffers > 0) pool_size_count += 1;
        if (self.samplers > 0) pool_size_count += 1;
        if (self.storage_buffers > 0) pool_size_count += 1;

        if (pool_size_count == 0) {
            return error.NoDescriptorTypesSpecified;
        }

        // Build pool sizes array (max 3 types currently supported)
        var pool_sizes: [3]vk.VkDescriptorPoolSize = undefined;
        var idx: u32 = 0;

        if (self.uniform_buffers > 0) {
            pool_sizes[idx] = .{
                .type = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .descriptorCount = self.uniform_buffers,
            };
            idx += 1;
        }

        if (self.samplers > 0) {
            pool_sizes[idx] = .{
                .type = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .descriptorCount = self.samplers,
            };
            idx += 1;
        }

        if (self.storage_buffers > 0) {
            pool_sizes[idx] = .{
                .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = self.storage_buffers,
            };
            idx += 1;
        }

        const pool_info = vk.VkDescriptorPoolCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .maxSets = self.max_sets,
            .poolSizeCount = pool_size_count,
            .pPoolSizes = &pool_sizes,
        };

        var pool: vk.VkDescriptorPool = undefined;
        if (vkCreateDescriptorPool(device, &pool_info, null, &pool) != vk.VK_SUCCESS) {
            return error.DescriptorPoolCreationFailed;
        }

        return pool;
    }
};
