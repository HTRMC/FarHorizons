#version 450
#extension GL_EXT_nonuniform_qualifier : require

// Bindless entity textures
layout(binding = 1) uniform texture2D textures[];
layout(binding = 2) uniform sampler texSampler;

layout(location = 0) in vec3 fragColor;
layout(location = 1) in vec2 fragTexCoord;
layout(location = 2) flat in uint fragTexIndex;

layout(location = 0) out vec4 outColor;

void main() {
    // Sample from bindless texture array using nonuniformEXT for dynamic indexing
    vec4 texColor = texture(sampler2D(textures[nonuniformEXT(fragTexIndex)], texSampler), fragTexCoord);

    // Discard fully transparent pixels
    if (texColor.a == 0.0) {
        discard;
    }

    // Apply vertex color for tinting/lighting
    outColor = vec4(texColor.rgb * fragColor, texColor.a);
}
