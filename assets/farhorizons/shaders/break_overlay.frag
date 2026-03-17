#version 450

layout(location = 0) in vec2 fragUV;

layout(set = 0, binding = 0) uniform sampler2DArray blockTextures;

layout(push_constant) uniform PushConstants {
    layout(offset = 64) int texLayer;
} pc;

layout(location = 0) out vec4 outColor;

void main() {
    vec4 texColor = texture(blockTextures, vec3(fragUV, float(pc.texLayer)));
    if (texColor.a < 0.01) discard;
    outColor = texColor;
}
