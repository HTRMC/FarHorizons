// Model types
pub const BlockModel = @import("model/block_model.zig").BlockModel;
pub const BlockElement = @import("model/block_element.zig").BlockElement;
pub const BlockElementFace = @import("model/block_element.zig").BlockElementFace;
pub const BlockElementRotation = @import("model/block_element.zig").BlockElementRotation;
pub const Direction = @import("model/block_element.zig").Direction;
pub const ModelLoader = @import("model/model_loader.zig").ModelLoader;
pub const BakedQuad = @import("model/baked_quad.zig").BakedQuad;
pub const FaceBakery = @import("model/face_bakery.zig").FaceBakery;
pub const FaceInfo = @import("face_info.zig").FaceInfo;

// Blockstate types
pub const blockstate = @import("blockstate.zig");
pub const BlockstateDefinition = blockstate.BlockstateDefinition;
pub const ModelVariant = blockstate.ModelVariant;
pub const BlockstateLoader = @import("blockstate_loader.zig").BlockstateLoader;
pub const StateMapper = @import("state_mapper.zig").StateMapper;
pub const BlockModelShaper = @import("block_model_shaper.zig").BlockModelShaper;
