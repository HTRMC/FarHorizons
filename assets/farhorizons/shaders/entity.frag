#version 450

layout(location = 0) in vec2 fragUV;
layout(location = 1) in vec3 fragNormal;

layout(set = 0, binding = 1) uniform sampler2D skinTexture;

layout(push_constant) uniform PushConstants {
    layout(offset = 64) vec3 ambientLight;
    layout(offset = 76) float contrast;
    layout(offset = 80) vec3 sunDir;
    layout(offset = 92) float skyLevel;
    layout(offset = 96) vec3 blockLight;
} pc;

layout(location = 0) out vec4 outColor;

void main() {
    vec4 texColor = texture(skinTexture, fragUV);
    if (texColor.a < 0.01) discard;

    // Directional shading matching terrain: normal-based variation
    vec3 n = normalize(fragNormal);
    float baseLighting = 1.0 - pc.contrast;
    float variation = baseLighting + dot(n, vec3(0, pc.contrast / 2.0, pc.contrast));

    // Sky light: ambient * sky level * directional variation
    vec3 sky = pc.ambientLight * pc.skyLevel * variation;

    // Combine sky and block light (same as terrain)
    vec3 light = min(vec3(1.0), sqrt(sky * sky + pc.blockLight * pc.blockLight));

    outColor = vec4(texColor.rgb * light, texColor.a);
}
