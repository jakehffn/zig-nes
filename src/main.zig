const std = @import("std");
const GPA = std.heap.GeneralPurposeAllocator;

const builtin = @import("builtin");
const DEBUG = builtin.mode == .Debug;

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
const ControllerStatus = @import("./controllers.zig").Status;

const PaletteViewer = @import("./ppu/debug/palette_viewer.zig");
const SpriteViewer = @import("./ppu/debug/sprite_viewer.zig");
const NametableViewer = @import("./ppu/debug/nametable_viewer.zig");

fn initSDL() !void {
    if (c_sdl.SDL_Init(c_sdl.SDL_INIT_VIDEO | c_sdl.SDL_INIT_AUDIO) != 0) {
        std.debug.print("ZigNES: Failed to initialize SDL: {s}\n", .{c_sdl.SDL_GetError()});
        return error.Unable;
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

    audio_device = c_sdl.SDL_OpenAudioDevice(null, 0, &spec_requested, &spec_obtained, 0);

    if (audio_device == 0) {
        std.debug.print("ZigNES: Unable to initialize audio device: {s}\n", .{c_sdl.SDL_GetError()});
        return error.Unable;
    }
    c_sdl.SDL_PauseAudioDevice(audio_device, 0);
}

fn deinitSDL() void {
    c_sdl.SDL_Quit();
    c_sdl.SDL_DestroyWindow(window);
    c_sdl.SDL_GL_DeleteContext(gl_context);
    if (audio_device != 0) {
        c_sdl.SDL_CloseAudioDevice(audio_device);
    }
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
                    c_sdl.SDLK_l => {
                        emulator.cpu.should_log = @bitCast(sdl_event.type == c_sdl.SDL_KEYDOWN);
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

fn updateNametableViewerTexture() void {
    c_glew.glBindTexture(c_glew.GL_TEXTURE_2D, gui.nametable_viewer_texture);
    c_glew.glTexImage2D(
        c_glew.GL_TEXTURE_2D, 
        0, 
        c_glew.GL_RGB, 
        NametableViewer.width, 
        NametableViewer.height, 
        0, 
        c_glew.GL_RGB, 
        c_glew.GL_UNSIGNED_BYTE, 
        emulator.getNametableViewerPixels()
    );
    c_glew.glBindTexture(c_glew.GL_TEXTURE_2D, 0);
}

pub fn renderCallback() void {
    bufferFrame();
    // Let the emulator end the frame to start gui render and event handles
    emulator.frame_ready = true;
}

pub fn emptyCallback() void {}

inline fn bufferFrame() void {
    // Updates the screen texture
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

fn audioCallback() void {
    const bytes_per_sample = 2;
    _ = c_sdl.SDL_QueueAudio(audio_device, emulator.getSampleBuffer(), sample_buffer_size * bytes_per_sample);
    while (c_sdl.SDL_GetQueuedAudioSize(audio_device) > sample_buffer_size * 2) {
        c_sdl.SDL_Delay(1);
        surplus_time += 1;
    }
}

fn startFrame() void {
    c_imgui.ImGui_ImplOpenGL3_NewFrame();
    c_imgui.ImGui_ImplSDL2_NewFrame();
    c_imgui.igNewFrame();
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

pub const sample_buffer_size = 2048;
pub const audio_frequency = 44100;
pub const ppu_log_file: ?[]const u8 = "./log/ZigNES_PPU.log";
pub const cpu_log_file: ?[]const u8 = "./log/ZigNES.log";

var gpa = GPA(.{}){};
var emulator: Emulator = .{};

var window: ?*c_sdl.SDL_Window = null;
var current_display_mode: c_sdl.SDL_DisplayMode = undefined;
var gl_context: c_sdl.SDL_GLContext = undefined;

var spec_requested: c_sdl.SDL_AudioSpec = .{
    .freq = audio_frequency, 
    .format = c_sdl.AUDIO_U16,
    .channels = 1,
    .silence = undefined,
    .samples = sample_buffer_size,
    .size = undefined,
    .callback = null,
    .userdata = undefined,
    .padding = undefined
};
var spec_obtained: c_sdl.SDL_AudioSpec = undefined;
var audio_device: c_sdl.SDL_AudioDeviceID = undefined;

var gui: Gui = undefined;
var controller_status: ControllerStatus = .{};

var surplus_time: f16 = 0;

pub fn main() !void {
    var allocator = gpa.allocator();
    
    try initSDL();
    defer deinitSDL();
    initGl();
    initImgui();
    defer deinitImgui();

    try emulator.init(allocator, renderCallback, audioCallback);
    defer emulator.deinit();

    gui = Gui.init(allocator);
    gui.loadSettings(&emulator) catch |e| {
        std.debug.print("Error loading settings: {}\n", .{e});
    };
    defer gui.saveSettings() catch {
        std.debug.print("Error saving settings\n", .{});
    };

    gui.screen_texture = createTexture();
    gui.palette_viewer_texture = createTexture();
    gui.sprite_viewer_texture = createTexture();
    gui.nametable_viewer_texture = createTexture();

    Gui.initStyles();

    // Main loop
    while (gui.not_quit) {
        pollEvents();
        emulator.setControllerOneStatus(controller_status);

        if (!gui.paused) {
            if (emulator.apu.emulation_speed == 1.0) {
                emulator.stepFrame();
            } else {
                // This is less accurate and may cause screen tearing, so it's only used for non-realtime speeds
                const frame_steps = 29780.5;
                emulator.stepN(@intFromFloat(frame_steps * emulator.apu.emulation_speed));
                // Values less than one will use the callback to buffer a frame when needed
                if (emulator.apu.emulation_speed > 1.0) {
                    bufferFrame();
                }
            }
        }

        startFrame();
        gui.showMainWindow(&emulator);
        if (gui.show_load_rom_modal) {
            gui.showLoadRomModal(&emulator);
        }
        if (gui.show_load_palette_modal) {
            gui.showLoadPaletteModal(&emulator);
        }
        if (gui.saved_settings.show_palette_viewer) {
            updatePaletteViewerTexture();
            gui.showPaletteViewer();
        }
        if (gui.saved_settings.show_sprite_viewer) {
            updateSpriteViewerTexture();
            gui.showSpriteViewer();
        }
        if (gui.saved_settings.show_nametable_viewer) {
            updateNametableViewerTexture();
            gui.showNametableViewer();
        }
        if (gui.saved_settings.show_performance_monitor) {
            gui.showPerformanceMonitor(surplus_time);
            surplus_time = 0;
        }

        render();
    }
}