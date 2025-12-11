// Common global uniforms available to all shaders
// Usage: #moj_import <farhorizons:globals.glsl>

layout(std140, binding = 0) uniform UniformBufferObject {
    mat4 model;
    mat4 view;
    mat4 proj;
} ubo;
