#version 450

layout(set=0, binding=1) uniform sampler2DArray tex;

layout(location=0) in vec2 fragUV;
layout(location=1) flat in uint fragTexIndex;
layout(location=2) in vec3 fragLight;

layout(location=0) out vec4 outColor;

void main() {
    outColor = texture(tex, vec3(fragUV, float(fragTexIndex))) * vec4(fragLight, 1.0);
}
