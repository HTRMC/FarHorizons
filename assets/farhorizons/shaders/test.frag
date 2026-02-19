#version 450

layout(set = 0, binding = 1) uniform sampler2DArray tex;

layout(location = 0) in vec2 fragUV;
layout(location = 1) flat in uint fragTexIndex;

layout(location = 0) out vec4 outColor;

void main() {
    outColor = texture(tex, vec3(fragUV, float(fragTexIndex)));
}
