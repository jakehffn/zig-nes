const std = @import("std");
const GPA = std.heap.GeneralPurposeAllocator;
const c = @cImport({
    @cInclude("SDL.h");
});

const MainBus = @import("./cpu/main_bus.zig").MainBus;
const Cpu = @import("./cpu/cpu.zig").Cpu;

const PpuBus = @import("./ppu/ppu_bus.zig").PpuBus;
const Ppu = @import("./ppu/ppu.zig").Ppu;

const Ram = @import("./bus/ram.zig").Ram;
const MemoryMirror = @import("./bus/memory_mirror.zig").MemoryMirror;
const Rom = @import("./rom/rom.zig").Rom;

const ControllerStatus = @import("./bus/controller.zig").Controller.Status;

pub fn main() !void {
    var gpa = GPA(.{}){};
    var allocator = gpa.allocator();

    var ppu_bus = try PpuBus.init(allocator);
    defer ppu_bus.deinit(allocator);
    ppu_bus.setCallbacks();

    var ppu = try Ppu("./log/ZigNES_PPU.log").init(&ppu_bus);
    defer ppu.deinit();

    var main_bus = try MainBus.init(allocator);
    defer main_bus.deinit(allocator);
    main_bus.setCallbacks(&ppu);

    var cpu = try Cpu("./log/ZigNES.log").init(&main_bus);
    defer cpu.deinit();

    ppu.setMainBus(&main_bus);

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();
    var rom_path = args.next() orelse {
        std.debug.print("ZigNES: Please provide the path to a ROM file", .{});
        return;
    };
    std.debug.print("ZigNES: Loading rom: {s}\n", .{rom_path});

    var rom = Rom.init(allocator);
    defer rom.deinit();
    rom.load(rom_path) catch {
        std.debug.print("ZigNES: Unable to load ROM file", .{});
        return;
    };

    main_bus.loadRom(&rom);
    ppu_bus.loadRom(&rom);

    cpu.reset();

    _ = c.SDL_Init(c.SDL_INIT_VIDEO);
    defer c.SDL_Quit();

    const scale = 2;
    var window = c.SDL_CreateWindow("ZigNES", c.SDL_WINDOWPOS_CENTERED, c.SDL_WINDOWPOS_CENTERED, 256*scale, 240*scale, 0);
    defer c.SDL_DestroyWindow(window);

    var renderer = c.SDL_CreateRenderer(window, 0, c.SDL_RENDERER_PRESENTVSYNC);
    defer c.SDL_DestroyRenderer(renderer);

    _ = c.SDL_RenderSetScale(renderer, scale, scale);

    var texture = c.SDL_CreateTexture(
        renderer, 
        c.SDL_PIXELFORMAT_RGB24, 
        c.SDL_TEXTUREACCESS_STREAMING, 
        256, 
        240
    );

    var cpu_step_cycles: u32 = 0;
    var controller_status: ControllerStatus = .{};

    mainloop: while (true) {

        cpu_step_cycles = cpu.step();
        ppu.step(cpu_step_cycles);

        if (main_bus.nmi) {
            var sdl_event: c.SDL_Event = undefined;
            while (c.SDL_PollEvent(&sdl_event) != 0) {
                switch (sdl_event.type) {
                    c.SDL_QUIT => break :mainloop,
                    c.SDL_KEYDOWN, c.SDL_KEYUP => {
                        switch (sdl_event.key.keysym.sym) {
                            c.SDLK_w, c.SDLK_UP => {
                                controller_status.up = @bitCast(sdl_event.type == c.SDL_KEYDOWN);
                            },
                            c.SDLK_a, c.SDLK_LEFT => {
                                controller_status.left = @bitCast(sdl_event.type == c.SDL_KEYDOWN);
                            },
                            c.SDLK_s, c.SDLK_DOWN => {
                                controller_status.down = @bitCast(sdl_event.type == c.SDL_KEYDOWN);
                            },
                            c.SDLK_d, c.SDLK_RIGHT => {
                                controller_status.right = @bitCast(sdl_event.type == c.SDL_KEYDOWN);
                            },
                            c.SDLK_RETURN => {
                                controller_status.start = @bitCast(sdl_event.type == c.SDL_KEYDOWN);
                            },
                            c.SDLK_SPACE => {
                                controller_status.select = @bitCast(sdl_event.type == c.SDL_KEYDOWN);
                            },
                            c.SDLK_j => {
                                controller_status.a = @bitCast(sdl_event.type == c.SDL_KEYDOWN);
                            },
                            c.SDLK_k => {
                                controller_status.b = @bitCast(sdl_event.type == c.SDL_KEYDOWN);
                            },
                            c.SDLK_l => {
                                cpu.should_log = sdl_event.type == c.SDL_KEYDOWN;
                            },
                            else => {}
                        }
                    },
                    else => {},
                }
            }

            main_bus.controller.status = controller_status;

            ppu.render();
            _ = c.SDL_UpdateTexture(texture, null, &ppu.screen.data, 256*3);
            _ = c.SDL_RenderCopy(renderer, texture, null, null);
            c.SDL_RenderPresent(renderer);
        }
    }
}