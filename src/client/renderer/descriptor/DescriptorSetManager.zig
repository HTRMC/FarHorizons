// DescriptorSetManager - Centralized descriptor set allocation and update
//
// Provides helper functions for common descriptor set operations.

const std = @import("std");
const volk = @import("volk");
const vk = volk.c;

pub const DescriptorSetManager = struct {
    /// Allocate descriptor sets from a pool using a layout
    /// Returns a slice of allocated sets. Caller must provide the output array.
    pub fn allocateSets(
        device: vk.VkDevice,
        pool: vk.VkDescriptorPool,
        layout: vk.VkDescriptorSetLayout,
        comptime count: u32,
        output: *[count]vk.VkDescriptorSet,
    ) !void {
        const vkAllocateDescriptorSets = vk.vkAllocateDescriptorSets orelse return error.VulkanFunctionNotLoaded;

        var layouts: [count]vk.VkDescriptorSetLayout = undefined;
        for (&layouts) |*l| {
            l.* = layout;
        }

        const alloc_info = vk.VkDescriptorSetAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = pool,
            .descriptorSetCount = count,
            .pSetLayouts = &layouts,
        };

        if (vkAllocateDescriptorSets(device, &alloc_info, output) != vk.VK_SUCCESS) {
            return error.DescriptorSetAllocationFailed;
        }
    }

    /// Update a descriptor set with a uniform buffer binding
    pub fn updateUniformBuffer(
        device: vk.VkDevice,
        set: vk.VkDescriptorSet,
        binding: u32,
        buffer: vk.VkBuffer,
        size: u64,
    ) void {
        const vkUpdateDescriptorSets = vk.vkUpdateDescriptorSets orelse return;

        const buffer_info = vk.VkDescriptorBufferInfo{
            .buffer = buffer,
            .offset = 0,
            .range = size,
        };

        const descriptor_write = vk.VkWriteDescriptorSet{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = set,
            .dstBinding = binding,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = &buffer_info,
            .pTexelBufferView = null,
        };

        vkUpdateDescriptorSets(device, 1, &descriptor_write, 0, null);
    }

    /// Update a descriptor set with a combined image sampler binding
    pub fn updateSampler(
        device: vk.VkDevice,
        set: vk.VkDescriptorSet,
        binding: u32,
        view: vk.VkImageView,
        sampler: vk.VkSampler,
    ) void {
        const vkUpdateDescriptorSets = vk.vkUpdateDescriptorSets orelse return;

        const image_info = vk.VkDescriptorImageInfo{
            .sampler = sampler,
            .imageView = view,
            .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };

        const descriptor_write = vk.VkWriteDescriptorSet{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = set,
            .dstBinding = binding,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &image_info,
            .pBufferInfo = null,
            .pTexelBufferView = null,
        };

        vkUpdateDescriptorSets(device, 1, &descriptor_write, 0, null);
    }

    /// Update a descriptor set with a storage buffer binding
    pub fn updateStorageBuffer(
        device: vk.VkDevice,
        set: vk.VkDescriptorSet,
        binding: u32,
        buffer: vk.VkBuffer,
        size: u64,
    ) void {
        const vkUpdateDescriptorSets = vk.vkUpdateDescriptorSets orelse return;

        const buffer_info = vk.VkDescriptorBufferInfo{
            .buffer = buffer,
            .offset = 0,
            .range = size,
        };

        const descriptor_write = vk.VkWriteDescriptorSet{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = set,
            .dstBinding = binding,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = &buffer_info,
            .pTexelBufferView = null,
        };

        vkUpdateDescriptorSets(device, 1, &descriptor_write, 0, null);
    }

    /// Update a descriptor set with both uniform buffer and sampler in a single call
    /// This is more efficient than calling updateUniformBuffer and updateSampler separately
    pub fn updateUniformBufferAndSampler(
        device: vk.VkDevice,
        set: vk.VkDescriptorSet,
        buffer_binding: u32,
        buffer: vk.VkBuffer,
        buffer_size: u64,
        sampler_binding: u32,
        view: vk.VkImageView,
        sampler: vk.VkSampler,
    ) void {
        const vkUpdateDescriptorSets = vk.vkUpdateDescriptorSets orelse return;

        const buffer_info = vk.VkDescriptorBufferInfo{
            .buffer = buffer,
            .offset = 0,
            .range = buffer_size,
        };

        const image_info = vk.VkDescriptorImageInfo{
            .sampler = sampler,
            .imageView = view,
            .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };

        const descriptor_writes = [_]vk.VkWriteDescriptorSet{
            .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = set,
                .dstBinding = buffer_binding,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .pImageInfo = null,
                .pBufferInfo = &buffer_info,
                .pTexelBufferView = null,
            },
            .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = set,
                .dstBinding = sampler_binding,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .pImageInfo = &image_info,
                .pBufferInfo = null,
                .pTexelBufferView = null,
            },
        };

        vkUpdateDescriptorSets(device, descriptor_writes.len, &descriptor_writes, 0, null);
    }
};
