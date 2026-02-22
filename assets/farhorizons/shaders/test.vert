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
layout(location=2) out vec3 fragLight;

void main() {
    uint faceID = gl_VertexIndex >> 2;
    uint cornerID = gl_VertexIndex & 3;
    uint chunkID = gl_InstanceIndex;

    FaceData face = faces[faceID];
    ChunkData chunk = chunks[chunkID];

    uint x = face.word0 & 0x1F;
    uint y = (face.word0 >> 5) & 0x1F;
    uint z = (face.word0 >> 10) & 0x1F;
    uint texIdx = (face.word0 >> 15) & 0xFF;
    uint normIdx = (face.word0 >> 23) & 0x7;
    uint lightIdx = (face.word0 >> 26) & 0x3F;

    QuadModel model = models[normIdx];
    vec3 block_pos = vec3(float(chunk.position[0]) + float(x),
                          float(chunk.position[1]) + float(y),
                          float(chunk.position[2]) + float(z));
    vec3 corner = vec3(model.corners[cornerID*3], model.corners[cornerID*3+1], model.corners[cornerID*3+2]);
    gl_Position = pc.mvp * vec4(block_pos + corner, 1.0);

    fragUV = vec2(model.uvs[cornerID*2], model.uvs[cornerID*2+1]);
    fragTexIndex = texIdx;

    uint packed = lights[chunk.lightStart + lightIdx].corners[cornerID];
    fragLight = vec3(float(packed & 0xFF), float((packed>>8)&0xFF), float((packed>>16)&0xFF)) / 255.0;

    // Per-vertex ambient occlusion
    uint aoData = face.word1;
    uint aoLevel = (aoData >> (cornerID * 2)) & 0x3;
    const float ao_curve[4] = float[4](1.0, 0.8, 0.6, 0.4);
    fragLight *= ao_curve[aoLevel];
}
