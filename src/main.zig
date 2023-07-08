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
const ControllerStatus = @import("./bus/controller.zig").Status;

fn colorRgbToImVec4(r: f32, g: f32, b: f32, a: f32) c_imgui.ImVec4 {
    return .{.x = r/255, .y = g/255, .z = b/255, .w = a/255};
}

fn initSDL(window: *?*c_sdl.SDL_Window, current_display_mode: *c_sdl.SDL_DisplayMode, gl_context: *c_sdl.SDL_GLContext) void {
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

    _ = c_sdl.SDL_GetCurrentDisplayMode(0, current_display_mode);

    window.* = c_sdl.SDL_CreateWindow(
        "ZigNES", 
        c_sdl.SDL_WINDOWPOS_CENTERED, 
        c_sdl.SDL_WINDOWPOS_CENTERED, 
        400, 
        400, 
        c_sdl.SDL_WINDOW_HIDDEN | c_sdl.SDL_WINDOW_RESIZABLE | c_sdl.SDL_WINDOW_OPENGL
    );

    gl_context.* = c_sdl.SDL_GL_CreateContext(window.*);
    _ = c_sdl.SDL_GL_SetSwapInterval(1);
}

fn deinitSDL(window: ?*c_sdl.SDL_Window, gl_context: *c_sdl.SDL_GLContext) void {
    c_sdl.SDL_Quit();
    c_sdl.SDL_DestroyWindow(window);
    c_sdl.SDL_GL_DeleteContext(gl_context.*);
}

fn initImgui(window: ?*c_sdl.SDL_Window, gl_context: *c_sdl.SDL_GLContext) void {
    _ = c_imgui.igCreateContext(null);

    var io: *c_imgui.ImGuiIO = c_imgui.igGetIO();
    io.*.ConfigFlags |= c_imgui.ImGuiConfigFlags_NavEnableKeyboard;
    io.*.ConfigFlags |= c_imgui.ImGuiConfigFlags_DockingEnable;         
    io.*.ConfigFlags |= c_imgui.ImGuiConfigFlags_ViewportsEnable; 
    _ = c_imgui.ImGui_ImplSDL2_InitForOpenGL(@ptrCast(window), gl_context.*);
    _ = c_imgui.ImGui_ImplOpenGL3_Init("#version 130");

    initImguiStyles();
}

fn initImguiStyles() void {
    c_imgui.igStyleColorsDark(null);
    var styles = c_imgui.igGetStyle();

    styles.*.Colors[c_imgui.ImGuiCol_Text] = colorRgbToImVec4(211, 198, 170, 255);

    styles.*.Colors[c_imgui.ImGuiCol_TitleBgActive] = colorRgbToImVec4(45, 53, 59, 255);

    styles.*.Colors[c_imgui.ImGuiCol_Border] = colorRgbToImVec4(45, 53, 59, 255);

    styles.*.Colors[c_imgui.ImGuiCol_WindowBg] = colorRgbToImVec4(45, 53, 59, 255);

    styles.*.Colors[c_imgui.ImGuiCol_MenuBarBg] = colorRgbToImVec4(45, 53, 59, 255);

    styles.*.Colors[c_imgui.ImGuiCol_Button] = colorRgbToImVec4(45, 53, 59, 255);
    styles.*.Colors[c_imgui.ImGuiCol_ButtonHovered] = colorRgbToImVec4(54, 63, 69, 255);
    styles.*.Colors[c_imgui.ImGuiCol_ButtonActive] = colorRgbToImVec4(45, 53, 59, 255);
}

fn deinitImgui() void {
    c_imgui.ImGui_ImplOpenGL3_Shutdown();
    c_imgui.ImGui_ImplSDL2_Shutdown();
    c_imgui.igDestroyContext(null);
}

fn createScreenTexture() c_uint {
    var screen_texture: c_uint = undefined;
    c_glew.glGenTextures(1, &screen_texture);
    c_glew.glBindTexture(c_glew.GL_TEXTURE_2D, screen_texture);

    c_glew.glTexParameteri(c_glew.GL_TEXTURE_2D, c_glew.GL_TEXTURE_MIN_FILTER, c_glew.GL_NEAREST);
    c_glew.glTexParameteri(c_glew.GL_TEXTURE_2D, c_glew.GL_TEXTURE_MAG_FILTER, c_glew.GL_NEAREST);
    c_glew.glTexParameteri(c_glew.GL_TEXTURE_2D, c_glew.GL_TEXTURE_WRAP_S, c_glew.GL_CLAMP_TO_EDGE); 
    c_glew.glTexParameteri(c_glew.GL_TEXTURE_2D, c_glew.GL_TEXTURE_WRAP_T, c_glew.GL_CLAMP_TO_EDGE);

    c_glew.glBindTexture(c_glew.GL_TEXTURE_2D, 0);

    return screen_texture;
}

fn pollEvents(not_quit: *bool, controller_status: *ControllerStatus) void {
    var sdl_event: c_sdl.SDL_Event = undefined;
    while (c_sdl.SDL_PollEvent(&sdl_event) != 0) {
        _ = c_imgui.ImGui_ImplSDL2_ProcessEvent(@ptrCast(&sdl_event));
        switch (sdl_event.type) {
            c_sdl.SDL_QUIT => {
                not_quit.* = false;
            },
            c_sdl.SDL_KEYDOWN, c_sdl.SDL_KEYUP => {
                switch (sdl_event.key.keysym.sym) {
                    c_sdl.SDLK_w, c_sdl.SDLK_UP => {
                        controller_status.*.up = @bitCast(sdl_event.type == c_sdl.SDL_KEYDOWN);
                    },
                    c_sdl.SDLK_a, c_sdl.SDLK_LEFT => {
                        controller_status.*.left = @bitCast(sdl_event.type == c_sdl.SDL_KEYDOWN);
                    },
                    c_sdl.SDLK_s, c_sdl.SDLK_DOWN => {
                        controller_status.*.down = @bitCast(sdl_event.type == c_sdl.SDL_KEYDOWN);
                    },
                    c_sdl.SDLK_d, c_sdl.SDLK_RIGHT => {
                        controller_status.*.right = @bitCast(sdl_event.type == c_sdl.SDL_KEYDOWN);
                    },
                    c_sdl.SDLK_RETURN => {
                        controller_status.*.start = @bitCast(sdl_event.type == c_sdl.SDL_KEYDOWN);
                    },
                    c_sdl.SDLK_SPACE => {
                        controller_status.*.select = @bitCast(sdl_event.type == c_sdl.SDL_KEYDOWN);
                    },
                    c_sdl.SDLK_j => {
                        controller_status.*.a = @bitCast(sdl_event.type == c_sdl.SDL_KEYDOWN);
                    },
                    c_sdl.SDLK_k => {
                        controller_status.*.b = @bitCast(sdl_event.type == c_sdl.SDL_KEYDOWN);
                    },
                    else => {}
                }
            },
            else => {},
        }
    }
}

fn showMainWindow(screen_texture: c_uint, emulator: *Emulator, not_quit: *bool, screen_scale: *f32) void {
    c_glew.glBindTexture(c_glew.GL_TEXTURE_2D, screen_texture);
    c_glew.glTexImage2D(
        c_glew.GL_TEXTURE_2D, 
        0, 
        c_glew.GL_RGB, 
        256, 
        240, 
        0, 
        c_glew.GL_RGB, 
        c_glew.GL_UNSIGNED_BYTE, 
        emulator.*.getScreenPixels()
    );
    c_glew.glBindTexture(c_glew.GL_TEXTURE_2D, 0);

    _ = c_imgui.igBegin(
        "ZigNES", 
        not_quit, 
        c_imgui.ImGuiWindowFlags_MenuBar     | 
        c_imgui.ImGuiWindowFlags_NoCollapse         |
        c_imgui.ImGuiWindowFlags_NoResize           |
        c_imgui.ImGuiWindowFlags_MenuBar
    );
    c_imgui.igImage(
        @ptrFromInt(screen_texture),  
        c_imgui.ImVec2{.x = 256 * screen_scale.*, .y = 240 * screen_scale.*}, 
        c_imgui.ImVec2{.x = 0, .y = 0}, 
        c_imgui.ImVec2{.x = 1, .y = 1},
        c_imgui.ImVec4{.x = 1, .y = 1, .z = 1, .w = 1},
        c_imgui.ImVec4{.x = 0, .y = 0, .z = 0, .w = 1} 
    );
    c_imgui.igEnd(); 
}

fn render(window: ?*c_sdl.SDL_Window, gl_context: *c_sdl.SDL_GLContext) void {
    var io: *c_imgui.ImGuiIO = c_imgui.igGetIO();

    c_imgui.igRender();
    _ = c_sdl.SDL_GL_MakeCurrent(window, gl_context.*);
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
}

pub fn main() !void {
    var gpa = GPA(.{}){};
    var allocator = gpa.allocator();

    var emulator: Emulator = .{};
    try emulator.init(allocator);

    emulator.loadRom("./test-files/game-roms/Pac-Man (USA) (Namco).nes", allocator);

    var window: ?*c_sdl.SDL_Window = null;
    var current_display_mode: c_sdl.SDL_DisplayMode = undefined;
    var gl_context: c_sdl.SDL_GLContext = undefined;
    initSDL(&window, &current_display_mode, &gl_context);
    defer deinitSDL(window, &gl_context);

    if (c_glew.glewInit() != c_glew.GLEW_OK) {
        std.debug.print("ZigNES: Failed to initialize GLEW\n", .{});
        return;
    }

    initImgui(window, &gl_context);
    defer deinitImgui();

    var screen_texture: c_uint = createScreenTexture();
    var controller_status: ControllerStatus = .{};
    var not_quit: bool = true;
    var screen_scale: f32 = 2;

    mainloop: while (true) {
        if (!not_quit) {
            break :mainloop;
        }
        const start_time = c_sdl.SDL_GetPerformanceCounter();

        c_imgui.ImGui_ImplOpenGL3_NewFrame();
        c_imgui.ImGui_ImplSDL2_NewFrame();
        c_imgui.igNewFrame();

        emulator.stepFrame();

        pollEvents(&not_quit, &controller_status);

        emulator.setControllerStatus(controller_status);

        showMainWindow(screen_texture, &emulator, &not_quit, &screen_scale);

        render(window, &gl_context);

        const end_time = c_sdl.SDL_GetPerformanceCounter();
        const elapsed_time_ms = @as(f64, @floatFromInt(end_time - start_time)) / @as(f64, @floatFromInt(c_sdl.SDL_GetPerformanceFrequency())) * 1000;
        const frame_time_ms: f64 = 16.66;
        c_sdl.SDL_Delay(@as(u32, @intFromFloat(@max(0, frame_time_ms - elapsed_time_ms))));
    }
}