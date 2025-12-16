// Platform module - window, display, and input management

pub const Window = @import("Window.zig").Window;
pub const DisplayData = @import("DisplayData.zig").DisplayData;
pub const MouseHandler = @import("MouseHandler.zig").MouseHandler;
pub const KeyboardInput = @import("KeyboardInput.zig").KeyboardInput;
pub const Input = @import("KeyboardInput.zig").Input;
pub const InputConstants = @import("InputConstants.zig");

pub const initBackend = @import("Window.zig").initBackend;
pub const terminateBackend = @import("Window.zig").terminateBackend;
pub const isVulkanSupported = @import("Window.zig").isVulkanSupported;
pub const getRequiredVulkanExtensions = @import("Window.zig").getRequiredVulkanExtensions;
pub const pollEvents = @import("Window.zig").pollEvents;
