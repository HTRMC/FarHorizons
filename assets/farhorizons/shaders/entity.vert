#version 450

struct EntityVertex {
    float px, py, pz;
    float nx, ny, nz;
    float u, v;
};

layout(set = 0, binding = 0) readonly buffer VertexBuffer {
    EntityVertex vertices[];
};

layout(push_constant) uniform PushConstants {
    mat4 mvp;
} pc;

layout(location = 0) out vec2 fragUV;
layout(location = 1) out vec3 fragNormal;

void main() {
    EntityVertex vert = vertices[gl_VertexIndex];
    gl_Position = pc.mvp * vec4(vert.px, vert.py, vert.pz, 1.0);
    fragUV = vec2(vert.u, vert.v);
    fragNormal = vec3(vert.nx, vert.ny, vert.nz);
}
