#version 450

layout(location = 0) in vec2 fragUV;
layout(location = 1) in vec3 fragNormal;

layout(set = 0, binding = 1) uniform sampler2D skinTexture;

layout(push_constant) uniform PushConstants {
    layout(offset = 64) vec4 ambientContrast;   // xyz=ambient, w=contrast
    layout(offset = 80) vec4 sunDirSky;         // xyz=sunDir, w=skyLevel
    layout(offset = 96) vec4 blockLightYaw;     // xyz=blockLight, w=modelYaw
    layout(offset = 116) float hurtTint;        // damage flash intensity
} pc;

layout(location = 0) out vec4 outColor;

void main() {
    vec4 texColor = texture(skinTexture, fragUV);
    if (texColor.a < 0.01) discard;

    vec3 n = normalize(fragNormal);
    float nDotL = max(dot(n, pc.sunDirSky.xyz), 0.0);
    float contrast = pc.ambientContrast.w;
    float variation = mix(1.0, 0.6 + 0.4 * nDotL, contrast);

    vec3 sky = pc.ambientContrast.xyz * pc.sunDirSky.w * variation;
    vec3 light = min(vec3(1.0), sqrt(sky * sky + pc.blockLightYaw.xyz * pc.blockLightYaw.xyz));

    vec3 color = texColor.rgb * light;

    if (pc.hurtTint > 0.0) {
        color = mix(color, vec3(1.0, 0.0, 0.0), pc.hurtTint * 0.5);
    }

    outColor = vec4(color, texColor.a);
}
