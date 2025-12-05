#version 450

layout(binding = 1) uniform sampler2D texSampler;

layout(location = 0) in vec3 fragColor;
layout(location = 1) in vec2 fragTexCoord;

layout(location = 0) out vec4 outColor;

void main() {
    // Sample from the texture
    vec4 texColor = texture(texSampler, fragTexCoord);

    // Output the texture color (ignore vertex color for now)
    outColor = texColor;
}
