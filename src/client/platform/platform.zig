// Platform module - window and display management

pub const Window = @import("window.zig").Window;
pub const DisplayData = @import("display_data.zig").DisplayData;

pub const initBackend = @import("window.zig").initBackend;
pub const terminateBackend = @import("window.zig").terminateBackend;
pub const isVulkanSupported = @import("window.zig").isVulkanSupported;
pub const getRequiredVulkanExtensions = @import("window.zig").getRequiredVulkanExtensions;
pub const pollEvents = @import("window.zig").pollEvents;
