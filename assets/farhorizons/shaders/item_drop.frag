#version 450

layout(location = 0) in vec2 fragUV;
layout(location = 1) in vec3 fragNormal;

layout(set = 0, binding = 1) uniform sampler2DArray blockTextures;

layout(push_constant) uniform PushConstants {
    layout(offset = 64) int texLayer;
    layout(offset = 68) float contrast;
    layout(offset = 80) vec3 ambientLight;
    layout(offset = 92) float skyLevel;
    layout(offset = 96) vec3 blockLight;
} pc;

layout(location = 0) out vec4 outColor;

// Minecraft-style dual directional lighting for items
const float MC_LIGHT_POWER = 0.6;
const float MC_AMBIENT_LIGHT = 0.4;
const vec3 LIGHT0_DIR = normalize(vec3(0.2, 1.0, -0.7));
const vec3 LIGHT1_DIR = normalize(vec3(-0.2, 0.8, 0.5));

void main() {
    vec4 texColor = texture(blockTextures, vec3(fragUV, float(pc.texLayer)));
    if (texColor.a < 0.01) discard;

    vec3 n = normalize(fragNormal);

    // Minecraft-style face shading: two directional lights + ambient floor
    float light0 = max(0.0, dot(LIGHT0_DIR, n));
    float light1 = max(0.0, dot(LIGHT1_DIR, n));
    float faceShade = min(1.0, (light0 + light1) * MC_LIGHT_POWER + MC_AMBIENT_LIGHT);

    // Environment lighting: sky + block light from sampleLightAt
    vec3 sky = pc.ambientLight * pc.skyLevel;
    vec3 envLight = min(vec3(1.0), sqrt(sky * sky + pc.blockLight * pc.blockLight));

    outColor = vec4(texColor.rgb * envLight * faceShade, texColor.a);
}
