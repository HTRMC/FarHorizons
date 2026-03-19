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
    vec4 ambientContrast;       // 64-79
    vec4 sunDirSky;             // 80-95
    vec4 blockLightYaw;         // 96-111
    float legPhase;             // 112-115
} pc;

layout(location = 0) out vec2 fragUV;
layout(location = 1) out vec3 fragNormal;

// Pig model constants (scale = 0.9 / 16 = 0.05625)
// Part order: 0=head, 1=snout, 2=body, 3=leg_fr, 4=leg_fl, 5=leg_br, 6=leg_bl
const int VERTS_PER_PART = 36;
const float LEG_PIVOT_Y = 0.3375;       // top of leg: 6 * 0.05625
const float FRONT_PIVOT_Z = 0.3375;     // front leg center Z: (4+2) * 0.05625
const float BACK_PIVOT_Z = -0.1125;     // back leg center Z: (-4+2) * 0.05625
const float MAX_SWING = 0.6;            // max swing angle in radians (~34 degrees)

void main() {
    EntityVertex vert = vertices[gl_VertexIndex];
    vec3 pos = vec3(vert.px, vert.py, vert.pz);
    vec3 norm = vec3(vert.nx, vert.ny, vert.nz);

    // Leg animation: rotate around X-axis at pivot point
    int partIndex = gl_VertexIndex / VERTS_PER_PART;

    if (partIndex >= 3 && partIndex <= 6) {
        // Trot gait: front-right(3) + back-left(6) swing together,
        //            front-left(4) + back-right(5) swing together (opposite)
        float sign = (partIndex == 3 || partIndex == 6) ? 1.0 : -1.0;
        float angle = sin(pc.legPhase) * MAX_SWING * sign;

        float pivotZ = (partIndex <= 4) ? FRONT_PIVOT_Z : BACK_PIVOT_Z;

        float relY = pos.y - LEG_PIVOT_Y;
        float relZ = pos.z - pivotZ;
        float cs = cos(angle);
        float sn = sin(angle);

        pos.y = LEG_PIVOT_Y + relY * cs - relZ * sn;
        pos.z = pivotZ + relY * sn + relZ * cs;

        // Rotate normal too
        float ny2 = norm.y * cs - norm.z * sn;
        float nz2 = norm.y * sn + norm.z * cs;
        norm.y = ny2;
        norm.z = nz2;
    }

    gl_Position = pc.mvp * vec4(pos, 1.0);
    fragUV = vec2(vert.u, vert.v);

    // Rotate normal to world space using modelYaw
    float yaw = pc.blockLightYaw.w;
    float cy = cos(yaw);
    float sy = sin(yaw);
    fragNormal = vec3(cy * norm.x + sy * norm.z, norm.y, -sy * norm.x + cy * norm.z);
}
