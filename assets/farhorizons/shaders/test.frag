#version 450

layout(set=0, binding=1) uniform sampler2DArray tex;

layout(location=0) in vec2 fragUV;
layout(location=1) flat in uint fragTexIndex;
layout(location=2) in vec3 fragLight;
layout(location=3) flat in uint fragAoData;

layout(location=0) out vec4 outColor;

void main() {
    // Bilinear interpolation of AO across the quad using fragUV.
    // UV-to-corner mapping: (0,0)=corner3, (1,0)=corner2, (0,1)=corner0, (1,1)=corner1
    const float ao_curve[4] = float[4](1.0, 0.8, 0.6, 0.4);
    float a00 = ao_curve[(fragAoData >> 6) & 0x3]; // corner 3 at UV (0,0)
    float a10 = ao_curve[(fragAoData >> 4) & 0x3]; // corner 2 at UV (1,0)
    float a01 = ao_curve[(fragAoData >> 0) & 0x3]; // corner 0 at UV (0,1)
    float a11 = ao_curve[(fragAoData >> 2) & 0x3]; // corner 1 at UV (1,1)
    float ao = mix(mix(a00, a10, fragUV.x), mix(a01, a11, fragUV.x), fragUV.y);

    // Scale AO by brightness: less ambient light = less ambient to occlude
    float brightness = max(fragLight.r, max(fragLight.g, fragLight.b));
    float effective_ao = mix(1.0, ao, brightness);

    outColor = texture(tex, vec3(fragUV, float(fragTexIndex))) * vec4(fragLight * effective_ao, 1.0);
}
