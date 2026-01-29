// RenderPipelines - Composable pipeline configuration system
// Inspired by Minecraft's com.mojang.blaze3d.pipeline.RenderPipeline

const std = @import("std");
const volk = @import("volk");
const vk = volk.c;

pub const DepthTestFunction = enum {
    disabled,
    always,
    never,
    less,
    less_equal,
    greater,
    greater_equal,
    equal,
    not_equal,

    pub fn toVk(self: DepthTestFunction) struct { enable: bool, op: c_uint } {
        return switch (self) {
            .disabled => .{ .enable = false, .op = vk.VK_COMPARE_OP_ALWAYS },
            .always => .{ .enable = true, .op = vk.VK_COMPARE_OP_ALWAYS },
            .never => .{ .enable = true, .op = vk.VK_COMPARE_OP_NEVER },
            .less => .{ .enable = true, .op = vk.VK_COMPARE_OP_LESS },
            .less_equal => .{ .enable = true, .op = vk.VK_COMPARE_OP_LESS_OR_EQUAL },
            .greater => .{ .enable = true, .op = vk.VK_COMPARE_OP_GREATER },
            .greater_equal => .{ .enable = true, .op = vk.VK_COMPARE_OP_GREATER_OR_EQUAL },
            .equal => .{ .enable = true, .op = vk.VK_COMPARE_OP_EQUAL },
            .not_equal => .{ .enable = true, .op = vk.VK_COMPARE_OP_NOT_EQUAL },
        };
    }
};

pub const BlendFunction = struct {
    src_color: BlendFactor = .one,
    dst_color: BlendFactor = .zero,
    color_op: BlendOp = .add,
    src_alpha: BlendFactor = .one,
    dst_alpha: BlendFactor = .zero,
    alpha_op: BlendOp = .add,

    pub const DISABLED: BlendFunction = .{};
    pub const TRANSLUCENT: BlendFunction = .{
        .src_color = .src_alpha,
        .dst_color = .one_minus_src_alpha,
        .src_alpha = .one,
        .dst_alpha = .one_minus_src_alpha,
    };
    pub const ADDITIVE: BlendFunction = .{
        .src_color = .src_alpha,
        .dst_color = .one,
        .src_alpha = .one,
        .dst_alpha = .zero,
    };
    pub const MULTIPLY: BlendFunction = .{
        .src_color = .dst_color,
        .dst_color = .zero,
    };

    pub fn isEnabled(self: BlendFunction) bool {
        return self.src_color != .one or self.dst_color != .zero or
            self.src_alpha != .one or self.dst_alpha != .zero;
    }
};

pub const BlendFactor = enum {
    zero,
    one,
    src_color,
    one_minus_src_color,
    dst_color,
    one_minus_dst_color,
    src_alpha,
    one_minus_src_alpha,
    dst_alpha,
    one_minus_dst_alpha,

    pub fn toVk(self: BlendFactor) c_uint {
        return switch (self) {
            .zero => vk.VK_BLEND_FACTOR_ZERO,
            .one => vk.VK_BLEND_FACTOR_ONE,
            .src_color => vk.VK_BLEND_FACTOR_SRC_COLOR,
            .one_minus_src_color => vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR,
            .dst_color => vk.VK_BLEND_FACTOR_DST_COLOR,
            .one_minus_dst_color => vk.VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR,
            .src_alpha => vk.VK_BLEND_FACTOR_SRC_ALPHA,
            .one_minus_src_alpha => vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .dst_alpha => vk.VK_BLEND_FACTOR_DST_ALPHA,
            .one_minus_dst_alpha => vk.VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA,
        };
    }
};

pub const BlendOp = enum {
    add,
    subtract,
    reverse_subtract,
    min,
    max,

    pub fn toVk(self: BlendOp) c_uint {
        return switch (self) {
            .add => vk.VK_BLEND_OP_ADD,
            .subtract => vk.VK_BLEND_OP_SUBTRACT,
            .reverse_subtract => vk.VK_BLEND_OP_REVERSE_SUBTRACT,
            .min => vk.VK_BLEND_OP_MIN,
            .max => vk.VK_BLEND_OP_MAX,
        };
    }
};

pub const CullMode = enum {
    none,
    front,
    back,
    front_and_back,

    pub fn toVk(self: CullMode) c_uint {
        return switch (self) {
            .none => vk.VK_CULL_MODE_NONE,
            .front => vk.VK_CULL_MODE_FRONT_BIT,
            .back => vk.VK_CULL_MODE_BACK_BIT,
            .front_and_back => vk.VK_CULL_MODE_FRONT_AND_BACK,
        };
    }
};

pub const PolygonMode = enum {
    fill,
    line,
    point,

    pub fn toVk(self: PolygonMode) c_uint {
        return switch (self) {
            .fill => vk.VK_POLYGON_MODE_FILL,
            .line => vk.VK_POLYGON_MODE_LINE,
            .point => vk.VK_POLYGON_MODE_POINT,
        };
    }
};

pub const PrimitiveTopology = enum {
    triangle_list,
    triangle_strip,
    triangle_fan,
    line_list,
    line_strip,
    point_list,

    pub fn toVk(self: PrimitiveTopology) c_uint {
        return switch (self) {
            .triangle_list => vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .triangle_strip => vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP,
            .triangle_fan => vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN,
            .line_list => vk.VK_PRIMITIVE_TOPOLOGY_LINE_LIST,
            .line_strip => vk.VK_PRIMITIVE_TOPOLOGY_LINE_STRIP,
            .point_list => vk.VK_PRIMITIVE_TOPOLOGY_POINT_LIST,
        };
    }
};

/// A reusable fragment of pipeline configuration that can be composed
pub const PipelineSnippet = struct {
    vertex_shader: ?[]const u8 = null,
    fragment_shader: ?[]const u8 = null,

    cull_mode: ?CullMode = null,
    polygon_mode: ?PolygonMode = null,
    line_width: ?f32 = null,

    depth_test: ?DepthTestFunction = null,
    depth_write: ?bool = null,
    depth_bias_enable: ?bool = null,
    depth_bias_constant: ?f32 = null,
    depth_bias_slope: ?f32 = null,

    blend: ?BlendFunction = null,
    write_color: ?bool = null,
    write_alpha: ?bool = null,

    topology: ?PrimitiveTopology = null,
    primitive_restart: ?bool = null,

    sample_count: ?u8 = null,

    /// Merge another snippet into this one (other takes precedence)
    pub fn merge(self: PipelineSnippet, other: PipelineSnippet) PipelineSnippet {
        return .{
            .vertex_shader = other.vertex_shader orelse self.vertex_shader,
            .fragment_shader = other.fragment_shader orelse self.fragment_shader,
            .cull_mode = other.cull_mode orelse self.cull_mode,
            .polygon_mode = other.polygon_mode orelse self.polygon_mode,
            .line_width = other.line_width orelse self.line_width,
            .depth_test = other.depth_test orelse self.depth_test,
            .depth_write = other.depth_write orelse self.depth_write,
            .depth_bias_enable = other.depth_bias_enable orelse self.depth_bias_enable,
            .depth_bias_constant = other.depth_bias_constant orelse self.depth_bias_constant,
            .depth_bias_slope = other.depth_bias_slope orelse self.depth_bias_slope,
            .blend = other.blend orelse self.blend,
            .write_color = other.write_color orelse self.write_color,
            .write_alpha = other.write_alpha orelse self.write_alpha,
            .topology = other.topology orelse self.topology,
            .primitive_restart = other.primitive_restart orelse self.primitive_restart,
            .sample_count = other.sample_count orelse self.sample_count,
        };
    }

    /// Merge multiple snippets (later snippets take precedence)
    pub fn mergeAll(snippets: []const PipelineSnippet) PipelineSnippet {
        var result = PipelineSnippet{};
        for (snippets) |snippet| {
            result = result.merge(snippet);
        }
        return result;
    }
};

pub const Snippets = struct {
    /// Base 3D rendering with depth test
    pub const BASE_3D: PipelineSnippet = .{
        .depth_test = .less_equal,
        .depth_write = true,
        .cull_mode = .back,
        .polygon_mode = .fill,
        .topology = .triangle_list,
    };

    /// No depth testing (for UI/overlay)
    pub const NO_DEPTH: PipelineSnippet = .{
        .depth_test = .disabled,
        .depth_write = false,
    };

    /// Translucent blending
    pub const TRANSLUCENT: PipelineSnippet = .{
        .blend = BlendFunction.TRANSLUCENT,
        .depth_write = false,
    };

    /// Additive blending (for glow effects)
    pub const ADDITIVE: PipelineSnippet = .{
        .blend = BlendFunction.ADDITIVE,
        .depth_write = false,
    };

    /// No culling (double-sided)
    pub const NO_CULL: PipelineSnippet = .{
        .cull_mode = .none,
    };

    /// Front-face culling
    pub const CULL_FRONT: PipelineSnippet = .{
        .cull_mode = .front,
    };

    /// Wireframe rendering
    pub const WIREFRAME: PipelineSnippet = .{
        .polygon_mode = .line,
        .line_width = 1.0,
    };

    /// Line rendering
    pub const LINES: PipelineSnippet = .{
        .topology = .line_list,
        .cull_mode = .none,
    };

    /// UI rendering base
    pub const UI_BASE: PipelineSnippet = .{
        .depth_test = .disabled,
        .depth_write = false,
        .cull_mode = .none,
        .blend = BlendFunction.TRANSLUCENT,
        .topology = .triangle_list,
    };

    /// Solid block rendering
    pub const SOLID_BLOCK: PipelineSnippet = .{
        .vertex_shader = "core/block",
        .fragment_shader = "core/block",
        .depth_test = .less_equal,
        .depth_write = true,
        .cull_mode = .back,
    };

    /// Cutout block rendering (with alpha test)
    pub const CUTOUT_BLOCK: PipelineSnippet = .{
        .vertex_shader = "core/block",
        .fragment_shader = "core/block_cutout",
        .depth_test = .less_equal,
        .depth_write = true,
        .cull_mode = .back,
    };

    /// Translucent block rendering
    pub const TRANSLUCENT_BLOCK: PipelineSnippet = .{
        .vertex_shader = "core/block",
        .fragment_shader = "core/block",
        .depth_test = .less_equal,
        .depth_write = false,
        .cull_mode = .back,
        .blend = BlendFunction.TRANSLUCENT,
    };

    /// Entity rendering
    pub const ENTITY: PipelineSnippet = .{
        .vertex_shader = "core/entity",
        .fragment_shader = "core/entity",
        .depth_test = .less_equal,
        .depth_write = true,
        .cull_mode = .back,
    };

    /// Particle rendering
    pub const PARTICLE: PipelineSnippet = .{
        .vertex_shader = "core/particle",
        .fragment_shader = "core/particle",
        .depth_test = .less_equal,
        .depth_write = false,
        .cull_mode = .none,
        .blend = BlendFunction.TRANSLUCENT,
    };
};

/// Builder for creating RenderPipeline configurations
pub const PipelineBuilder = struct {
    const Self = @This();

    config: PipelineSnippet = .{},
    name: ?[]const u8 = null,

    /// Create a new builder
    pub fn init() Self {
        return .{};
    }

    /// Create a builder from existing snippets
    pub fn from(snippets: []const PipelineSnippet) Self {
        return .{
            .config = PipelineSnippet.mergeAll(snippets),
        };
    }

    /// Set pipeline name/location
    pub fn withName(self: Self, name: []const u8) Self {
        var result = self;
        result.name = name;
        return result;
    }

    /// Apply a snippet
    pub fn withSnippet(self: Self, snippet: PipelineSnippet) Self {
        var result = self;
        result.config = self.config.merge(snippet);
        return result;
    }

    /// Set vertex shader
    pub fn withVertexShader(self: Self, shader: []const u8) Self {
        var result = self;
        result.config.vertex_shader = shader;
        return result;
    }

    /// Set fragment shader
    pub fn withFragmentShader(self: Self, shader: []const u8) Self {
        var result = self;
        result.config.fragment_shader = shader;
        return result;
    }

    /// Set depth test function
    pub fn withDepthTest(self: Self, depth_test: DepthTestFunction) Self {
        var result = self;
        result.config.depth_test = depth_test;
        return result;
    }

    /// Enable/disable depth writing
    pub fn withDepthWrite(self: Self, enabled: bool) Self {
        var result = self;
        result.config.depth_write = enabled;
        return result;
    }

    /// Set cull mode
    pub fn withCull(self: Self, cull_mode: CullMode) Self {
        var result = self;
        result.config.cull_mode = cull_mode;
        return result;
    }

    /// Disable culling
    pub fn withoutCull(self: Self) Self {
        var result = self;
        result.config.cull_mode = .none;
        return result;
    }

    /// Set blend function
    pub fn withBlend(self: Self, blend: BlendFunction) Self {
        var result = self;
        result.config.blend = blend;
        return result;
    }

    /// Disable blending
    pub fn withoutBlend(self: Self) Self {
        var result = self;
        result.config.blend = BlendFunction.DISABLED;
        return result;
    }

    /// Set polygon mode
    pub fn withPolygonMode(self: Self, mode: PolygonMode) Self {
        var result = self;
        result.config.polygon_mode = mode;
        return result;
    }

    /// Set primitive topology
    pub fn withTopology(self: Self, topology: PrimitiveTopology) Self {
        var result = self;
        result.config.topology = topology;
        return result;
    }

    /// Set depth bias
    pub fn withDepthBias(self: Self, constant: f32, slope: f32) Self {
        var result = self;
        result.config.depth_bias_enable = true;
        result.config.depth_bias_constant = constant;
        result.config.depth_bias_slope = slope;
        return result;
    }

    /// Build as a snippet (for reuse)
    pub fn buildSnippet(self: Self) PipelineSnippet {
        return self.config;
    }

    /// Build the final pipeline config
    pub fn build(self: Self) RenderPipelineConfig {
        return RenderPipelineConfig.fromSnippet(self.name, self.config);
    }
};

/// Complete pipeline configuration ready for Vulkan pipeline creation
pub const RenderPipelineConfig = struct {
    name: ?[]const u8,

    vertex_shader: []const u8,
    fragment_shader: []const u8,

    cull_mode: CullMode,
    polygon_mode: PolygonMode,
    line_width: f32,

    depth_test: DepthTestFunction,
    depth_write: bool,
    depth_bias_enable: bool,
    depth_bias_constant: f32,
    depth_bias_slope: f32,

    blend: BlendFunction,
    write_color: bool,
    write_alpha: bool,

    topology: PrimitiveTopology,
    primitive_restart: bool,

    sample_count: u8,

    /// Create from a snippet with defaults for missing values
    pub fn fromSnippet(name: ?[]const u8, snippet: PipelineSnippet) RenderPipelineConfig {
        return .{
            .name = name,
            .vertex_shader = snippet.vertex_shader orelse "core/default",
            .fragment_shader = snippet.fragment_shader orelse "core/default",
            .cull_mode = snippet.cull_mode orelse .back,
            .polygon_mode = snippet.polygon_mode orelse .fill,
            .line_width = snippet.line_width orelse 1.0,
            .depth_test = snippet.depth_test orelse .less_equal,
            .depth_write = snippet.depth_write orelse true,
            .depth_bias_enable = snippet.depth_bias_enable orelse false,
            .depth_bias_constant = snippet.depth_bias_constant orelse 0.0,
            .depth_bias_slope = snippet.depth_bias_slope orelse 0.0,
            .blend = snippet.blend orelse BlendFunction.DISABLED,
            .write_color = snippet.write_color orelse true,
            .write_alpha = snippet.write_alpha orelse true,
            .topology = snippet.topology orelse .triangle_list,
            .primitive_restart = snippet.primitive_restart orelse false,
            .sample_count = snippet.sample_count orelse 1,
        };
    }

    /// Create Vulkan rasterization state
    pub fn toRasterizationState(self: *const RenderPipelineConfig) vk.VkPipelineRasterizationStateCreateInfo {
        return .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthClampEnable = vk.VK_FALSE,
            .rasterizerDiscardEnable = vk.VK_FALSE,
            .polygonMode = self.polygon_mode.toVk(),
            .cullMode = self.cull_mode.toVk(),
            .frontFace = vk.VK_FRONT_FACE_COUNTER_CLOCKWISE,
            .depthBiasEnable = if (self.depth_bias_enable) vk.VK_TRUE else vk.VK_FALSE,
            .depthBiasConstantFactor = self.depth_bias_constant,
            .depthBiasClamp = 0.0,
            .depthBiasSlopeFactor = self.depth_bias_slope,
            .lineWidth = self.line_width,
        };
    }

    /// Create Vulkan depth stencil state
    pub fn toDepthStencilState(self: *const RenderPipelineConfig) vk.VkPipelineDepthStencilStateCreateInfo {
        const depth_info = self.depth_test.toVk();
        return .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthTestEnable = if (depth_info.enable) vk.VK_TRUE else vk.VK_FALSE,
            .depthWriteEnable = if (self.depth_write) vk.VK_TRUE else vk.VK_FALSE,
            .depthCompareOp = depth_info.op,
            .depthBoundsTestEnable = vk.VK_FALSE,
            .stencilTestEnable = vk.VK_FALSE,
            .front = std.mem.zeroes(vk.VkStencilOpState),
            .back = std.mem.zeroes(vk.VkStencilOpState),
            .minDepthBounds = 0.0,
            .maxDepthBounds = 1.0,
        };
    }

    /// Create Vulkan color blend attachment state
    pub fn toColorBlendAttachment(self: *const RenderPipelineConfig) vk.VkPipelineColorBlendAttachmentState {
        var color_mask: c_uint = 0;
        if (self.write_color) {
            color_mask |= vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT | vk.VK_COLOR_COMPONENT_B_BIT;
        }
        if (self.write_alpha) {
            color_mask |= vk.VK_COLOR_COMPONENT_A_BIT;
        }

        return .{
            .blendEnable = if (self.blend.isEnabled()) vk.VK_TRUE else vk.VK_FALSE,
            .srcColorBlendFactor = self.blend.src_color.toVk(),
            .dstColorBlendFactor = self.blend.dst_color.toVk(),
            .colorBlendOp = self.blend.color_op.toVk(),
            .srcAlphaBlendFactor = self.blend.src_alpha.toVk(),
            .dstAlphaBlendFactor = self.blend.dst_alpha.toVk(),
            .alphaBlendOp = self.blend.alpha_op.toVk(),
            .colorWriteMask = color_mask,
        };
    }

    /// Create Vulkan input assembly state
    pub fn toInputAssemblyState(self: *const RenderPipelineConfig) vk.VkPipelineInputAssemblyStateCreateInfo {
        return .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .topology = self.topology.toVk(),
            .primitiveRestartEnable = if (self.primitive_restart) vk.VK_TRUE else vk.VK_FALSE,
        };
    }
};

pub const Pipelines = struct {
    pub const SOLID_BLOCK = PipelineBuilder.init()
        .withSnippet(Snippets.SOLID_BLOCK)
        .withName("pipeline/solid_block")
        .build();

    pub const CUTOUT_BLOCK = PipelineBuilder.init()
        .withSnippet(Snippets.CUTOUT_BLOCK)
        .withName("pipeline/cutout_block")
        .build();

    pub const TRANSLUCENT_BLOCK = PipelineBuilder.init()
        .withSnippet(Snippets.TRANSLUCENT_BLOCK)
        .withName("pipeline/translucent_block")
        .build();

    pub const ENTITY_SOLID = PipelineBuilder.init()
        .withSnippet(Snippets.ENTITY)
        .withName("pipeline/entity_solid")
        .build();

    pub const ENTITY_TRANSLUCENT = PipelineBuilder.init()
        .withSnippet(Snippets.ENTITY)
        .withSnippet(Snippets.TRANSLUCENT)
        .withName("pipeline/entity_translucent")
        .build();

    pub const PARTICLE = PipelineBuilder.init()
        .withSnippet(Snippets.PARTICLE)
        .withName("pipeline/particle")
        .build();

    pub const UI = PipelineBuilder.init()
        .withSnippet(Snippets.UI_BASE)
        .withVertexShader("core/ui")
        .withFragmentShader("core/ui")
        .withName("pipeline/ui")
        .build();

    pub const LINES = PipelineBuilder.init()
        .withSnippet(Snippets.BASE_3D)
        .withSnippet(Snippets.LINES)
        .withSnippet(Snippets.TRANSLUCENT)
        .withVertexShader("core/lines")
        .withFragmentShader("core/lines")
        .withName("pipeline/lines")
        .build();

    pub const DEBUG_WIREFRAME = PipelineBuilder.init()
        .withSnippet(Snippets.BASE_3D)
        .withSnippet(Snippets.WIREFRAME)
        .withSnippet(Snippets.NO_CULL)
        .withName("pipeline/debug_wireframe")
        .build();
};
