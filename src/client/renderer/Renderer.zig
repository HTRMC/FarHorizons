// Renderer module - Vulkan rendering

pub const RenderSystem = @import("RenderSystem.zig").RenderSystem;
pub const Vertex = @import("RenderSystem.zig").Vertex;
pub const LineVertex = @import("RenderSystem.zig").LineVertex;
pub const TextureManager = @import("TextureManager.zig").TextureManager;
pub const BlockOutlineRenderer = @import("BlockOutlineRenderer.zig").BlockOutlineRenderer;
pub const GpuDevice = @import("GpuDevice.zig").GpuDevice;
pub const TextureLoader = @import("resource/TextureLoader.zig").TextureLoader;
pub const block = @import("block/Model.zig");

// Buffer management
pub const buffer = @import("buffer/Buffer.zig");

// Shader system
pub const ShaderPreprocessor = @import("GlslPreprocessor.zig").ShaderPreprocessor;
pub const ShaderCompiler = @import("ShaderCompiler.zig").ShaderCompiler;
pub const ShaderKind = @import("ShaderCompiler.zig").ShaderKind;
pub const CompiledShader = @import("ShaderCompiler.zig").CompiledShader;
pub const ShaderManager = @import("ShaderManager.zig").ShaderManager;
