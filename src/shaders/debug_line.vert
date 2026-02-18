#version 450

struct LineVertex {
    float px, py, pz;
    float r, g, b, a;
};

layout(set = 0, binding = 0) readonly buffer VertexBuffer {
    LineVertex vertices[];
};

layout(push_constant) uniform PushConstants {
    mat4 mvp;
} pc;

layout(location = 0) out vec4 fragColor;

void main() {
    LineVertex vert = vertices[gl_VertexIndex];
    gl_Position = pc.mvp * vec4(vert.px, vert.py, vert.pz, 1.0);
    fragColor = vec4(vert.r, vert.g, vert.b, vert.a);
}
