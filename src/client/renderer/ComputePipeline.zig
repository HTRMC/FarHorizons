/// ComputePipeline - Helper for creating Vulkan compute pipelines
const std = @import("std");
const volk = @import("volk");
const vk = volk.c;
const shared = @import("Shared");
const Logger = shared.Logger;

const Self = @This();
const logger = Logger.scoped(Self);

pub const ComputePipelineConfig = struct {
    shader_module: vk.VkShaderModule,
    pipeline_layout: vk.VkPipelineLayout,
    entry_point: [*:0]const u8 = "main",
};

/// Create a compute pipeline from a shader module and layout
pub fn create(
    device: vk.VkDevice,
    config: ComputePipelineConfig,
) !vk.VkPipeline {
    const vkCreateComputePipelines = vk.vkCreateComputePipelines orelse return error.VulkanFunctionNotLoaded;

    const stage = vk.VkPipelineShaderStageCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .stage = vk.VK_SHADER_STAGE_COMPUTE_BIT,
        .module = config.shader_module,
        .pName = config.entry_point,
        .pSpecializationInfo = null,
    };

    const create_info = vk.VkComputePipelineCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .stage = stage,
        .layout = config.pipeline_layout,
        .basePipelineHandle = null,
        .basePipelineIndex = -1,
    };

    var pipeline: vk.VkPipeline = null;
    const result = vkCreateComputePipelines(device, null, 1, &create_info, null, &pipeline);
    if (result != vk.VK_SUCCESS) {
        logger.err("Failed to create compute pipeline: {}", .{result});
        return error.ComputePipelineCreationFailed;
    }

    return pipeline;
}

/// Destroy a compute pipeline
pub fn destroy(device: vk.VkDevice, pipeline: vk.VkPipeline) void {
    if (vk.vkDestroyPipeline) |destroyFn| {
        destroyFn(device, pipeline, null);
    }
}

/// Create a descriptor set layout for compute shaders
pub fn createDescriptorSetLayout(
    device: vk.VkDevice,
    bindings: []const vk.VkDescriptorSetLayoutBinding,
) !vk.VkDescriptorSetLayout {
    const vkCreateDescriptorSetLayout = vk.vkCreateDescriptorSetLayout orelse return error.VulkanFunctionNotLoaded;

    const layout_info = vk.VkDescriptorSetLayoutCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .bindingCount = @intCast(bindings.len),
        .pBindings = bindings.ptr,
    };

    var layout: vk.VkDescriptorSetLayout = null;
    const result = vkCreateDescriptorSetLayout(device, &layout_info, null, &layout);
    if (result != vk.VK_SUCCESS) {
        return error.DescriptorSetLayoutCreationFailed;
    }

    return layout;
}

/// Create a pipeline layout with push constants
pub fn createPipelineLayout(
    device: vk.VkDevice,
    descriptor_set_layouts: []const vk.VkDescriptorSetLayout,
    push_constant_ranges: []const vk.VkPushConstantRange,
) !vk.VkPipelineLayout {
    const vkCreatePipelineLayout = vk.vkCreatePipelineLayout orelse return error.VulkanFunctionNotLoaded;

    const layout_info = vk.VkPipelineLayoutCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .setLayoutCount = @intCast(descriptor_set_layouts.len),
        .pSetLayouts = if (descriptor_set_layouts.len > 0) descriptor_set_layouts.ptr else null,
        .pushConstantRangeCount = @intCast(push_constant_ranges.len),
        .pPushConstantRanges = if (push_constant_ranges.len > 0) push_constant_ranges.ptr else null,
    };

    var layout: vk.VkPipelineLayout = null;
    const result = vkCreatePipelineLayout(device, &layout_info, null, &layout);
    if (result != vk.VK_SUCCESS) {
        return error.PipelineLayoutCreationFailed;
    }

    return layout;
}

/// Storage buffer binding helper
pub fn storageBufferBinding(binding: u32, stage_flags: vk.VkShaderStageFlags) vk.VkDescriptorSetLayoutBinding {
    return .{
        .binding = binding,
        .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .descriptorCount = 1,
        .stageFlags = stage_flags,
        .pImmutableSamplers = null,
    };
}

/// Record compute dispatch command
pub fn dispatch(
    cmd_buffer: vk.VkCommandBuffer,
    pipeline: vk.VkPipeline,
    pipeline_layout: vk.VkPipelineLayout,
    descriptor_set: vk.VkDescriptorSet,
    group_count_x: u32,
    group_count_y: u32,
    group_count_z: u32,
) void {
    const vkCmdBindPipeline = vk.vkCmdBindPipeline orelse return;
    const vkCmdBindDescriptorSets = vk.vkCmdBindDescriptorSets orelse return;
    const vkCmdDispatch = vk.vkCmdDispatch orelse return;

    vkCmdBindPipeline(cmd_buffer, vk.VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);

    const descriptor_sets = [_]vk.VkDescriptorSet{descriptor_set};
    vkCmdBindDescriptorSets(
        cmd_buffer,
        vk.VK_PIPELINE_BIND_POINT_COMPUTE,
        pipeline_layout,
        0,
        1,
        &descriptor_sets,
        0,
        null,
    );

    vkCmdDispatch(cmd_buffer, group_count_x, group_count_y, group_count_z);
}

/// Record indirect compute dispatch command
pub fn dispatchIndirect(
    cmd_buffer: vk.VkCommandBuffer,
    pipeline: vk.VkPipeline,
    pipeline_layout: vk.VkPipelineLayout,
    descriptor_set: vk.VkDescriptorSet,
    indirect_buffer: vk.VkBuffer,
    offset: u64,
) void {
    const vkCmdBindPipeline = vk.vkCmdBindPipeline orelse return;
    const vkCmdBindDescriptorSets = vk.vkCmdBindDescriptorSets orelse return;
    const vkCmdDispatchIndirect = vk.vkCmdDispatchIndirect orelse return;

    vkCmdBindPipeline(cmd_buffer, vk.VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);

    const descriptor_sets = [_]vk.VkDescriptorSet{descriptor_set};
    vkCmdBindDescriptorSets(
        cmd_buffer,
        vk.VK_PIPELINE_BIND_POINT_COMPUTE,
        pipeline_layout,
        0,
        1,
        &descriptor_sets,
        0,
        null,
    );

    vkCmdDispatchIndirect(cmd_buffer, indirect_buffer, offset);
}

/// Insert memory barrier between compute stages
pub fn insertComputeBarrier(cmd_buffer: vk.VkCommandBuffer) void {
    const vkCmdPipelineBarrier = vk.vkCmdPipelineBarrier orelse return;

    const barrier = vk.VkMemoryBarrier{
        .sType = vk.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = vk.VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT,
    };

    vkCmdPipelineBarrier(
        cmd_buffer,
        vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        0,
        1,
        &barrier,
        0,
        null,
        0,
        null,
    );
}

/// Insert memory barrier from compute to draw indirect
pub fn insertComputeToDrawBarrier(cmd_buffer: vk.VkCommandBuffer) void {
    const vkCmdPipelineBarrier = vk.vkCmdPipelineBarrier orelse return;

    const barrier = vk.VkMemoryBarrier{
        .sType = vk.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = vk.VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = vk.VK_ACCESS_INDIRECT_COMMAND_READ_BIT,
    };

    vkCmdPipelineBarrier(
        cmd_buffer,
        vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        vk.VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT,
        0,
        1,
        &barrier,
        0,
        null,
        0,
        null,
    );
}
