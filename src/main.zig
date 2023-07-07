const std = @import("std");
const GPA = std.heap.GeneralPurposeAllocator;
const c_sdl = @cImport({
    @cInclude("SDL.h");
});
const c_imgui = @cImport({
    @cDefine("CIMGUI_DEFINE_ENUMS_AND_STRCUTS", {});
    @cInclude("cimgui.h");
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
    // var ppu = try Ppu(null).init(&ppu_bus);
    defer ppu.deinit();

    var main_bus = try MainBus.init(allocator);
    defer main_bus.deinit(allocator);
    main_bus.setCallbacks(&ppu);

    var cpu = try Cpu("./log/ZigNES.log").init(&main_bus);
    // var cpu = try Cpu(null).init(&main_bus);
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

    _ = c_sdl.SDL_Init(c_sdl.SDL_INIT_VIDEO);
    defer c_sdl.SDL_Quit();

    const scale = 2;
    var window = c_sdl.SDL_CreateWindow("ZigNES", c_sdl.SDL_WINDOWPOS_CENTERED, c_sdl.SDL_WINDOWPOS_CENTERED, 256*scale, 240*scale, 0);
    defer c_sdl.SDL_DestroyWindow(window);

    var renderer = c_sdl.SDL_CreateRenderer(window, 0, c_sdl.SDL_RENDERER_PRESENTVSYNC);
    defer c_sdl.SDL_DestroyRenderer(renderer);

    _ = c_sdl.SDL_RenderSetScale(renderer, scale, scale);

    var texture = c_sdl.SDL_CreateTexture(
        renderer, 
        c_sdl.SDL_PIXELFORMAT_RGB24, 
        c_sdl.SDL_TEXTUREACCESS_STREAMING, 
        256, 
        240
    );

    var controller_status: ControllerStatus = .{};

    mainloop: while (true) {
        const start_time = c_sdl.SDL_GetPerformanceCounter();

        // This is about the number of cpu cycles per frame
        for (0..29780) |_| {
            cpu.step();
            // In the future, it would be nice to implement a PPU stack
            // Explained in this: https://gist.github.com/adamveld12/d0398717145a2c8dedab
            ppu.step();
            ppu.step();
            ppu.step();
        }

        var sdl_event: c_sdl.SDL_Event = undefined;
        while (c_sdl.SDL_PollEvent(&sdl_event) != 0) {
            switch (sdl_event.type) {
                c_sdl.SDL_QUIT => break :mainloop,
                c_sdl.SDL_KEYDOWN, c_sdl.SDL_KEYUP => {
                    switch (sdl_event.key.keysym.sym) {
                        c_sdl.SDLK_w, c_sdl.SDLK_UP => {
                            controller_status.up = @bitCast(sdl_event.type == c_sdl.SDL_KEYDOWN);
                        },
                        c_sdl.SDLK_a, c_sdl.SDLK_LEFT => {
                            controller_status.left = @bitCast(sdl_event.type == c_sdl.SDL_KEYDOWN);
                        },
                        c_sdl.SDLK_s, c_sdl.SDLK_DOWN => {
                            controller_status.down = @bitCast(sdl_event.type == c_sdl.SDL_KEYDOWN);
                        },
                        c_sdl.SDLK_d, c_sdl.SDLK_RIGHT => {
                            controller_status.right = @bitCast(sdl_event.type == c_sdl.SDL_KEYDOWN);
                        },
                        c_sdl.SDLK_RETURN => {
                            controller_status.start = @bitCast(sdl_event.type == c_sdl.SDL_KEYDOWN);
                        },
                        c_sdl.SDLK_SPACE => {
                            controller_status.select = @bitCast(sdl_event.type == c_sdl.SDL_KEYDOWN);
                        },
                        c_sdl.SDLK_j => {
                            controller_status.a = @bitCast(sdl_event.type == c_sdl.SDL_KEYDOWN);
                        },
                        c_sdl.SDLK_k => {
                            controller_status.b = @bitCast(sdl_event.type == c_sdl.SDL_KEYDOWN);
                        },
                        c_sdl.SDLK_l => {
                            cpu.should_log = sdl_event.type == c_sdl.SDL_KEYDOWN;
                        },
                        else => {}
                    }
                },
                else => {},
            }
        }

        main_bus.controller.status = controller_status;
        _ = c_sdl.SDL_UpdateTexture(texture, null, &ppu.screen.data, 256*3);
        _ = c_sdl.SDL_RenderCopy(renderer, texture, null, null);
        c_sdl.SDL_RenderPresent(renderer);

        const end_time = c_sdl.SDL_GetPerformanceCounter();
        const elapsed_time_ms = @as(f64, @floatFromInt(end_time - start_time)) / @as(f64, @floatFromInt(c_sdl.SDL_GetPerformanceFrequency())) * 1000;
        const frame_time_ms: f64 = 16.66;
        c_sdl.SDL_Delay(@as(u32, @intFromFloat(@max(0, frame_time_ms - elapsed_time_ms))));
    }
}