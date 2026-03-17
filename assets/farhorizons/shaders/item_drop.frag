#version 450

layout(location = 0) in vec3 fragNormal;

layout(push_constant) uniform PushConstants {
    mat4 mvp;
    vec4 color;
    vec3 ambient_light;
    float _pad;
} pc;

layout(location = 0) out vec4 outColor;

void main() {
    // Simple directional lighting based on normal
    vec3 lightDir = normalize(vec3(0.3, 1.0, 0.5));
    float ndl = max(dot(normalize(fragNormal), lightDir), 0.0);
    float light = 0.4 + 0.6 * ndl;

    vec3 lit = pc.color.rgb * pc.ambient_light * light;
    outColor = vec4(lit, pc.color.a);
}
