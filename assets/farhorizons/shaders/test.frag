#version 450

layout(set=0, binding=1) uniform sampler2DArray tex;

layout(location=0) in vec2 fragUV;
layout(location=1) flat in uint fragTexIndex;
layout(location=2) flat in uvec4 fragLightPacked;
layout(location=3) flat in uint fragAoData;
layout(location=4) flat in vec3 fragNormal;

layout(push_constant) uniform PC { layout(offset=64) float contrast; } pc;

layout(location=0) out vec4 outColor;

float lightVariation(vec3 normal) {
    vec3 directionalPart = vec3(0, pc.contrast / 2.0, pc.contrast);
    float baseLighting = 1.0 - pc.contrast;
    return baseLighting + dot(normal, directionalPart);
}

// Unpack 5-bit channels: sky_r:5|sky_g:5|sky_b:5|block_r:5|block_g:5|block_b:5
void unpackLight(uint packed, out vec3 sky, out vec3 block) {
    sky = vec3(
        float((packed >>  0) & 0x1Fu) / 31.0,
        float((packed >>  5) & 0x1Fu) / 31.0,
        float((packed >> 10) & 0x1Fu) / 31.0
    );
    block = vec3(
        float((packed >> 15) & 0x1Fu) / 31.0,
        float((packed >> 20) & 0x1Fu) / 31.0,
        float((packed >> 25) & 0x1Fu) / 31.0
    );
}

void main() {
    // Smoothstep UV for C1 gradient continuity at face boundaries:
    // derivative goes to zero at edges, so adjacent faces meet smoothly
    vec2 st = smoothstep(0.0, 1.0, fragUV);

    // Bilinear interpolation of light across the quad
    // fragLightPacked: [0]=UV(0,0), [1]=UV(1,0), [2]=UV(0,1), [3]=UV(1,1)
    vec3 sky00, blk00, sky10, blk10, sky01, blk01, sky11, blk11;
    unpackLight(fragLightPacked[0], sky00, blk00);
    unpackLight(fragLightPacked[1], sky10, blk10);
    unpackLight(fragLightPacked[2], sky01, blk01);
    unpackLight(fragLightPacked[3], sky11, blk11);

    vec3 skyLight = mix(mix(sky00, sky10, st.x), mix(sky01, sky11, st.x), st.y);
    vec3 blockLight = mix(mix(blk00, blk10, st.x), mix(blk01, blk11, st.x), st.y);

    // Directional shading only on sky light (sun has direction, torches don't)
    vec3 sky = skyLight * lightVariation(fragNormal);
    vec3 light = min(vec3(1.0), sqrt(sky * sky + blockLight * blockLight));

    // Bilinear interpolation of AO across the quad
    // UV-to-corner mapping: (0,0)=corner3, (1,0)=corner2, (0,1)=corner0, (1,1)=corner1
    const float ao_curve[4] = float[4](1.0, 0.8, 0.6, 0.4);
    float a00 = ao_curve[(fragAoData >> 6) & 0x3]; // corner 3 at UV (0,0)
    float a10 = ao_curve[(fragAoData >> 4) & 0x3]; // corner 2 at UV (1,0)
    float a01 = ao_curve[(fragAoData >> 0) & 0x3]; // corner 0 at UV (0,1)
    float a11 = ao_curve[(fragAoData >> 2) & 0x3]; // corner 1 at UV (1,1)
    float ao = mix(mix(a00, a10, st.x), mix(a01, a11, st.x), st.y);

    // Scale AO by brightness: less ambient light = less ambient to occlude
    float brightness = max(light.r, max(light.g, light.b));
    float effective_ao = mix(1.0, ao, brightness);

    outColor = texture(tex, vec3(fragUV, float(fragTexIndex))) * vec4(light * effective_ao, 1.0);
}
