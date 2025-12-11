// Fog utilities for distance-based fog effects
// Usage: #moj_import <farhorizons:fog.glsl>

// Fog parameters - can be set via push constants or UBO
const vec4 FOG_COLOR = vec4(0.6, 0.7, 0.9, 1.0);
const float FOG_START = 64.0;
const float FOG_END = 128.0;

float linearFogFactor(float distance) {
    return clamp((distance - FOG_START) / (FOG_END - FOG_START), 0.0, 1.0);
}

float exponentialFogFactor(float distance, float density) {
    return 1.0 - exp(-density * distance);
}

float exponentialSquaredFogFactor(float distance, float density) {
    float d = density * distance;
    return 1.0 - exp(-d * d);
}

vec4 applyFog(vec4 color, float distance) {
    float fogFactor = linearFogFactor(distance);
    return mix(color, FOG_COLOR, fogFactor);
}

vec4 applyFogCustom(vec4 color, float distance, vec4 fogColor, float fogStart, float fogEnd) {
    float fogFactor = clamp((distance - fogStart) / (fogEnd - fogStart), 0.0, 1.0);
    return mix(color, fogColor, fogFactor);
}
