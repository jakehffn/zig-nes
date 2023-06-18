const std = @import("std");
const c = @cImport({
    @cInclude("SDL.h");
});

const CPU = @import("./cpu.zig").CPU;
const Bus = @import("./bus.zig").Bus;
const WorkRam = @import("./work_ram.zig").WorkRam;
const Snake = @import("./snake.zig").Snake;

pub fn main() !void {
    var mapped_random_number = Snake.MappedRandomNumber{};
    var random_number_bc = mapped_random_number.busCallback();

    var mapped_controller = Snake.MappedController{};
    var controller_bc = mapped_controller.busCallback();

    var mapped_screen = Snake.MappedScreen{};
    var screen_bc = mapped_screen.busCallback();

    var work_ram = WorkRam(0x10000){};
    work_ram.write_bytes(&Snake.game_code, 0x600);
    var work_ram_bc = work_ram.busCallback();

    var bus = Bus.init(&work_ram_bc);

    bus.set_callbacks(&random_number_bc, 0xFE, 0xFF);
    bus.set_callbacks(&controller_bc, 0xFF, 0x100);
    bus.set_callbacks(&screen_bc, 0x200, 0x600);

    var cpu = CPU.init(&bus);
    cpu.pc = 0x600;

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
        32, 
        32
    );

    mainloop: while (true) {
        var sdl_event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&sdl_event) != 0) {
            switch (sdl_event.type) {
                c.SDL_QUIT => break :mainloop,
                c.SDL_KEYDOWN => {
                    switch (sdl_event.key.keysym.sym) {
                        c.SDLK_w, c.SDLK_UP => { 
                            mapped_controller.setLastInput(0x77);
                        },
                        c.SDLK_a, c.SDLK_LEFT => { 
                            mapped_controller.setLastInput(0x61);
                        },
                        c.SDLK_s, c.SDLK_DOWN => { 
                            mapped_controller.setLastInput(0x73);
                        },
                        c.SDLK_d, c.SDLK_RIGHT => { 
                            mapped_controller.setLastInput(0x64);
                        },
                        else => {}
                    }
                },
                else => {},
            }
        }

        cpu.step();

        if (mapped_screen.hasUpdate()) {
            _ = c.SDL_UpdateTexture(texture, null, mapped_screen.data(), 32*3);
            _ = c.SDL_RenderCopy(renderer, texture, null, null);
            c.SDL_RenderPresent(renderer);

            std.time.sleep(std.time.ns_per_ms * 10);
        }
    }
}
