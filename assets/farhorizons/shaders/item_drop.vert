#version 450

layout(set = 0, binding = 0) readonly buffer VertexBuffer {
    float data[];
} vertices;

layout(push_constant) uniform PushConstants {
    mat4 mvp;
    vec4 color;
    vec3 ambient_light;
    float _pad;
} pc;

layout(location = 0) out vec3 fragNormal;

void main() {
    // Each vertex: 3 floats pos + 3 floats normal = 6 floats
    int base = gl_VertexIndex * 6;
    vec3 pos = vec3(vertices.data[base], vertices.data[base + 1], vertices.data[base + 2]);
    vec3 normal = vec3(vertices.data[base + 3], vertices.data[base + 4], vertices.data[base + 5]);

    gl_Position = pc.mvp * vec4(pos, 1.0);
    fragNormal = normal;
}
