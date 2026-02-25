#version 450

struct UiVertex {
    float px, py;
    float u, v;
    float r, g, b, a;
    float clip_min_x, clip_min_y, clip_max_x, clip_max_y;
};

layout(set = 0, binding = 0) readonly buffer VertexBuffer {
    UiVertex vertices[];
};

layout(push_constant) uniform PushConstants {
    mat4 ortho;
} pc;

layout(location = 0) out vec2 fragUV;
layout(location = 1) out vec4 fragColor;
layout(location = 2) flat out vec4 fragClipRect;

void main() {
    UiVertex vert = vertices[gl_VertexIndex];
    gl_Position = pc.ortho * vec4(vert.px, vert.py, 0.0, 1.0);
    fragUV = vec2(vert.u, vert.v);
    fragColor = vec4(vert.r, vert.g, vert.b, vert.a);
    fragClipRect = vec4(vert.clip_min_x, vert.clip_min_y, vert.clip_max_x, vert.clip_max_y);
}
