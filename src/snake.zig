const std = @import("std");
const Rand = std.rand.DefaultPrng;
const c = @cImport({
    @cInclude("SDL.h");
});

const CPU = @import("./cpu.zig").CPU;
const Bus = @import("./bus.zig").Bus;
const BusCallback = Bus.BusCallback;
const Ram = @import("./ram.zig").Ram;

pub const Snake = struct {
    // Game code from here: https://gist.github.com/wkjagt/9043907
    pub var game_code = [_]u8{
        0x20, 0x06, 0x06, 0x20, 0x38, 0x06, 0x20, 0x0d, 0x06, 0x20, 0x2a, 0x06, 0x60, 0xa9, 0x02, 0x85,
        0x02, 0xa9, 0x04, 0x85, 0x03, 0xa9, 0x11, 0x85, 0x10, 0xa9, 0x10, 0x85, 0x12, 0xa9, 0x0f, 0x85,
        0x14, 0xa9, 0x04, 0x85, 0x11, 0x85, 0x13, 0x85, 0x15, 0x60, 0xa5, 0xfe, 0x85, 0x00, 0xa5, 0xfe,
        0x29, 0x03, 0x18, 0x69, 0x02, 0x85, 0x01, 0x60, 0x20, 0x4d, 0x06, 0x20, 0x8d, 0x06, 0x20, 0xc3,
        0x06, 0x20, 0x19, 0x07, 0x20, 0x20, 0x07, 0x20, 0x2d, 0x07, 0x4c, 0x38, 0x06, 0xa5, 0xff, 0xc9,
        0x77, 0xf0, 0x0d, 0xc9, 0x64, 0xf0, 0x14, 0xc9, 0x73, 0xf0, 0x1b, 0xc9, 0x61, 0xf0, 0x22, 0x60,
        0xa9, 0x04, 0x24, 0x02, 0xd0, 0x26, 0xa9, 0x01, 0x85, 0x02, 0x60, 0xa9, 0x08, 0x24, 0x02, 0xd0,
        0x1b, 0xa9, 0x02, 0x85, 0x02, 0x60, 0xa9, 0x01, 0x24, 0x02, 0xd0, 0x10, 0xa9, 0x04, 0x85, 0x02,
        0x60, 0xa9, 0x02, 0x24, 0x02, 0xd0, 0x05, 0xa9, 0x08, 0x85, 0x02, 0x60, 0x60, 0x20, 0x94, 0x06,
        0x20, 0xa8, 0x06, 0x60, 0xa5, 0x00, 0xc5, 0x10, 0xd0, 0x0d, 0xa5, 0x01, 0xc5, 0x11, 0xd0, 0x07,
        0xe6, 0x03, 0xe6, 0x03, 0x20, 0x2a, 0x06, 0x60, 0xa2, 0x02, 0xb5, 0x10, 0xc5, 0x10, 0xd0, 0x06,
        0xb5, 0x11, 0xc5, 0x11, 0xf0, 0x09, 0xe8, 0xe8, 0xe4, 0x03, 0xf0, 0x06, 0x4c, 0xaa, 0x06, 0x4c,
        0x35, 0x07, 0x60, 0xa6, 0x03, 0xca, 0x8a, 0xb5, 0x10, 0x95, 0x12, 0xca, 0x10, 0xf9, 0xa5, 0x02,
        0x4a, 0xb0, 0x09, 0x4a, 0xb0, 0x19, 0x4a, 0xb0, 0x1f, 0x4a, 0xb0, 0x2f, 0xa5, 0x10, 0x38, 0xe9,
        0x20, 0x85, 0x10, 0x90, 0x01, 0x60, 0xc6, 0x11, 0xa9, 0x01, 0xc5, 0x11, 0xf0, 0x28, 0x60, 0xe6,
        0x10, 0xa9, 0x1f, 0x24, 0x10, 0xf0, 0x1f, 0x60, 0xa5, 0x10, 0x18, 0x69, 0x20, 0x85, 0x10, 0xb0,
        0x01, 0x60, 0xe6, 0x11, 0xa9, 0x06, 0xc5, 0x11, 0xf0, 0x0c, 0x60, 0xc6, 0x10, 0xa5, 0x10, 0x29,
        0x1f, 0xc9, 0x1f, 0xf0, 0x01, 0x60, 0x4c, 0x35, 0x07, 0xa0, 0x00, 0xa5, 0xfe, 0x91, 0x00, 0x60,
        0xa6, 0x03, 0xa9, 0x00, 0x81, 0x10, 0xa2, 0x00, 0xa9, 0x01, 0x81, 0x10, 0x60, 0xa2, 0x00, 0xea,
        0xea, 0xca, 0xd0, 0xfb, 0x60
    };

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
    var random_number_bc = mapped_random_number.busCallback();

    var mapped_controller = Snake.MappedController{};
    var controller_bc = mapped_controller.busCallback();

    var mapped_screen = Snake.MappedScreen{};
    var screen_bc = mapped_screen.busCallback();

    var ram = Ram(0x10000){};
    ram.write_bytes(&Snake.game_code, 0x600);
    var work_ram_bc = ram.busCallback();

    var bus = Bus.init(&work_ram_bc);

    bus.set_callbacks(&random_number_bc, 0xFE, 0xFF);
    bus.set_callbacks(&controller_bc, 0xFF, 0x100);
    bus.set_callbacks(&screen_bc, 0x200, 0x600);

    var cpu = CPU.init(&bus);
    cpu.pc = 0x600;

    _ = c.SDL_Init(c.SDL_INIT_VIDEO);
    defer c.SDL_Quit();

    // var window = c.SDL_CreateWindow("ZigNES", c.SDL_WINDOWPOS_CENTERED, c.SDL_WINDOWPOS_CENTERED, 256, 240, 0);
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

            std.time.sleep(std.time.ns_per_ms * 10);
        }
    }
}
