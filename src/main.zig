const builtin = @import("builtin");

const Emulator = @import("./core/emulator.zig");

pub const Frontend = @import("./frontends/sdl_imgui/sdl_imgui.zig");

var emulator: Emulator = .{};

pub fn main() !void {
    try Frontend.begin(&emulator);
}