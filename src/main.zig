const builtin = @import("builtin");

const Emulator = @import("./core/emulator.zig");

pub const Frontend = switch (builtin.cpu.arch) {
    //.wasm32, .wasm64 => @import();
    else => @import("./frontends/sdl_imgui/sdl_imgui.zig")
};
var emulator: Emulator = .{};

pub fn main() !void {
    try Frontend.begin(&emulator);
}