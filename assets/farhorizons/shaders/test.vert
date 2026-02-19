#version 450

struct Vertex {
    float px, py, pz;
    float u, v;
    uint texIndex;
};

layout(set = 0, binding = 0) readonly buffer VertexBuffer {
    Vertex vertices[];
};

layout(push_constant) uniform PushConstants {
    mat4 mvp;
} pc;

layout(location = 0) out vec2 fragUV;
layout(location = 1) flat out uint fragTexIndex;

void main() {
    Vertex vert = vertices[gl_VertexIndex];
    gl_Position = pc.mvp * vec4(vert.px, vert.py, vert.pz, 1.0);
    fragUV = vec2(vert.u, vert.v);
    fragTexIndex = vert.texIndex;
}
