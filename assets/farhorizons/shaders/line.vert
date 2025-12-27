#version 450

// Line vertex shader for block outline rendering
// Uses the same MVP uniforms as the main triangle shader

#fh_import <farhorizons:globals.glsl>

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec4 inColor;

layout(location = 0) out vec4 fragColor;

void main() {
    gl_Position = ubo.proj * ubo.view * ubo.model * vec4(inPosition, 1.0);
    fragColor = inColor;
}
