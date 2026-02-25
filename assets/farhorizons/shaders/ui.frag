#version 450

layout(location = 0) in vec2 fragUV;
layout(location = 1) in vec4 fragColor;
layout(location = 2) flat in vec4 fragClipRect;

layout(set = 0, binding = 1) uniform sampler2D uiAtlas;

layout(location = 0) out vec4 outColor;

void main() {
    // Clip rect test (pixel coordinates)
    if (gl_FragCoord.x < fragClipRect.x || gl_FragCoord.x > fragClipRect.z ||
        gl_FragCoord.y < fragClipRect.y || gl_FragCoord.y > fragClipRect.w) {
        discard;
    }
    // UV of (0,0) signals a solid-color quad (no texture sampling)
    if (fragUV.x == 0.0 && fragUV.y == 0.0) {
        outColor = fragColor;
    } else {
        // Sample atlas and multiply by tint color
        vec4 texel = texture(uiAtlas, fragUV);
        outColor = texel * fragColor;
    }
    if (outColor.a < 0.01) discard;
}
