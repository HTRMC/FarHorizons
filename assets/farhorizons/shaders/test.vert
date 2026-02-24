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
layout(location=2) flat out uvec4 fragLightPacked;
layout(location=3) flat out uint fragAoData;
layout(location=4) flat out vec3 fragNormal;

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

    // Pass all 4 corners' packed light in UV order for fragment bilinear interpolation
    // All faces: corner0=UV(0,1), corner1=UV(1,1), corner2=UV(1,0), corner3=UV(0,0)
    // UV layout: [0]=UV(0,0)=c3, [1]=UV(1,0)=c2, [2]=UV(0,1)=c0, [3]=UV(1,1)=c1
    uint lightIdx = chunk.lightStart + (faceID - chunk.faceStart);
    fragLightPacked = uvec4(
        lights[lightIdx].corners[3],
        lights[lightIdx].corners[2],
        lights[lightIdx].corners[0],
        lights[lightIdx].corners[1]
    );

    fragAoData = face.word1;
}
