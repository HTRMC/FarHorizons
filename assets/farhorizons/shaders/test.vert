#version 450
#extension GL_ARB_shader_draw_parameters : require

struct Vertex {
    float px, py, pz;
    float u, v;
    uint texIndex;
    float light;
};

layout(set = 0, binding = 0) readonly buffer VertexBuffer {
    Vertex vertices[];
};

layout(set = 0, binding = 2) readonly buffer ChunkPositions {
    vec4 chunk_positions[];
};

layout(push_constant) uniform PushConstants {
    mat4 mvp;
} pc;

layout(location = 0) out vec2 fragUV;
layout(location = 1) flat out uint fragTexIndex;
layout(location = 2) out float fragLight;

void main() {
    Vertex vert = vertices[gl_VertexIndex];
    vec3 chunk_pos = chunk_positions[gl_DrawIDARB].xyz * 16.0;
    vec3 world_pos = chunk_pos + vec3(vert.px, vert.py, vert.pz);
    gl_Position = pc.mvp * vec4(world_pos, 1.0);
    fragUV = vec2(vert.u, vert.v);
    fragTexIndex = vert.texIndex;
    fragLight = vert.light;
}
