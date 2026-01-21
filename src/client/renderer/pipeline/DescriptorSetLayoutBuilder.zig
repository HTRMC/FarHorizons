// DescriptorSetLayoutBuilder - Fluent builder for Vulkan descriptor set layouts
//
// Replaces duplicate descriptor set layout creation code with a unified builder pattern.

const volk = @import("volk");
const vk = volk.c;

pub const DescriptorSetLayoutBuilder = struct {
    const Self = @This();
    const MAX_BINDINGS = 8;

    bindings: [MAX_BINDINGS]vk.VkDescriptorSetLayoutBinding = undefined,
    count: u32 = 0,

    pub fn init() Self {
        return .{};
    }

    /// Add a uniform buffer binding
    pub fn withUniformBuffer(self: Self, binding: u32, stage: vk.VkShaderStageFlags) Self {
        return self.addBinding(binding, vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, stage);
    }

    /// Add a combined image sampler binding
    pub fn withSampler(self: Self, binding: u32, stage: vk.VkShaderStageFlags) Self {
        return self.addBinding(binding, vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, stage);
    }

    /// Add a storage buffer binding
    pub fn withStorageBuffer(self: Self, binding: u32, stage: vk.VkShaderStageFlags) Self {
        return self.addBinding(binding, vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, stage);
    }

    fn addBinding(self: Self, binding: u32, descriptor_type: c_uint, stage: vk.VkShaderStageFlags) Self {
        var copy = self;
        if (copy.count < MAX_BINDINGS) {
            copy.bindings[copy.count] = .{
                .binding = binding,
                .descriptorType = descriptor_type,
                .descriptorCount = 1,
                .stageFlags = stage,
                .pImmutableSamplers = null,
            };
            copy.count += 1;
        }
        return copy;
    }

    /// Build the descriptor set layout
    pub fn build(self: Self, device: vk.VkDevice) !vk.VkDescriptorSetLayout {
        const vkCreateDescriptorSetLayout = vk.vkCreateDescriptorSetLayout orelse return error.VulkanFunctionNotLoaded;

        if (self.count == 0) {
            return error.NoBindingsSpecified;
        }

        const layout_info = vk.VkDescriptorSetLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .bindingCount = self.count,
            .pBindings = &self.bindings,
        };

        var layout: vk.VkDescriptorSetLayout = undefined;
        if (vkCreateDescriptorSetLayout(device, &layout_info, null, &layout) != vk.VK_SUCCESS) {
            return error.DescriptorSetLayoutCreationFailed;
        }

        return layout;
    }
};
