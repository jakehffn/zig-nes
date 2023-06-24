const std = @import("std");
const page_allocator = std.heap.page_allocator;
const c = @cImport({
    @cInclude("SDL.h");
});

const MainBus = @import("./main_bus.zig").MainBus;
const CPU = @import("./cpu.zig").CPU;

const PPUBus = @import("./ppu_bus.zig").PPUBus;
const PPU = @import("./ppu.zig").PPU;

const Ram = @import("./ram.zig").Ram;
const MemoryMirror = @import("./memory_mirror.zig").MemoryMirror;
const Rom = @import("./rom.zig").Rom;

pub fn main() !void {
    
    var main_bus = try MainBus.init(page_allocator);
    defer main_bus.deinit(page_allocator);
    var cpu = try CPU("./log/ZigNES.log").init(&main_bus.bus);
    defer cpu.deinit();

    var ppu_bus = try PPUBus.init(page_allocator);
    defer ppu_bus.deinit(page_allocator);
    var ppu = PPU.init(&ppu_bus.bus);
    main_bus.bus.setCallback(ppu.address_register.busCallback(), 0);

    var snake_rom = Rom.init(page_allocator);
    try snake_rom.load("./test-files/nestest.nes");

    main_bus.loadRom(&snake_rom);

    _ = c.SDL_Init(c.SDL_INIT_VIDEO);
    defer c.SDL_Quit();

    // var window = c.SDL_CreateWindow("ZigNES", c.SDL_WINDOWPOS_CENTERED, c.SDL_WINDOWPOS_CENTERED, 256, 240, 0);
    var window = c.SDL_CreateWindow("ZigNES", c.SDL_WINDOWPOS_CENTERED, c.SDL_WINDOWPOS_CENTERED, 32*10, 32*10, 0);
    defer c.SDL_DestroyWindow(window);

    var renderer = c.SDL_CreateRenderer(window, 0, c.SDL_RENDERER_PRESENTVSYNC);
    defer c.SDL_DestroyRenderer(renderer);

    const scale = 4;
    _ = c.SDL_RenderSetScale(renderer, scale, scale);

    var texture = c.SDL_CreateTexture(
        renderer, 
        c.SDL_PIXELFORMAT_RGB24, 
        c.SDL_TEXTUREACCESS_STREAMING, 
        256, 
        240
    );

    mainloop: while (true) {
        var sdl_event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&sdl_event) != 0) {
            switch (sdl_event.type) {
                c.SDL_QUIT => break :mainloop,
                c.SDL_KEYDOWN => {
                    switch (sdl_event.key.keysym.sym) {
                        c.SDLK_w, c.SDLK_UP => {},
                        c.SDLK_a, c.SDLK_LEFT => {},
                        c.SDLK_s, c.SDLK_DOWN => {},
                        c.SDLK_d, c.SDLK_RIGHT => {},
                        else => {}
                    }
                },
                else => {},
            }
        }

        cpu.step();

        // _ = c.SDL_UpdateTexture(texture, null, mapped_screen.data(), 32*3);
        _ = c.SDL_RenderCopy(renderer, texture, null, null);
        c.SDL_RenderPresent(renderer);
    }
}
