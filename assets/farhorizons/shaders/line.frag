#version 450

// Line fragment shader for block outline rendering

layout(location = 0) in vec4 fragColor;

layout(location = 0) out vec4 outColor;

void main() {
    outColor = fragColor;
}
