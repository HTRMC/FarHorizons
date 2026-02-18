const std = @import("std");
pub const c = @import("c.zig").c;

// Re-export types
pub const VkInstance = c.VkInstance;
pub const VkPhysicalDevice = c.VkPhysicalDevice;
pub const VkDevice = c.VkDevice;
pub const VkQueue = c.VkQueue;
pub const VkSurfaceKHR = c.VkSurfaceKHR;
pub const VkSwapchainKHR = c.VkSwapchainKHR;
pub const VkImage = c.VkImage;
pub const VkImageView = c.VkImageView;
pub const VkImageCreateInfo = c.VkImageCreateInfo;
pub const VkFormat = c.VkFormat;
pub const VkExtent2D = c.VkExtent2D;
pub const VkResult = c.VkResult;
pub const VkBool32 = c.VkBool32;

pub const VkInstanceCreateInfo = c.VkInstanceCreateInfo;
pub const VkApplicationInfo = c.VkApplicationInfo;
pub const VkPhysicalDeviceProperties = c.VkPhysicalDeviceProperties;
pub const VkQueueFamilyProperties = c.VkQueueFamilyProperties;
pub const VkDeviceCreateInfo = c.VkDeviceCreateInfo;
pub const VkDeviceQueueCreateInfo = c.VkDeviceQueueCreateInfo;
pub const VkPhysicalDeviceVulkan12Features = c.VkPhysicalDeviceVulkan12Features;
pub const VkSurfaceCapabilitiesKHR = c.VkSurfaceCapabilitiesKHR;
pub const VkSurfaceFormatKHR = c.VkSurfaceFormatKHR;
pub const VkSwapchainCreateInfoKHR = c.VkSwapchainCreateInfoKHR;
pub const VkImageViewCreateInfo = c.VkImageViewCreateInfo;
pub const VkAllocationCallbacks = c.VkAllocationCallbacks;
pub const VkRenderPass = c.VkRenderPass;
pub const VkFramebuffer = c.VkFramebuffer;
pub const VkRenderPassCreateInfo = c.VkRenderPassCreateInfo;
pub const VkFramebufferCreateInfo = c.VkFramebufferCreateInfo;
pub const VkAttachmentDescription = c.VkAttachmentDescription;
pub const VkAttachmentReference = c.VkAttachmentReference;
pub const VkSubpassDescription = c.VkSubpassDescription;
pub const VkSubpassDependency = c.VkSubpassDependency;
pub const VkCommandPool = c.VkCommandPool;
pub const VkCommandBuffer = c.VkCommandBuffer;
pub const VkSemaphore = c.VkSemaphore;
pub const VkFence = c.VkFence;
pub const VkBuffer = c.VkBuffer;
pub const VkDeviceMemory = c.VkDeviceMemory;
pub const VkDeviceSize = c.VkDeviceSize;
pub const VkCommandPoolCreateInfo = c.VkCommandPoolCreateInfo;
pub const VkCommandBufferAllocateInfo = c.VkCommandBufferAllocateInfo;
pub const VkSemaphoreCreateInfo = c.VkSemaphoreCreateInfo;
pub const VkFenceCreateInfo = c.VkFenceCreateInfo;
pub const VkSubmitInfo = c.VkSubmitInfo;
pub const VkPresentInfoKHR = c.VkPresentInfoKHR;
pub const VkCommandBufferBeginInfo = c.VkCommandBufferBeginInfo;
pub const VkRenderPassBeginInfo = c.VkRenderPassBeginInfo;
pub const VkClearValue = c.VkClearValue;
pub const VkClearColorValue = c.VkClearColorValue;
pub const VkRect2D = c.VkRect2D;
pub const VkOffset2D = c.VkOffset2D;
pub const VkBufferCreateInfo = c.VkBufferCreateInfo;
pub const VkMemoryAllocateInfo = c.VkMemoryAllocateInfo;
pub const VkMemoryRequirements = c.VkMemoryRequirements;
pub const VkPhysicalDeviceMemoryProperties = c.VkPhysicalDeviceMemoryProperties;
pub const VkDrawIndirectCommand = c.VkDrawIndirectCommand;
pub const VkDrawIndexedIndirectCommand = c.VkDrawIndexedIndirectCommand;
pub const VkIndexType = c.VkIndexType;
pub const VkBufferMemoryBarrier = c.VkBufferMemoryBarrier;
pub const VkBufferCopy = c.VkBufferCopy;
pub const VkVertexInputBindingDescription = c.VkVertexInputBindingDescription;
pub const VkVertexInputAttributeDescription = c.VkVertexInputAttributeDescription;

// Texture and sampler types
pub const VkSampler = c.VkSampler;
pub const VkSamplerCreateInfo = c.VkSamplerCreateInfo;
pub const VkDescriptorImageInfo = c.VkDescriptorImageInfo;
pub const VkBufferImageCopy = c.VkBufferImageCopy;
pub const VkImageMemoryBarrier = c.VkImageMemoryBarrier;
pub const VkImageSubresourceRange = c.VkImageSubresourceRange;
pub const VkImageSubresourceLayers = c.VkImageSubresourceLayers;
pub const VkExtent3D = c.VkExtent3D;
pub const VkOffset3D = c.VkOffset3D;

// Dynamic rendering types (Vulkan 1.3)
pub const VkRenderingInfo = c.VkRenderingInfo;
pub const VkRenderingAttachmentInfo = c.VkRenderingAttachmentInfo;
pub const VkPipelineRenderingCreateInfo = c.VkPipelineRenderingCreateInfo;
pub const VkPhysicalDeviceVulkan13Features = c.VkPhysicalDeviceVulkan13Features;

// Bindless descriptor types
pub const VkDescriptorSetLayoutBindingFlagsCreateInfo = c.VkDescriptorSetLayoutBindingFlagsCreateInfo;
pub const VkDescriptorSetVariableDescriptorCountAllocateInfo = c.VkDescriptorSetVariableDescriptorCountAllocateInfo;

// Re-export constants
pub const VK_SUCCESS = c.VK_SUCCESS;
pub const VK_TRUE = c.VK_TRUE;
pub const VK_FALSE = c.VK_FALSE;
pub const VK_FORMAT_UNDEFINED = c.VK_FORMAT_UNDEFINED;
pub const VK_STRUCTURE_TYPE_APPLICATION_INFO = c.VK_STRUCTURE_TYPE_APPLICATION_INFO;
pub const VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES;
pub const VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
pub const VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
pub const VK_IMAGE_TYPE_2D = c.VK_IMAGE_TYPE_2D;
pub const VK_IMAGE_TILING_OPTIMAL = c.VK_IMAGE_TILING_OPTIMAL;
pub const VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT = c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
pub const VK_IMAGE_USAGE_SAMPLED_BIT = c.VK_IMAGE_USAGE_SAMPLED_BIT;
pub const VK_FORMAT_D32_SFLOAT = c.VK_FORMAT_D32_SFLOAT;
pub const VK_IMAGE_ASPECT_DEPTH_BIT = c.VK_IMAGE_ASPECT_DEPTH_BIT;
pub const VK_QUEUE_GRAPHICS_BIT = c.VK_QUEUE_GRAPHICS_BIT;
pub const VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
pub const VK_SHARING_MODE_EXCLUSIVE = c.VK_SHARING_MODE_EXCLUSIVE;
pub const VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
pub const VK_PRESENT_MODE_FIFO_KHR = c.VK_PRESENT_MODE_FIFO_KHR;
pub const VK_SUBOPTIMAL_KHR = c.VK_SUBOPTIMAL_KHR;
pub const VK_IMAGE_VIEW_TYPE_2D = c.VK_IMAGE_VIEW_TYPE_2D;
pub const VK_COMPONENT_SWIZZLE_IDENTITY = c.VK_COMPONENT_SWIZZLE_IDENTITY;
pub const VK_IMAGE_ASPECT_COLOR_BIT = c.VK_IMAGE_ASPECT_COLOR_BIT;
pub const VK_KHR_SWAPCHAIN_EXTENSION_NAME = c.VK_KHR_SWAPCHAIN_EXTENSION_NAME;
pub const VK_EXT_DEBUG_UTILS_EXTENSION_NAME = c.VK_EXT_DEBUG_UTILS_EXTENSION_NAME;
pub const VK_MAKE_VERSION = c.VK_MAKE_VERSION;
pub const VK_API_VERSION_1_2 = c.VK_API_VERSION_1_2;
pub const VK_API_VERSION_1_3 = c.VK_API_VERSION_1_3;
pub const VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
pub const VK_ATTACHMENT_LOAD_OP_CLEAR = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
pub const VK_ATTACHMENT_LOAD_OP_DONT_CARE = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
pub const VK_ATTACHMENT_STORE_OP_STORE = c.VK_ATTACHMENT_STORE_OP_STORE;
pub const VK_ATTACHMENT_STORE_OP_DONT_CARE = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
pub const VK_IMAGE_LAYOUT_UNDEFINED = c.VK_IMAGE_LAYOUT_UNDEFINED;
pub const VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
pub const VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
pub const VK_IMAGE_LAYOUT_PRESENT_SRC_KHR = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
pub const VK_PIPELINE_BIND_POINT_GRAPHICS = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
pub const VK_SUBPASS_EXTERNAL = c.VK_SUBPASS_EXTERNAL;
pub const VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
pub const VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT = c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
pub const VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
pub const VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT = c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT;
pub const VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT = c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
pub const VK_SAMPLE_COUNT_1_BIT = c.VK_SAMPLE_COUNT_1_BIT;
pub const VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
pub const VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_FENCE_CREATE_INFO = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_SUBMIT_INFO = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
pub const VK_STRUCTURE_TYPE_PRESENT_INFO_KHR = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
pub const VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
pub const VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
pub const VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
pub const VK_COMMAND_BUFFER_LEVEL_PRIMARY = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
pub const VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
pub const VK_FENCE_CREATE_SIGNALED_BIT = c.VK_FENCE_CREATE_SIGNALED_BIT;
pub const VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT = c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
pub const VK_SUBPASS_CONTENTS_INLINE = c.VK_SUBPASS_CONTENTS_INLINE;

// Buffer and memory constants
pub const VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
pub const VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT = c.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT;
pub const VK_BUFFER_USAGE_STORAGE_BUFFER_BIT = c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
pub const VK_BUFFER_USAGE_TRANSFER_SRC_BIT = c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
pub const VK_BUFFER_USAGE_TRANSFER_DST_BIT = c.VK_BUFFER_USAGE_TRANSFER_DST_BIT;
pub const VK_BUFFER_USAGE_VERTEX_BUFFER_BIT = c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT;
pub const VK_BUFFER_USAGE_INDEX_BUFFER_BIT = c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT;
pub const VK_INDEX_TYPE_UINT16 = c.VK_INDEX_TYPE_UINT16;
pub const VK_INDEX_TYPE_UINT32 = c.VK_INDEX_TYPE_UINT32;
pub const VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT;
pub const VK_MEMORY_PROPERTY_HOST_COHERENT_BIT = c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
pub const VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT = c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
pub const VK_VERTEX_INPUT_RATE_VERTEX = c.VK_VERTEX_INPUT_RATE_VERTEX;
pub const VK_FORMAT_R32G32B32_SFLOAT = c.VK_FORMAT_R32G32B32_SFLOAT;
pub const VK_FORMAT_R32G32_SFLOAT = c.VK_FORMAT_R32G32_SFLOAT;
pub const VK_FORMAT_R8G8B8A8_SRGB = c.VK_FORMAT_R8G8B8A8_SRGB;

// Image layout constants for textures
pub const VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
pub const VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
pub const VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL = c.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL;

// Image usage
pub const VK_IMAGE_USAGE_TRANSFER_DST_BIT = c.VK_IMAGE_USAGE_TRANSFER_DST_BIT;

// Descriptor type
pub const VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;

// Sampler constants
pub const VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
pub const VK_FILTER_NEAREST = c.VK_FILTER_NEAREST;
pub const VK_SAMPLER_MIPMAP_MODE_NEAREST = c.VK_SAMPLER_MIPMAP_MODE_NEAREST;
pub const VK_SAMPLER_ADDRESS_MODE_REPEAT = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
pub const VK_BORDER_COLOR_INT_OPAQUE_BLACK = c.VK_BORDER_COLOR_INT_OPAQUE_BLACK;

// Barrier constants
pub const VK_PIPELINE_STAGE_TRANSFER_BIT = c.VK_PIPELINE_STAGE_TRANSFER_BIT;
pub const VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
pub const VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT = c.VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT;
pub const VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT = c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT;
pub const VK_ACCESS_TRANSFER_WRITE_BIT = c.VK_ACCESS_TRANSFER_WRITE_BIT;
pub const VK_ACCESS_SHADER_READ_BIT = c.VK_ACCESS_SHADER_READ_BIT;
pub const VK_ACCESS_INDIRECT_COMMAND_READ_BIT = c.VK_ACCESS_INDIRECT_COMMAND_READ_BIT;
pub const VK_ACCESS_SHADER_WRITE_BIT = c.VK_ACCESS_SHADER_WRITE_BIT;
pub const VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
pub const VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER = c.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
pub const VK_QUEUE_FAMILY_IGNORED = c.VK_QUEUE_FAMILY_IGNORED;

// Dynamic rendering constants (Vulkan 1.3)
pub const VK_STRUCTURE_TYPE_RENDERING_INFO = c.VK_STRUCTURE_TYPE_RENDERING_INFO;
pub const VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
pub const VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO = c.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES;

// Bindless descriptor flags
pub const VK_DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT = c.VK_DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT;
pub const VK_DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT = c.VK_DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT;
pub const VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT = c.VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT;
pub const VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT = c.VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT;
pub const VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT = c.VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO;

// Shader and pipeline types
pub const VkShaderModule = c.VkShaderModule;
pub const VkPipeline = c.VkPipeline;
pub const VkPipelineLayout = c.VkPipelineLayout;
pub const VkDescriptorSetLayout = c.VkDescriptorSetLayout;
pub const VkDescriptorPool = c.VkDescriptorPool;
pub const VkDescriptorSet = c.VkDescriptorSet;
pub const VkShaderModuleCreateInfo = c.VkShaderModuleCreateInfo;
pub const VkPipelineShaderStageCreateInfo = c.VkPipelineShaderStageCreateInfo;
pub const VkPipelineVertexInputStateCreateInfo = c.VkPipelineVertexInputStateCreateInfo;
pub const VkPipelineInputAssemblyStateCreateInfo = c.VkPipelineInputAssemblyStateCreateInfo;
pub const VkPipelineViewportStateCreateInfo = c.VkPipelineViewportStateCreateInfo;
pub const VkPipelineRasterizationStateCreateInfo = c.VkPipelineRasterizationStateCreateInfo;
pub const VkPipelineMultisampleStateCreateInfo = c.VkPipelineMultisampleStateCreateInfo;
pub const VkPipelineColorBlendAttachmentState = c.VkPipelineColorBlendAttachmentState;
pub const VkPipelineColorBlendStateCreateInfo = c.VkPipelineColorBlendStateCreateInfo;
pub const VkPipelineDepthStencilStateCreateInfo = c.VkPipelineDepthStencilStateCreateInfo;
pub const VkStencilOpState = c.VkStencilOpState;
pub const VkPipelineLayoutCreateInfo = c.VkPipelineLayoutCreateInfo;
pub const VkPushConstantRange = c.VkPushConstantRange;
pub const VkGraphicsPipelineCreateInfo = c.VkGraphicsPipelineCreateInfo;
pub const VkComputePipelineCreateInfo = c.VkComputePipelineCreateInfo;
pub const VkDescriptorSetLayoutBinding = c.VkDescriptorSetLayoutBinding;
pub const VkDescriptorSetLayoutCreateInfo = c.VkDescriptorSetLayoutCreateInfo;
pub const VkDescriptorPoolSize = c.VkDescriptorPoolSize;
pub const VkDescriptorPoolCreateInfo = c.VkDescriptorPoolCreateInfo;
pub const VkDescriptorSetAllocateInfo = c.VkDescriptorSetAllocateInfo;
pub const VkWriteDescriptorSet = c.VkWriteDescriptorSet;
pub const VkDescriptorBufferInfo = c.VkDescriptorBufferInfo;
pub const VkViewport = c.VkViewport;
pub const VkShaderStageFlagBits = c.VkShaderStageFlagBits;

// Shader and pipeline constants
pub const VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
pub const VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
pub const VK_SHADER_STAGE_VERTEX_BIT = c.VK_SHADER_STAGE_VERTEX_BIT;
pub const VK_SHADER_STAGE_FRAGMENT_BIT = c.VK_SHADER_STAGE_FRAGMENT_BIT;
pub const VK_SHADER_STAGE_COMPUTE_BIT = c.VK_SHADER_STAGE_COMPUTE_BIT;
pub const VK_DESCRIPTOR_TYPE_STORAGE_BUFFER = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
pub const VK_PIPELINE_BIND_POINT_COMPUTE = c.VK_PIPELINE_BIND_POINT_COMPUTE;
pub const VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
pub const VK_PRIMITIVE_TOPOLOGY_LINE_LIST = c.VK_PRIMITIVE_TOPOLOGY_LINE_LIST;
pub const VK_POLYGON_MODE_FILL = c.VK_POLYGON_MODE_FILL;
pub const VK_CULL_MODE_BACK_BIT = c.VK_CULL_MODE_BACK_BIT;
pub const VK_CULL_MODE_NONE = c.VK_CULL_MODE_NONE;
pub const VK_FRONT_FACE_CLOCKWISE = c.VK_FRONT_FACE_CLOCKWISE;
pub const VK_FRONT_FACE_COUNTER_CLOCKWISE = c.VK_FRONT_FACE_COUNTER_CLOCKWISE;
pub const VK_BLEND_FACTOR_ONE = c.VK_BLEND_FACTOR_ONE;
pub const VK_BLEND_FACTOR_ZERO = c.VK_BLEND_FACTOR_ZERO;
pub const VK_BLEND_FACTOR_SRC_ALPHA = c.VK_BLEND_FACTOR_SRC_ALPHA;
pub const VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
pub const VK_BLEND_OP_ADD = c.VK_BLEND_OP_ADD;
pub const VK_COMPARE_OP_LESS = c.VK_COMPARE_OP_LESS;
pub const VK_COMPARE_OP_LESS_OR_EQUAL = c.VK_COMPARE_OP_LESS_OR_EQUAL;
pub const VK_COLOR_COMPONENT_R_BIT = c.VK_COLOR_COMPONENT_R_BIT;
pub const VK_COLOR_COMPONENT_G_BIT = c.VK_COLOR_COMPONENT_G_BIT;
pub const VK_COLOR_COMPONENT_B_BIT = c.VK_COLOR_COMPONENT_B_BIT;
pub const VK_COLOR_COMPONENT_A_BIT = c.VK_COLOR_COMPONENT_A_BIT;

// Debug utils types
pub const VkDebugUtilsMessengerEXT = c.VkDebugUtilsMessengerEXT;
pub const VkDebugUtilsMessengerCreateInfoEXT = c.VkDebugUtilsMessengerCreateInfoEXT;
pub const VkDebugUtilsMessageSeverityFlagBitsEXT = c.VkDebugUtilsMessageSeverityFlagBitsEXT;
pub const VkDebugUtilsMessageTypeFlagsEXT = c.VkDebugUtilsMessageTypeFlagsEXT;
pub const VkDebugUtilsMessengerCallbackDataEXT = c.VkDebugUtilsMessengerCallbackDataEXT;

// Debug utils constants
pub const VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT = c.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT;
pub const VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT;
pub const VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT;
pub const VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT;
pub const VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
pub const VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT = c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT;
pub const VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT = c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT;
pub const VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT = c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;

// Error types
pub const VulkanError = error{
    FunctionNotLoaded,
    // Core errors
    OutOfHostMemory,
    OutOfDeviceMemory,
    InitializationFailed,
    DeviceLost,
    MemoryMapFailed,
    LayerNotPresent,
    ExtensionNotPresent,
    FeatureNotPresent,
    IncompatibleDriver,
    TooManyObjects,
    FormatNotSupported,
    FragmentedPool,
    OutOfPoolMemory,
    InvalidExternalHandle,
    Fragmentation,
    InvalidOpaqueCaptureAddress,
    // Surface/Swapchain errors (KHR)
    SurfaceLostKHR,
    NativeWindowInUseKHR,
    OutOfDateKHR,
    IncompatibleDisplayKHR,
    FullScreenExclusiveModeLostEXT,
    // Validation and shader errors
    ValidationFailedEXT,
    InvalidShaderNV,
    IncompatibleShaderBinaryEXT,
    // Pipeline and rendering errors
    PipelineCompileRequiredEXT,
    InvalidDrmFormatModifierPlaneLayoutEXT,
    NotPermittedEXT,
    // Compression errors
    CompressionExhaustedEXT,
    // Video errors
    ImageUsageNotSupportedKHR,
    VideoPictureLayoutNotSupportedKHR,
    VideoProfileOperationNotSupportedKHR,
    VideoProfileFormatNotSupportedKHR,
    VideoProfileCodecNotSupportedKHR,
    VideoStdVersionNotSupportedKHR,
    // Unknown fallback
    Unknown,
};

fn vkResultToError(result: VkResult) VulkanError!void {
    return switch (result) {
        c.VK_SUCCESS, c.VK_SUBOPTIMAL_KHR => {},
        // Core errors
        c.VK_ERROR_OUT_OF_HOST_MEMORY => error.OutOfHostMemory,
        c.VK_ERROR_OUT_OF_DEVICE_MEMORY => error.OutOfDeviceMemory,
        c.VK_ERROR_INITIALIZATION_FAILED => error.InitializationFailed,
        c.VK_ERROR_DEVICE_LOST => error.DeviceLost,
        c.VK_ERROR_MEMORY_MAP_FAILED => error.MemoryMapFailed,
        c.VK_ERROR_LAYER_NOT_PRESENT => error.LayerNotPresent,
        c.VK_ERROR_EXTENSION_NOT_PRESENT => error.ExtensionNotPresent,
        c.VK_ERROR_FEATURE_NOT_PRESENT => error.FeatureNotPresent,
        c.VK_ERROR_INCOMPATIBLE_DRIVER => error.IncompatibleDriver,
        c.VK_ERROR_TOO_MANY_OBJECTS => error.TooManyObjects,
        c.VK_ERROR_FORMAT_NOT_SUPPORTED => error.FormatNotSupported,
        c.VK_ERROR_FRAGMENTED_POOL => error.FragmentedPool,
        c.VK_ERROR_OUT_OF_POOL_MEMORY => error.OutOfPoolMemory,
        c.VK_ERROR_INVALID_EXTERNAL_HANDLE => error.InvalidExternalHandle,
        c.VK_ERROR_FRAGMENTATION => error.Fragmentation,
        c.VK_ERROR_INVALID_OPAQUE_CAPTURE_ADDRESS => error.InvalidOpaqueCaptureAddress,
        // Surface/Swapchain errors
        c.VK_ERROR_SURFACE_LOST_KHR => error.SurfaceLostKHR,
        c.VK_ERROR_NATIVE_WINDOW_IN_USE_KHR => error.NativeWindowInUseKHR,
        c.VK_ERROR_OUT_OF_DATE_KHR => error.OutOfDateKHR,
        c.VK_ERROR_INCOMPATIBLE_DISPLAY_KHR => error.IncompatibleDisplayKHR,
        c.VK_ERROR_VALIDATION_FAILED_EXT => error.ValidationFailedEXT,
        c.VK_ERROR_INVALID_SHADER_NV => error.InvalidShaderNV,
        c.VK_ERROR_INVALID_DRM_FORMAT_MODIFIER_PLANE_LAYOUT_EXT => error.InvalidDrmFormatModifierPlaneLayoutEXT,
        c.VK_ERROR_NOT_PERMITTED_KHR => error.NotPermittedEXT,
        c.VK_ERROR_FULL_SCREEN_EXCLUSIVE_MODE_LOST_EXT => error.FullScreenExclusiveModeLostEXT,
        c.VK_ERROR_COMPRESSION_EXHAUSTED_EXT => error.CompressionExhaustedEXT,
        c.VK_ERROR_INCOMPATIBLE_SHADER_BINARY_EXT => error.IncompatibleShaderBinaryEXT,
        else => {
            std.log.err("Unhandled VkResult: {d} (0x{x})", .{ result, result });
            return error.Unknown;
        },
    };
}

// Safe Volk initialization
pub fn initialize() VulkanError!void {
    const result = c.volkInitialize();
    try vkResultToError(result);
}

pub fn loadInstance(instance: VkInstance) void {
    c.volkLoadInstance(instance);
}

pub fn loadDevice(device: VkDevice) void {
    c.volkLoadDevice(device);
}

// Safe Vulkan function wrappers
pub fn createInstance(
    create_info: *const VkInstanceCreateInfo,
    allocator: ?*const VkAllocationCallbacks,
) VulkanError!VkInstance {
    const fn_ptr = c.vkCreateInstance orelse return error.FunctionNotLoaded;
    var instance: VkInstance = undefined;
    const result = fn_ptr(create_info, allocator, &instance);
    try vkResultToError(result);
    return instance;
}

pub fn destroyInstance(instance: VkInstance, allocator: ?*const VkAllocationCallbacks) void {
    if (c.vkDestroyInstance) |fn_ptr| {
        fn_ptr(instance, allocator);
    }
}

pub fn enumeratePhysicalDevices(
    instance: VkInstance,
    device_count: *u32,
    devices: ?[*]VkPhysicalDevice,
) VulkanError!void {
    const fn_ptr = c.vkEnumeratePhysicalDevices orelse return error.FunctionNotLoaded;
    const result = fn_ptr(instance, device_count, devices);
    try vkResultToError(result);
}

pub fn getPhysicalDeviceProperties(
    physical_device: VkPhysicalDevice,
    properties: *VkPhysicalDeviceProperties,
) VulkanError!void {
    const fn_ptr = c.vkGetPhysicalDeviceProperties orelse return error.FunctionNotLoaded;
    fn_ptr(physical_device, properties);
}

pub fn getPhysicalDeviceQueueFamilyProperties(
    physical_device: VkPhysicalDevice,
    queue_family_count: *u32,
    queue_families: ?[*]VkQueueFamilyProperties,
) VulkanError!void {
    const fn_ptr = c.vkGetPhysicalDeviceQueueFamilyProperties orelse return error.FunctionNotLoaded;
    fn_ptr(physical_device, queue_family_count, queue_families);
}

pub fn getPhysicalDeviceSurfaceSupportKHR(
    physical_device: VkPhysicalDevice,
    queue_family_index: u32,
    surface: VkSurfaceKHR,
    supported: *VkBool32,
) VulkanError!void {
    const fn_ptr = c.vkGetPhysicalDeviceSurfaceSupportKHR orelse return error.FunctionNotLoaded;
    const result = fn_ptr(physical_device, queue_family_index, surface, supported);
    try vkResultToError(result);
}

pub fn createDevice(
    physical_device: VkPhysicalDevice,
    create_info: *const VkDeviceCreateInfo,
    allocator: ?*const VkAllocationCallbacks,
) VulkanError!VkDevice {
    const fn_ptr = c.vkCreateDevice orelse return error.FunctionNotLoaded;
    var device: VkDevice = undefined;
    const result = fn_ptr(physical_device, create_info, allocator, &device);
    try vkResultToError(result);
    return device;
}

pub fn destroyDevice(device: VkDevice, allocator: ?*const VkAllocationCallbacks) void {
    if (c.vkDestroyDevice) |fn_ptr| {
        fn_ptr(device, allocator);
    }
}

pub fn getDeviceQueue(
    device: VkDevice,
    queue_family_index: u32,
    queue_index: u32,
    queue: *VkQueue,
) void {
    if (c.vkGetDeviceQueue) |fn_ptr| {
        fn_ptr(device, queue_family_index, queue_index, queue);
    }
}

pub fn deviceWaitIdle(device: VkDevice) VulkanError!void {
    const fn_ptr = c.vkDeviceWaitIdle orelse return error.FunctionNotLoaded;
    const result = fn_ptr(device);
    try vkResultToError(result);
}

pub fn destroySurfaceKHR(
    instance: VkInstance,
    surface: VkSurfaceKHR,
    allocator: ?*const VkAllocationCallbacks,
) void {
    if (c.vkDestroySurfaceKHR) |fn_ptr| {
        fn_ptr(instance, surface, allocator);
    }
}

pub fn getPhysicalDeviceSurfaceCapabilitiesKHR(
    physical_device: VkPhysicalDevice,
    surface: VkSurfaceKHR,
    capabilities: *VkSurfaceCapabilitiesKHR,
) VulkanError!void {
    const fn_ptr = c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR orelse return error.FunctionNotLoaded;
    const result = fn_ptr(physical_device, surface, capabilities);
    try vkResultToError(result);
}

pub fn getPhysicalDeviceSurfaceFormatsKHR(
    physical_device: VkPhysicalDevice,
    surface: VkSurfaceKHR,
    format_count: *u32,
    formats: ?[*]VkSurfaceFormatKHR,
) VulkanError!void {
    const fn_ptr = c.vkGetPhysicalDeviceSurfaceFormatsKHR orelse return error.FunctionNotLoaded;
    const result = fn_ptr(physical_device, surface, format_count, formats);
    try vkResultToError(result);
}

pub fn createSwapchainKHR(
    device: VkDevice,
    create_info: *const VkSwapchainCreateInfoKHR,
    allocator: ?*const VkAllocationCallbacks,
) VulkanError!VkSwapchainKHR {
    const fn_ptr = c.vkCreateSwapchainKHR orelse return error.FunctionNotLoaded;
    var swapchain: VkSwapchainKHR = undefined;
    const result = fn_ptr(device, create_info, allocator, &swapchain);
    try vkResultToError(result);
    return swapchain;
}

pub fn destroySwapchainKHR(
    device: VkDevice,
    swapchain: VkSwapchainKHR,
    allocator: ?*const VkAllocationCallbacks,
) void {
    if (c.vkDestroySwapchainKHR) |fn_ptr| {
        fn_ptr(device, swapchain, allocator);
    }
}

pub fn getSwapchainImagesKHR(
    device: VkDevice,
    swapchain: VkSwapchainKHR,
    image_count: *u32,
    images: ?[*]VkImage,
) VulkanError!void {
    const fn_ptr = c.vkGetSwapchainImagesKHR orelse return error.FunctionNotLoaded;
    const result = fn_ptr(device, swapchain, image_count, images);
    try vkResultToError(result);
}

pub fn createImageView(
    device: VkDevice,
    create_info: *const VkImageViewCreateInfo,
    allocator: ?*const VkAllocationCallbacks,
) VulkanError!VkImageView {
    const fn_ptr = c.vkCreateImageView orelse return error.FunctionNotLoaded;
    var image_view: VkImageView = undefined;
    const result = fn_ptr(device, create_info, allocator, &image_view);
    try vkResultToError(result);
    return image_view;
}

pub fn destroyImageView(
    device: VkDevice,
    image_view: VkImageView,
    allocator: ?*const VkAllocationCallbacks,
) void {
    if (c.vkDestroyImageView) |fn_ptr| {
        fn_ptr(device, image_view, allocator);
    }
}

// Debug utils functions
pub fn createDebugUtilsMessengerEXT(
    instance: VkInstance,
    create_info: *const VkDebugUtilsMessengerCreateInfoEXT,
    allocator: ?*const VkAllocationCallbacks,
) VulkanError!VkDebugUtilsMessengerEXT {
    const fn_ptr = c.vkCreateDebugUtilsMessengerEXT orelse return error.FunctionNotLoaded;
    var messenger: VkDebugUtilsMessengerEXT = undefined;
    const result = fn_ptr(instance, create_info, allocator, &messenger);
    try vkResultToError(result);
    return messenger;
}

pub fn destroyDebugUtilsMessengerEXT(
    instance: VkInstance,
    messenger: VkDebugUtilsMessengerEXT,
    allocator: ?*const VkAllocationCallbacks,
) void {
    if (c.vkDestroyDebugUtilsMessengerEXT) |fn_ptr| {
        fn_ptr(instance, messenger, allocator);
    }
}

pub fn createRenderPass(
    device: VkDevice,
    create_info: *const VkRenderPassCreateInfo,
    allocator: ?*const VkAllocationCallbacks,
) VulkanError!VkRenderPass {
    const fn_ptr = c.vkCreateRenderPass orelse return error.FunctionNotLoaded;
    var render_pass: VkRenderPass = undefined;
    const result = fn_ptr(device, create_info, allocator, &render_pass);
    try vkResultToError(result);
    return render_pass;
}

pub fn destroyRenderPass(
    device: VkDevice,
    render_pass: VkRenderPass,
    allocator: ?*const VkAllocationCallbacks,
) void {
    if (c.vkDestroyRenderPass) |fn_ptr| {
        fn_ptr(device, render_pass, allocator);
    }
}

pub fn createFramebuffer(
    device: VkDevice,
    create_info: *const VkFramebufferCreateInfo,
    allocator: ?*const VkAllocationCallbacks,
) VulkanError!VkFramebuffer {
    const fn_ptr = c.vkCreateFramebuffer orelse return error.FunctionNotLoaded;
    var framebuffer: VkFramebuffer = undefined;
    const result = fn_ptr(device, create_info, allocator, &framebuffer);
    try vkResultToError(result);
    return framebuffer;
}

pub fn destroyFramebuffer(
    device: VkDevice,
    framebuffer: VkFramebuffer,
    allocator: ?*const VkAllocationCallbacks,
) void {
    if (c.vkDestroyFramebuffer) |fn_ptr| {
        fn_ptr(device, framebuffer, allocator);
    }
}

pub fn createCommandPool(
    device: VkDevice,
    create_info: *const VkCommandPoolCreateInfo,
    allocator: ?*const VkAllocationCallbacks,
) VulkanError!VkCommandPool {
    const fn_ptr = c.vkCreateCommandPool orelse return error.FunctionNotLoaded;
    var command_pool: VkCommandPool = undefined;
    const result = fn_ptr(device, create_info, allocator, &command_pool);
    try vkResultToError(result);
    return command_pool;
}

pub fn destroyCommandPool(
    device: VkDevice,
    command_pool: VkCommandPool,
    allocator: ?*const VkAllocationCallbacks,
) void {
    if (c.vkDestroyCommandPool) |fn_ptr| {
        fn_ptr(device, command_pool, allocator);
    }
}

pub fn allocateCommandBuffers(
    device: VkDevice,
    allocate_info: *const VkCommandBufferAllocateInfo,
    command_buffers: [*]VkCommandBuffer,
) VulkanError!void {
    const fn_ptr = c.vkAllocateCommandBuffers orelse return error.FunctionNotLoaded;
    const result = fn_ptr(device, allocate_info, command_buffers);
    try vkResultToError(result);
}

pub fn freeCommandBuffers(
    device: VkDevice,
    command_pool: VkCommandPool,
    command_buffer_count: u32,
    command_buffers: [*]const VkCommandBuffer,
) void {
    if (c.vkFreeCommandBuffers) |fn_ptr| {
        fn_ptr(device, command_pool, command_buffer_count, command_buffers);
    }
}

pub fn createSemaphore(
    device: VkDevice,
    create_info: *const VkSemaphoreCreateInfo,
    allocator: ?*const VkAllocationCallbacks,
) VulkanError!VkSemaphore {
    const fn_ptr = c.vkCreateSemaphore orelse return error.FunctionNotLoaded;
    var semaphore: VkSemaphore = undefined;
    const result = fn_ptr(device, create_info, allocator, &semaphore);
    try vkResultToError(result);
    return semaphore;
}

pub fn destroySemaphore(
    device: VkDevice,
    semaphore: VkSemaphore,
    allocator: ?*const VkAllocationCallbacks,
) void {
    if (c.vkDestroySemaphore) |fn_ptr| {
        fn_ptr(device, semaphore, allocator);
    }
}

pub fn createFence(
    device: VkDevice,
    create_info: *const VkFenceCreateInfo,
    allocator: ?*const VkAllocationCallbacks,
) VulkanError!VkFence {
    const fn_ptr = c.vkCreateFence orelse return error.FunctionNotLoaded;
    var fence: VkFence = undefined;
    const result = fn_ptr(device, create_info, allocator, &fence);
    try vkResultToError(result);
    return fence;
}

pub fn destroyFence(
    device: VkDevice,
    fence: VkFence,
    allocator: ?*const VkAllocationCallbacks,
) void {
    if (c.vkDestroyFence) |fn_ptr| {
        fn_ptr(device, fence, allocator);
    }
}

pub fn waitForFences(
    device: VkDevice,
    fence_count: u32,
    fences: [*]const VkFence,
    wait_all: VkBool32,
    timeout: u64,
) VulkanError!void {
    const fn_ptr = c.vkWaitForFences orelse return error.FunctionNotLoaded;
    const result = fn_ptr(device, fence_count, fences, wait_all, timeout);
    try vkResultToError(result);
}

pub fn resetFences(
    device: VkDevice,
    fence_count: u32,
    fences: [*]const VkFence,
) VulkanError!void {
    const fn_ptr = c.vkResetFences orelse return error.FunctionNotLoaded;
    const result = fn_ptr(device, fence_count, fences);
    try vkResultToError(result);
}

pub fn acquireNextImageKHR(
    device: VkDevice,
    swapchain: VkSwapchainKHR,
    timeout: u64,
    semaphore: VkSemaphore,
    fence: VkFence,
    image_index: *u32,
) VulkanError!void {
    const fn_ptr = c.vkAcquireNextImageKHR orelse return error.FunctionNotLoaded;
    const result = fn_ptr(device, swapchain, timeout, semaphore, fence, image_index);
    try vkResultToError(result);
}

pub fn acquireNextImageKHRResult(
    device: VkDevice,
    swapchain: VkSwapchainKHR,
    timeout: u64,
    semaphore: VkSemaphore,
    fence: VkFence,
    image_index: *u32,
) VulkanError!VkResult {
    const fn_ptr = c.vkAcquireNextImageKHR orelse return error.FunctionNotLoaded;
    const result = fn_ptr(device, swapchain, timeout, semaphore, fence, image_index);
    try vkResultToError(result);
    return result;
}

pub fn queueSubmit(
    queue: VkQueue,
    submit_count: u32,
    submits: ?[*]const VkSubmitInfo,
    fence: VkFence,
) VulkanError!void {
    const fn_ptr = c.vkQueueSubmit orelse return error.FunctionNotLoaded;
    const result = fn_ptr(queue, submit_count, submits, fence);
    try vkResultToError(result);
}

pub fn queueWaitIdle(queue: VkQueue) VulkanError!void {
    const fn_ptr = c.vkQueueWaitIdle orelse return error.FunctionNotLoaded;
    const result = fn_ptr(queue);
    try vkResultToError(result);
}

pub fn queuePresentKHR(
    queue: VkQueue,
    present_info: *const VkPresentInfoKHR,
) VulkanError!void {
    const fn_ptr = c.vkQueuePresentKHR orelse return error.FunctionNotLoaded;
    const result = fn_ptr(queue, present_info);
    try vkResultToError(result);
}

pub fn queuePresentKHRResult(
    queue: VkQueue,
    present_info: *const VkPresentInfoKHR,
) VulkanError!VkResult {
    const fn_ptr = c.vkQueuePresentKHR orelse return error.FunctionNotLoaded;
    const result = fn_ptr(queue, present_info);
    try vkResultToError(result);
    return result;
}

pub fn beginCommandBuffer(
    command_buffer: VkCommandBuffer,
    begin_info: *const VkCommandBufferBeginInfo,
) VulkanError!void {
    const fn_ptr = c.vkBeginCommandBuffer orelse return error.FunctionNotLoaded;
    const result = fn_ptr(command_buffer, begin_info);
    try vkResultToError(result);
}

pub fn endCommandBuffer(
    command_buffer: VkCommandBuffer,
) VulkanError!void {
    const fn_ptr = c.vkEndCommandBuffer orelse return error.FunctionNotLoaded;
    const result = fn_ptr(command_buffer);
    try vkResultToError(result);
}

pub fn cmdBeginRenderPass(
    command_buffer: VkCommandBuffer,
    render_pass_info: *const VkRenderPassBeginInfo,
    contents: c.VkSubpassContents,
) void {
    if (c.vkCmdBeginRenderPass) |fn_ptr| {
        fn_ptr(command_buffer, render_pass_info, contents);
    }
}

pub fn cmdEndRenderPass(
    command_buffer: VkCommandBuffer,
) void {
    if (c.vkCmdEndRenderPass) |fn_ptr| {
        fn_ptr(command_buffer);
    }
}

pub fn cmdDraw(
    command_buffer: VkCommandBuffer,
    vertex_count: u32,
    instance_count: u32,
    first_vertex: u32,
    first_instance: u32,
) void {
    if (c.vkCmdDraw) |fn_ptr| {
        fn_ptr(command_buffer, vertex_count, instance_count, first_vertex, first_instance);
    }
}

pub fn cmdBindVertexBuffers(
    command_buffer: VkCommandBuffer,
    first_binding: u32,
    binding_count: u32,
    buffers: [*]const VkBuffer,
    offsets: [*]const VkDeviceSize,
) void {
    if (c.vkCmdBindVertexBuffers) |fn_ptr| {
        fn_ptr(command_buffer, first_binding, binding_count, buffers, offsets);
    }
}

pub fn cmdBindIndexBuffer(
    command_buffer: VkCommandBuffer,
    buffer: VkBuffer,
    offset: VkDeviceSize,
    index_type: VkIndexType,
) void {
    if (c.vkCmdBindIndexBuffer) |fn_ptr| {
        fn_ptr(command_buffer, buffer, offset, index_type);
    }
}

pub fn cmdDrawIndexed(
    command_buffer: VkCommandBuffer,
    index_count: u32,
    instance_count: u32,
    first_index: u32,
    vertex_offset: i32,
    first_instance: u32,
) void {
    if (c.vkCmdDrawIndexed) |fn_ptr| {
        fn_ptr(command_buffer, index_count, instance_count, first_index, vertex_offset, first_instance);
    }
}

pub fn cmdCopyBuffer(
    command_buffer: VkCommandBuffer,
    src_buffer: VkBuffer,
    dst_buffer: VkBuffer,
    region_count: u32,
    regions: [*]const VkBufferCopy,
) void {
    if (c.vkCmdCopyBuffer) |fn_ptr| {
        fn_ptr(command_buffer, src_buffer, dst_buffer, region_count, regions);
    }
}

pub fn createShaderModule(
    device: VkDevice,
    create_info: *const VkShaderModuleCreateInfo,
    allocator: ?*const VkAllocationCallbacks,
) VulkanError!VkShaderModule {
    const fn_ptr = c.vkCreateShaderModule orelse return error.FunctionNotLoaded;
    var shader_module: VkShaderModule = undefined;
    const result = fn_ptr(device, create_info, allocator, &shader_module);
    try vkResultToError(result);
    return shader_module;
}

pub fn destroyShaderModule(
    device: VkDevice,
    shader_module: VkShaderModule,
    allocator: ?*const VkAllocationCallbacks,
) void {
    if (c.vkDestroyShaderModule) |fn_ptr| {
        fn_ptr(device, shader_module, allocator);
    }
}

pub fn createPipelineLayout(
    device: VkDevice,
    create_info: *const VkPipelineLayoutCreateInfo,
    allocator: ?*const VkAllocationCallbacks,
) VulkanError!VkPipelineLayout {
    const fn_ptr = c.vkCreatePipelineLayout orelse return error.FunctionNotLoaded;
    var pipeline_layout: VkPipelineLayout = undefined;
    const result = fn_ptr(device, create_info, allocator, &pipeline_layout);
    try vkResultToError(result);
    return pipeline_layout;
}

pub fn destroyPipelineLayout(
    device: VkDevice,
    pipeline_layout: VkPipelineLayout,
    allocator: ?*const VkAllocationCallbacks,
) void {
    if (c.vkDestroyPipelineLayout) |fn_ptr| {
        fn_ptr(device, pipeline_layout, allocator);
    }
}

pub fn createGraphicsPipelines(
    device: VkDevice,
    pipeline_cache: c.VkPipelineCache,
    create_info_count: u32,
    create_infos: [*]const VkGraphicsPipelineCreateInfo,
    allocator: ?*const VkAllocationCallbacks,
    pipelines: [*]VkPipeline,
) VulkanError!void {
    const fn_ptr = c.vkCreateGraphicsPipelines orelse return error.FunctionNotLoaded;
    const result = fn_ptr(device, pipeline_cache, create_info_count, create_infos, allocator, pipelines);
    try vkResultToError(result);
}

pub fn destroyPipeline(
    device: VkDevice,
    pipeline: VkPipeline,
    allocator: ?*const VkAllocationCallbacks,
) void {
    if (c.vkDestroyPipeline) |fn_ptr| {
        fn_ptr(device, pipeline, allocator);
    }
}

pub fn cmdBindPipeline(
    command_buffer: VkCommandBuffer,
    pipeline_bind_point: c.VkPipelineBindPoint,
    pipeline: VkPipeline,
) void {
    if (c.vkCmdBindPipeline) |fn_ptr| {
        fn_ptr(command_buffer, pipeline_bind_point, pipeline);
    }
}

pub fn cmdDrawIndirectCount(
    command_buffer: VkCommandBuffer,
    buffer: VkBuffer,
    offset: VkDeviceSize,
    count_buffer: VkBuffer,
    count_buffer_offset: VkDeviceSize,
    max_draw_count: u32,
    stride: u32,
) void {
    if (c.vkCmdDrawIndirectCount) |fn_ptr| {
        fn_ptr(command_buffer, buffer, offset, count_buffer, count_buffer_offset, max_draw_count, stride);
    }
}

pub fn cmdDrawIndexedIndirectCount(
    command_buffer: VkCommandBuffer,
    buffer: VkBuffer,
    offset: VkDeviceSize,
    count_buffer: VkBuffer,
    count_buffer_offset: VkDeviceSize,
    max_draw_count: u32,
    stride: u32,
) void {
    if (c.vkCmdDrawIndexedIndirectCount) |fn_ptr| {
        fn_ptr(command_buffer, buffer, offset, count_buffer, count_buffer_offset, max_draw_count, stride);
    }
}

pub fn createBuffer(
    device: VkDevice,
    create_info: *const VkBufferCreateInfo,
    allocator: ?*const VkAllocationCallbacks,
) VulkanError!VkBuffer {
    const fn_ptr = c.vkCreateBuffer orelse return error.FunctionNotLoaded;
    var buffer: VkBuffer = undefined;
    const result = fn_ptr(device, create_info, allocator, &buffer);
    try vkResultToError(result);
    return buffer;
}

pub fn destroyBuffer(
    device: VkDevice,
    buffer: VkBuffer,
    allocator: ?*const VkAllocationCallbacks,
) void {
    if (c.vkDestroyBuffer) |fn_ptr| {
        fn_ptr(device, buffer, allocator);
    }
}

pub fn getBufferMemoryRequirements(
    device: VkDevice,
    buffer: VkBuffer,
    memory_requirements: *VkMemoryRequirements,
) void {
    if (c.vkGetBufferMemoryRequirements) |fn_ptr| {
        fn_ptr(device, buffer, memory_requirements);
    }
}

pub fn getPhysicalDeviceMemoryProperties(
    physical_device: VkPhysicalDevice,
    memory_properties: *VkPhysicalDeviceMemoryProperties,
) void {
    if (c.vkGetPhysicalDeviceMemoryProperties) |fn_ptr| {
        fn_ptr(physical_device, memory_properties);
    }
}

pub fn allocateMemory(
    device: VkDevice,
    allocate_info: *const VkMemoryAllocateInfo,
    allocator: ?*const VkAllocationCallbacks,
) VulkanError!VkDeviceMemory {
    const fn_ptr = c.vkAllocateMemory orelse return error.FunctionNotLoaded;
    var memory: VkDeviceMemory = undefined;
    const result = fn_ptr(device, allocate_info, allocator, &memory);
    try vkResultToError(result);
    return memory;
}

pub fn freeMemory(
    device: VkDevice,
    memory: VkDeviceMemory,
    allocator: ?*const VkAllocationCallbacks,
) void {
    if (c.vkFreeMemory) |fn_ptr| {
        fn_ptr(device, memory, allocator);
    }
}

pub fn bindBufferMemory(
    device: VkDevice,
    buffer: VkBuffer,
    memory: VkDeviceMemory,
    memory_offset: VkDeviceSize,
) VulkanError!void {
    const fn_ptr = c.vkBindBufferMemory orelse return error.FunctionNotLoaded;
    const result = fn_ptr(device, buffer, memory, memory_offset);
    try vkResultToError(result);
}

pub fn mapMemory(
    device: VkDevice,
    memory: VkDeviceMemory,
    offset: VkDeviceSize,
    size: VkDeviceSize,
    flags: c.VkMemoryMapFlags,
    data: *?*anyopaque,
) VulkanError!void {
    const fn_ptr = c.vkMapMemory orelse return error.FunctionNotLoaded;
    const result = fn_ptr(device, memory, offset, size, flags, data);
    try vkResultToError(result);
}

pub fn unmapMemory(
    device: VkDevice,
    memory: VkDeviceMemory,
) void {
    if (c.vkUnmapMemory) |fn_ptr| {
        fn_ptr(device, memory);
    }
}

pub fn createDescriptorSetLayout(
    device: VkDevice,
    create_info: *const VkDescriptorSetLayoutCreateInfo,
    allocator: ?*const VkAllocationCallbacks,
) VulkanError!VkDescriptorSetLayout {
    const fn_ptr = c.vkCreateDescriptorSetLayout orelse return error.FunctionNotLoaded;
    var descriptor_set_layout: VkDescriptorSetLayout = undefined;
    const result = fn_ptr(device, create_info, allocator, &descriptor_set_layout);
    try vkResultToError(result);
    return descriptor_set_layout;
}

pub fn destroyDescriptorSetLayout(
    device: VkDevice,
    descriptor_set_layout: VkDescriptorSetLayout,
    allocator: ?*const VkAllocationCallbacks,
) void {
    if (c.vkDestroyDescriptorSetLayout) |fn_ptr| {
        fn_ptr(device, descriptor_set_layout, allocator);
    }
}

pub fn createDescriptorPool(
    device: VkDevice,
    create_info: *const VkDescriptorPoolCreateInfo,
    allocator: ?*const VkAllocationCallbacks,
) VulkanError!VkDescriptorPool {
    const fn_ptr = c.vkCreateDescriptorPool orelse return error.FunctionNotLoaded;
    var descriptor_pool: VkDescriptorPool = undefined;
    const result = fn_ptr(device, create_info, allocator, &descriptor_pool);
    try vkResultToError(result);
    return descriptor_pool;
}

pub fn destroyDescriptorPool(
    device: VkDevice,
    descriptor_pool: VkDescriptorPool,
    allocator: ?*const VkAllocationCallbacks,
) void {
    if (c.vkDestroyDescriptorPool) |fn_ptr| {
        fn_ptr(device, descriptor_pool, allocator);
    }
}

pub fn allocateDescriptorSets(
    device: VkDevice,
    allocate_info: *const VkDescriptorSetAllocateInfo,
    descriptor_sets: [*]VkDescriptorSet,
) VulkanError!void {
    const fn_ptr = c.vkAllocateDescriptorSets orelse return error.FunctionNotLoaded;
    const result = fn_ptr(device, allocate_info, descriptor_sets);
    try vkResultToError(result);
}

pub fn updateDescriptorSets(
    device: VkDevice,
    descriptor_write_count: u32,
    descriptor_writes: [*]const VkWriteDescriptorSet,
    descriptor_copy_count: u32,
    descriptor_copies: ?[*]const c.VkCopyDescriptorSet,
) void {
    if (c.vkUpdateDescriptorSets) |fn_ptr| {
        fn_ptr(device, descriptor_write_count, descriptor_writes, descriptor_copy_count, descriptor_copies);
    }
}

pub fn createComputePipelines(
    device: VkDevice,
    pipeline_cache: c.VkPipelineCache,
    create_info_count: u32,
    create_infos: [*]const VkComputePipelineCreateInfo,
    allocator: ?*const VkAllocationCallbacks,
    pipelines: [*]VkPipeline,
) VulkanError!void {
    const fn_ptr = c.vkCreateComputePipelines orelse return error.FunctionNotLoaded;
    const result = fn_ptr(device, pipeline_cache, create_info_count, create_infos, allocator, pipelines);
    try vkResultToError(result);
}

pub fn cmdBindDescriptorSets(
    command_buffer: VkCommandBuffer,
    pipeline_bind_point: c.VkPipelineBindPoint,
    layout: VkPipelineLayout,
    first_set: u32,
    descriptor_set_count: u32,
    descriptor_sets: [*]const VkDescriptorSet,
    dynamic_offset_count: u32,
    dynamic_offsets: ?[*]const u32,
) void {
    if (c.vkCmdBindDescriptorSets) |fn_ptr| {
        fn_ptr(command_buffer, pipeline_bind_point, layout, first_set, descriptor_set_count, descriptor_sets, dynamic_offset_count, dynamic_offsets);
    }
}

pub fn cmdDispatch(
    command_buffer: VkCommandBuffer,
    group_count_x: u32,
    group_count_y: u32,
    group_count_z: u32,
) void {
    if (c.vkCmdDispatch) |fn_ptr| {
        fn_ptr(command_buffer, group_count_x, group_count_y, group_count_z);
    }
}

pub fn createImage(
    device: VkDevice,
    create_info: *const VkImageCreateInfo,
    allocator: ?*const VkAllocationCallbacks,
) VulkanError!VkImage {
    const fn_ptr = c.vkCreateImage orelse return error.FunctionNotLoaded;
    var image: VkImage = undefined;
    const result = fn_ptr(device, create_info, allocator, &image);
    try vkResultToError(result);
    return image;
}

pub fn destroyImage(
    device: VkDevice,
    image: VkImage,
    allocator: ?*const VkAllocationCallbacks,
) void {
    if (c.vkDestroyImage) |fn_ptr| {
        fn_ptr(device, image, allocator);
    }
}

pub fn getImageMemoryRequirements(
    device: VkDevice,
    image: VkImage,
    memory_requirements: *VkMemoryRequirements,
) void {
    if (c.vkGetImageMemoryRequirements) |fn_ptr| {
        fn_ptr(device, image, memory_requirements);
    }
}

pub fn bindImageMemory(
    device: VkDevice,
    image: VkImage,
    memory: VkDeviceMemory,
    memory_offset: VkDeviceSize,
) VulkanError!void {
    const fn_ptr = c.vkBindImageMemory orelse return error.FunctionNotLoaded;
    const result = fn_ptr(device, image, memory, memory_offset);
    try vkResultToError(result);
}

pub fn cmdPushConstants(
    command_buffer: VkCommandBuffer,
    layout: VkPipelineLayout,
    stage_flags: c.VkShaderStageFlags,
    offset: u32,
    size: u32,
    values: *const anyopaque,
) void {
    if (c.vkCmdPushConstants) |fn_ptr| {
        fn_ptr(command_buffer, layout, stage_flags, offset, size, values);
    }
}

pub fn cmdCopyBufferToImage(
    command_buffer: VkCommandBuffer,
    src_buffer: VkBuffer,
    dst_image: VkImage,
    dst_image_layout: c.VkImageLayout,
    region_count: u32,
    regions: [*]const VkBufferImageCopy,
) void {
    if (c.vkCmdCopyBufferToImage) |fn_ptr| {
        fn_ptr(command_buffer, src_buffer, dst_image, dst_image_layout, region_count, regions);
    }
}

pub fn cmdPipelineBarrier(
    command_buffer: VkCommandBuffer,
    src_stage_mask: c.VkPipelineStageFlags,
    dst_stage_mask: c.VkPipelineStageFlags,
    dependency_flags: c.VkDependencyFlags,
    memory_barrier_count: u32,
    memory_barriers: ?[*]const c.VkMemoryBarrier,
    buffer_memory_barrier_count: u32,
    buffer_memory_barriers: ?[*]const c.VkBufferMemoryBarrier,
    image_memory_barrier_count: u32,
    image_memory_barriers: ?[*]const VkImageMemoryBarrier,
) void {
    if (c.vkCmdPipelineBarrier) |fn_ptr| {
        fn_ptr(command_buffer, src_stage_mask, dst_stage_mask, dependency_flags, memory_barrier_count, memory_barriers, buffer_memory_barrier_count, buffer_memory_barriers, image_memory_barrier_count, image_memory_barriers);
    }
}

pub fn createSampler(
    device: VkDevice,
    create_info: *const VkSamplerCreateInfo,
    allocator: ?*const VkAllocationCallbacks,
) VulkanError!VkSampler {
    const fn_ptr = c.vkCreateSampler orelse return error.FunctionNotLoaded;
    var sampler: VkSampler = undefined;
    const result = fn_ptr(device, create_info, allocator, &sampler);
    try vkResultToError(result);
    return sampler;
}

pub fn destroySampler(
    device: VkDevice,
    sampler: VkSampler,
    allocator: ?*const VkAllocationCallbacks,
) void {
    if (c.vkDestroySampler) |fn_ptr| {
        fn_ptr(device, sampler, allocator);
    }
}

pub fn cmdBeginRendering(
    command_buffer: VkCommandBuffer,
    rendering_info: *const VkRenderingInfo,
) void {
    if (c.vkCmdBeginRendering) |fn_ptr| {
        fn_ptr(command_buffer, rendering_info);
    }
}

pub fn cmdEndRendering(
    command_buffer: VkCommandBuffer,
) void {
    if (c.vkCmdEndRendering) |fn_ptr| {
        fn_ptr(command_buffer);
    }
}

pub fn cmdSetViewport(
    command_buffer: VkCommandBuffer,
    first_viewport: u32,
    viewport_count: u32,
    viewports: [*]const VkViewport,
) void {
    if (c.vkCmdSetViewport) |fn_ptr| {
        fn_ptr(command_buffer, first_viewport, viewport_count, viewports);
    }
}

pub fn cmdSetScissor(
    command_buffer: VkCommandBuffer,
    first_scissor: u32,
    scissor_count: u32,
    scissors: [*]const VkRect2D,
) void {
    if (c.vkCmdSetScissor) |fn_ptr| {
        fn_ptr(command_buffer, first_scissor, scissor_count, scissors);
    }
}
