#version 450

layout(location = 0) in vec2 fragUV;
layout(location = 1) in vec4 fragColor;
layout(location = 2) flat in vec4 fragClipRect;
layout(location = 3) flat in float fragTexIndex;

layout(set = 0, binding = 1) uniform sampler2D uiAtlas;
layout(set = 0, binding = 2) uniform sampler2DArray blockTextures;

layout(location = 0) out vec4 outColor;

void main() {
    // Clip rect test (pixel coordinates)
    if (gl_FragCoord.x < fragClipRect.x || gl_FragCoord.x > fragClipRect.z ||
        gl_FragCoord.y < fragClipRect.y || gl_FragCoord.y > fragClipRect.w) {
        discard;
    }
    if (fragTexIndex >= 0.0) {
        // Sample from block texture array
        vec4 texel = texture(blockTextures, vec3(fragUV, fragTexIndex));
        outColor = texel * fragColor;
    } else if (fragUV.x < 0.0) {
        // Solid-color quad (no texture sampling)
        outColor = fragColor;
    } else {
        // Sample atlas and multiply by tint color
        vec4 texel = texture(uiAtlas, fragUV);
        outColor = texel * fragColor;
    }
    if (outColor.a < 0.01) discard;
}
