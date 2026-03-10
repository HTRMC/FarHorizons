#version 450

struct EntityVertex {
    float px, py, pz;
    float nx, ny, nz;
    float r, g, b, a;
};

layout(set = 0, binding = 0) readonly buffer VertexBuffer {
    EntityVertex vertices[];
};

layout(push_constant) uniform PushConstants {
    mat4 mvp;
} pc;

layout(location = 0) out vec4 fragColor;
layout(location = 1) out vec3 fragNormal;

void main() {
    EntityVertex vert = vertices[gl_VertexIndex];
    gl_Position = pc.mvp * vec4(vert.px, vert.py, vert.pz, 1.0);
    fragColor = vec4(vert.r, vert.g, vert.b, vert.a);
    fragNormal = vec3(vert.nx, vert.ny, vert.nz);
}
