#version 450

#fh_import <farhorizons:globals.glsl>
#fh_import <farhorizons:chunk_data.glsl>

// CompactVertex inputs (12 bytes total):
// location 0: A2B10G10R10_UNORM_PACK32 -> vec4 (xyz = position unorm, w = AO index / 3.0)
// location 1: R16G16_UNORM -> vec2 (UV coordinates, hardware-decoded)
// location 2: R32_UINT -> uint (low 8 bits = tex_index)
layout(location = 0) in vec4 inPosAo;
layout(location = 1) in vec2 inTexCoord;
layout(location = 2) in uint inData;

layout(location = 0) out vec3 fragColor;
layout(location = 1) out vec2 fragTexCoord;
layout(location = 2) flat out uint fragTexIndex;

// AO brightness lookup table (must match CompactVertex.AO_TABLE / AO_BRIGHTNESS)
const float AO_TABLE[4] = float[4](0.2, 0.5, 0.8, 1.0);

void main() {
    // Decode chunk-local position from unorm: localPos = inPosAo.xyz * 20.0 - 2.0
    vec3 localPos = inPosAo.xyz * 20.0 - 2.0;

    // Read chunk world origin from metadata SSBO using gl_InstanceIndex (= firstInstance = chunk index)
    vec3 chunkOrigin = chunkData.chunks[gl_InstanceIndex].aabbMin;

    // Reconstruct world position
    vec3 worldPos = localPos + chunkOrigin;

    gl_Position = ubo.proj * ubo.view * ubo.model * vec4(worldPos, 1.0);

    // Decode AO from 2-bit index (stored in alpha channel as unorm: 0/3, 1/3, 2/3, 3/3)
    int aoIndex = int(inPosAo.w * 3.0 + 0.5);
    float ao = AO_TABLE[aoIndex];
    fragColor = vec3(ao, ao, ao);

    // UV comes pre-decoded from R16G16_UNORM hardware conversion
    fragTexCoord = inTexCoord;

    // tex_index from low 8 bits of data word
    fragTexIndex = inData & 0xFFu;
}
