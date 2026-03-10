#version 450

layout(location = 0) in vec4 fragColor;
layout(location = 1) in vec3 fragNormal;

layout(location = 0) out vec4 outColor;

void main() {
    // Simple directional lighting from upper-right
    vec3 lightDir = normalize(vec3(0.4, 0.8, 0.5));
    float ambient = 0.35;
    float diffuse = max(dot(normalize(fragNormal), lightDir), 0.0) * 0.65;
    float lighting = ambient + diffuse;

    outColor = vec4(fragColor.rgb * lighting, fragColor.a);
}
