// Basic lighting utilities
// Usage: #moj_import <farhorizons:lighting.glsl>

const float AMBIENT_LIGHT = 0.4;
const float DIFFUSE_STRENGTH = 0.6;

// Simple directional light
vec3 calculateDirectionalLight(vec3 normal, vec3 lightDir, vec3 lightColor) {
    float diff = max(dot(normal, -lightDir), 0.0);
    return lightColor * (AMBIENT_LIGHT + diff * DIFFUSE_STRENGTH);
}

// Point light attenuation
float calculateAttenuation(float distance, float constant, float linear, float quadratic) {
    return 1.0 / (constant + linear * distance + quadratic * distance * distance);
}

// Minecraft-style face shading (different brightness per face direction)
float getFaceShading(vec3 normal) {
    // Top faces are brightest, bottom darkest, sides in between
    if (normal.y > 0.5) return 1.0;      // Top
    if (normal.y < -0.5) return 0.5;     // Bottom
    if (abs(normal.z) > 0.5) return 0.8; // North/South
    return 0.6;                           // East/West
}
