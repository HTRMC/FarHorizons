const vk = @import("../../platform/volk.zig");

pub const VulkanContext = struct {
    device: vk.VkDevice,
    physical_device: vk.VkPhysicalDevice,
    graphics_queue: vk.VkQueue,
    queue_family_index: u32,
    command_pool: vk.VkCommandPool,
    pipeline_cache: vk.VkPipelineCache,
};
