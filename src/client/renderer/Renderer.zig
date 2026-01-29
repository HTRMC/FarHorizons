// Renderer module - Vulkan rendering

pub const RenderSystem = @import("RenderSystem.zig").RenderSystem;
pub const Vertex = @import("RenderSystem.zig").Vertex;
pub const LineVertex = @import("RenderSystem.zig").LineVertex;
pub const TextureManager = @import("TextureManager.zig").TextureManager;
pub const BlockOutlineRenderer = @import("BlockOutlineRenderer.zig").BlockOutlineRenderer;
pub const GpuDevice = @import("GpuDevice.zig").GpuDevice;
pub const block = @import("block/Model.zig");

pub const TextureLoader = @import("resource/TextureLoader.zig").TextureLoader;
pub const ImageViewHelper = @import("resource/ImageViewHelper.zig").ImageViewHelper;

pub const buffer = @import("buffer/Buffer.zig");
pub const GpuBuffer = @import("GpuBuffer.zig").GpuBuffer;
pub const ManagedBuffer = @import("GpuBuffer.zig").ManagedBuffer;
pub const GPUDrivenTypes = @import("GPUDrivenTypes.zig");

pub const DescriptorPoolBuilder = @import("descriptor/DescriptorPoolBuilder.zig").DescriptorPoolBuilder;
pub const DescriptorSetManager = @import("descriptor/DescriptorSetManager.zig").DescriptorSetManager;

pub const RenderPipelines = @import("RenderPipelines.zig");
pub const DescriptorSetLayoutBuilder = @import("pipeline/DescriptorSetLayoutBuilder.zig").DescriptorSetLayoutBuilder;
pub const VulkanPipelineFactory = @import("pipeline/VulkanPipelineFactory.zig").VulkanPipelineFactory;

pub const ShaderPreprocessor = @import("GlslPreprocessor.zig").ShaderPreprocessor;
pub const ShaderCompiler = @import("ShaderCompiler.zig").ShaderCompiler;
pub const ShaderKind = @import("ShaderCompiler.zig").ShaderKind;
pub const CompiledShader = @import("ShaderCompiler.zig").CompiledShader;
pub const ShaderManager = @import("ShaderManager.zig").ShaderManager;
