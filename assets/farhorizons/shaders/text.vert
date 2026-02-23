#version 450

struct TextVertex {
    float px, py;
    float u, v;
    float r, g, b, a;
};

layout(set = 0, binding = 0) readonly buffer VertexBuffer {
    TextVertex vertices[];
};

layout(push_constant) uniform PushConstants {
    mat4 ortho;
} pc;

layout(location = 0) out vec2 fragUV;
layout(location = 1) out vec4 fragColor;

void main() {
    TextVertex vert = vertices[gl_VertexIndex];
    gl_Position = pc.ortho * vec4(vert.px, vert.py, 0.0, 1.0);
    fragUV = vec2(vert.u, vert.v);
    fragColor = vec4(vert.r, vert.g, vert.b, vert.a);
}
