#version 450

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec2 inTexCoord;
layout(location = 2) in uint inTexIndex;

layout(location = 0) out vec2 fragTexCoord;
layout(location = 1) flat out uint fragTexIndex;

void main() {
    gl_Position = vec4(inPosition.xy, 0.0, 1.0);
    fragTexCoord = inTexCoord;
    fragTexIndex = inTexIndex;
}
