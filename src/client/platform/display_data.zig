// Display configuration data

pub const DisplayData = struct {
    width: u32 = 854,
    height: u32 = 480,
    fullscreen: bool = false,
    vsync: bool = true,

    pub fn init() DisplayData {
        return .{};
    }

    pub fn withSize(width: u32, height: u32) DisplayData {
        return .{
            .width = width,
            .height = height,
        };
    }
};
