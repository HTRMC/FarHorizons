// Model types
pub const BlockModel = @import("model/BlockModel.zig").BlockModel;
pub const BlockElement = @import("model/BlockElement.zig").BlockElement;
pub const BlockElementFace = @import("model/BlockElement.zig").BlockElementFace;
pub const BlockElementRotation = @import("model/BlockElement.zig").BlockElementRotation;
pub const Direction = @import("model/BlockElement.zig").Direction;
pub const ModelLoader = @import("model/ModelLoader.zig").ModelLoader;
pub const BakedQuad = @import("model/BakedQuad.zig").BakedQuad;
pub const FaceBakery = @import("model/FaceBakery.zig").FaceBakery;
pub const FaceInfo = @import("FaceInfo.zig").FaceInfo;

// Blockstate types
pub const blockstate = @import("Blockstate.zig");
pub const BlockstateDefinition = blockstate.BlockstateDefinition;
pub const ModelVariant = blockstate.ModelVariant;
pub const BlockstateLoader = @import("BlockstateLoader.zig").BlockstateLoader;
pub const StateMapper = @import("StateMapper.zig").StateMapper;
pub const BlockModelShaper = @import("BlockModelShaper.zig").BlockModelShaper;
