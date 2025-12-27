#version 450

// Line vertex shader for block outline rendering
// Uses the same MVP uniforms as the main triangle shader

#fh_import <farhorizons:globals.glsl>

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec4 inColor;

layout(location = 0) out vec4 fragColor;

// Minecraft's view-space scaling to prevent outline clipping into blocks
// This slightly shrinks the view-space coordinates, pushing the outline towards the camera
const float VIEW_SHRINK = 1.0 - (1.0 / 256.0);
const mat4 VIEW_SCALE = mat4(
    VIEW_SHRINK, 0.0, 0.0, 0.0,
    0.0, VIEW_SHRINK, 0.0, 0.0,
    0.0, 0.0, VIEW_SHRINK, 0.0,
    0.0, 0.0, 0.0, 1.0
);

void main() {
    // Apply view-space scaling between view and projection matrices
    gl_Position = ubo.proj * VIEW_SCALE * ubo.view * ubo.model * vec4(inPosition, 1.0);
    fragColor = inColor;
}
