// ImageViewHelper - Common image view creation helpers
//
// Provides utilities for creating VkImageView with common configurations.

const volk = @import("volk");
const vk = volk.c;

pub const ImageViewHelper = struct {
    /// Create a 2D image view with standard identity swizzle
    pub fn create2D(
        device: vk.VkDevice,
        image: vk.VkImage,
        format: vk.VkFormat,
        aspect_mask: vk.VkImageAspectFlags,
    ) !vk.VkImageView {
        return create2DArray(device, image, format, aspect_mask, 1);
    }

    /// Create a 2D array image view with standard identity swizzle
    pub fn create2DArray(
        device: vk.VkDevice,
        image: vk.VkImage,
        format: vk.VkFormat,
        aspect_mask: vk.VkImageAspectFlags,
        layer_count: u32,
    ) !vk.VkImageView {
        const vkCreateImageView = vk.vkCreateImageView orelse return error.VulkanFunctionNotLoaded;

        const view_type: c_uint = if (layer_count > 1)
            vk.VK_IMAGE_VIEW_TYPE_2D_ARRAY
        else
            vk.VK_IMAGE_VIEW_TYPE_2D;

        const create_info = vk.VkImageViewCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = image,
            .viewType = view_type,
            .format = format,
            .components = .{
                .r = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = .{
                .aspectMask = aspect_mask,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = layer_count,
            },
        };

        var view: vk.VkImageView = undefined;
        if (vkCreateImageView(device, &create_info, null, &view) != vk.VK_SUCCESS) {
            return error.ImageViewCreationFailed;
        }

        return view;
    }

    /// Create a color image view (shorthand for COLOR_BIT aspect)
    pub fn createColor2D(
        device: vk.VkDevice,
        image: vk.VkImage,
        format: vk.VkFormat,
    ) !vk.VkImageView {
        return create2D(device, image, format, vk.VK_IMAGE_ASPECT_COLOR_BIT);
    }

    /// Create a depth image view (shorthand for DEPTH_BIT aspect)
    pub fn createDepth2D(
        device: vk.VkDevice,
        image: vk.VkImage,
        format: vk.VkFormat,
    ) !vk.VkImageView {
        return create2D(device, image, format, vk.VK_IMAGE_ASPECT_DEPTH_BIT);
    }
};
