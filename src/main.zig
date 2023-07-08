const std = @import("std");
const GPA = std.heap.GeneralPurposeAllocator;
const c_glew = @cImport({
    @cInclude("GL/glew.h");
});
const c_sdl = @cImport({
    @cInclude("SDL.h");
    @cInclude("SDL_opengl.h");
});
const c_imgui = @cImport({
    @cDefine("CIMGUI_DEFINE_ENUMS_AND_STRUCTS", {});
    @cInclude("cimgui.h");
    @cDefine("CIMGUI_USE_SDL2", {});
    @cDefine("CIMGUI_USE_OPENGL3", {});
    @cInclude("cimgui_impl.h");
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

    if (c_sdl.SDL_Init(c_sdl.SDL_INIT_VIDEO) != 0) {
        std.debug.print("ZigNES: Failed to initialize SDL: {s}\n", .{c_sdl.SDL_GetError()});
        return;
    } 
    defer c_sdl.SDL_Quit();

    _ = c_sdl.SDL_GL_SetAttribute(c_sdl.SDL_GL_CONTEXT_FLAGS, 0);
    _ = c_sdl.SDL_GL_SetAttribute(c_sdl.SDL_GL_CONTEXT_PROFILE_MASK, c_sdl.SDL_GL_CONTEXT_PROFILE_CORE);
    _ = c_sdl.SDL_GL_SetAttribute(c_sdl.SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    _ = c_sdl.SDL_GL_SetAttribute(c_sdl.SDL_GL_CONTEXT_MINOR_VERSION, 0);

    _ = c_sdl.SDL_SetHint(c_sdl.SDL_HINT_RENDER_DRIVER, "opengl");
    _ = c_sdl.SDL_GL_SetAttribute(c_sdl.SDL_GL_DEPTH_SIZE, 24);
    _ = c_sdl.SDL_GL_SetAttribute(c_sdl.SDL_GL_STENCIL_SIZE, 8);
    _ = c_sdl.SDL_GL_SetAttribute(c_sdl.SDL_GL_DOUBLEBUFFER, 1);
    var current: c_sdl.SDL_DisplayMode = undefined;
    _ = c_sdl.SDL_GetCurrentDisplayMode(0, &current);

    var window = c_sdl.SDL_CreateWindow(
        "ZigNES", 
        c_sdl.SDL_WINDOWPOS_CENTERED, 
        c_sdl.SDL_WINDOWPOS_CENTERED, 
        400, 
        400, 
        c_sdl.SDL_WINDOW_HIDDEN | c_sdl.SDL_WINDOW_RESIZABLE | c_sdl.SDL_WINDOW_OPENGL
    );
    defer c_sdl.SDL_DestroyWindow(window);

    var gl_context: c_sdl.SDL_GLContext = c_sdl.SDL_GL_CreateContext(window);
    defer c_sdl.SDL_GL_DeleteContext(gl_context);
    _ = c_sdl.SDL_GL_SetSwapInterval(1);

    if (c_glew.glewInit() != c_glew.GLEW_OK) {
        std.debug.print("ZigNES: Failed to initialize GLEW\n", .{});
        return;
    }

    _ = c_imgui.igCreateContext(null);
    defer c_imgui.igDestroyContext(null);

    var io: *c_imgui.ImGuiIO = c_imgui.igGetIO();
    io.*.ConfigFlags |= c_imgui.ImGuiConfigFlags_NavEnableKeyboard;
    io.*.ConfigFlags |= c_imgui.ImGuiConfigFlags_DockingEnable;         
    io.*.ConfigFlags |= c_imgui.ImGuiConfigFlags_ViewportsEnable; 
    _ = c_imgui.ImGui_ImplSDL2_InitForOpenGL(@ptrCast(window), gl_context);
    
    defer c_imgui.ImGui_ImplSDL2_Shutdown();
    _ = c_imgui.ImGui_ImplOpenGL3_Init("#version 130");
    defer c_imgui.ImGui_ImplOpenGL3_Shutdown();

    c_imgui.igStyleColorsDark(null);

    var styles = c_imgui.igGetStyle();
    styles.*.Colors[c_imgui.ImGuiCol_TitleBgActive] = c_imgui.ImVec4{.x = 0.5, .y = 0, .z = 0.5, .w = 1};

    var controller_status: ControllerStatus = .{};
    var screen_texture: c_uint = undefined;
    c_glew.glGenTextures(1, &screen_texture);
    c_glew.glBindTexture(c_glew.GL_TEXTURE_2D, screen_texture);

    c_glew.glTexParameteri(c_glew.GL_TEXTURE_2D, c_glew.GL_TEXTURE_MIN_FILTER, c_glew.GL_NEAREST);
    c_glew.glTexParameteri(c_glew.GL_TEXTURE_2D, c_glew.GL_TEXTURE_MAG_FILTER, c_glew.GL_NEAREST);
    c_glew.glTexParameteri(c_glew.GL_TEXTURE_2D, c_glew.GL_TEXTURE_WRAP_S, c_glew.GL_CLAMP_TO_EDGE); // This is required on Webc_glew.GL for non power-of-two textures
    c_glew.glTexParameteri(c_glew.GL_TEXTURE_2D, c_glew.GL_TEXTURE_WRAP_T, c_glew.GL_CLAMP_TO_EDGE); // Same

    c_glew.glBindTexture(c_glew.GL_TEXTURE_2D, 0);

    var not_quit: bool = true;

    mainloop: while (true) {
        if (!not_quit) {
            break :mainloop;
        }
        const start_time = c_sdl.SDL_GetPerformanceCounter();

        c_imgui.ImGui_ImplOpenGL3_NewFrame();
        c_imgui.ImGui_ImplSDL2_NewFrame();
        c_imgui.igNewFrame();

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
            _ = c_imgui.ImGui_ImplSDL2_ProcessEvent(@ptrCast(&sdl_event));
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

        c_glew.glBindTexture(c_glew.GL_TEXTURE_2D, screen_texture);
        c_glew.glTexImage2D(c_glew.GL_TEXTURE_2D, 0, c_glew.GL_RGB, 256, 240, 0, c_glew.GL_RGB, c_glew.GL_UNSIGNED_BYTE, &ppu.screen.data);
        // c_glew.glGenerateMipmap(c_glew.GL_TEXTURE_2D);

        c_glew.glBindTexture(c_glew.GL_TEXTURE_2D, 0);

        var screen_scale: f32 = 2;
        _ = c_imgui.igBegin(
            "ZigNES", 
            &not_quit, 
            c_imgui.ImGuiWindowFlags_MenuBar  | 
            c_imgui.ImGuiWindowFlags_NoCollapse         |
            c_imgui.ImGuiWindowFlags_NoResize           |
            c_imgui.ImGuiWindowFlags_MenuBar
        );
        c_imgui.igImage(
            @ptrFromInt(screen_texture),  
            c_imgui.ImVec2{.x = 256 * screen_scale, .y = 240 * screen_scale}, 
            c_imgui.ImVec2{.x = 0, .y = 0}, 
            c_imgui.ImVec2{.x = 1, .y = 1},
            c_imgui.ImVec4{.x = 1, .y = 1, .z = 1, .w = 1},
            c_imgui.ImVec4{.x = 0, .y = 0, .z = 0, .w = 1} 
        );
        c_imgui.igEnd(); 

        c_imgui.igRender();
        _ = c_sdl.SDL_GL_MakeCurrent(window, gl_context);
        c_glew.glViewport(0, 0, @intFromFloat(io.DisplaySize.x), @intFromFloat(io.DisplaySize.y));
        c_glew.glClearColor(0.45, 0.55, 0.6, 1);
        c_glew.glClear(c_glew.GL_COLOR_BUFFER_BIT);
        c_imgui.ImGui_ImplOpenGL3_RenderDrawData(c_imgui.igGetDrawData());
        
        if (io.ConfigFlags & c_imgui.ImGuiConfigFlags_ViewportsEnable != 0) {
            var backup_current_window = c_sdl.SDL_GL_GetCurrentWindow();
            var backup_current_context = c_sdl.SDL_GL_GetCurrentContext();
            c_imgui.igUpdatePlatformWindows();
            c_imgui.igRenderPlatformWindowsDefault(null, null);
            _ = c_sdl.SDL_GL_MakeCurrent(backup_current_window, backup_current_context);
        }

        c_sdl.SDL_GL_SwapWindow(window);

        const end_time = c_sdl.SDL_GetPerformanceCounter();
        const elapsed_time_ms = @as(f64, @floatFromInt(end_time - start_time)) / @as(f64, @floatFromInt(c_sdl.SDL_GetPerformanceFrequency())) * 1000;
        const frame_time_ms: f64 = 16.66;
        c_sdl.SDL_Delay(@as(u32, @intFromFloat(@max(0, frame_time_ms - elapsed_time_ms))));
    }
}