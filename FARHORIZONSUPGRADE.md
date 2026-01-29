# FarHorizons GPU-Driven Rendering Migration Plan

## Overview

This document outlines an incremental migration path from FarHorizons' current CPU-driven indirect rendering to Voxy-style GPU-driven Multi-Draw Indirect Count (MDIC) rendering.

### Current Architecture (CPU-Driven)

```
Frame:
  CPU: Iterate all chunks in getDrawCommands()     O(n)
  CPU: Sort by layer/arena                         O(n log n)
  CPU: Write indirect commands to mapped buffer    O(n)
  CPU: Issue N x vkCmdDrawIndexedIndirect calls
```

### Target Architecture (GPU-Driven)

```
Frame:
  CPU: vkCmdDispatch(prep.comp)                    O(1)
  CPU: vkCmdDispatchIndirect(cmdgen.comp)          O(1)
  CPU: vkCmdDrawIndexedIndirectCount x 3           O(1)

  GPU: Zero counters
  GPU: Frustum cull + generate draw commands
  GPU: Execute draws (count read from buffer)
```

---

## Phase 1: GPU Buffer Infrastructure

**Effort:** Medium | **Impact:** None yet (foundation) | **Risk:** Low

Add new GPU buffers to support GPU-driven rendering.

### New Structures

```zig
// In RenderSystem.zig or new file: GPUDrivenTypes.zig

/// Per-chunk data uploaded to GPU for culling and command generation
pub const ChunkGPUData = extern struct {
    /// Chunk world position (center)
    world_pos: [3]f32,
    _pad0: f32 = 0,

    /// AABB minimum for frustum culling
    aabb_min: [3]f32,
    _pad1: f32 = 0,

    /// AABB maximum for frustum culling
    aabb_max: [3]f32,
    _pad2: f32 = 0,

    /// Per-layer rendering data
    layers: [3]LayerGPUData,

    _pad3: f32 = 0,
};

/// Per-layer data for command generation
pub const LayerGPUData = extern struct {
    vertex_offset: u32,      // Byte offset in vertex buffer
    index_offset: u32,       // Byte offset in index buffer
    index_count: u32,        // Number of indices
    arena_indices: u32,      // vertex_arena << 16 | index_arena
};

/// Atomic counters for GPU command generation
pub const DrawCountData = extern struct {
    /// Compute dispatch dimensions (set by prep.comp)
    dispatch_x: u32,
    dispatch_y: u32,
    dispatch_z: u32,

    /// Draw command counts (atomically incremented by cmdgen.comp)
    solid_count: u32,
    cutout_count: u32,
    translucent_count: u32,
};

/// Matches VkDrawIndexedIndirectCommand exactly
pub const IndirectDrawCommand = extern struct {
    index_count: u32,
    instance_count: u32,
    first_index: u32,
    vertex_offset: i32,
    first_instance: u32,
};
```

### New Buffers in RenderSystem

```zig
// Add to RenderSystem struct

/// GPU buffer containing ChunkGPUData for all loaded chunks
chunk_metadata_buffer: ManagedBuffer,

/// Visibility flags per chunk (u32 per chunk, stores frameId when visible)
visibility_buffer: ManagedBuffer,

/// Atomic counters for draw command counts
draw_count_buffer: ManagedBuffer,

/// GPU-generated draw commands (written by cmdgen.comp)
gpu_draw_buffer: ManagedBuffer,

/// Maps chunk slot ID to chunk metadata index
chunk_slot_allocator: SlotAllocator,
```

### Buffer Sizes

```zig
const MAX_CHUNKS = 65536;
const MAX_DRAWS_PER_LAYER = 100000;

// Allocations
chunk_metadata_buffer: MAX_CHUNKS * @sizeOf(ChunkGPUData),           // ~4 MB
visibility_buffer: MAX_CHUNKS * @sizeOf(u32),                         // 256 KB
draw_count_buffer: @sizeOf(DrawCountData),                            // 24 bytes
gpu_draw_buffer: 3 * MAX_DRAWS_PER_LAYER * @sizeOf(IndirectDrawCommand), // ~6 MB
```

### Integration Points

**On chunk ready (RenderChunk.zig):**

```zig
pub fn onBecomeReady(self: *RenderChunk, gpu_driven: *GPUDrivenRenderer) void {
    self.gpu_slot = gpu_driven.allocateSlot();
    gpu_driven.uploadChunkMetadata(self.gpu_slot, self.buildGPUData());
}
```

**On chunk unload:**

```zig
pub fn onUnload(self: *RenderChunk, gpu_driven: *GPUDrivenRenderer) void {
    gpu_driven.freeSlot(self.gpu_slot);
}
```

---

## Phase 2: Compute Pipeline Infrastructure

**Effort:** Medium | **Impact:** None yet (foundation) | **Risk:** Low

Add compute shader compilation and pipeline creation.

### New Files

```
src/client/renderer/
  ComputePipeline.zig      # Compute pipeline wrapper
  GPUDrivenRenderer.zig    # Orchestrates GPU-driven rendering

assets/shaders/compute/
  prep.comp                # Zero counters, set dispatch size
  cmdgen.comp              # Frustum cull + generate draw commands
```

### prep.comp

```glsl
#version 450
layout(local_size_x = 1) in;

layout(set = 0, binding = 0, std430) buffer DrawCounts {
    uint dispatchX;
    uint dispatchY;
    uint dispatchZ;
    uint solidCount;
    uint cutoutCount;
    uint translucentCount;
} counts;

layout(push_constant) uniform PushConstants {
    uint chunkCount;
} pc;

void main() {
    // Set dispatch size for cmdgen.comp (64 threads per workgroup)
    counts.dispatchX = (pc.chunkCount + 63) / 64;
    counts.dispatchY = 1;
    counts.dispatchZ = 1;

    // Zero draw counters
    counts.solidCount = 0;
    counts.cutoutCount = 0;
    counts.translucentCount = 0;
}
```

### Compute Pipeline Creation

```zig
// In ComputePipeline.zig

pub fn createComputePipeline(
    device: vk.VkDevice,
    shader_module: vk.VkShaderModule,
    layout: vk.VkPipelineLayout,
) !vk.VkPipeline {
    const stage = vk.VkPipelineShaderStageCreateInfo{
        .sType = .VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = .VK_SHADER_STAGE_COMPUTE_BIT,
        .module = shader_module,
        .pName = "main",
        // ...
    };

    const create_info = vk.VkComputePipelineCreateInfo{
        .sType = .VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .stage = stage,
        .layout = layout,
        // ...
    };

    var pipeline: vk.VkPipeline = undefined;
    try checkVk(vk.vkCreateComputePipelines(
        device, null, 1, &create_info, null, &pipeline
    ));
    return pipeline;
}
```

---

## Phase 3: GPU Frustum Culling + Command Generation

**Effort:** High | **Impact:** High | **Risk:** Medium

Implement the core GPU command generation.

### cmdgen.comp

```glsl
#version 450
layout(local_size_x = 64) in;

// Chunk metadata buffer
layout(set = 0, binding = 0, std430) readonly buffer ChunkMetadata {
    ChunkGPUData chunks[];
};

// Draw count buffer (atomic counters)
layout(set = 0, binding = 1, std430) buffer DrawCounts {
    uint dispatchX;
    uint dispatchY;
    uint dispatchZ;
    uint solidCount;
    uint cutoutCount;
    uint translucentCount;
} counts;

// Output draw commands (3 arrays: solid, cutout, translucent)
layout(set = 0, binding = 2, std430) writeonly buffer SolidCommands {
    DrawCommand solidCmds[];
};

layout(set = 0, binding = 3, std430) writeonly buffer CutoutCommands {
    DrawCommand cutoutCmds[];
};

layout(set = 0, binding = 4, std430) writeonly buffer TranslucentCommands {
    DrawCommand translucentCmds[];
};

layout(push_constant) uniform PushConstants {
    mat4 viewProj;      // For frustum extraction
    vec3 cameraPos;     // For face culling (optional)
    uint chunkCount;
} pc;

struct ChunkGPUData {
    vec3 worldPos;
    float _pad0;
    vec3 aabbMin;
    float _pad1;
    vec3 aabbMax;
    float _pad2;
    LayerGPUData layers[3];
    float _pad3;
};

struct LayerGPUData {
    uint vertexOffset;
    uint indexOffset;
    uint indexCount;
    uint arenaIndices;
};

struct DrawCommand {
    uint indexCount;
    uint instanceCount;
    uint firstIndex;
    int  vertexOffset;
    uint firstInstance;
};

// Frustum planes extracted from viewProj matrix
vec4 frustumPlanes[6];

void extractFrustumPlanes() {
    mat4 m = pc.viewProj;

    // Left plane
    frustumPlanes[0] = vec4(
        m[0][3] + m[0][0],
        m[1][3] + m[1][0],
        m[2][3] + m[2][0],
        m[3][3] + m[3][0]
    );

    // Right plane
    frustumPlanes[1] = vec4(
        m[0][3] - m[0][0],
        m[1][3] - m[1][0],
        m[2][3] - m[2][0],
        m[3][3] - m[3][0]
    );

    // Bottom plane
    frustumPlanes[2] = vec4(
        m[0][3] + m[0][1],
        m[1][3] + m[1][1],
        m[2][3] + m[2][1],
        m[3][3] + m[3][1]
    );

    // Top plane
    frustumPlanes[3] = vec4(
        m[0][3] - m[0][1],
        m[1][3] - m[1][1],
        m[2][3] - m[2][1],
        m[3][3] - m[3][1]
    );

    // Near plane
    frustumPlanes[4] = vec4(
        m[0][3] + m[0][2],
        m[1][3] + m[1][2],
        m[2][3] + m[2][2],
        m[3][3] + m[3][2]
    );

    // Far plane
    frustumPlanes[5] = vec4(
        m[0][3] - m[0][2],
        m[1][3] - m[1][2],
        m[2][3] - m[2][2],
        m[3][3] - m[3][2]
    );

    // Normalize planes
    for (int i = 0; i < 6; i++) {
        float len = length(frustumPlanes[i].xyz);
        frustumPlanes[i] /= len;
    }
}

bool frustumTestAABB(vec3 aabbMin, vec3 aabbMax) {
    for (int i = 0; i < 6; i++) {
        vec4 plane = frustumPlanes[i];

        // Find the positive vertex (furthest along plane normal)
        vec3 pVertex = vec3(
            plane.x > 0 ? aabbMax.x : aabbMin.x,
            plane.y > 0 ? aabbMax.y : aabbMin.y,
            plane.z > 0 ? aabbMax.z : aabbMin.z
        );

        // If positive vertex is outside, AABB is outside
        if (dot(plane.xyz, pVertex) + plane.w < 0) {
            return false;
        }
    }
    return true;
}

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= pc.chunkCount) return;

    extractFrustumPlanes();

    ChunkGPUData chunk = chunks[idx];

    // Frustum culling
    if (!frustumTestAABB(chunk.aabbMin, chunk.aabbMax)) {
        return;  // Chunk not visible, skip
    }

    // Generate draw commands for each non-empty layer
    for (uint layer = 0; layer < 3; layer++) {
        LayerGPUData ld = chunk.layers[layer];

        if (ld.indexCount == 0) continue;

        // Atomically allocate slot in appropriate command array
        uint slot;
        if (layer == 0) {
            slot = atomicAdd(counts.solidCount, 1);
        } else if (layer == 1) {
            slot = atomicAdd(counts.cutoutCount, 1);
        } else {
            slot = atomicAdd(counts.translucentCount, 1);
        }

        // Build draw command
        DrawCommand cmd;
        cmd.indexCount = ld.indexCount;
        cmd.instanceCount = 1;
        cmd.firstIndex = ld.indexOffset / 4;           // Convert bytes to indices
        cmd.vertexOffset = int(ld.vertexOffset / 36);  // Convert bytes to vertices
        cmd.firstInstance = idx;                        // Chunk ID for vertex shader

        // Write to appropriate command buffer
        if (layer == 0) {
            solidCmds[slot] = cmd;
        } else if (layer == 1) {
            cutoutCmds[slot] = cmd;
        } else {
            translucentCmds[slot] = cmd;
        }
    }
}
```

---

## Phase 4: Switch to DrawIndexedIndirectCount

**Effort:** Low | **Impact:** High | **Risk:** Low

Replace the current draw loop with GPU-driven rendering.

### Current Code (RenderSystem.zig ~L638-718)

```zig
// OLD: CPU-driven indirect drawing
fn recordRenderCommands(...) {
    // CPU writes commands
    for (commands, 0..) |cmd, i| {
        indirect_cmds[i] = IndirectDrawCommand{...};
    }

    // CPU-driven batched dispatch
    for (batches) |batch| {
        if (layer_changed) bindPipeline(...);
        if (buffer_changed) bindBuffers(...);
        vk.vkCmdDrawIndexedIndirect(cmd_buf, ..., batch.count, ...);
    }
}
```

### New Code

```zig
// NEW: GPU-driven rendering
fn recordGPUDrivenCommands(
    self: *Self,
    cmd_buf: vk.VkCommandBuffer,
    chunk_count: u32,
    view_proj: [16]f32,
    camera_pos: [3]f32,
) void {
    // Bind compute descriptor set
    vk.vkCmdBindDescriptorSets(
        cmd_buf,
        .VK_PIPELINE_BIND_POINT_COMPUTE,
        self.compute_pipeline_layout,
        0, 1, &self.compute_descriptor_set,
        0, null
    );

    // === PREP PASS ===
    vk.vkCmdBindPipeline(cmd_buf, .VK_PIPELINE_BIND_POINT_COMPUTE, self.prep_pipeline);

    const prep_push = extern struct { chunk_count: u32 }{ .chunk_count = chunk_count };
    vk.vkCmdPushConstants(cmd_buf, self.compute_pipeline_layout,
        .VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(@TypeOf(prep_push)), &prep_push);

    vk.vkCmdDispatch(cmd_buf, 1, 1, 1);

    // Memory barrier: prep writes -> cmdgen reads
    self.insertComputeBarrier(cmd_buf);

    // === COMMAND GENERATION PASS ===
    vk.vkCmdBindPipeline(cmd_buf, .VK_PIPELINE_BIND_POINT_COMPUTE, self.cmdgen_pipeline);

    const cmdgen_push = extern struct {
        view_proj: [16]f32,
        camera_pos: [3]f32,
        chunk_count: u32,
    }{
        .view_proj = view_proj,
        .camera_pos = camera_pos,
        .chunk_count = chunk_count,
    };
    vk.vkCmdPushConstants(cmd_buf, self.compute_pipeline_layout,
        .VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(@TypeOf(cmdgen_push)), &cmdgen_push);

    // Indirect dispatch - size determined by prep.comp
    vk.vkCmdDispatchIndirect(cmd_buf, self.draw_count_buffer.handle, 0);

    // Memory barrier: cmdgen writes -> draw reads
    self.insertComputeToDrawBarrier(cmd_buf);

    // === DRAW PASSES ===

    // Solid layer
    vk.vkCmdBindPipeline(cmd_buf, .VK_PIPELINE_BIND_POINT_GRAPHICS, self.solid_pipeline);
    vk.vkCmdBindVertexBuffers(cmd_buf, 0, 1, &self.vertex_buffer, &zero_offset);
    vk.vkCmdBindIndexBuffer(cmd_buf, self.index_buffer, 0, .VK_INDEX_TYPE_UINT32);

    vk.vkCmdDrawIndexedIndirectCount(
        cmd_buf,
        self.gpu_draw_buffer.handle,                    // Command buffer
        0,                                               // Offset to solid commands
        self.draw_count_buffer.handle,                  // Count buffer
        @offsetOf(DrawCountData, "solid_count"),        // Offset to count
        MAX_DRAWS_PER_LAYER,                            // Max draw count
        @sizeOf(IndirectDrawCommand),                   // Stride
    );

    // Cutout layer
    vk.vkCmdBindPipeline(cmd_buf, .VK_PIPELINE_BIND_POINT_GRAPHICS, self.cutout_pipeline);

    vk.vkCmdDrawIndexedIndirectCount(
        cmd_buf,
        self.gpu_draw_buffer.handle,
        MAX_DRAWS_PER_LAYER * @sizeOf(IndirectDrawCommand),  // Offset to cutout commands
        self.draw_count_buffer.handle,
        @offsetOf(DrawCountData, "cutout_count"),
        MAX_DRAWS_PER_LAYER,
        @sizeOf(IndirectDrawCommand),
    );

    // Translucent layer
    vk.vkCmdBindPipeline(cmd_buf, .VK_PIPELINE_BIND_POINT_GRAPHICS, self.translucent_pipeline);

    vk.vkCmdDrawIndexedIndirectCount(
        cmd_buf,
        self.gpu_draw_buffer.handle,
        2 * MAX_DRAWS_PER_LAYER * @sizeOf(IndirectDrawCommand),  // Offset to translucent
        self.draw_count_buffer.handle,
        @offsetOf(DrawCountData, "translucent_count"),
        MAX_DRAWS_PER_LAYER,
        @sizeOf(IndirectDrawCommand),
    );
}

fn insertComputeBarrier(self: *Self, cmd_buf: vk.VkCommandBuffer) void {
    const barrier = vk.VkMemoryBarrier{
        .sType = .VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .srcAccessMask = .VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = .VK_ACCESS_SHADER_READ_BIT,
    };
    vk.vkCmdPipelineBarrier(
        cmd_buf,
        .VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        .VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        0, 1, &barrier, 0, null, 0, null
    );
}

fn insertComputeToDrawBarrier(self: *Self, cmd_buf: vk.VkCommandBuffer) void {
    const barrier = vk.VkMemoryBarrier{
        .sType = .VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .srcAccessMask = .VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = .VK_ACCESS_INDIRECT_COMMAND_READ_BIT,
    };
    vk.vkCmdPipelineBarrier(
        cmd_buf,
        .VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        .VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT,
        0, 1, &barrier, 0, null, 0, null
    );
}
```

---

## Phase 5: Remove CPU Chunk Iteration

**Effort:** Low | **Impact:** Cleanup | **Risk:** Low

Remove now-unused CPU-side code.

### Delete from ChunkManager.zig

```zig
// DELETE these:
draw_commands: std.ArrayListUnmanaged(ChunkDrawCommand),

pub fn getDrawCommands(self: *Self) []const ChunkDrawCommand { ... }

// The sorting comparator
std.mem.sort(ChunkDrawCommand, self.draw_commands.items, {}, struct { ... });
```

### Keep

```zig
// KEEP: Still needed for dispatch sizing
pub fn getActiveChunkCount(self: *Self) u32 {
    var count: u32 = 0;
    var iter = self.chunk_storage.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.*.isReady()) count += 1;
    }
    return count;
}
```

### Simplify Main Loop (FarHorizonsClient.zig)

```zig
// OLD
const draw_commands = cm.getDrawCommands();
self.render_system.drawFrameMultiArena(..., draw_commands, ...);

// NEW
const chunk_count = cm.getActiveChunkCount();
self.render_system.drawFrameGPUDriven(chunk_count, view_proj, camera_pos);
```

---

## Phase 6 (Optional): Occlusion Culling

**Effort:** High | **Impact:** Medium | **Risk:** Medium

Add Voxy-style rasterization-based occlusion culling for additional gains.

### Overview

Instead of just frustum culling, render chunk AABBs against the depth buffer to determine true visibility (chunks behind mountains won't render).

### New Shaders

```
assets/shaders/cull/
  raster.vert      # Transform AABB corners
  raster.frag      # Write visibility on depth pass
```

### raster.vert

```glsl
#version 450

layout(set = 0, binding = 0, std430) readonly buffer ChunkMetadata {
    ChunkGPUData chunks[];
};

layout(push_constant) uniform PushConstants {
    mat4 viewProj;
} pc;

// Vertex ID 0-7 maps to AABB corners
void main() {
    uint chunkIdx = gl_InstanceIndex;
    uint cornerIdx = gl_VertexIndex;

    ChunkGPUData chunk = chunks[chunkIdx];

    // Compute corner position from vertex index
    vec3 corner = vec3(
        (cornerIdx & 1) != 0 ? chunk.aabbMax.x : chunk.aabbMin.x,
        (cornerIdx & 2) != 0 ? chunk.aabbMax.y : chunk.aabbMin.y,
        (cornerIdx & 4) != 0 ? chunk.aabbMax.z : chunk.aabbMin.z
    );

    gl_Position = pc.viewProj * vec4(corner, 1.0);
}
```

### raster.frag

```glsl
#version 450

layout(early_fragment_tests) in;  // Key: only run if depth test passes

layout(set = 0, binding = 1, std430) buffer VisibilityBuffer {
    uint visibility[];
};

layout(push_constant) uniform PushConstants {
    mat4 viewProj;
    uint frameId;
} pc;

flat in uint chunkIdx;

void main() {
    // If we get here, fragment passed depth test = chunk is visible
    atomicExchange(visibility[chunkIdx], pc.frameId);
}
```

### Modified cmdgen.comp

```glsl
// Add visibility check
layout(set = 0, binding = 5, std430) readonly buffer VisibilityBuffer {
    uint visibility[];
};

void main() {
    // ...existing frustum cull...

    // Check occlusion visibility
    if (visibility[idx] != pc.frameId) {
        return;  // Not visible this frame
    }

    // ...generate commands...
}
```

### Render Order with Occlusion

```
1. Render previous frame's visible geometry (using last frame's commands)
2. Run occlusion cull pass (render AABBs against depth from step 1)
3. Run cmdgen.comp (reads visibility buffer)
4. Store commands for next frame
```

This creates a 1-frame latency but provides true occlusion culling.

---

## Buffer Architecture: Single Arena (Voxy Approach)

FarHorizons currently uses multiple vertex/index buffer arenas. For GPU-driven rendering, consolidate to a single large buffer with internal suballocation (what Voxy does):

```java
// From BasicSectionGeometryManager.java
private final BufferArena geometry;  // One big buffer, suballocate within it

public BasicSectionGeometryManager(int maxSectionCount, long geometryCapacity) {
    this.geometry = new BufferArena(geometryCapacity, 8);  // 8-byte alignment
}

// Upload returns offset into the single buffer
int geometryPtr = (int) this.geometry.upload(geometry.geometryBuffer);

// Single shared index buffer for all geometry
glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, SharedIndexBuffer.INSTANCE.id());
```

**Benefits:**
- No buffer rebinding between draws
- Compute shader only needs offsets, not buffer IDs
- Single `vkCmdBindVertexBuffers` / `vkCmdBindIndexBuffer` per frame
- Simpler GPU-driven implementation

**Migration:**
- Replace multi-arena `ChunkBufferManager` with single large buffer + suballocator
- Use power-of-2 growth when buffer fills (allocate larger, copy, free old)

---

## Summary

| Phase         | What Changes         | CPU Work              | Draw Calls      |
| ------------- | -------------------- | --------------------- | --------------- |
| **Current**   | -                    | O(n) iteration + sort | N indirect      |
| **Phase 0**   | +Frustum cull        | O(n) but fewer draws  | Fewer indirect  |
| **Phase 1-2** | +GPU buffers         | O(n) still            | N indirect      |
| **Phase 3-4** | GPU cmdgen           | O(1) dispatch only    | 3 IndirectCount |
| **Phase 5**   | Remove CPU iteration | O(1)                  | 3 IndirectCount |
| **Phase 6**   | +Occlusion cull      | O(1)                  | 3 IndirectCount |

### Recommended Implementation Order

1. **Phase 1** - Add buffer structures (low risk foundation)
2. **Phase 2** - Add compute pipeline infrastructure
3. **Phase 3** - Implement cmdgen.comp (biggest change)
4. **Phase 4** - Switch to DrawIndexedIndirectCount
5. **Phase 5** - Clean up old code
6. **Phase 6** - Optional occlusion culling polish

Skip Phase 0 if going directly to GPU-driven. Each phase can be tested independently.

---

## References

- **Voxy Implementation:** `C:\Users\HTRMC\Dev\Projects\voxy\src\main\resources\assets\voxy\shaders\lod\gl46\cmdgen.comp`
- **Vulkan Spec:** `vkCmdDrawIndexedIndirectCount` (core in Vulkan 1.2)
- **Current FarHorizons:** `src/client/renderer/RenderSystem.zig`, `src/client/world/ChunkManager.zig`
