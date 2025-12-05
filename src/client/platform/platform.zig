// Platform module - window, display, and input management

pub const Window = @import("window.zig").Window;
pub const DisplayData = @import("display_data.zig").DisplayData;
pub const MouseHandler = @import("mouse_handler.zig").MouseHandler;
pub const KeyboardInput = @import("keyboard_input.zig").KeyboardInput;
pub const Input = @import("keyboard_input.zig").Input;
pub const InputConstants = @import("input_constants.zig");

pub const initBackend = @import("window.zig").initBackend;
pub const terminateBackend = @import("window.zig").terminateBackend;
pub const isVulkanSupported = @import("window.zig").isVulkanSupported;
pub const getRequiredVulkanExtensions = @import("window.zig").getRequiredVulkanExtensions;
pub const pollEvents = @import("window.zig").pollEvents;
