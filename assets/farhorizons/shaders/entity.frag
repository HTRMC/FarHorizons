#version 450

layout(location = 0) in vec2 fragUV;
layout(location = 1) in vec3 fragNormal;

layout(set = 0, binding = 1) uniform sampler2D skinTexture;

layout(location = 0) out vec4 outColor;

void main() {
    vec4 texColor = texture(skinTexture, fragUV);
    if (texColor.a < 0.01) discard;

    // Simple directional lighting from upper-right
    vec3 lightDir = normalize(vec3(0.4, 0.8, 0.5));
    float ambient = 0.35;
    float diffuse = max(dot(normalize(fragNormal), lightDir), 0.0) * 0.65;
    float lighting = ambient + diffuse;

    outColor = vec4(texColor.rgb * lighting, texColor.a);
}
