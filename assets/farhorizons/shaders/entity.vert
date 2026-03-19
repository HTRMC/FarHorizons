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
    mat4 mvp;                   // 0-63
    vec4 ambientContrast;       // 64-79  (xyz=ambient, w=contrast)
    vec4 sunDirSky;             // 80-95  (xyz=sunDir, w=skyLevel)
    vec4 blockLightYaw;         // 96-111 (xyz=blockLight, w=modelYaw)
} pc;

layout(location = 0) out vec2 fragUV;
layout(location = 1) out vec3 fragNormal;

void main() {
    EntityVertex vert = vertices[gl_VertexIndex];
    gl_Position = pc.mvp * vec4(vert.px, vert.py, vert.pz, 1.0);
    fragUV = vec2(vert.u, vert.v);

    // Rotate normal to world space using modelYaw (Y-axis rotation)
    float yaw = pc.blockLightYaw.w;
    float cy = cos(yaw);
    float sy = sin(yaw);
    vec3 n = vec3(vert.nx, vert.ny, vert.nz);
    fragNormal = vec3(cy * n.x + sy * n.z, n.y, -sy * n.x + cy * n.z);
}
