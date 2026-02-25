#version 450

layout(location = 0) in vec2 fragUV;
layout(location = 1) in vec4 fragColor;
layout(location = 2) flat in vec4 fragClipRect;

layout(set = 0, binding = 1) uniform sampler2D fontAtlas;

layout(location = 0) out vec4 outColor;

void main() {
    // Clip rect test (pixel coordinates)
    if (gl_FragCoord.x < fragClipRect.x || gl_FragCoord.x > fragClipRect.z ||
        gl_FragCoord.y < fragClipRect.y || gl_FragCoord.y > fragClipRect.w) {
        discard;
    }
    float texAlpha = texture(fontAtlas, fragUV).a;
    if (texAlpha < 0.01) discard;
    outColor = vec4(fragColor.rgb, fragColor.a * texAlpha);
}
