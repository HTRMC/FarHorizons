// RenderPass - Abstract render pass for command recording
// Inspired by Minecraft's com.mojang.blaze3d.systems.RenderPass

const std = @import("std");
const volk = @import("volk");
const vk = volk.c;

const GpuBuffer = @import("GpuBuffer.zig");

/// Scissor state for render pass
pub const ScissorState = struct {
    enabled: bool = false,
    x: i32 = 0,
    y: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,

    pub fn enable(self: *ScissorState, x: i32, y: i32, width: u32, height: u32) void {
        self.enabled = true;
        self.x = x;
        self.y = y;
        self.width = width;
        self.height = height;
    }

    pub fn disable(self: *ScissorState) void {
        self.enabled = false;
    }

    pub fn toVkRect2D(self: *const ScissorState) vk.VkRect2D {
        return .{
            .offset = .{ .x = self.x, .y = self.y },
            .extent = .{ .width = self.width, .height = self.height },
        };
    }
};

/// Viewport configuration
pub const Viewport = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    width: f32,
    height: f32,
    min_depth: f32 = 0.0,
    max_depth: f32 = 1.0,

    pub fn fromExtent(extent: vk.VkExtent2D) Viewport {
        return .{
            .width = @floatFromInt(extent.width),
            .height = @floatFromInt(extent.height),
        };
    }

    pub fn toVkViewport(self: *const Viewport) vk.VkViewport {
        return .{
            .x = self.x,
            .y = self.y,
            .width = self.width,
            .height = self.height,
            .minDepth = self.min_depth,
            .maxDepth = self.max_depth,
        };
    }
};

/// Clear values for render pass
pub const ClearValues = struct {
    color: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 },
    depth: f32 = 1.0,
    stencil: u32 = 0,

    pub fn toVkClearValues(self: *const ClearValues) [2]vk.VkClearValue {
        return .{
            .{ .color = .{ .float32 = self.color } },
            .{ .depthStencil = .{ .depth = self.depth, .stencil = self.stencil } },
        };
    }
};

/// Render Pass - encapsulates command buffer recording state
pub const RenderPass = struct {
    const Self = @This();

    // Command buffer being recorded
    command_buffer: vk.VkCommandBuffer,

    // Current state
    current_pipeline: ?vk.VkPipeline = null,
    current_pipeline_layout: ?vk.VkPipelineLayout = null,
    vertex_buffers: [4]?vk.VkBuffer = .{ null, null, null, null },
    vertex_offsets: [4]vk.VkDeviceSize = .{ 0, 0, 0, 0 },
    index_buffer: ?vk.VkBuffer = null,
    index_type: GpuBuffer.IndexType = .u32,

    // Viewport and scissor
    viewport: Viewport,
    scissor_state: ScissorState = .{},

    // Render pass state
    render_pass_handle: vk.VkRenderPass,
    framebuffer: vk.VkFramebuffer,
    extent: vk.VkExtent2D,
    closed: bool = false,

    /// Begin a render pass
    pub fn begin(
        command_buffer: vk.VkCommandBuffer,
        render_pass_handle: vk.VkRenderPass,
        framebuffer: vk.VkFramebuffer,
        extent: vk.VkExtent2D,
        clear_values: ClearValues,
    ) !Self {
        const vkCmdBeginRenderPass = vk.vkCmdBeginRenderPass orelse return error.VulkanFunctionNotLoaded;

        const vk_clear_values = clear_values.toVkClearValues();

        const render_pass_info = vk.VkRenderPassBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .pNext = null,
            .renderPass = render_pass_handle,
            .framebuffer = framebuffer,
            .renderArea = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = extent,
            },
            .clearValueCount = vk_clear_values.len,
            .pClearValues = &vk_clear_values,
        };

        vkCmdBeginRenderPass(command_buffer, &render_pass_info, vk.VK_SUBPASS_CONTENTS_INLINE);

        var self = Self{
            .command_buffer = command_buffer,
            .render_pass_handle = render_pass_handle,
            .framebuffer = framebuffer,
            .extent = extent,
            .viewport = Viewport.fromExtent(extent),
        };

        // Set initial viewport and scissor
        try self.applyViewport();
        try self.applyScissor();

        return self;
    }

    /// Bind a graphics pipeline
    pub fn setPipeline(self: *Self, pipeline: vk.VkPipeline, layout: vk.VkPipelineLayout) !void {
        if (self.closed) return error.RenderPassClosed;

        const vkCmdBindPipeline = vk.vkCmdBindPipeline orelse return error.VulkanFunctionNotLoaded;

        if (self.current_pipeline != pipeline) {
            vkCmdBindPipeline(self.command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
            self.current_pipeline = pipeline;
            self.current_pipeline_layout = layout;
        }
    }

    /// Bind descriptor sets
    pub fn setDescriptorSets(
        self: *Self,
        descriptor_sets: []const vk.VkDescriptorSet,
    ) !void {
        if (self.closed) return error.RenderPassClosed;
        if (self.current_pipeline_layout == null) return error.NoPipelineBound;

        const vkCmdBindDescriptorSets = vk.vkCmdBindDescriptorSets orelse return error.VulkanFunctionNotLoaded;

        vkCmdBindDescriptorSets(
            self.command_buffer,
            vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.current_pipeline_layout.?,
            0,
            @intCast(descriptor_sets.len),
            descriptor_sets.ptr,
            0,
            null,
        );
    }

    /// Bind a vertex buffer
    pub fn setVertexBuffer(self: *Self, slot: u32, buffer: *GpuBuffer.GpuBuffer) !void {
        if (self.closed) return error.RenderPassClosed;
        if (slot >= self.vertex_buffers.len) return error.InvalidBufferSlot;

        self.vertex_buffers[slot] = buffer.handle;
        self.vertex_offsets[slot] = 0;
    }

    /// Bind a vertex buffer with offset
    pub fn setVertexBufferWithOffset(self: *Self, slot: u32, buffer: vk.VkBuffer, offset: u64) !void {
        if (self.closed) return error.RenderPassClosed;
        if (slot >= self.vertex_buffers.len) return error.InvalidBufferSlot;

        self.vertex_buffers[slot] = buffer;
        self.vertex_offsets[slot] = offset;
    }

    /// Bind an index buffer
    pub fn setIndexBuffer(self: *Self, buffer: *GpuBuffer.GpuBuffer, index_type: GpuBuffer.IndexType) !void {
        if (self.closed) return error.RenderPassClosed;

        self.index_buffer = buffer.handle;
        self.index_type = index_type;
    }

    /// Bind an index buffer by handle
    pub fn setIndexBufferHandle(self: *Self, buffer: vk.VkBuffer, index_type: GpuBuffer.IndexType) !void {
        if (self.closed) return error.RenderPassClosed;

        self.index_buffer = buffer;
        self.index_type = index_type;
    }

    /// Set viewport
    pub fn setViewport(self: *Self, viewport: Viewport) !void {
        if (self.closed) return error.RenderPassClosed;
        self.viewport = viewport;
        try self.applyViewport();
    }

    /// Enable scissor test
    pub fn enableScissor(self: *Self, x: i32, y: i32, width: u32, height: u32) !void {
        if (self.closed) return error.RenderPassClosed;
        self.scissor_state.enable(x, y, width, height);
        try self.applyScissor();
    }

    /// Disable scissor test (use full viewport)
    pub fn disableScissor(self: *Self) !void {
        if (self.closed) return error.RenderPassClosed;
        self.scissor_state.disable();
        try self.applyScissor();
    }

    /// Draw indexed primitives
    pub fn drawIndexed(
        self: *Self,
        index_count: u32,
        instance_count: u32,
        first_index: u32,
        vertex_offset: i32,
        first_instance: u32,
    ) !void {
        if (self.closed) return error.RenderPassClosed;

        const vkCmdBindVertexBuffers = vk.vkCmdBindVertexBuffers orelse return error.VulkanFunctionNotLoaded;
        const vkCmdBindIndexBuffer = vk.vkCmdBindIndexBuffer orelse return error.VulkanFunctionNotLoaded;
        const vkCmdDrawIndexed = vk.vkCmdDrawIndexed orelse return error.VulkanFunctionNotLoaded;

        // Bind vertex buffers
        var buffer_count: u32 = 0;
        for (self.vertex_buffers) |buf| {
            if (buf != null) buffer_count += 1 else break;
        }

        if (buffer_count > 0) {
            var buffers: [4]vk.VkBuffer = undefined;
            for (0..buffer_count) |i| {
                buffers[i] = self.vertex_buffers[i].?;
            }
            vkCmdBindVertexBuffers(self.command_buffer, 0, buffer_count, &buffers, &self.vertex_offsets);
        }

        // Bind index buffer
        if (self.index_buffer) |idx_buf| {
            vkCmdBindIndexBuffer(self.command_buffer, idx_buf, 0, self.index_type.toVk());
        }

        vkCmdDrawIndexed(self.command_buffer, index_count, instance_count, first_index, vertex_offset, first_instance);
    }

    /// Draw non-indexed primitives
    pub fn draw(self: *Self, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) !void {
        if (self.closed) return error.RenderPassClosed;

        const vkCmdBindVertexBuffers = vk.vkCmdBindVertexBuffers orelse return error.VulkanFunctionNotLoaded;
        const vkCmdDraw = vk.vkCmdDraw orelse return error.VulkanFunctionNotLoaded;

        // Bind vertex buffers
        var buffer_count: u32 = 0;
        for (self.vertex_buffers) |buf| {
            if (buf != null) buffer_count += 1 else break;
        }

        if (buffer_count > 0) {
            var buffers: [4]vk.VkBuffer = undefined;
            for (0..buffer_count) |i| {
                buffers[i] = self.vertex_buffers[i].?;
            }
            vkCmdBindVertexBuffers(self.command_buffer, 0, buffer_count, &buffers, &self.vertex_offsets);
        }

        vkCmdDraw(self.command_buffer, vertex_count, instance_count, first_vertex, first_instance);
    }

    /// End the render pass
    pub fn end(self: *Self) !void {
        if (self.closed) return;

        const vkCmdEndRenderPass = vk.vkCmdEndRenderPass orelse return error.VulkanFunctionNotLoaded;
        vkCmdEndRenderPass(self.command_buffer);

        self.closed = true;
    }

    /// Close/end the render pass (alias for end)
    pub fn close(self: *Self) void {
        self.end() catch {};
    }

    // ============================================================
    // Internal helpers
    // ============================================================

    fn applyViewport(self: *Self) !void {
        const vkCmdSetViewport = vk.vkCmdSetViewport orelse return error.VulkanFunctionNotLoaded;
        const vp = self.viewport.toVkViewport();
        vkCmdSetViewport(self.command_buffer, 0, 1, &vp);
    }

    fn applyScissor(self: *Self) !void {
        const vkCmdSetScissor = vk.vkCmdSetScissor orelse return error.VulkanFunctionNotLoaded;

        const scissor = if (self.scissor_state.enabled)
            self.scissor_state.toVkRect2D()
        else
            vk.VkRect2D{
                .offset = .{ .x = 0, .y = 0 },
                .extent = self.extent,
            };

        vkCmdSetScissor(self.command_buffer, 0, 1, &scissor);
    }
};

/// Draw command for batched rendering
pub const DrawCommand = struct {
    /// Offset into the vertex buffer (in bytes)
    vertex_offset: u64 = 0,
    /// Offset into the index buffer (in bytes)
    index_offset: u64 = 0,
    /// Number of indices to draw
    index_count: u32,
    /// Base vertex offset (added to each index)
    vertex_base: i32 = 0,
    /// Number of instances
    instance_count: u32 = 1,
    /// First instance
    first_instance: u32 = 0,
};

/// Execute multiple draw commands efficiently
pub fn executeDrawCommands(
    render_pass: *RenderPass,
    vertex_buffer: vk.VkBuffer,
    index_buffer: vk.VkBuffer,
    index_type: GpuBuffer.IndexType,
    commands: []const DrawCommand,
) !void {
    const vkCmdBindVertexBuffers = vk.vkCmdBindVertexBuffers orelse return error.VulkanFunctionNotLoaded;
    const vkCmdBindIndexBuffer = vk.vkCmdBindIndexBuffer orelse return error.VulkanFunctionNotLoaded;
    const vkCmdDrawIndexed = vk.vkCmdDrawIndexed orelse return error.VulkanFunctionNotLoaded;

    // Bind buffers once
    const vertex_buffers = [_]vk.VkBuffer{vertex_buffer};
    const offsets = [_]vk.VkDeviceSize{0};
    vkCmdBindVertexBuffers(render_pass.command_buffer, 0, 1, &vertex_buffers, &offsets);
    vkCmdBindIndexBuffer(render_pass.command_buffer, index_buffer, 0, index_type.toVk());

    // Execute all draw commands
    const index_size = index_type.byteSize();
    for (commands) |cmd| {
        if (cmd.index_count == 0) continue;

        const first_index: u32 = @intCast(cmd.index_offset / index_size);
        const vertex_offset: i32 = cmd.vertex_base;

        vkCmdDrawIndexed(
            render_pass.command_buffer,
            cmd.index_count,
            cmd.instance_count,
            first_index,
            vertex_offset,
            cmd.first_instance,
        );
    }
}
