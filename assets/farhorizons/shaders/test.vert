#version 450

struct FaceData { uint word0; uint word1; };
struct QuadModel { float corners[12]; float uvs[8]; float normal[3]; };
struct ChunkData { int position[3]; uint lightStart; uint faceStart; uint faceCounts[6]; };
struct LightEntry { uint corners[4]; };

layout(set=0, binding=0) readonly buffer FaceBuffer { FaceData faces[]; };
layout(set=0, binding=2) readonly buffer ChunkDataBuf { ChunkData chunks[]; };
layout(set=0, binding=3) readonly buffer ModelBuf { QuadModel models[]; };
layout(set=0, binding=4) readonly buffer LightBuf { LightEntry lights[]; };
layout(push_constant) uniform PC { mat4 mvp; } pc;

layout(location=0) out vec2 fragUV;
layout(location=1) flat out uint fragTexIndex;
layout(location=2) out vec3 fragSkyLight;
layout(location=3) flat out uint fragAoData;
layout(location=4) out vec3 fragBlockLight;
layout(location=5) flat out vec3 fragNormal;

void main() {
    uint faceID = gl_VertexIndex >> 2;
    uint cornerID = gl_VertexIndex & 3;
    uint chunkID = gl_InstanceIndex;

    FaceData face = faces[faceID];
    ChunkData chunk = chunks[chunkID];

    // Flip quad diagonal to fix AO interpolation anisotropy:
    // rotating cornerID by 1 changes the index-buffer split from
    // the 0-2 diagonal to the 1-3 diagonal.
    uint flipBit = (face.word1 >> 8) & 0x1;
    cornerID = (cornerID + flipBit) & 3;

    uint x = face.word0 & 0x1F;
    uint y = (face.word0 >> 5) & 0x1F;
    uint z = (face.word0 >> 10) & 0x1F;
    uint texIdx = (face.word0 >> 15) & 0xFF;
    uint normIdx = (face.word0 >> 23) & 0x7;

    QuadModel model = models[normIdx];
    vec3 block_pos = vec3(float(chunk.position[0]) + float(x),
                          float(chunk.position[1]) + float(y),
                          float(chunk.position[2]) + float(z));
    vec3 corner = vec3(model.corners[cornerID*3], model.corners[cornerID*3+1], model.corners[cornerID*3+2]);
    gl_Position = pc.mvp * vec4(block_pos + corner, 1.0);

    fragUV = vec2(model.uvs[cornerID*2], model.uvs[cornerID*2+1]);
    fragTexIndex = texIdx;
    fragNormal = vec3(model.normal[0], model.normal[1], model.normal[2]);

    // Unpack 5-bit light channels: sky_r:5|sky_g:5|sky_b:5|block_r:5|block_g:5|block_b:5
    uint localFace = faceID - chunk.faceStart;
    uint packed = lights[chunk.lightStart + localFace].corners[cornerID];
    float sr = float((packed >>  0) & 0x1F) / 31.0;
    float sg = float((packed >>  5) & 0x1F) / 31.0;
    float sb = float((packed >> 10) & 0x1F) / 31.0;
    float br = float((packed >> 15) & 0x1F) / 31.0;
    float bg = float((packed >> 20) & 0x1F) / 31.0;
    float bb = float((packed >> 25) & 0x1F) / 31.0;
    fragSkyLight = vec3(sr, sg, sb);
    fragBlockLight = vec3(br, bg, bb);

    // Pass raw AO data to fragment shader for bilinear interpolation
    fragAoData = face.word1;
}
