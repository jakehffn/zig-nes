const std = @import("std");
const page_allocator = std.heap.page_allocator;
const Rand = std.rand.DefaultPrng;
const c = @cImport({
    @cInclude("SDL.h");
});

const CPU = @import("./cpu.zig").CPU;
const Bus = @import("./bus.zig").Bus;
const BusCallback = Bus.BusCallback;
const Ram = @import("./ram.zig").Ram;
const Rom = @import("./rom.zig").Rom;

pub const Snake = struct {
    pub const MappedRandomNumber = struct {
        const Self = @This();

        var rand = Rand.init(0);

        fn read(self: *Self, bus: *Bus, address: u16) u8 {
            _ = self;
            _ = bus;
            _ = address;
            return rand.random().int(u8);
        }

        fn write(self: *Self, bus: *Bus, adress: u16, value: u8) void {
            _ = self;
            _ = bus;
            _ = adress;
            _ = value;
        }

        pub fn busCallback(self: *Self) BusCallback {
            return BusCallback.init(self, read, write);
        }
    };

    pub const MappedController = struct {
        const Self = @This();

        last_input: u8 = 0,

        fn read(self: *Self, bus: *Bus, address: u16) u8 {
            _ = bus;
            _ = address;
            return self.last_input; 
        }

        fn write(self: *Self, bus: *Bus, address: u16, value: u8) void {
            _ = bus;
            _ = address;
            self.last_input = value;
        }

        pub fn busCallback(self: *Self) BusCallback {
            return BusCallback.init(self, read, write);
        }

        pub fn setLastInput(self: *Self, value: u8) void {
            self.last_input = value;
        }        
    };

    pub const MappedScreen = struct {
        const Self = @This();

        screen_bytes: [0x400*3]u8 = [_]u8{0} ** (0x400*3),
        has_update_since_read: bool = false,

        fn read(self: *Self, bus: *Bus, address: u16) u8 {
            _ = bus;
            return self.screen_bytes[address*3];
        }

        fn write(self: *Self, bus: *Bus, address: u16, value: u8) void {
            _ = bus;
            var color = switch (value & 0xF) {
                0  => [_]u8{0x0, 0x0, 0x0},
                1  => [_]u8{0xFF, 0xFF, 0xFF},
                2, 9  => [_]u8{0x80, 0x80, 0x80},
                3, 10  => [_]u8{0xFF, 0x0, 0x0},
                4, 11  => [_]u8{0x0, 0xFF, 0x0},
                5, 12  => [_]u8{0x0, 0x0, 0xFF},
                6, 13  => [_]u8{0xFF, 0x0, 0xFF},
                7, 14  => [_]u8{0xFF, 0xFF, 0x0},
                else  => [_]u8{0x0, 0xFF, 0xFF},
            };

            self.screen_bytes[address*3] = color[0];
            self.screen_bytes[address*3 + 1] = color[1];
            self.screen_bytes[address*3 + 2] = color[2];

            self.has_update_since_read = true;
        }

        pub fn busCallback(self: *Self) BusCallback {
            return BusCallback.init(self, read, write);
        }

        pub fn data(self: *Self) *u8 {
            self.has_update_since_read = false;
            return &(self.screen_bytes[0]);
        }

        pub fn hasUpdate(self: Self) bool {
            return self.has_update_since_read;
        }
    };
};

pub fn main() !void {
    var mapped_random_number = Snake.MappedRandomNumber{};
    var mapped_controller = Snake.MappedController{};
    var mapped_screen = Snake.MappedScreen{};
    var ram = Ram(0x10000).init();
    var snake_rom = Rom.init(page_allocator);
    try snake_rom.load("./test-files/snake.nes");

    var bus = Bus.init(ram.busCallback());

    bus.set_callbacks(mapped_random_number.busCallback(), 0xFE, 0xFF);
    bus.set_callbacks(mapped_controller.busCallback(), 0xFF, 0x100);
    bus.set_callbacks(mapped_screen.busCallback(), 0x200, 0x600);
    bus.set_callbacks(snake_rom.prg_rom.busCallback(), 0x8000, 0x10000);

    var cpu = try CPU("./log/6502_snake_test.log").init(&bus);
    defer cpu.deinit();
    cpu.pc = 0x8600;

    _ = c.SDL_Init(c.SDL_INIT_VIDEO);
    defer c.SDL_Quit();

    var window = c.SDL_CreateWindow("6502 Snake Test", c.SDL_WINDOWPOS_CENTERED, c.SDL_WINDOWPOS_CENTERED, 32*10, 32*10, 0);
    defer c.SDL_DestroyWindow(window);

    var renderer = c.SDL_CreateRenderer(window, 0, c.SDL_RENDERER_PRESENTVSYNC);
    defer c.SDL_DestroyRenderer(renderer);

    _ = c.SDL_RenderSetScale(renderer, 10.0, 10.0);

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
        }
    }
}
