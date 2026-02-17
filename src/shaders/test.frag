#version 450
#extension GL_EXT_nonuniform_qualifier : require

layout(set = 0, binding = 1) uniform sampler2D textures[];

layout(location = 0) in vec2 fragUV;
layout(location = 1) flat in uint fragTexIndex;

layout(location = 0) out vec4 outColor;

void main() {
    outColor = texture(textures[nonuniformEXT(fragTexIndex)], fragUV);
}
