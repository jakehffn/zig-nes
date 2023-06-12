const std = @import("std");
const c = @cImport({
    @cInclude("SDL.h");
});

const CPU = @import("./cpu.zig").CPU;
const Bus = @import("./bus.zig").Bus;
const TestMemory = @import("./test_memory.zig").TestMemory;

pub fn main() !void {
    var bus: Bus = Bus.init();

    var example_memory: TestMemory = .{};
    var example_bus_callback: Bus.BusCallback = example_memory.busCallback();
    bus.set_callbacks(&example_bus_callback, 0, 1 << 16 - 1);

    try bus.write_byte(0x42, 0xFF);
    std.debug.print("After setting with callback: {}\n", .{bus.read_byte(0x42) catch 0x42});
    var cpu: CPU = CPU.init(bus);

    cpu.execute(CPU.Byte{ .raw = 0x10 });
    cpu.execute(CPU.Byte{ .raw = 0x20 });
    cpu.execute(CPU.Byte{ .raw = 0xA6 });
    cpu.execute(CPU.Byte{ .raw = 0x40 });
    cpu.execute(CPU.Byte{ .raw = 0x50 });

    _ = c.SDL_Init(c.SDL_INIT_VIDEO);
    defer c.SDL_Quit();

    var window = c.SDL_CreateWindow("ZigNES", c.SDL_WINDOWPOS_CENTERED, c.SDL_WINDOWPOS_CENTERED, 256, 240, 0);
    defer c.SDL_DestroyWindow(window);

    var renderer = c.SDL_CreateRenderer(window, 0, c.SDL_RENDERER_PRESENTVSYNC);
    defer c.SDL_DestroyRenderer(renderer);

    mainloop: while (true) {
        var sdl_event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&sdl_event) != 0) {
            switch (sdl_event.type) {
                c.SDL_QUIT => break :mainloop,
                else => {},
            }
        }

        _ = c.SDL_SetRenderDrawColor(renderer, 0xff, 0xff, 0xff, 0xff);
        _ = c.SDL_RenderClear(renderer);
        c.SDL_RenderPresent(renderer);
    }
}
