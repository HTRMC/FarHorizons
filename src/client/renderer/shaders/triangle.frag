#version 450

layout(location = 0) in vec3 fragColor;
layout(location = 1) in vec2 fragTexCoord;

layout(location = 0) out vec4 outColor;

void main() {
    // Procedural checkerboard pattern to verify UVs are working
    // 4x4 checkerboard pattern
    float checker = mod(floor(fragTexCoord.x * 4.0) + floor(fragTexCoord.y * 4.0), 2.0);
    vec3 texColor = mix(vec3(0.2), vec3(0.8), checker);

    // Multiply by face color to keep face distinction visible
    outColor = vec4(fragColor * texColor, 1.0);
}
