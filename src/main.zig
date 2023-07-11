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

const Emulator = @import("emulator.zig");
const Gui = @import("gui.zig");
const ControllerStatus = @import("./bus/controller.zig").Status;

const PaletteViewer = @import("./ppu/debug/palette_viewer.zig");
const SpriteViewer = @import("./ppu/debug/sprite_viewer.zig");

fn initSDL() void {
    if (c_sdl.SDL_Init(c_sdl.SDL_INIT_VIDEO) != 0) {
        std.debug.print("ZigNES: Failed to initialize SDL: {s}\n", .{c_sdl.SDL_GetError()});
        return;
    } 
    _ = c_sdl.SDL_GL_SetAttribute(c_sdl.SDL_GL_CONTEXT_FLAGS, 0);
    _ = c_sdl.SDL_GL_SetAttribute(c_sdl.SDL_GL_CONTEXT_PROFILE_MASK, c_sdl.SDL_GL_CONTEXT_PROFILE_CORE);
    _ = c_sdl.SDL_GL_SetAttribute(c_sdl.SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    _ = c_sdl.SDL_GL_SetAttribute(c_sdl.SDL_GL_CONTEXT_MINOR_VERSION, 0);

    _ = c_sdl.SDL_SetHint(c_sdl.SDL_HINT_RENDER_DRIVER, "opengl");
    _ = c_sdl.SDL_GL_SetAttribute(c_sdl.SDL_GL_DEPTH_SIZE, 24);
    _ = c_sdl.SDL_GL_SetAttribute(c_sdl.SDL_GL_STENCIL_SIZE, 8);
    _ = c_sdl.SDL_GL_SetAttribute(c_sdl.SDL_GL_DOUBLEBUFFER, 1);

    _ = c_sdl.SDL_GetCurrentDisplayMode(0, &current_display_mode);

    window = c_sdl.SDL_CreateWindow(
        "ZigNES", 
        c_sdl.SDL_WINDOWPOS_CENTERED, 
        c_sdl.SDL_WINDOWPOS_CENTERED, 
        0, 
        0, 
        c_sdl.SDL_WINDOW_HIDDEN | c_sdl.SDL_WINDOW_RESIZABLE | c_sdl.SDL_WINDOW_OPENGL
    );

    gl_context = c_sdl.SDL_GL_CreateContext(window);
    _ = c_sdl.SDL_GL_SetSwapInterval(1);
}

fn deinitSDL() void {
    c_sdl.SDL_Quit();
    c_sdl.SDL_DestroyWindow(window);
    c_sdl.SDL_GL_DeleteContext(gl_context);
}

fn initGl() void {
    if (c_glew.glewInit() != c_glew.GLEW_OK) {
        std.debug.print("ZigNES: Failed to initialize GLEW\n", .{});
        return;
    }
}

fn initImgui() void {
    _ = c_imgui.igCreateContext(null);

    var io: *c_imgui.ImGuiIO = c_imgui.igGetIO();
    io.*.ConfigFlags |= c_imgui.ImGuiConfigFlags_NavEnableKeyboard;
    io.*.ConfigFlags |= c_imgui.ImGuiConfigFlags_DockingEnable;         
    io.*.ConfigFlags |= c_imgui.ImGuiConfigFlags_ViewportsEnable; 
    _ = c_imgui.ImGui_ImplSDL2_InitForOpenGL(@ptrCast(window), gl_context);
    _ = c_imgui.ImGui_ImplOpenGL3_Init("#version 130");
}

fn deinitImgui() void {
    c_imgui.ImGui_ImplOpenGL3_Shutdown();
    c_imgui.ImGui_ImplSDL2_Shutdown();
    c_imgui.igDestroyContext(null);
}

fn createTexture() c_uint {
    var texture: c_uint = undefined;
    c_glew.glGenTextures(1, &texture);
    c_glew.glBindTexture(c_glew.GL_TEXTURE_2D, texture);

    c_glew.glTexParameteri(c_glew.GL_TEXTURE_2D, c_glew.GL_TEXTURE_MIN_FILTER, c_glew.GL_NEAREST);
    c_glew.glTexParameteri(c_glew.GL_TEXTURE_2D, c_glew.GL_TEXTURE_MAG_FILTER, c_glew.GL_NEAREST);
    c_glew.glTexParameteri(c_glew.GL_TEXTURE_2D, c_glew.GL_TEXTURE_WRAP_S, c_glew.GL_CLAMP_TO_EDGE); 
    c_glew.glTexParameteri(c_glew.GL_TEXTURE_2D, c_glew.GL_TEXTURE_WRAP_T, c_glew.GL_CLAMP_TO_EDGE);

    c_glew.glBindTexture(c_glew.GL_TEXTURE_2D, 0);

    return texture;
}

fn pollEvents() void {
    var sdl_event: c_sdl.SDL_Event = undefined;
    while (c_sdl.SDL_PollEvent(&sdl_event) != 0) {
        _ = c_imgui.ImGui_ImplSDL2_ProcessEvent(@ptrCast(&sdl_event));
        switch (sdl_event.type) {
            c_sdl.SDL_QUIT => {
                gui.not_quit = false;
            },
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
                    else => {}
                }
            },
            else => {},
        }
    }
}

fn updatePaletteViewerTexture() void {
    c_glew.glBindTexture(c_glew.GL_TEXTURE_2D, gui.palette_viewer_texture);
    c_glew.glTexImage2D(
        c_glew.GL_TEXTURE_2D, 
        0, 
        c_glew.GL_RGB, 
        PaletteViewer.width, 
        PaletteViewer.height, 
        0, 
        c_glew.GL_RGB, 
        c_glew.GL_UNSIGNED_BYTE, 
        emulator.getPaletteViewerPixels()
    );
    c_glew.glBindTexture(c_glew.GL_TEXTURE_2D, 0);
}

fn updateSpriteViewerTexture() void {
    c_glew.glBindTexture(c_glew.GL_TEXTURE_2D, gui.sprite_viewer_texture);
    c_glew.glTexImage2D(
        c_glew.GL_TEXTURE_2D, 
        0, 
        c_glew.GL_RGB, 
        SpriteViewer.width, 
        SpriteViewer.height, 
        0, 
        c_glew.GL_RGB, 
        c_glew.GL_UNSIGNED_BYTE, 
        emulator.getSpriteViewerPixels()
    );
    c_glew.glBindTexture(c_glew.GL_TEXTURE_2D, 0);
}

fn updateScreenTexture() void {
    c_glew.glBindTexture(c_glew.GL_TEXTURE_2D, gui.screen_texture);
    c_glew.glTexImage2D(
        c_glew.GL_TEXTURE_2D, 
        0, 
        c_glew.GL_RGB, 
        256, 
        240, 
        0, 
        c_glew.GL_RGB, 
        c_glew.GL_UNSIGNED_BYTE, 
        emulator.getScreenPixels()
    );
    c_glew.glBindTexture(c_glew.GL_TEXTURE_2D, 0);
}

fn startFrame() void {
    frame_start = c_sdl.SDL_GetPerformanceCounter();

    c_imgui.ImGui_ImplOpenGL3_NewFrame();
    c_imgui.ImGui_ImplSDL2_NewFrame();
    c_imgui.igNewFrame();
}

fn endFrame() void {
    frame_end = c_sdl.SDL_GetPerformanceCounter();
    const elapsed_time_ms = @as(f64, @floatFromInt(frame_end - frame_start)) / 
        @as(f64, @floatFromInt(c_sdl.SDL_GetPerformanceFrequency())) * 1000;
    const frame_time_ms: f64 = 16.66;
    c_sdl.SDL_Delay(@as(u32, @intFromFloat(@max(0, frame_time_ms - elapsed_time_ms))));
}

fn render() void {
    var io: *c_imgui.ImGuiIO = c_imgui.igGetIO();

    c_imgui.igRender();
    _ = c_sdl.SDL_GL_MakeCurrent(window, gl_context);
    c_glew.glViewport(0, 0, @intFromFloat(io.DisplaySize.x), @intFromFloat(io.DisplaySize.y));
    c_glew.glClearColor(0.01, 0.0, 0.005, 1);
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
}

var gpa = GPA(.{}){};
var emulator: Emulator = .{};

var window: ?*c_sdl.SDL_Window = null;
var current_display_mode: c_sdl.SDL_DisplayMode = undefined;
var gl_context: c_sdl.SDL_GLContext = undefined;

var gui: Gui = .{
    .screen_texture = undefined,
    .palette_viewer_texture = undefined,
    .sprite_viewer_texture = undefined,
    .tile_viewer_texture = undefined
};
var controller_status: ControllerStatus = .{};

var frame_start: u64 = 0;
var frame_end: u64 = 0;

pub fn main() !void {
    var allocator = gpa.allocator();
    try emulator.init(allocator);

    // emulator.loadRom("./test-files/game-roms/Pac-Man (USA) (Namco).nes", allocator);
    
    initSDL();
    defer deinitSDL();
    initGl();
    initImgui();
    defer deinitImgui();

    gui.screen_texture = createTexture();
    gui.palette_viewer_texture = createTexture();
    gui.sprite_viewer_texture = createTexture();
    gui.tile_viewer_texture = createTexture();

    Gui.initStyles();

    // Main loop
    while (gui.not_quit) {
        pollEvents();
        emulator.setControllerStatus(controller_status);

        startFrame();
        if (!gui.paused) {
            emulator.stepFrame();
            updateScreenTexture();
        }

        gui.showMainWindow(&emulator);
        if (gui.show_load_rom_modal) {
            gui.showLoadRomModal(&emulator, allocator);
        }
        if (gui.show_palette_viewer) {
            updatePaletteViewerTexture();
            gui.showPaletteViewer();
        }
        if (gui.show_sprite_viewer) {
            updateSpriteViewerTexture();
            gui.showSpriteViewer();
        }
        if (gui.show_tile_viewer) {
            gui.showTileViewer();
        }
            
        render();
        endFrame();
    }
}