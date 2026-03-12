#version 450

layout(set=0, binding=0) uniform sampler2DArray tex;

layout(location=0) in vec2 fragUV;
layout(location=1) flat in int bodyIndex;

layout(location=0) out vec4 outColor;

void main() {
    outColor = texture(tex, vec3(fragUV, float(bodyIndex)));
}
