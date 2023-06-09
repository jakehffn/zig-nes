const std = @import("std");
const c = @cImport({
    @cInclude("SDL.h");
});

const CPU = @import("./cpu.zig").CPU;
const Bus = @import("./bus.zig").Bus;

var example_mem = [_]u8{0} ** 2000;

fn exampleMemRead(address: u16) u8 {
    return example_mem[address];
}

fn exampleMemWrite(address: u16, data: u8) void {
    example_mem[address] = data;
}

pub fn main() !void {
    var bus: Bus = Bus.init();
    bus.set_read_callback(0, 1000, exampleMemRead);
    bus.set_write_callback(0, 1000, exampleMemWrite);
    try bus.write_byte(0x42, 0xFF);
    std.debug.print("After setting with callback: {}\n", .{bus.read_byte(0x42) catch 0x42});
    var cpu: CPU = CPU.init(bus);

    cpu.execute(CPU.Instruction{.byte = 0x10});
    cpu.execute(CPU.Instruction{.byte = 0x20});
    cpu.execute(CPU.Instruction{.byte = 0xA6});
    cpu.execute(CPU.Instruction{.byte = 0x40});
    cpu.execute(CPU.Instruction{.byte = 0x50});
    
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