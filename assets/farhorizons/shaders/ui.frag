#version 450

layout(location = 0) in vec2 fragUV;
layout(location = 1) in vec4 fragColor;

layout(location = 0) out vec4 outColor;

void main() {
    // UV of (0,0) signals a solid-color quad (no texture sampling)
    // Non-zero UV would sample from a UI atlas (Phase 4)
    outColor = fragColor;
    if (outColor.a < 0.01) discard;
}
