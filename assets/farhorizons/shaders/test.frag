#version 450

layout(set=0, binding=1) uniform sampler2DArray tex;

layout(location=0) in vec2 fragUV;
layout(location=1) flat in uint fragTexIndex;
layout(location=2) in vec3 fragSkyLight;
layout(location=3) in float fragAo;
layout(location=4) in vec3 fragBlockLight;
layout(location=5) flat in vec3 fragNormal;

layout(push_constant) uniform PC { layout(offset=64) float contrast; } pc;

layout(location=0) out vec4 outColor;

float lightVariation(vec3 normal) {
    vec3 directionalPart = vec3(0, pc.contrast / 2.0, pc.contrast);
    float baseLighting = 1.0 - pc.contrast;
    return baseLighting + dot(normal, directionalPart);
}

void main() {
    // Directional shading only on sky light (sun has direction, torches don't)
    vec3 sky = fragSkyLight * lightVariation(fragNormal);
    vec3 light = min(vec3(1.0), sqrt(sky * sky + fragBlockLight * fragBlockLight));

    // Scale AO by brightness: less ambient light = less ambient to occlude
    float brightness = max(light.r, max(light.g, light.b));
    float effective_ao = mix(1.0, fragAo, brightness);

    outColor = texture(tex, vec3(fragUV, float(fragTexIndex))) * vec4(light * effective_ao, 1.0);
}
