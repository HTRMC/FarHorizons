#version 450

layout(binding = 1) uniform sampler2DArray texSampler;

layout(location = 0) in vec3 fragColor;
layout(location = 1) in vec2 fragTexCoord;
layout(location = 2) flat in uint fragTexIndex;

layout(location = 0) out vec4 outColor;

void main() {
    // Sample from texture array using layer index
    vec4 texColor = texture(texSampler, vec3(fragTexCoord, float(fragTexIndex)));

    // Apply vertex color (contains ambient occlusion) to texture
    outColor = vec4(texColor.rgb * fragColor, texColor.a);
}
