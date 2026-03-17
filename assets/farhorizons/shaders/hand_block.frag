#version 450

layout(location = 0) in vec2 fragUV;
layout(location = 1) in vec3 fragNormal;

layout(set = 0, binding = 1) uniform sampler2D skinTexture;
layout(set = 0, binding = 2) uniform sampler2DArray blockTextures;

layout(push_constant) uniform PushConstants {
    layout(offset = 64) int useBlockTexture;
    layout(offset = 68) int texLayer;
    layout(offset = 80) vec3 ambientLight;
    layout(offset = 92) float contrast;
    layout(offset = 96) vec3 sunDir;
} pc;

layout(location = 0) out vec4 outColor;

void main() {
    vec4 texColor;
    if (pc.useBlockTexture == 0) {
        texColor = texture(skinTexture, fragUV);
    } else {
        texColor = texture(blockTextures, vec3(fragUV, float(pc.texLayer)));
    }
    if (texColor.a < 0.01) discard;

    // Directional shading matching terrain: normal-based variation
    vec3 n = normalize(fragNormal);
    float baseLighting = 1.0 - pc.contrast;
    float variation = baseLighting + dot(n, vec3(0, pc.contrast / 2.0, pc.contrast));

    // Diffuse from sun direction
    float sunDiffuse = max(dot(n, normalize(pc.sunDir)), 0.0) * 0.3;

    vec3 light = pc.ambientLight * (variation + sunDiffuse);
    light = min(light, vec3(1.0));

    outColor = vec4(texColor.rgb * light, texColor.a);
}
