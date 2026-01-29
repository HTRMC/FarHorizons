#version 450

layout(binding = 0) uniform sampler2DArray texSampler;

layout(location = 0) in vec2 fragTexCoord;
layout(location = 1) flat in uint fragTexIndex;

layout(location = 0) out vec4 outColor;

void main() {
    outColor = texture(texSampler, vec3(fragTexCoord, float(fragTexIndex)));
    if (outColor.a < 0.1) discard;
}
