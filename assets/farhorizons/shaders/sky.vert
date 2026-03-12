#version 450

layout(push_constant) uniform PC {
    mat4 viewProj;
    vec4 sunDirSize;   // xyz = direction, w = angular size
    vec4 moonDirSize;  // xyz = direction, w = angular size
} pc;

layout(location=0) out vec2 fragUV;
layout(location=1) flat out int bodyIndex;

void main() {
    bodyIndex = gl_VertexIndex / 6;
    int vi = gl_VertexIndex % 6;

    // Quad corners: two triangles forming a [-1,1] quad
    const vec2 corners[6] = vec2[6](
        vec2(-1, -1), vec2(1, -1), vec2(-1, 1),
        vec2(-1, 1),  vec2(1, -1), vec2(1, 1)
    );
    vec2 corner = corners[vi];

    // UV for texture sampling: map [-1,1] to [0,1]
    fragUV = corner * 0.5 + 0.5;

    vec4 dirSize = bodyIndex == 0 ? pc.sunDirSize : pc.moonDirSize;
    vec3 dir = normalize(dirSize.xyz);
    float size = dirSize.w;

    // Billboard axes: sun orbits in YZ plane, so right is always along X
    vec3 right = vec3(1.0, 0.0, 0.0);
    vec3 up = cross(dir, right);

    vec3 worldPos = dir + (right * corner.x + up * corner.y) * size;

    // w=0 strips camera translation (skybox trick — infinite distance)
    vec4 clipPos = pc.viewProj * vec4(worldPos, 0.0);
    clipPos.z = clipPos.w; // force to far plane (depth = 1.0)

    gl_Position = clipPos;
}
