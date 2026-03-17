#version 450

layout(push_constant) uniform PushConstants {
    mat4 mvp;
} pc;

// 6 faces × 2 triangles × 3 vertices = 36 vertices
// Face order: +X, -X, +Y, -Y, +Z, -Z
const vec3 positions[36] = vec3[36](
    // +X face
    vec3(1,0,0), vec3(1,1,0), vec3(1,1,1),
    vec3(1,0,0), vec3(1,1,1), vec3(1,0,1),
    // -X face
    vec3(0,0,1), vec3(0,1,1), vec3(0,1,0),
    vec3(0,0,1), vec3(0,1,0), vec3(0,0,0),
    // +Y face
    vec3(0,1,0), vec3(0,1,1), vec3(1,1,1),
    vec3(0,1,0), vec3(1,1,1), vec3(1,1,0),
    // -Y face
    vec3(0,0,1), vec3(0,0,0), vec3(1,0,0),
    vec3(0,0,1), vec3(1,0,0), vec3(1,0,1),
    // +Z face
    vec3(1,0,1), vec3(1,1,1), vec3(0,1,1),
    vec3(1,0,1), vec3(0,1,1), vec3(0,0,1),
    // -Z face
    vec3(0,0,0), vec3(0,1,0), vec3(1,1,0),
    vec3(0,0,0), vec3(1,1,0), vec3(1,0,0)
);

const vec2 uvs[6] = vec2[6](
    vec2(0,1), vec2(0,0), vec2(1,0),
    vec2(0,1), vec2(1,0), vec2(1,1)
);

layout(location = 0) out vec2 fragUV;

void main() {
    vec3 pos = positions[gl_VertexIndex];
    gl_Position = pc.mvp * vec4(pos, 1.0);
    fragUV = uvs[gl_VertexIndex % 6];
}
