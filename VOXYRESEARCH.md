# Voxy vs FarHorizons: High Render Distance Analysis

## Executive Summary

Voxy achieves render distances of **1-2km+** while FarHorizons is currently limited to ~**256 blocks** (16 chunks). The fundamental difference: **Voxy doesn't render distant terrain at full detail** - it uses a sophisticated LOD system that FarHorizons lacks entirely.

---

# Part 1: What Voxy Does

---

## Key Techniques

### 1. Hierarchical Level-of-Detail (LOD) System

**The Core Idea:** Instead of rendering every block at full detail, voxy uses 5 LOD levels (0-4) where distant terrain is progressively simplified.

| Level | Resolution | Coverage |
|-------|-----------|----------|
| 0 | 1 block per voxel | 32×32×32 blocks |
| 1 | 2 blocks per voxel | 64×64×64 blocks |
| 2 | 4 blocks per voxel | 128×128×128 blocks |
| 3 | 8 blocks per voxel | 256×256×256 blocks |
| 4 | 16 blocks per voxel | 512×512×512 blocks |

**Key Files:**
- `WorldEngine.java` - MAX_LOD_LAYER = 4, section ID encoding
- `WorldSection.java` - 32×32×32 voxel sections with `nonEmptyChildren` tracking
- `NodeManager.java` - Hierarchical octree management

### 2. GPU-Driven Hierarchical Occlusion Culling

**The Magic:** The GPU decides what's visible, not the CPU. This is huge for performance.

**Technique Stack:**
1. **HiZ (Hierarchical Z-Buffer):** Builds mipmap pyramid from depth buffer for fast depth tests
2. **Frustum Culling:** Standard 6-plane AABB tests in compute shader
3. **Screen-Space Size Culling:** Nodes below a pixel threshold aren't subdivided further
4. **Rasterization-Based Visibility:** Renders AABBs to visibility buffer, then generates draw commands

**Key Files:**
- `HierarchicalOcclusionTraverser.java` - Orchestrates GPU culling
- `HiZBuffer.java` - Hierarchical depth buffer
- `traversal_dev.comp` - Core traversal compute shader
- `cmdgen.comp` - Indirect draw command generation

### 3. Multi-Draw Indirect Count (MDIC) Rendering

**Why It's Fast:** Single draw call renders potentially hundreds of thousands of sections.

```
CPU doesn't know what to render → GPU decides visibility → GPU generates draw commands → GPU renders
```

- Uses `glMultiDrawElementsIndirectCountARB`
- Up to 400K opaque + 100K translucent draw commands
- No CPU-GPU round-trips for visibility decisions

**Key File:** `MDICSectionRenderer.java`

### 4. Efficient Data Compression

**Block Storage:** 64-bit packed format per block
```
Light (8 bits) | Block ID (20 bits) | Biome ID (9 bits) | Reserved (27 bits)
```

**Quad Storage:** 8 bytes per quad containing position, size, face, block state, biome, light

**Compression Pipeline:**
1. **Palette encoding** - Only stores unique blocks/biomes per section
2. **Bit-packing** - Dynamic bit width (1-12 bits per entry)
3. **Light optimization** - Single byte if all lights identical
4. **ZSTD/LZ4** - Optional external compression layer

**Key Files:**
- `SaveLoadSystem2.java` - Palette + bitpacking serialization
- `Mapper.java` - Block/biome ID mapping
- `ZSTDCompressor.java`, `LZ4Compressor.java`

### 5. Async Multi-Threaded Architecture

**Thread Distribution:**
| Thread | Purpose |
|--------|---------|
| Main/Render | Frame rendering, GPU uploads |
| AsyncNodeManager | Dedicated thread for node lifecycle |
| 10 Worker Threads | Mesh generation (RenderGenerationService) |
| Model Baking | Block model processing |
| Storage I/O | Database read/write |

**Key Sync Mechanism:** Lock-free VarHandle operations between AsyncNodeManager and render thread

**Key Files:**
- `AsyncNodeManager.java` - Separate thread for node management
- `RenderGenerationService.java` - 10-worker priority queue
- `ServiceManager.java` - Weighted job distribution

### 6. Smart Memory Management

**GPU Memory:**
- `AllocationArena` - Custom allocator with coalescing, RB-tree tracking
- 256MB-4GB geometry buffer (auto-sized to GPU)
- Sparse buffer fallback for low-memory situations

**CPU Memory:**
- 3-tier caching: Primary sharded (64 shards), LRU (1024-2048), Array pool (400)
- Section array reuse eliminates GC pressure
- StampedLock for high-concurrency reads

**Key Files:**
- `AllocationArena.java` - GPU memory allocator
- `ActiveSectionTracker.java` - Multi-tier section caching
- `BufferArena.java` - SSBO management

### 7. Greedy Meshing

**Technique:** `ScanMesher2D` aggregates adjacent same-material faces into larger quads

**Result:** Dramatically fewer quads to render. A flat wall becomes 1 quad instead of hundreds.

**Key File:** `RenderDataFactory.java`

---

## Architecture Overview

```
VoxyRenderSystem
├── ModelBakerySubsystem (block model caching)
├── RenderGenerationService (10 mesh generation workers)
├── AsyncNodeManager (dedicated thread)
│   ├── NodeManager (hierarchical octree)
│   ├── BasicAsyncGeometryManager (GPU uploads)
│   └── GeometryCache (mesh deduplication)
├── HierarchicalOcclusionTraverser (GPU culling)
├── RenderDistanceTracker (spatial load management)
├── MDICSectionRenderer (indirect rendering)
└── WorldEngine
    ├── SectionStorage (RocksDB/LMDB)
    ├── Mapper (block/biome IDs)
    └── ActiveSectionTracker (LRU cache)
```

---

## What Makes This Different From Standard Approaches

| Standard Minecraft | Voxy |
|-------------------|------|
| CPU decides visibility | GPU decides visibility |
| Fixed detail everywhere | 5 LOD levels |
| One draw call per chunk | Single MDIC draw call |
| Vanilla chunk format | 64-bit packed + palette compression |
| Single-threaded meshing | 10-thread priority queue |
| No distant terrain | Renders 1-2km+ with LOD |

---

## Key Shader Pipeline

1. **prep.comp** - Reset counters, initialize buffers
2. **traversal_dev.comp** - Hierarchical tree traversal with frustum/HiZ culling
3. **raster.vert/frag** - AABB rasterization for visibility buffer
4. **cmdgen.comp** - Generate indirect draw commands from visibility
5. **quads3.vert + quads.frag** - Actual rendering with model atlas sampling

---

## Performance Knobs

- `sectionRenderDistance` - How many sections to render (default 16)
- `subDivisionSize` - Screen-space size threshold (28-256, default 64)
- `serviceThreads` - Worker thread count (auto: CPU cores / 1.5)
- Dynamic FPS targeting (55-65 FPS) with adaptive subdivision

---

## Summary: The Secret Sauce

1. **LOD = Don't render what you can't see in detail**
2. **GPU culling = Don't let CPU be the bottleneck**
3. **MDIC = One draw call to rule them all**
4. **Compression = Fit more in memory**
5. **Async = Never stall the render thread**
6. **Greedy meshing = Fewer triangles**

This is a highly sophisticated system that pushes modern GPU capabilities to their limits while maintaining efficient CPU-side data management.

---

# Part 2: What FarHorizons Currently Does

## Current Architecture

| Aspect | FarHorizons Implementation |
|--------|---------------------------|
| **Language/API** | Zig + Vulkan |
| **Chunk Size** | 16×16×16 blocks |
| **Block Storage** | 16-bit packed (8-bit ID + 8-bit state) = 8KB/chunk |
| **View Distance** | 16 chunks horizontal (~256 blocks) |
| **LOD System** | ❌ None |
| **GPU Culling** | ❌ None (relies on Z-buffer) |
| **Frustum Culling** | ❌ None detected |
| **Indirect Rendering** | ✅ Yes (`vkCmdDrawIndexedIndirect`) |
| **Multi-threading** | ✅ C2ME-style 2-phase loading |
| **Memory Management** | ✅ Growable buffer arenas |

## FarHorizons Strengths (Already Implemented)

1. **C2ME-Style Two-Phase Loading** - Terrain gen and meshing decoupled
2. **Growable Buffer Arenas** - Async expansion, no frame stalls
3. **Ring Buffer Chunk Storage** - O(1) access, no hash collisions
4. **Indirect Draw Batching** - Groups by layer/arena
5. **Per-Layer Rendering** - Solid/cutout/translucent separation
6. **Worker Buffer Reuse** - 3.6MB per worker, eliminates GC
7. **Staging Ring Buffer** - Efficient GPU uploads
8. **Ambient Occlusion** - Per-vertex smooth lighting
9. **Occlusion Cache** - LRU cache for face culling tests

---

# Part 3: Gap Analysis - What FarHorizons Is Missing

## 🔴 Critical Missing Features (Required for High Render Distance)

### 1. Level of Detail (LOD) System
**Voxy**: 5 LOD levels (0-4), distant terrain at 16:1 simplification
**FarHorizons**: ❌ All chunks rendered at full detail

**Impact**: This is THE major bottleneck. Without LOD, you cannot render far terrain - the geometry count explodes.

**What Voxy Does**:
- Level 0: 32×32×32 at 1:1 (near)
- Level 4: 32×32×32 representing 512×512×512 blocks (far)
- `WorldSection` with `nonEmptyChildren` tracking for sparse storage
- Hierarchical octree structure managed by `NodeManager`

### 2. GPU-Driven Hierarchical Culling
**Voxy**: Compute shader traverses octree, GPU decides visibility
**FarHorizons**: ❌ No frustum culling, no occlusion culling

**Impact**: Without GPU culling, CPU must decide what to render. This doesn't scale.

**What Voxy Does**:
- `HiZBuffer` - Hierarchical depth buffer for fast occlusion tests
- `traversal_dev.comp` - GPU compute shader traverses LOD tree
- Screen-space size culling - nodes below pixel threshold skipped
- Frustum culling in shader with 6-plane AABB tests

### 3. Multi-Draw Indirect Count (MDIC)
**Voxy**: GPU generates draw commands, single MDIC call renders everything
**FarHorizons**: ⚠️ Has indirect draw, but CPU still decides what to draw

**Impact**: FarHorizons batches draws but CPU still iterates chunks. Voxy's GPU generates commands.

**What Voxy Does**:
- `cmdgen.comp` - GPU generates `DrawIndexedIndirect` commands
- `glMultiDrawElementsIndirectCountARB` - GPU knows count
- Up to 500K draw commands from single CPU call

### 4. Hierarchical World Storage
**Voxy**: Multi-level sections with sparse storage
**FarHorizons**: ❌ Flat chunk storage, no hierarchy

**Impact**: Can't represent distant terrain compactly without hierarchy.

**What Voxy Does**:
- `WorldEngine` with 5 LOD layers
- `WorldSection` - 32³ voxels at each level
- `nonEmptyChildren` byte for sparse traversal
- Section ID packs level + position into 64-bit key

---

## 🟡 Important Missing Features (Significant Performance Impact)

### 5. Frustum Culling
**Voxy**: GPU-side frustum test in traversal shader
**FarHorizons**: ❌ All ready chunks rendered

**Impact**: Rendering chunks behind camera wastes GPU time.

### 6. Greedy Meshing
**Voxy**: `ScanMesher2D` merges adjacent faces into larger quads
**FarHorizons**: ⚠️ Has face culling but not greedy merging

**Impact**: A flat wall is many quads instead of one. More triangles = slower.

### 7. Geometry Compression
**Voxy**: 8 bytes per quad (packed position, size, face, block, biome, light)
**FarHorizons**: 36 bytes per vertex × 4 vertices per face = 144 bytes per quad

**Impact**: ~18× more VRAM per quad. Limits how much geometry fits in memory.

### 8. Palette-Based Block Compression
**Voxy**: Palette encoding + bit-packing + ZSTD/LZ4
**FarHorizons**: Fixed 16-bit per block, no compression

**Impact**: For storage/streaming, voxy can compress 50-80%.

### 9. Async Node Manager Thread
**Voxy**: Dedicated thread for LOD tree management with lock-free sync
**FarHorizons**: Main thread handles chunk state

**Impact**: Render thread never stalls on node operations in voxy.

---

## 🟢 Already Comparable (FarHorizons Does Well)

| Feature | Voxy | FarHorizons |
|---------|------|-------------|
| Multi-threaded meshing | 10 workers | Configurable workers |
| Async GPU uploads | Persistent mapped buffers | Staging ring buffer |
| Per-layer rendering | 3 layers | 3 layers (solid/cutout/translucent) |
| Indirect draw calls | ✅ MDIC | ✅ Indirect indexed |
| Buffer arena management | AllocationArena | GrowableBufferArena |
| Block model system | Runtime baking | JSON-based model loading |
| Texture arrays | Bindless-like | Texture array indexing |

---

# Part 4: Priority Recommendations

## To Achieve Voxy-Like Render Distances

### Phase 1: Foundation (Required)
1. **Implement LOD System** - Multi-level world sections (most critical)
2. **Add Frustum Culling** - CPU-side first, then GPU
3. **Hierarchical Storage** - Octree or level-based sections

### Phase 2: GPU Acceleration
4. **GPU Occlusion Culling** - HiZ buffer + compute shader
5. **GPU Command Generation** - Move draw decision to GPU
6. **MDIC Rendering** - `vkCmdDrawIndexedIndirectCount`

### Phase 3: Optimization
7. **Greedy Meshing** - Merge adjacent same-material faces
8. **Geometry Compression** - Pack quads into fewer bytes
9. **Block Data Compression** - Palette + bit-packing for storage

---

# Summary Comparison Table

| Technique | Voxy | FarHorizons | Priority |
|-----------|------|-------------|----------|
| LOD System | ✅ 5 levels | ❌ None | 🔴 Critical |
| GPU Culling | ✅ HiZ + Compute | ❌ None | 🔴 Critical |
| Frustum Culling | ✅ GPU | ❌ None | 🔴 Critical |
| Hierarchical Storage | ✅ Octree-like | ❌ Flat | 🔴 Critical |
| MDIC Rendering | ✅ GPU count | ⚠️ CPU count | 🟡 Important |
| Greedy Meshing | ✅ ScanMesher2D | ❌ Per-face | 🟡 Important |
| Geometry Compression | ✅ 8 bytes/quad | ❌ 144 bytes/quad | 🟡 Important |
| Block Compression | ✅ Palette+ZSTD | ❌ Fixed 16-bit | 🟢 Nice-to-have |
| Multi-thread Meshing | ✅ | ✅ | ✅ Done |
| Async GPU Upload | ✅ | ✅ | ✅ Done |
| Per-layer Render | ✅ | ✅ | ✅ Done |
| Indirect Draw | ✅ | ✅ | ✅ Done |

---

## The Bottom Line

**FarHorizons can't achieve high render distances without an LOD system.** Everything else is optimization. The core architectural difference is:

- **Voxy**: "Render distant terrain at lower detail"
- **FarHorizons**: "Render all terrain at full detail" (limits max distance)

To match voxy's capabilities, FarHorizons needs:
1. Hierarchical LOD world representation
2. GPU-driven visibility determination
3. Efficient distant terrain mesh generation

The good news: FarHorizons already has solid foundations (Vulkan, indirect draw, multi-threading, buffer management) that will support these additions.

---

# Part 5: Deep Dive - How Voxy's LOD System Actually Works

## Overview

Voxy's LOD is NOT about simplifying geometry at distance. It's about:
1. **Hierarchical spatial organization** - World divided into multi-level sections
2. **GPU-driven traversal** - Compute shader decides what to render
3. **Screen-space LOD selection** - If a node covers fewer pixels than threshold, don't subdivide

## Data Structures

### 1. WorldSection - The Core Unit

Every LOD level uses the same 32×32×32 section structure:

```
WorldSection {
    long[] data;              // 32,768 blocks (32³)
    byte nonEmptyChildren;    // 8-bit mask: which octants have data
    int atomicState;          // Bit 0 = loaded, bits 1-30 = ref count
}
```

**Index calculation:**
```
index = (y << 10) | (z << 5) | x
// x: bits 0-4, z: bits 5-9, y: bits 10-14
```

**NonEmptyChildren bitmask (for sparse traversal):**
```
Bit 0: child at (x&1=0, y&1=0, z&1=0)
Bit 1: child at (x&1=1, y&1=0, z&1=0)
Bit 2: child at (x&1=0, y&1=0, z&1=1)
...
Bit 7: child at (x&1=1, y&1=1, z&1=1)
```

### 2. Section ID Encoding (64-bit)

```
Bits 60-63 (4 bits):  LOD Level (0-4)
Bits 52-59 (8 bits):  Y coordinate
Bits 28-51 (24 bits): Z coordinate
Bits 4-27 (24 bits):  X coordinate
Bits 0-3 (4 bits):    Reserved
```

**Decoding:**
```java
level = (id >> 60) & 0xF
y = (id >> 52) & 0xFF
z = (id >> 28) & 0xFFFFFF
x = (id >> 4) & 0xFFFFFF
```

### 3. LOD Level to World Coordinates

| Level | Section Size | World Coverage | Block Resolution |
|-------|--------------|----------------|------------------|
| 0 | 32×32×32 | 32×32×32 blocks | 1:1 (full detail) |
| 1 | 32×32×32 | 64×64×64 blocks | 2:1 |
| 2 | 32×32×32 | 128×128×128 blocks | 4:1 |
| 3 | 32×32×32 | 256×256×256 blocks | 8:1 |
| 4 | 32×32×32 | 512×512×512 blocks | 16:1 |

**Key insight:** Every level stores 32³ voxels. Higher levels just represent larger world areas.

**World coordinate calculation:**
```
worldBlockX = sectionX * 32 * (1 << level)
worldBlockY = sectionY * 32 * (1 << level)
worldBlockZ = sectionZ * 32 * (1 << level)
```

### 4. Node Storage (GPU-side)

Each node is 16 bytes (4 × uint32):

```
node[0]: Position (packed section ID)
node[1]:
  - bits 0-23:  Geometry pointer (mesh ID)
  - bits 24-47: Child pointer (first child index)
  - bits 48-55: Child existence mask (8 bits)
  - bits 56-58: Child count - 1 (3 bits, 1-8 children)
  - bit 59:     Geometry in-flight flag
  - bit 63:     Request in-flight flag
node[2]: Request ID + flags
node[3]: Reserved
```

## Parent-Child Relationships

**Parent → Children:**
```
parentLevel = N
childLevel = N - 1

For each bit i in nonEmptyChildren (0-7):
    childX = (parentX << 1) | (i & 1)
    childY = (parentY << 1) | ((i >> 2) & 1)
    childZ = (parentZ << 1) | ((i >> 1) & 1)
```

**Child → Parent:**
```
parentX = childX >> 1
parentY = childY >> 1
parentZ = childZ >> 1
parentLevel = childLevel + 1
```

## GPU Traversal Algorithm

### The Core Decision Loop (compute shader)

```glsl
void traverse(UnpackedNode node) {
    // 1. Compute screen-space projection
    setupScreenspace(node);

    // 2. Early culling
    if (outsideFrustum() || isCulledByHiz()) {
        return;  // DISCARD
    }

    // 3. LOD decision
    if (node.lodLevel != 0 && shouldDescend()) {
        // Need more detail
        if (hasChildren(node)) {
            enqueueChildren(node);  // Process children next iteration
        } else {
            addRequest(node);       // Request children to be loaded
            enqueueSelfForRender(node);  // Render self as fallback
        }
    } else {
        // Current detail is enough
        if (hasMesh(node)) {
            enqueueSelfForRender(node);
        } else {
            addRequest(node);
            if (node.lodLevel != 0) {
                enqueueChildren(node);
            }
        }
    }
}
```

### Screen-Space Size Calculation

```glsl
void setupScreenspace(UnpackedNode node) {
    // World position
    vec3 worldPos = vec3((node.pos << node.lodLevel) - camPos) * 32.0;
    float nodeSize = 32.0 * (1 << node.lodLevel);

    // Project 8 AABB corners
    vec4 corners[8];
    corners[0] = VP * vec4(worldPos, 1);
    corners[1] = VP * vec4(worldPos + vec3(nodeSize, 0, 0), 1);
    // ... all 8 corners

    // Perspective divide to NDC
    for (int i = 0; i < 8; i++) {
        corners[i].xyz /= corners[i].w;
        corners[i].xyz = corners[i].xyz * 0.5 + 0.5;  // [0,1] range
    }

    // Compute 2D projected area using cross products
    screenSize = computeProjectedArea(corners);

    // Store min/max for HiZ culling
    minBB = min(all corners);
    maxBB = max(all corners);
}
```

### The LOD Decision: `shouldDescend()`

```glsl
uniform float minSSS;  // Minimum screen-space size threshold

bool shouldDescend() {
    return screenSize > minSSS;
}
```

**minSSS calculation (CPU-side):**
```java
float subDivisionSize = 64;  // pixels (configurable 28-256)
float minSSS = (subDivisionSize * subDivisionSize) / (viewportWidth * viewportHeight);
```

**Auto-tuning based on FPS:**
```java
if (fps < 55) {
    subDivisionSize = min(subDivisionSize + 2, 256);  // Coarser LOD
}
if (fps > 65) {
    subDivisionSize = max(subDivisionSize - 1, 28);   // Finer LOD
}
```

### HiZ Culling

```glsl
bool isCulledByHiz() {
    // Compute mip level based on screen coverage
    vec2 screenExtent = (maxBB.xy - minBB.xy) * hizSize;
    float mipLevel = floor(log2(max(screenExtent.x, screenExtent.y))) - 1;
    mipLevel = clamp(mipLevel, 0, maxMipLevel);

    // Sample HiZ at that mip level
    float maxDepth = texelFetch(hizSampler, screenCoord, int(mipLevel)).r;

    // Cull if all sampled depths are closer than node's minimum depth
    return maxDepth <= minBB.z;
}
```

## Iteration Structure

The traversal runs in **layers**, one compute dispatch per LOD level:

```
Iteration 0: Process top-level nodes (LOD 4)
  └─ Enqueue visible children to scratch buffer A

Iteration 1: Process LOD 3 nodes from buffer A
  └─ Enqueue visible children to scratch buffer B

Iteration 2: Process LOD 2 nodes from buffer B
  └─ Enqueue visible children to scratch buffer A (flip-flop)

... up to MAX_ITERATIONS (16)
```

**Queue metadata (per iteration):**
```
uvec4 {
    .x = dispatch width (workgroups)
    .y = 1
    .z = 1
    .w = queue size (node count)
}
```

## Request System (Async Child Loading)

When the GPU needs children that aren't loaded:

1. **GPU adds request:** `requestQueue[atomicAdd(requestCount, 1)] = nodePosition`
2. **CPU reads request buffer** after frame
3. **AsyncNodeManager thread** processes requests:
   - Load/generate child sections from storage
   - Generate meshes for children
   - Update node's child pointer
4. **Next frame:** Children available for traversal

**Rate limiting:**
```java
// Limit requests based on mesh generation queue depth
double fillness = (4000 - meshGenQueue.size()) / 4000.0;
int maxRequests = (int)(fillness * fillness * 50);  // 0-50 requests
```

## Mesh Generation

**Key insight:** Voxy uses the SAME mesher for ALL LOD levels. There's no geometry simplification.

The "LOD" comes from:
1. **Spatial aggregation:** Level 2 section represents 4× the world area
2. **Rendering selection:** GPU decides which level to render based on screen size
3. **Priority:** Near sections (LOD 0) mesh first, distant (LOD 4) mesh later

**Greedy meshing (ScanMesher2D):**
- Processes 32×32 layers
- Merges adjacent same-material blocks horizontally (up to 16 wide)
- Merges identical rows vertically (up to 16 tall)
- Result: 1 quad instead of up to 256 per-block quads

## Summary: What FarHorizons Needs to Implement

### Minimum Viable LOD System

1. **Multi-level section storage**
   - Same 16×16×16 or 32×32×32 structure at each level
   - Section ID encoding with level + coordinates
   - `nonEmptyChildren` bitmask for sparse traversal

2. **Hierarchical node tree**
   - Nodes track: position, mesh pointer, child pointer, child existence
   - Parent-child coordinate relationships (shift + mask)

3. **Screen-space LOD selection**
   - Project node AABB to screen
   - Compute projected area
   - Compare to threshold (`shouldDescend = screenSize > minSSS`)

4. **Iterative traversal**
   - Process one LOD level per iteration
   - Flip-flop between queue buffers
   - Enqueue children or render self

5. **Request system**
   - GPU outputs requests for missing children
   - CPU processes requests async
   - Children available next frame

### Nice-to-Have (Performance)

6. **HiZ culling** - Build depth pyramid, cull occluded nodes
7. **Frustum culling** - 6-plane AABB test
8. **Adaptive threshold** - Auto-tune `minSSS` based on FPS
9. **Greedy meshing** - Reduce quad count dramatically

---

# Part 6: OpenGL → Vulkan Translation Guide

## Buffer Types

| Voxy (OpenGL) | FarHorizons (Vulkan) | Purpose |
|---------------|----------------------|---------|
| `GL_SHADER_STORAGE_BUFFER` (SSBO) | `VK_BUFFER_USAGE_STORAGE_BUFFER_BIT` | Node data, queues, requests |
| `GL_DRAW_INDIRECT_BUFFER` | `VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT` | Indirect draw commands |
| `GL_UNIFORM_BUFFER` | `VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT` | Per-frame constants |
| Persistent mapped buffer | `VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT` + `vkMapMemory` | CPU→GPU uploads |

## Compute Shader Setup

### Voxy (OpenGL)
```java
// Bind SSBOs
glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, nodeBuffer);
glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 1, queueSourceBuffer);
glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 2, queueSinkBuffer);
glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 3, renderQueueBuffer);
glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 4, requestQueueBuffer);

// Dispatch
glDispatchCompute(workgroupsX, 1, 1);
glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);
```

### FarHorizons (Vulkan)
```zig
// Descriptor set layout
const bindings = [_]vk.DescriptorSetLayoutBinding{
    .{ .binding = 0, .descriptor_type = .storage_buffer, ... },  // nodes
    .{ .binding = 1, .descriptor_type = .storage_buffer, ... },  // queue source
    .{ .binding = 2, .descriptor_type = .storage_buffer, ... },  // queue sink
    .{ .binding =3, .descriptor_type = .storage_buffer, ... },  // render queue
    .{ .binding = 4, .descriptor_type = .storage_buffer, ... },  // request queue
};

// Record commands
vk.cmdBindPipeline(cmd, .compute, traversal_pipeline);
vk.cmdBindDescriptorSets(cmd, .compute, layout, 0, &.{descriptor_set}, &.{});
vk.cmdDispatch(cmd, workgroups_x, 1, 1);

// Memory barrier
const barrier = vk.MemoryBarrier{
    .src_access_mask = .{ .shader_write_bit = true },
    .dst_access_mask = .{ .shader_read_bit = true, .indirect_command_read_bit = true },
};
vk.cmdPipelineBarrier(cmd, .compute_shader_bit, .compute_shader_bit | .draw_indirect_bit, ...);
```

## Indirect Dispatch (Iterative Traversal)

### Voxy (OpenGL)
```java
// Queue metadata buffer contains dispatch parameters
// struct { uvec4 metadata[16]; } where .xyz = dispatch size
glDispatchComputeIndirect(iteration * 16);  // Offset into metadata buffer
```

### FarHorizons (Vulkan)
```zig
// VkDispatchIndirectCommand struct: { u32 x, y, z }
// Store at offset = iteration * sizeof(VkDispatchIndirectCommand)

vk.cmdDispatchIndirect(cmd, metadata_buffer, iteration * 12);
```

**Buffer layout:**
```
Offset 0:   { workgroups_x, 1, 1 }  // Iteration 0
Offset 12:  { workgroups_x, 1, 1 }  // Iteration 1
Offset 24:  { workgroups_x, 1, 1 }  // Iteration 2
...
```

## Queue Flip-Flop Pattern

### Voxy (OpenGL)
```java
for (int iter = 0; iter < MAX_ITERATIONS; iter++) {
    // Alternate between buffers A and B
    glBindBufferBase(SSBO, SOURCE_BINDING, (iter & 1) == 0 ? bufferA : bufferB);
    glBindBufferBase(SSBO, SINK_BINDING,   (iter & 1) == 0 ? bufferB : bufferA);
    glDispatchComputeIndirect(iter * 16);
    glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);
}
```

### FarHorizons (Vulkan)
```zig
// Option 1: Multiple descriptor sets (preferred)
const desc_sets = [2]vk.DescriptorSet{ desc_set_a_to_b, desc_set_b_to_a };

for (0..MAX_ITERATIONS) |iter| {
    vk.cmdBindDescriptorSets(cmd, .compute, layout, 0, &.{desc_sets[iter & 1]}, &.{});
    vk.cmdDispatchIndirect(cmd, metadata_buffer, iter * 12);

    // Barrier between iterations
    vk.cmdPipelineBarrier(cmd, .compute_shader_bit, .compute_shader_bit | .draw_indirect_bit, ...);
}

// Option 2: Dynamic offsets (if using single descriptor set)
// Use push constants or dynamic buffer offsets to swap source/sink
```

## HiZ Buffer Generation

### Voxy (OpenGL)
```java
// Generate mipmap pyramid from depth buffer
glBindTexture(GL_TEXTURE_2D, hizTexture);
glGenerateMipmap(GL_TEXTURE_2D);
// Or use compute shader for max reduction
```

### FarHorizons (Vulkan)
```zig
// Vulkan doesn't have glGenerateMipmap - must do manually

// Option 1: Blit chain (simpler but uses max filter)
for (1..mip_levels) |mip| {
    const src_region = vk.ImageBlit{ .src_subresource = .{ .mip_level = mip - 1, ... }, ... };
    const dst_region = vk.ImageBlit{ .dst_subresource = .{ .mip_level = mip, ... }, ... };
    vk.cmdBlitImage(cmd, depth_image, .transfer_src_optimal,
                    hiz_image, .transfer_dst_optimal, &.{blit}, .nearest);
    // Transition mip for next iteration
}

// Option 2: Compute shader (better - proper max reduction)
// hiz_downsample.comp:
//   Read 2x2 texels from mip N
//   Write max(4 texels) to mip N+1
```

**Compute shader for HiZ:**
```glsl
// hiz_downsample.comp
layout(set = 0, binding = 0) uniform sampler2D srcMip;
layout(set = 0, binding = 1, r32f) uniform writeonly image2D dstMip;

layout(local_size_x = 8, local_size_y = 8) in;

void main() {
    ivec2 dstCoord = ivec2(gl_GlobalInvocationID.xy);
    ivec2 srcCoord = dstCoord * 2;

    float d00 = texelFetch(srcMip, srcCoord + ivec2(0,0), 0).r;
    float d10 = texelFetch(srcMip, srcCoord + ivec2(1,0), 0).r;
    float d01 = texelFetch(srcMip, srcCoord + ivec2(0,1), 0).r;
    float d11 = texelFetch(srcMip, srcCoord + ivec2(1,1), 0).r;

    // For reversed-Z: use min. For normal Z: use max.
    float maxDepth = max(max(d00, d10), max(d01, d11));

    imageStore(dstMip, dstCoord, vec4(maxDepth));
}
```

## Multi-Draw Indirect Count

### Voxy (OpenGL)
```java
// GPU writes draw commands to buffer
// GPU also writes count to separate location
glMultiDrawElementsIndirectCountARB(
    GL_TRIANGLES,
    GL_UNSIGNED_INT,
    drawCommandBuffer,     // Commands
    countOffset,           // Offset to count
    maxDrawCount,          // Upper limit
    sizeof(DrawCommand)    // Stride
);
```

### FarHorizons (Vulkan)
```zig
// Requires VK_KHR_draw_indirect_count extension (core in Vulkan 1.2)

// Check feature support
if (physical_device_features.draw_indirect_count) {
    vk.cmdDrawIndexedIndirectCount(
        cmd,
        draw_command_buffer,
        0,                      // Command buffer offset
        count_buffer,
        count_offset,           // Offset to u32 count
        max_draw_count,
        @sizeOf(VkDrawIndexedIndirectCommand)  // 20 bytes
    );
} else {
    // Fallback: read count on CPU (slower)
    // Or use indirect dispatch + compute to filter
}
```

**VkDrawIndexedIndirectCommand structure:**
```zig
const VkDrawIndexedIndirectCommand = extern struct {
    index_count: u32,
    instance_count: u32,
    first_index: u32,
    vertex_offset: i32,
    first_instance: u32,
};
```

## Synchronization Patterns

### Voxy (OpenGL)
```java
// Implicit synchronization with barriers
glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT | GL_COMMAND_BARRIER_BIT);
```

### FarHorizons (Vulkan)
```zig
// Explicit pipeline barriers required

// After compute writes to render queue:
const compute_to_draw_barrier = vk.BufferMemoryBarrier{
    .src_access_mask = .{ .shader_write_bit = true },
    .dst_access_mask = .{ .indirect_command_read_bit = true, .vertex_attribute_read_bit = true },
    .buffer = render_queue_buffer,
    .offset = 0,
    .size = vk.WHOLE_SIZE,
};

vk.cmdPipelineBarrier(
    cmd,
    .{ .compute_shader_bit = true },              // srcStageMask
    .{ .draw_indirect_bit = true, .vertex_input_bit = true },  // dstStageMask
    .{},  // dependency flags
    &.{},  // memory barriers
    &.{compute_to_draw_barrier},  // buffer barriers
    &.{},  // image barriers
);
```

## Request Queue Readback

### Voxy (OpenGL)
```java
// Map buffer to read GPU-generated requests
ByteBuffer mapped = glMapBufferRange(GL_SHADER_STORAGE_BUFFER,
    0, requestQueueSize, GL_MAP_READ_BIT);
int count = mapped.getInt(0);
for (int i = 0; i < count; i++) {
    long position = mapped.getLong(8 + i * 8);
    processRequest(position);
}
glUnmapBuffer(GL_SHADER_STORAGE_BUFFER);
```

### FarHorizons (Vulkan)
```zig
// Option 1: Staging buffer + transfer (non-blocking)
vk.cmdCopyBuffer(cmd, request_buffer, staging_buffer, &.{copy_region});
// Submit, wait for fence, then read from mapped staging buffer

// Option 2: HOST_VISIBLE request buffer (simpler but may be slower)
const mapped = @ptrCast([*]u32, vk.mapMemory(device, request_memory, 0, size, .{}));
const count = mapped[0];
for (0..count) |i| {
    const position = @as(u64, mapped[2 + i*2]) << 32 | mapped[2 + i*2 + 1];
    processRequest(position);
}
vk.unmapMemory(device, request_memory);
```

## Complete Pipeline Overview

```
Frame N:
┌─────────────────────────────────────────────────────────────────┐
│ 1. DEPTH PREPASS (render near chunks, write depth)              │
│    └─ Output: depth buffer                                      │
├─────────────────────────────────────────────────────────────────┤
│ 2. HIZ GENERATION (compute shader chain)                        │
│    └─ Input: depth buffer                                       │
│    └─ Output: HiZ mipmap pyramid                                │
├─────────────────────────────────────────────────────────────────┤
│ 3. LOD TRAVERSAL (compute shader, N iterations)                 │
│    └─ Input: node buffer, HiZ, camera matrices                  │
│    └─ Output: render queue, request queue                       │
│    └─ Barrier: compute → indirect + vertex                      │
├─────────────────────────────────────────────────────────────────┤
│ 4. LOD RENDERING (graphics, indirect count)                     │
│    └─ Input: render queue, geometry buffers                     │
│    └─ vkCmdDrawIndexedIndirectCount(...)                        │
├─────────────────────────────────────────────────────────────────┤
│ 5. REQUEST READBACK (async, for next frame)                     │
│    └─ Copy request queue → staging                              │
│    └─ CPU processes requests on separate thread                 │
└─────────────────────────────────────────────────────────────────┘
```

## Vulkan-Specific Considerations

### 1. Descriptor Set Strategy

**Recommended:** Use 2 descriptor sets for queue flip-flop:
- Set A: source=queueA, sink=queueB
- Set B: source=queueB, sink=queueA

Bind alternating sets each iteration.

### 2. Push Constants for Per-Iteration Data

```zig
const TraversalPushConstants = extern struct {
    iteration: u32,
    minSSS: f32,
    frameId: u32,
    _padding: u32,
};

vk.cmdPushConstants(cmd, layout, .{ .compute_bit = true }, 0, @sizeOf(TraversalPushConstants), &push_constants);
```

### 3. Subgroup Operations (Optional Optimization)

Vulkan 1.1+ supports subgroup operations for efficient reductions:
```glsl
// In traversal shader
uint visibleCount = subgroupAdd(isVisible ? 1 : 0);
if (subgroupElect()) {
    atomicAdd(renderQueueCount, visibleCount);
}
```

### 4. Timeline Semaphores for Async Requests

```zig
// Frame N compute submits with timeline semaphore value N
// Async thread waits for value N, processes requests
// Frame N+1 can use new nodes

const wait_info = vk.SemaphoreWaitInfo{
    .semaphore_count = 1,
    .p_semaphores = &timeline_semaphore,
    .p_values = &@as(u64, frame_number),
};
vk.waitSemaphores(device, &wait_info, timeout);
```

## Zig Code Skeleton

Here's a minimal skeleton for the traversal system in Zig:

```zig
const LodTraverser = struct {
    device: vk.Device,

    // Pipelines
    traversal_pipeline: vk.Pipeline,
    hiz_pipeline: vk.Pipeline,

    // Buffers
    node_buffer: GpuBuffer,
    queue_a: GpuBuffer,
    queue_b: GpuBuffer,
    render_queue: GpuBuffer,
    request_queue: GpuBuffer,
    dispatch_metadata: GpuBuffer,

    // Descriptor sets (for flip-flop)
    desc_sets: [2]vk.DescriptorSet,

    // HiZ
    hiz_image: vk.Image,
    hiz_views: []vk.ImageView,  // One per mip level

    const MAX_ITERATIONS = 5;

    pub fn recordTraversal(self: *LodTraverser, cmd: vk.CommandBuffer, viewport: Viewport) void {
        // 1. Generate HiZ
        self.recordHizGeneration(cmd);

        // 2. Reset dispatch metadata
        vk.cmdFillBuffer(cmd, self.dispatch_metadata.handle, 0, @sizeOf(u32) * 4 * MAX_ITERATIONS, 0);
        // Set initial dispatch size for iteration 0
        // ...

        // 3. Traversal iterations
        vk.cmdBindPipeline(cmd, .compute, self.traversal_pipeline);

        for (0..MAX_ITERATIONS) |iter| {
            // Bind appropriate descriptor set for flip-flop
            vk.cmdBindDescriptorSets(cmd, .compute, self.pipeline_layout, 0,
                &.{self.desc_sets[iter & 1]}, &.{});

            // Push iteration-specific constants
            const push = TraversalPushConstants{
                .iteration = @intCast(iter),
                .minSSS = viewport.minScreenSpaceSize(),
                .frameId = viewport.frameId,
            };
            vk.cmdPushConstants(cmd, self.pipeline_layout, .{ .compute_bit = true },
                0, @sizeOf(TraversalPushConstants), std.mem.asBytes(&push));

            // Indirect dispatch
            vk.cmdDispatchIndirect(cmd, self.dispatch_metadata.handle, iter * 12);

            // Barrier for next iteration
            self.recordIterationBarrier(cmd);
        }

        // 4. Barrier before rendering
        self.recordComputeToDrawBarrier(cmd);
    }

    pub fn recordLodRendering(self: *LodTraverser, cmd: vk.CommandBuffer,
                               geometry_buffer: GpuBuffer, index_buffer: GpuBuffer) void {
        vk.cmdBindPipeline(cmd, .graphics, self.render_pipeline);
        vk.cmdBindVertexBuffers(cmd, 0, &.{geometry_buffer.handle}, &.{0});
        vk.cmdBindIndexBuffer(cmd, index_buffer.handle, 0, .uint32);

        // Draw with GPU-determined count
        vk.cmdDrawIndexedIndirectCount(
            cmd,
            self.render_queue.handle,  // Draw commands
            @sizeOf(u32),              // Skip count at offset 0
            self.render_queue.handle,  // Count buffer (same buffer)
            0,                          // Count at offset 0
            MAX_DRAW_COMMANDS,
            @sizeOf(vk.DrawIndexedIndirectCommand),
        );
    }
};
```

This gives you a complete mapping from voxy's OpenGL approach to Vulkan patterns that will work with FarHorizons' existing architecture.

---

# Part 7: Memory Requirements Comparison

## Block Data Storage

### FarHorizons (Current)

```
Block storage: 16 bits per block (8-bit ID + 8-bit state)
Chunk size: 16×16×16 = 4,096 blocks
Per chunk: 4,096 × 2 bytes = 8 KB

View distance 16 (diameter 33):
  Horizontal: 33 × 33 = 1,089 columns
  Vertical: 9 sections (assuming y range)
  Total chunks: 1,089 × 9 = 9,801 chunks
  Block data: 9,801 × 8 KB = 78.4 MB
```

### Voxy

```
Block storage: 64 bits per voxel (block ID + biome + light)
Section size: 32×32×32 = 32,768 voxels
Per section: 32,768 × 8 bytes = 256 KB

BUT: Voxy uses LOD, so not all sections are at full detail.

Typical loaded sections (estimated for 1km render distance):
  Level 0 (near):  ~500 sections  × 256 KB = 128 MB
  Level 1:         ~200 sections  × 256 KB = 51 MB
  Level 2:         ~100 sections  × 256 KB = 26 MB
  Level 3:         ~50 sections   × 256 KB = 13 MB
  Level 4 (far):   ~25 sections   × 256 KB = 6 MB
  Total block data: ~224 MB

Voxy also uses compression (ZSTD) for storage, reducing disk I/O.
```

## Geometry (GPU) Memory

### FarHorizons (Current)

```
Vertex format: 36 bytes
  - pos: 3 × f32 = 12 bytes
  - color: 3 × f32 = 12 bytes
  - uv: 2 × f32 = 8 bytes
  - tex_index: u32 = 4 bytes

Per quad: 4 vertices × 36 bytes = 144 bytes
Per face: ~144 bytes + 6 indices × 4 bytes = 168 bytes

Estimated geometry per chunk (average terrain):
  ~1,000 visible faces × 168 bytes = 168 KB

Total GPU geometry (9,801 chunks):
  9,801 × 168 KB = 1.6 GB (!!!)

FarHorizons config:
  vertex_arena_size: 256 MB (default)
  index_arena_size: 128 MB (default)
  Total configured: 384 MB
```

### Voxy

```
Quad format: 8 bytes (packed)
  - position (5+5+5 bits): 15 bits
  - size (4+4 bits): 8 bits
  - face direction: 3 bits
  - block state ID: 16 bits
  - biome ID: 9 bits
  - light: 8 bits
  Total: 64 bits = 8 bytes per quad

Greedy meshing reduces quad count by ~10-50×
  Average terrain: ~50-200 quads per section (vs 1,000+ faces per chunk)

Estimated geometry per section:
  ~100 quads × 8 bytes = 800 bytes

Total GPU geometry (estimated 875 sections):
  875 × 800 bytes = 700 KB (!!!)

Plus metadata per section: 32 bytes × 875 = 28 KB

Voxy geometry buffer config: 256 MB - 4 GB (configurable)
Actual usage: typically < 100 MB for massive render distances
```

## Node Overhead (Voxy Only)

```
Node storage: 16 bytes per node
  - position: 8 bytes
  - mesh ptr + child ptr + flags: 8 bytes

Max nodes: 2^21 = 2 million nodes
Total node buffer: 2M × 16 bytes = 32 MB

Typical active nodes: ~10,000
Active node memory: 10K × 16 bytes = 160 KB
```

## Queue and Request Buffers (Voxy Only)

```
Queue buffers (×2 for flip-flop):
  MAX_QUEUE_SIZE = 200,000 nodes
  Per queue: 200K × 4 bytes = 800 KB
  Both queues: 1.6 MB

Render queue:
  MAX_RENDER_QUEUE = 200,000 entries
  Per entry: 4 bytes (mesh ID)
  Total: 800 KB

Request queue:
  MAX_REQUESTS = 50 entries
  Per entry: 8 bytes (position)
  Total: 400 bytes

Dispatch metadata:
  16 iterations × 16 bytes = 256 bytes

Total traversal buffers: ~3.2 MB
```

## Comparison Summary

### For 256-block render distance (FarHorizons current max)

| Component | FarHorizons | Voxy |
|-----------|-------------|------|
| Block data (CPU) | 78 MB | ~50 MB (fewer sections needed) |
| Geometry (GPU) | **1.6 GB** | **< 10 MB** |
| Node data | N/A | 160 KB |
| Traversal buffers | N/A | 3.2 MB |
| **Total GPU** | **~1.6 GB** | **~15 MB** |

### For 1km render distance (voxy typical)

| Component | FarHorizons | Voxy |
|-----------|-------------|------|
| Block data (CPU) | **Would require ~2 GB+** | ~224 MB |
| Geometry (GPU) | **Would require ~20 GB+** | ~100 MB |
| Node data | N/A | 32 MB |
| Traversal buffers | N/A | 3.2 MB |
| **Total GPU** | **Impossible** | **~135 MB** |

## Why the Massive Difference?

### 1. Vertex Format: 18× overhead

```
FarHorizons: 144 bytes per quad (4 × 36-byte vertices)
Voxy:          8 bytes per quad (packed format)
Ratio: 18×
```

Voxy achieves this by:
- No per-vertex position (computed from quad data in shader)
- No per-vertex color (computed from block state)
- No per-vertex UV (computed from quad position + texture atlas)
- Single 64-bit value encodes entire quad

### 2. Greedy Meshing: 10-50× fewer quads

```
FarHorizons: 1 quad per visible block face
Voxy: 1 quad per contiguous region of same material

Example - flat grass field 32×32:
  FarHorizons: 1,024 quads (32×32 individual faces)
  Voxy: 4 quads (32×32 merged into 4 × 16×16 quads due to max size limit)
  Ratio: 256×
```

### 3. LOD: Only detail where needed

```
1km view distance:
  Without LOD: Must render ~15,000 chunks at full detail
  With LOD: Render ~500 chunks at full detail, rest at reduced resolution

Even with same vertex format, LOD alone provides 30× reduction.
```

## What FarHorizons Could Achieve

### Option A: Packed Vertex Format Only (No LOD)

```
Current: 144 bytes/quad
Packed:    8 bytes/quad
Savings: 18×

Result: 1.6 GB → ~90 MB for current view distance
Could potentially double view distance to 32 chunks (~512 blocks)
```

### Option B: Greedy Meshing Only (No LOD)

```
Current: ~1,000 faces/chunk
Greedy:  ~100 faces/chunk
Savings: 10×

Result: 1.6 GB → ~160 MB
Modest improvement, still limited by chunk count
```

### Option C: LOD System Only (No vertex optimization)

```
Current: 9,801 chunks at full detail
With LOD: ~500 chunks at full detail, ~400 at reduced

But without vertex optimization, each LOD section still uses
significant geometry memory. Savings: ~5-10×

Result: 1.6 GB → ~200-300 MB
Enables larger distances but still memory-heavy
```

### Option D: All Three (Voxy's Approach)

```
Packed vertices (18×) × Greedy meshing (10×) × LOD (10×) = 1800×

Result: 1.6 GB → < 1 MB for same area
Enables 1km+ render distances with < 100 MB GPU memory
```

## Recommended Priority

1. **Packed Vertex Format** - Highest impact, moderate effort
   - Define 8-byte quad structure
   - Modify vertex shader to unpack
   - Immediate 18× GPU memory savings

2. **Greedy Meshing** - High impact, moderate effort
   - Implement ScanMesher2D algorithm
   - 10× quad count reduction
   - Combined with #1: 180× savings

3. **LOD System** - Highest impact for distance, high effort
   - Multi-level section storage
   - Hierarchical traversal
   - Enables unlimited render distance

## Memory Budget Recommendation

For a modern gaming PC with 8GB VRAM:

```
Target GPU memory budget: 512 MB for terrain

With voxy-style optimization:
  512 MB ÷ 8 bytes/quad ÷ 100 quads/section = 640,000 sections

  At LOD 0: 640K sections × 32³ blocks = 21 trillion blocks
  Practically: Multi-km render distances easily achievable

Without optimization (FarHorizons current):
  512 MB ÷ 168 KB/chunk = 3,048 chunks
  View distance: ~17 chunks (current limit)
```

---

# Part 8: Packed Vertex Shader Implementation

## Quad Data Format (8 bytes)

Voxy packs all quad data into a single 64-bit value:

```
Bits 0-4:   X position within section (0-31)
Bits 5-9:   Y position within section (0-31)
Bits 10-14: Z position within section (0-31)
Bits 15-18: Width - 1 (0-15, so 1-16 blocks)
Bits 19-22: Height - 1 (0-15, so 1-16 blocks)
Bits 23-25: Face direction (0-5: -X, +X, -Y, +Y, -Z, +Z)
Bits 26-41: Block state ID (0-65535)
Bits 42-50: Biome ID (0-511)
Bits 51-58: Light level (0-255, packed sky+block)
Bits 59-63: Reserved/flags
```

## GLSL Vertex Shader (Vulkan)

```glsl
#version 450

// ============ INPUTS ============

// Quad data stored in SSBO (8 bytes per quad)
layout(set = 0, binding = 0, std430) readonly buffer QuadData {
    uvec2 quads[];  // Each quad is uvec2 (64 bits)
};

// Section metadata (position, etc.)
layout(set = 0, binding = 1, std430) readonly buffer SectionData {
    ivec4 sections[];  // xyz = section world pos, w = LOD level
};

// Indirect draw provides section index via gl_DrawID (Vulkan 1.2+)
// Or use gl_InstanceIndex if batching sections

// ============ UNIFORMS ============

layout(set = 1, binding = 0) uniform CameraUBO {
    mat4 viewProj;
    vec3 cameraPos;
    float time;
};

// Texture atlas info
layout(set = 1, binding = 1) uniform AtlasUBO {
    vec2 atlasSize;      // e.g., 256x256 tiles
    vec2 tileSize;       // e.g., 16x16 pixels per tile
};

// ============ OUTPUTS ============

layout(location = 0) out vec3 fragColor;
layout(location = 1) out vec2 fragUV;
layout(location = 2) flat out uint fragTexIndex;
layout(location = 3) out float fragAO;

// ============ CONSTANTS ============

// Face normals (indexed by face direction)
const vec3 FACE_NORMALS[6] = vec3[6](
    vec3(-1, 0, 0),  // -X
    vec3( 1, 0, 0),  // +X
    vec3( 0,-1, 0),  // -Y
    vec3( 0, 1, 0),  // +Y
    vec3( 0, 0,-1),  // -Z
    vec3( 0, 0, 1)   // +Z
);

// Face tangent/bitangent for UV generation
const vec3 FACE_TANGENT[6] = vec3[6](
    vec3( 0, 0, 1),  // -X: Z is U
    vec3( 0, 0,-1),  // +X: -Z is U
    vec3( 1, 0, 0),  // -Y: X is U
    vec3( 1, 0, 0),  // +Y: X is U
    vec3(-1, 0, 0),  // -Z: -X is U
    vec3( 1, 0, 0)   // +Z: X is U
);

const vec3 FACE_BITANGENT[6] = vec3[6](
    vec3( 0, 1, 0),  // -X: Y is V
    vec3( 0, 1, 0),  // +X: Y is V
    vec3( 0, 0, 1),  // -Y: Z is V
    vec3( 0, 0,-1),  // +Y: -Z is V
    vec3( 0, 1, 0),  // -Z: Y is V
    vec3( 0, 1, 0)   // +Z: Y is V
);

// Vertex positions within a quad (0-3)
// Triangles: 0-1-2, 2-3-0 (or use index buffer: 0,1,2,2,3,0)
const vec2 QUAD_VERTICES[4] = vec2[4](
    vec2(0, 0),  // Bottom-left
    vec2(1, 0),  // Bottom-right
    vec2(1, 1),  // Top-right
    vec2(0, 1)   // Top-left
);

// Minecraft-style face shading
const float FACE_SHADING[6] = float[6](
    0.6,  // -X (west)
    0.6,  // +X (east)
    0.5,  // -Y (bottom)
    1.0,  // +Y (top)
    0.8,  // -Z (north)
    0.8   // +Z (south)
);

// ============ HELPER FUNCTIONS ============

// Unpack quad data from 64-bit uvec2
void unpackQuad(uvec2 packed, out vec3 pos, out vec2 size, out uint face,
                out uint blockState, out uint biome, out uint light) {
    uint low = packed.x;
    uint high = packed.y;

    // Position (bits 0-14 of low)
    pos.x = float(low & 0x1Fu);
    pos.y = float((low >> 5) & 0x1Fu);
    pos.z = float((low >> 10) & 0x1Fu);

    // Size (bits 15-22 of low)
    size.x = float(((low >> 15) & 0xFu) + 1);
    size.y = float(((low >> 19) & 0xFu) + 1);

    // Face direction (bits 23-25 of low)
    face = (low >> 23) & 0x7u;

    // Block state (bits 26-31 of low + bits 0-9 of high)
    blockState = ((low >> 26) & 0x3Fu) | ((high & 0x3FFu) << 6);

    // Biome (bits 10-18 of high)
    biome = (high >> 10) & 0x1FFu;

    // Light (bits 19-26 of high)
    light = (high >> 19) & 0xFFu;
}

// Compute ambient occlusion from light value
float computeAO(uint light, uint vertexIndex) {
    // Simple: use light level directly
    // Advanced: encode per-vertex AO in additional bits
    float skyLight = float((light >> 4) & 0xFu) / 15.0;
    float blockLight = float(light & 0xFu) / 15.0;
    return max(skyLight, blockLight) * 0.5 + 0.5;
}

// Get texture index from block state (simplified - real impl uses lookup table)
uint getTextureIndex(uint blockState, uint face) {
    // For a real implementation, use a SSBO lookup table:
    // return textureIndices[blockState * 6 + face];

    // Simplified: assume blockState IS the texture index
    return blockState;
}

// ============ MAIN ============

void main() {
    // Determine which quad and which vertex within quad
    uint quadIndex = gl_VertexIndex / 4;
    uint vertexInQuad = gl_VertexIndex % 4;

    // Alternative: use index buffer with 6 indices per quad (0,1,2,2,3,0)
    // uint quadIndex = gl_VertexIndex / 6;
    // uint indexInQuad = gl_VertexIndex % 6;
    // uint vertexInQuad = uint[6](0,1,2,2,3,0)[indexInQuad];

    // Get section info (from gl_DrawID or gl_InstanceIndex)
    ivec4 section = sections[gl_InstanceIndex];
    vec3 sectionWorldPos = vec3(section.xyz) * 32.0;  // Section origin in world
    uint lodLevel = uint(section.w);

    // Load and unpack quad data
    uvec2 packedQuad = quads[quadIndex];
    vec3 quadPos;
    vec2 quadSize;
    uint face, blockState, biome, light;
    unpackQuad(packedQuad, quadPos, quadSize, face, blockState, biome, light);

    // Get vertex position within quad (0-1 range)
    vec2 vertexOffset = QUAD_VERTICES[vertexInQuad];

    // Scale by quad size
    vec2 scaledOffset = vertexOffset * quadSize;

    // Compute 3D offset using face tangent/bitangent
    vec3 tangent = FACE_TANGENT[face];
    vec3 bitangent = FACE_BITANGENT[face];
    vec3 normal = FACE_NORMALS[face];

    // Local position within section
    vec3 localPos = quadPos;
    localPos += tangent * scaledOffset.x;
    localPos += bitangent * scaledOffset.y;

    // Offset by half block in normal direction (face is on block surface)
    localPos += normal * 0.5;

    // Scale by LOD level (higher LOD = larger blocks)
    float lodScale = float(1u << lodLevel);
    localPos *= lodScale;

    // World position
    vec3 worldPos = sectionWorldPos * lodScale + localPos;

    // Transform to clip space
    gl_Position = viewProj * vec4(worldPos, 1.0);

    // ============ COMPUTE FRAGMENT OUTPUTS ============

    // UV coordinates (for texture sampling)
    fragUV = vertexOffset * quadSize;  // Tile UV (will repeat)

    // Texture index from block state
    fragTexIndex = getTextureIndex(blockState, face);

    // Base color from face shading
    float shade = FACE_SHADING[face];
    fragColor = vec3(shade);

    // Ambient occlusion
    fragAO = computeAO(light, vertexInQuad);
}
```

## GLSL Fragment Shader

```glsl
#version 450

layout(location = 0) in vec3 fragColor;
layout(location = 1) in vec2 fragUV;
layout(location = 2) flat in uint fragTexIndex;
layout(location = 3) in float fragAO;

layout(location = 0) out vec4 outColor;

// Texture array (all block textures in one array)
layout(set = 2, binding = 0) uniform sampler2DArray textureSampler;

void main() {
    // Sample texture (UV + texture index as array layer)
    vec4 texColor = texture(textureSampler, vec3(fragUV, float(fragTexIndex)));

    // Alpha test for cutout blocks
    if (texColor.a < 0.5) {
        discard;
    }

    // Apply face shading and ambient occlusion
    vec3 color = texColor.rgb * fragColor * fragAO;

    outColor = vec4(color, texColor.a);
}
```

## CPU-Side: Preparing Draw Commands

```zig
const PackedQuad = packed struct {
    x: u5,           // 0-31
    y: u5,           // 0-31
    z: u5,           // 0-31
    width_m1: u4,    // 0-15 (actual 1-16)
    height_m1: u4,   // 0-15 (actual 1-16)
    face: u3,        // 0-5
    block_state: u16,
    biome: u9,
    light: u8,
    _reserved: u5,
};

fn packQuad(x: u5, y: u5, z: u5, w: u4, h: u4, face: u3,
            block: u16, biome: u9, light: u8) u64 {
    return @as(u64, x)
         | (@as(u64, y) << 5)
         | (@as(u64, z) << 10)
         | (@as(u64, w) << 15)
         | (@as(u64, h) << 19)
         | (@as(u64, face) << 23)
         | (@as(u64, block) << 26)
         | (@as(u64, biome) << 42)
         | (@as(u64, light) << 51);
}

// Example: create a stone block face at (5, 10, 3) facing +Y
const quad = packQuad(5, 10, 3, 0, 0, 3, STONE_TEXTURE_ID, 0, 255);
```

## Indirect Draw Setup

```zig
// Each section gets one indirect draw command
const DrawCommand = extern struct {
    vertex_count: u32,      // quads * 4 (or quads * 6 with index buffer)
    instance_count: u32,    // 1
    first_vertex: u32,      // Offset into quad buffer
    first_instance: u32,    // Section index (passed as gl_InstanceIndex)
};

fn createDrawCommand(section_index: u32, quad_offset: u32, quad_count: u32) DrawCommand {
    return .{
        .vertex_count = quad_count * 4,  // 4 vertices per quad
        .instance_count = 1,
        .first_vertex = quad_offset * 4,
        .first_instance = section_index,
    };
}
```

## Memory Layout

```
QUAD BUFFER (SSBO, binding 0):
┌────────────────────────────────────────┐
│ Section 0 quads (N₀ × 8 bytes)         │
├────────────────────────────────────────┤
│ Section 1 quads (N₁ × 8 bytes)         │
├────────────────────────────────────────┤
│ ...                                    │
└────────────────────────────────────────┘

SECTION BUFFER (SSBO, binding 1):
┌─────────────────────────────┐
│ Section 0: ivec4(x,y,z,lod) │
├─────────────────────────────┤
│ Section 1: ivec4(x,y,z,lod) │
├─────────────────────────────┤
│ ...                         │
└─────────────────────────────┘

DRAW COMMAND BUFFER:
┌─────────────────────────────────────────┐
│ DrawCommand { vertex_count, 1, 0, 0 }   │  ← Section 0
├─────────────────────────────────────────┤
│ DrawCommand { vertex_count, 1, N₀, 1 }  │  ← Section 1
├─────────────────────────────────────────┤
│ ...                                     │
└─────────────────────────────────────────┘
```

## Rendering Call

```zig
// Bind pipeline and descriptor sets
vk.cmdBindPipeline(cmd, .graphics, packed_quad_pipeline);
vk.cmdBindDescriptorSets(cmd, .graphics, layout, 0, &.{
    quad_descriptor,     // Set 0: quad + section SSBOs
    camera_descriptor,   // Set 1: camera UBO, atlas UBO
    texture_descriptor,  // Set 2: texture array
}, &.{});

// Multi-draw indirect (all sections in one call)
vk.cmdDrawIndirect(
    cmd,
    draw_command_buffer,
    0,                     // Offset
    section_count,         // Draw count
    @sizeOf(DrawCommand),  // Stride
);

// Or with GPU-determined count (after LOD traversal):
vk.cmdDrawIndirectCount(
    cmd,
    draw_command_buffer,
    @sizeOf(u32),          // Commands start after count
    count_buffer,
    0,                      // Count at offset 0
    max_sections,
    @sizeOf(DrawCommand),
);
```

## Comparison: Before and After

### Before (FarHorizons current)

```zig
const Vertex = extern struct {
    pos: [3]f32,       // 12 bytes
    color: [3]f32,     // 12 bytes
    uv: [2]f32,        // 8 bytes
    tex_index: u32,    // 4 bytes
};  // Total: 36 bytes × 4 vertices = 144 bytes per quad
```

### After (Packed)

```zig
const PackedQuad = u64;  // 8 bytes per quad (entire quad, not per vertex!)
```

**Savings: 144 → 8 = 18× less GPU memory**

## Optional: Index Buffer for Better Cache Usage

Instead of 4 vertices per quad, use 4 vertices + 6 indices:

```zig
// Global index buffer (reusable for all quads)
const QUAD_INDICES = [6]u16{ 0, 1, 2, 2, 3, 0 };

// Create index buffer once at startup
fn createQuadIndexBuffer(max_quads: u32) GpuBuffer {
    var indices: []u16 = allocator.alloc(u16, max_quads * 6);
    for (0..max_quads) |q| {
        const base = @intCast(u16, q * 4);
        indices[q*6 + 0] = base + 0;
        indices[q*6 + 1] = base + 1;
        indices[q*6 + 2] = base + 2;
        indices[q*6 + 3] = base + 2;
        indices[q*6 + 4] = base + 3;
        indices[q*6 + 5] = base + 0;
    }
    return uploadToGpu(indices);
}
```

Then use `vkCmdDrawIndexedIndirect` instead of `vkCmdDrawIndirect`.

## Performance Notes

1. **gl_VertexIndex math is free** - Modern GPUs handle integer division/modulo efficiently
2. **Texture array sampling** - Same performance as individual textures, better batching
3. **SSBO access** - Cached well when accessed sequentially (quad buffer is sequential)
4. **gl_InstanceIndex for section** - Allows different LOD levels in same draw call

---

# Part 9: Greedy Meshing Algorithm (ScanMesher2D)

## The Problem

Naive meshing creates 1 quad per visible block face:
- A 32×32 flat surface = 1,024 quads
- Massive waste: all same material, could be 1 quad

Greedy meshing merges adjacent same-material faces:
- A 32×32 flat surface = 1-4 quads (limited by max quad size)

## Algorithm Overview

Process each face layer (e.g., all +Y faces at y=10) as a 2D grid:
1. **Horizontal scan**: Merge consecutive same-material cells into runs
2. **Vertical merge**: Combine identical runs from adjacent rows

```
Input (32×32 grid, S=stone, D=dirt, .=air):

SSSSDDDD....
SSSSDDDD....
SSSS........
SSSS........

Output quads:
- Quad 1: (0,0) size 4×4 = stone
- Quad 2: (4,0) size 4×2 = dirt
```

## The ScanMesher2D Algorithm

### Data Structures

```zig
const ScanMesher2D = struct {
    const MAX_SIZE = 16;  // Max quad dimension

    // Per-row tracking
    row_data: [32]u64,     // Material ID for each row's current run
    row_length: [32]u8,    // Horizontal length of current run
    row_depth: [32]u8,     // Vertical depth (merged rows)
    row_start_x: [32]u8,   // Starting X of current run
    row_bitset: u32,       // Which rows have active runs

    // Current position
    current_x: u8,
    current_y: u8,
    current_material: u64,
    current_run_length: u8,

    // Output
    quads: std.ArrayList(PackedQuad),
};
```

### Core Algorithm

```zig
pub fn process(self: *ScanMesher2D, grid: *const [32][32]u64) void {
    // Process row by row (Y direction)
    for (0..32) |y| {
        self.current_y = @intCast(y);
        self.processRow(&grid[y]);
    }
    // Flush any remaining runs
    self.flushAllRuns();
}

fn processRow(self: *ScanMesher2D, row: *const [32]u64) void {
    self.current_run_length = 0;
    self.current_material = 0;  // 0 = air/empty

    for (0..32) |x| {
        const material = row[x];
        self.processCell(@intCast(x), material);
    }

    // End of row: flush current run
    if (self.current_run_length > 0) {
        self.endRun();
    }
}

fn processCell(self: *ScanMesher2D, x: u8, material: u64) void {
    // Same material: extend current run
    if (material == self.current_material and self.current_run_length < MAX_SIZE) {
        self.current_run_length += 1;
        return;
    }

    // Different material or max size: end previous run
    if (self.current_run_length > 0) {
        self.endRun();
    }

    // Start new run
    self.current_material = material;
    self.current_run_length = if (material != 0) 1 else 0;
    self.row_start_x[self.current_y] = x;
}

fn endRun(self: *ScanMesher2D) void {
    if (self.current_material == 0) return;  // Skip air

    const y = self.current_y;
    const x = self.row_start_x[y];
    const length = self.current_run_length;

    // Try to merge with run from previous row
    if (self.canMergeWithPreviousRow(y, x, length)) {
        self.mergeWithPreviousRow(y);
    } else {
        // Can't merge: emit previous row's run if exists
        if (y > 0 and (self.row_bitset & (@as(u32, 1) << (y - 1))) != 0) {
            self.emitRun(y - 1);
        }
        // Start new run at this row
        self.startNewRun(y, x, length);
    }

    self.current_run_length = 0;
}

fn canMergeWithPreviousRow(self: *ScanMesher2D, y: u8, x: u8, length: u8) bool {
    if (y == 0) return false;

    const prev_y = y - 1;

    // Check if previous row has an active run
    if ((self.row_bitset & (@as(u32, 1) << prev_y)) == 0) return false;

    // Check if same position, length, and material
    return self.row_start_x[prev_y] == x
       and self.row_length[prev_y] == length
       and self.row_data[prev_y] == self.current_material
       and self.row_depth[prev_y] < MAX_SIZE;
}

fn mergeWithPreviousRow(self: *ScanMesher2D, y: u8) void {
    const prev_y = y - 1;

    // Extend the run from previous row
    self.row_depth[prev_y] += 1;

    // If max depth reached, emit the quad
    if (self.row_depth[prev_y] >= MAX_SIZE) {
        self.emitRun(prev_y);
    }
}

fn startNewRun(self: *ScanMesher2D, y: u8, x: u8, length: u8) void {
    self.row_data[y] = self.current_material;
    self.row_length[y] = length;
    self.row_depth[y] = 1;
    self.row_start_x[y] = x;
    self.row_bitset |= (@as(u32, 1) << y);
}

fn emitRun(self: *ScanMesher2D, y: u8) void {
    const x = self.row_start_x[y];
    const width = self.row_length[y];
    const height = self.row_depth[y];
    const material = self.row_data[y];

    // Create packed quad
    self.quads.append(.{
        .x = x,
        .y = y - height + 1,  // Start Y (run grew downward)
        .width = width,
        .height = height,
        .material = material,
    });

    // Clear the run
    self.row_bitset &= ~(@as(u32, 1) << y);
}

fn flushAllRuns(self: *ScanMesher2D) void {
    // Emit all remaining active runs
    var bitset = self.row_bitset;
    while (bitset != 0) {
        const y = @ctz(bitset);
        self.emitRun(@intCast(y));
        bitset &= bitset - 1;  // Clear lowest bit
    }
}
```

## Visual Example

### Input: 8×8 grid (S=stone, D=dirt)

```
Row 0: SSSSDDDD
Row 1: SSSSDDDD
Row 2: SSSSSSSS
Row 3: SSSSSSSS
Row 4: DDDDDDDD
Row 5: DDDDDDDD
Row 6: ........
Row 7: ........
```

### Processing Step by Step

```
Row 0: Scan left-to-right
  - Cells 0-3: SSSS → Run(x=0, len=4, mat=S)
  - Cells 4-7: DDDD → End S run, start Run(x=4, len=4, mat=D)
  After row 0:
    row_data[0] = S, row_length[0] = 4, row_start_x[0] = 0, row_depth[0] = 1
    (D run also stored)

Row 1: Scan left-to-right
  - Cells 0-3: SSSS → Same as row 0? Yes! Merge: row_depth[0] = 2
  - Cells 4-7: DDDD → Same as row 0 D? Yes! Merge: depth = 2

Row 2: Scan left-to-right
  - Cells 0-7: SSSSSSSS → Run(x=0, len=8, mat=S)
  - Can merge with row 1? No! (different length)
  - Emit row 1 stone: Quad(0, 0, 4, 2, S)
  - Emit row 1 dirt: Quad(4, 0, 4, 2, D)
  - Start new: row_data[2] = S, len=8, depth=1

Row 3: SSSSSSSS
  - Merge with row 2: depth = 2

Row 4: DDDDDDDD
  - Can't merge (different material)
  - Emit row 3: Quad(0, 2, 8, 2, S)
  - Start new dirt run

Row 5: DDDDDDDD
  - Merge: depth = 2

Rows 6-7: Empty
  - Emit row 5: Quad(0, 4, 8, 2, D)

Final flush: (nothing remaining)
```

### Output: 4 quads instead of 40 faces!

```
Quad 1: (0, 0) size 4×2 = stone   (was 8 blocks)
Quad 2: (4, 0) size 4×2 = dirt    (was 8 blocks)
Quad 3: (0, 2) size 8×2 = stone   (was 16 blocks)
Quad 4: (0, 4) size 8×2 = dirt    (was 16 blocks)
```

## Full Chunk Meshing

For a 3D chunk, run greedy meshing on each face layer:

```zig
pub fn meshChunk(chunk: *const Chunk) ChunkMesh {
    var quads = std.ArrayList(PackedQuad).init(allocator);

    // For each face direction
    for (0..6) |face| {
        // For each slice perpendicular to that face
        const axis = face / 2;  // 0=X, 1=Y, 2=Z
        const slices = if (axis == 1) CHUNK_HEIGHT else CHUNK_SIZE;

        for (0..slices) |slice| {
            // Extract 2D grid of visible faces for this slice
            var grid: [32][32]u64 = undefined;
            extractFaceGrid(chunk, face, slice, &grid);

            // Run greedy meshing
            var mesher = ScanMesher2D.init();
            mesher.process(&grid);

            // Convert to 3D quads and add to output
            for (mesher.quads.items) |quad2d| {
                const quad3d = convert2Dto3D(quad2d, face, slice);
                quads.append(quad3d);
            }
        }
    }

    return ChunkMesh{ .quads = quads };
}

fn extractFaceGrid(chunk: *const Chunk, face: u3, slice: u8, grid: *[32][32]u64) void {
    // face: 0=-X, 1=+X, 2=-Y, 3=+Y, 4=-Z, 5=+Z

    for (0..32) |a| {
        for (0..32) |b| {
            // Convert 2D (a, b) to 3D based on face
            const pos = faceToChunkPos(face, slice, a, b);

            // Check if face is visible (neighbor is air or transparent)
            const block = chunk.getBlock(pos);
            const neighbor_pos = pos + FACE_NORMALS[face];

            if (block.isAir()) {
                grid[a][b] = 0;  // Air = no face
            } else if (neighborIsOccluding(chunk, neighbor_pos)) {
                grid[a][b] = 0;  // Occluded = no face
            } else {
                // Encode material: block ID + face for texture lookup
                grid[a][b] = encodeBlockFace(block, face);
            }
        }
    }
}
```

## Optimization: Bitmask Culling

Before running greedy meshing, use bitmasks to skip empty slices:

```zig
// Pre-compute which slices have any visible faces
pub fn computeSliceMasks(chunk: *const Chunk) [6][32]u32 {
    var masks: [6][32]u32 = undefined;

    for (chunk.blocks, 0..) |block, i| {
        if (block.isAir()) continue;

        const x = i % 16;
        const z = (i / 16) % 16;
        const y = i / 256;

        // Check each face
        for (0..6) |face| {
            const neighbor = getNeighborPos(x, y, z, face);
            if (!chunk.isOccluded(neighbor)) {
                // Mark this slice as having visible faces
                const slice = getSliceForFace(face, x, y, z);
                const bit = getSliceBit(face, x, y, z);
                masks[face][slice] |= (@as(u32, 1) << bit);
            }
        }
    }

    return masks;
}

// Skip empty slices entirely
for (0..6) |face| {
    for (0..32) |slice| {
        if (slice_masks[face][slice] == 0) continue;  // No visible faces
        // ... run greedy meshing
    }
}
```

## Performance Comparison

### Test case: Flat terrain chunk (grass top, dirt sides, stone bottom)

**Naive meshing:**
- Top faces: 16×16 = 256 quads
- Side faces: 4 sides × 16×4 = 256 quads
- Bottom faces: 16×16 = 256 quads (if visible)
- **Total: ~768 quads**

**Greedy meshing:**
- Top: 1 quad (16×16 merged)
- Each side: 1 quad (16×4 merged)
- Bottom: 1 quad (16×16 merged)
- **Total: 6 quads**

**Reduction: 128×**

### Test case: Checkerboard pattern

**Naive meshing:**
- Every other block = 50% faces visible
- ~2,000 quads

**Greedy meshing:**
- No merging possible (alternating materials)
- ~2,000 quads

**Reduction: 1× (worst case)**

### Typical terrain (mixed):

- Naive: ~1,500 quads per chunk
- Greedy: ~100-300 quads per chunk
- **Typical reduction: 5-15×**

## Memory Impact

```
Naive:      1,500 quads × 144 bytes = 216 KB per chunk
Greedy:       150 quads ×   8 bytes =  1.2 KB per chunk

Reduction: 180× (combined with packed quads)

10,000 chunks:
  Naive:   2.16 GB
  Greedy:  12 MB
```

## Implementation Tips

1. **Process layers in parallel** - Each face direction is independent
2. **Reuse mesher instances** - Avoid allocations per chunk
3. **Cache neighbor lookups** - Neighbor chunk data accessed repeatedly
4. **Use bitmasks for empty detection** - Skip slices with no visible faces
5. **Limit max quad size** - 16×16 prevents visual artifacts from large quads

## Voxy's Additional Optimizations

1. **Separate fluid layer** - Water meshed separately (overlays on blocks)
2. **Non-opaque handling** - Transparent blocks (glass) meshed independently
3. **AO baking** - Ambient occlusion computed during meshing, stored in quad
4. **Biome blending** - Biome ID stored per quad for grass/foliage tinting
