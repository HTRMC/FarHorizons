// Shared chunk metadata structures for vertex shader chunk origin lookup
// Mirrors GPUDrivenTypes.zig layout (std430)

struct LayerGPUData {
    uint vertexOffset;
    uint indexOffset;
    uint indexCount;
    uint arenaIndices;
};

struct ChunkGPUData {
    vec3 worldPos;
    float _pad0;
    vec3 aabbMin;
    float _pad1;
    vec3 aabbMax;
    float _pad2;
    LayerGPUData layers[3];
    vec4 _pad3;
};

layout(set = 0, binding = 2, std430) readonly buffer ChunkMetadataVS {
    ChunkGPUData chunks[];
} chunkData;
