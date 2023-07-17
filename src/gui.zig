const std = @import("std");
const Allocator = std.mem.Allocator;

const c_imgui = @cImport({
    @cDefine("CIMGUI_DEFINE_ENUMS_AND_STRUCTS", {});
    @cInclude("cimgui.h");
    @cDefine("CIMGUI_USE_SDL2", {});
    @cDefine("CIMGUI_USE_OPENGL3", {});
    @cInclude("cimgui_impl.h");
});

const Emulator = @import("emulator.zig");

const renderCallback = @import("./main.zig").renderCallback;
const emptyCallback = @import("./main.zig").emptyCallback;

const Self = @This();

// Screen
screen_texture: c_uint,
screen_scale: f32 = 2,

// Rom picker
show_load_rom_modal: bool = false,
rom_path: [2048]u8 = undefined,

// Emu menu
not_quit: bool = true,
paused: bool = false,
resume_latch: bool = false,

// Palette viewer
show_palette_viewer: bool = false,
palette_viewer_texture: c_uint,
palette_viewer_scale: f32 = 32,

// Sprite viewer
show_sprite_viewer: bool = false,
sprite_viewer_texture: c_uint,
sprite_viewer_scale: f32 = 4,

// Tile viewer
show_tile_viewer: bool = false,
tile_viewer_texture: c_uint,
tile_viewer_scale: f32 = 1,

// Performance menu
show_performance_monitor: bool = false,
smoothed_surplus_ms: f16 = 0,
surplus_ms_smoothing: f16 = 0.95, // Amount of old value to use

// Audio settings
volume: f32 = 50,

fn colorRgbToImVec4(r: f32, g: f32, b: f32, a: f32) c_imgui.ImVec4 {
    return .{.x = r/255, .y = g/255, .z = b/255, .w = a/255};
}

pub fn initStyles() void {
    c_imgui.igStyleColorsDark(null);
    var styles = c_imgui.igGetStyle();

    const main_bg_color = colorRgbToImVec4(45, 53, 59, 255);
    const main_text_color = colorRgbToImVec4(211, 198, 170, 255);
    const hover_color = colorRgbToImVec4(54, 63, 69, 255);
    const main_dark_color = colorRgbToImVec4(33, 39, 43, 255);
    const accent_one = colorRgbToImVec4(131, 192, 146, 255);
    _ = accent_one;

    styles.*.Colors[c_imgui.ImGuiCol_Text] = main_text_color;
    styles.*.Colors[c_imgui.ImGuiCol_TitleBg] = main_bg_color;
    styles.*.Colors[c_imgui.ImGuiCol_TitleBgActive] = hover_color;
    styles.*.Colors[c_imgui.ImGuiCol_TextSelectedBg] = hover_color;
    styles.*.Colors[c_imgui.ImGuiCol_FrameBg] = main_dark_color;
    styles.*.Colors[c_imgui.ImGuiCol_PopupBg] = main_bg_color;

    // ---- Window stuff ----
    styles.*.Colors[c_imgui.ImGuiCol_Border] = main_dark_color;
    styles.*.Colors[c_imgui.ImGuiCol_WindowBg] = main_bg_color;
    styles.*.WindowBorderSize = 1;
    styles.*.WindowPadding = .{.x = 0, .y = 0};

    // ---- Menu stuff ----
    styles.*.Colors[c_imgui.ImGuiCol_MenuBarBg] = main_bg_color;
    // This also changes the menu item's hover color
    styles.*.Colors[c_imgui.ImGuiCol_Header] = hover_color;
    styles.*.Colors[c_imgui.ImGuiCol_HeaderHovered] = hover_color;

    // ---- Button stuff ----
    styles.*.Colors[c_imgui.ImGuiCol_Button] = main_bg_color;
    styles.*.Colors[c_imgui.ImGuiCol_ButtonHovered] = hover_color;
    styles.*.Colors[c_imgui.ImGuiCol_ButtonActive] = main_bg_color;

    // ---- Slider stuff ----
    styles.*.Colors[c_imgui.ImGuiCol_SliderGrab] = main_bg_color;
    styles.*.Colors[c_imgui.ImGuiCol_SliderGrabActive] = main_bg_color; 

    styles.*.Colors[c_imgui.ImGuiCol_FrameBg] = main_dark_color;
    styles.*.Colors[c_imgui.ImGuiCol_FrameBgHovered] = main_dark_color;
    styles.*.Colors[c_imgui.ImGuiCol_FrameBgActive] = hover_color;
}

fn showMainMenu(self: *Self, emulator: *Emulator) void {
    if (c_imgui.igBeginMenuBar()) {
        c_imgui.igPushStyleVar_Vec2(c_imgui.ImGuiStyleVar_WindowPadding, .{.x = 8, .y = 8});
        c_imgui.igPushStyleVar_Vec2(c_imgui.ImGuiStyleVar_ItemSpacing, .{.x = 6, .y = 6});
        if (c_imgui.igBeginMenu("File", true)) {
            self.show_load_rom_modal = c_imgui.igMenuItem_Bool("Open", "", false, true);
            c_imgui.igEndMenu();
        }
        if (c_imgui.igBeginMenu("Emu", true)) {
            if (!self.paused) {
                _ = c_imgui.igMenuItem_BoolPtr("Pause", "", &self.paused, true);
            } else {
                if (c_imgui.igMenuItem_BoolPtr("Resume", "", &self.resume_latch, true)) {
                    // Doing this so I can have "Pause" button switch to "Resume" without the checkmark appearing
                    self.paused = false;
                    self.resume_latch = false;
                }
            }
            if (c_imgui.igMenuItem_Bool("Reset", "", false, true)) {
                emulator.reset();
            }
            if (c_imgui.igBeginMenu("Speed", true)) {
                _ = c_imgui.igSliderFloat("##", &emulator.apu.emulation_speed, 0.1, 10, "%.2f%", 
                    0
                );
                c_imgui.igSameLine(0, 4);
                if (c_imgui.igButton("Reset", .{.x = 0, .y = 0})) {
                    emulator.apu.emulation_speed = 1.0;
                }
                if (emulator.apu.emulation_speed <= 1.0) {
                    // When the emulation is realtime or slower, the screen buffer only needs to be updated when
                    //  a new emulation frame is ready. Otherwise, screen tearing can occur
                    emulator.ppu.render_callback = renderCallback;
                } else {
                    // When the emulation is faster than realtime, the screen buffer does not need to be updated
                    //  every time an emulation frame is ready, as the emulator will only ever render ~60 fps
                    //  This risks screen tearing, but allows for much faster emulation speeds.
                    emulator.ppu.render_callback = emptyCallback;
                }
                c_imgui.igEndMenu();
            }
            c_imgui.igEndMenu();
        }
        if (c_imgui.igBeginMenu("Debug", true)) {
            _ = c_imgui.igMenuItem_BoolPtr("Palette Viewer", "", &self.show_palette_viewer, true);
            _ = c_imgui.igMenuItem_BoolPtr("Sprite Viewer", "", &self.show_sprite_viewer, true);
            _ = c_imgui.igMenuItem_BoolPtr("Tile Viewer", "", &self.show_tile_viewer, false); // TODO: Finish this
            _ = c_imgui.igMenuItem_BoolPtr("Performance Monitor", "", &self.show_performance_monitor, true);
            c_imgui.igEndMenu();
        }
        if (c_imgui.igBeginMenu("Settings", true)) {
            if (c_imgui.igBeginMenu("Volume", true)) {
                c_imgui.igPushStyleVar_Vec2(c_imgui.ImGuiStyleVar_FramePadding, .{.x = 0, .y = 100});
                c_imgui.igSetNextItemWidth(20);
                _ = c_imgui.igSliderFloat("##", &self.volume, 0, 100, "", 
                    c_imgui.ImGuiSliderFlags_NoRoundToFormat |
                    c_imgui.ImGuiSliderFlags_Vertical
                );
                emulator.setVolume(@floatCast(self.volume));
                c_imgui.igEndMenu();
                c_imgui.igPopStyleVar(1);
            }
            c_imgui.igEndMenu();
        }
        c_imgui.igEndMenuBar();
        c_imgui.igPopStyleVar(2);
    }
}

pub fn showLoadRomModal(self: *Self, emulator: *Emulator) void {
    c_imgui.igOpenPopup_Str("Load ROM", 0);
    c_imgui.igSetNextWindowSize(.{.x = 600, .y = 0}, 0);
    const load_rom_modal = c_imgui.igBeginPopupModal(
        "Load ROM", 
        &self.show_load_rom_modal, 
        c_imgui.ImGuiWindowFlags_NoCollapse
        
    );
    if (load_rom_modal) {
        const input_text_submit = c_imgui.igInputText(
            "ROM Path", 
            &self.rom_path, 
            2048, 
            c_imgui.ImGuiInputTextFlags_EnterReturnsTrue, 
            null, 
            null
        ); 
        
        if (input_text_submit) {
            std.debug.print("{s}\n", .{&self.rom_path});
            emulator.loadRom(&self.rom_path);
            self.show_load_rom_modal = false;
            c_imgui.igCloseCurrentPopup();
        }
        
        c_imgui.igEndPopup();
    }
}

pub fn showPaletteViewer(self: *Self) void {
    c_imgui.igSetNextWindowSize(.{.x = 0, .y = 0}, 0);
    const palette_viewer = c_imgui.igBegin(
        "Palette Viewer", 
        &self.show_palette_viewer, 
        c_imgui.ImGuiWindowFlags_NoCollapse |
        c_imgui.ImGuiWindowFlags_NoResize           
    );
    if (palette_viewer) {
        c_imgui.igImage(
            @ptrFromInt(self.palette_viewer_texture),  
            c_imgui.ImVec2{.x = 4 * self.palette_viewer_scale, .y = 8 * self.palette_viewer_scale}, 
            c_imgui.ImVec2{.x = 0, .y = 0}, 
            c_imgui.ImVec2{.x = 1, .y = 1},
            c_imgui.ImVec4{.x = 1, .y = 1, .z = 1, .w = 1},
            c_imgui.ImVec4{.x = 0, .y = 0, .z = 0, .w = 1} 
        );
        c_imgui.igEnd();
    }
}

pub fn showSpriteViewer(self: *Self) void {
    c_imgui.igSetNextWindowSize(.{.x = 0, .y = 0}, 0);
    const sprite_viewer = c_imgui.igBegin(
        "Sprite Viewer", 
        &self.show_sprite_viewer, 
        c_imgui.ImGuiWindowFlags_NoCollapse |
        c_imgui.ImGuiWindowFlags_NoResize           
    );
    if (sprite_viewer) {
        c_imgui.igImage(
            @ptrFromInt(self.sprite_viewer_texture),  
            c_imgui.ImVec2{.x = 64 * self.sprite_viewer_scale, .y = 64 * self.sprite_viewer_scale}, 
            c_imgui.ImVec2{.x = 0, .y = 0}, 
            c_imgui.ImVec2{.x = 1, .y = 1},
            c_imgui.ImVec4{.x = 1, .y = 1, .z = 1, .w = 1},
            c_imgui.ImVec4{.x = 0, .y = 0, .z = 0, .w = 1} 
        );
        c_imgui.igEnd();
    }
}

pub fn showTileViewer(self: *Self) void {
    c_imgui.igSetNextWindowSize(.{.x = 0, .y = 0}, 0);
    const tile_viewer = c_imgui.igBegin(
        "Tile Viewer", 
        &self.show_tile_viewer, 
        c_imgui.ImGuiWindowFlags_NoCollapse
    );
    if (tile_viewer) {
        c_imgui.igText("Test");
        c_imgui.igEnd();
    }
}

pub fn showPerformanceMonitor(self: *Self, surplus_time: f16) void {
    c_imgui.igPushStyleVar_Vec2(c_imgui.ImGuiStyleVar_WindowPadding, .{.x = 4, .y = 4});
    c_imgui.igSetNextWindowSize(.{.x = 200, .y = 0}, 0);
    const performance_menu = c_imgui.igBegin(
        "Performance Monitor", 
        &self.show_performance_monitor, 
        c_imgui.ImGuiWindowFlags_NoCollapse
    );
    if (performance_menu) {
        self.smoothed_surplus_ms = (self.surplus_ms_smoothing * self.smoothed_surplus_ms) + 
            ((1 - self.surplus_ms_smoothing) * surplus_time);
        c_imgui.igText("Idle Time (Per frame)");
        c_imgui.igText("%.2fms", self.smoothed_surplus_ms);
        const frame_duration_ms: f16 = 16.6667;
        c_imgui.igText("%.2f%%", 100.0 * (self.smoothed_surplus_ms / frame_duration_ms));
        c_imgui.igEnd();
    }
    c_imgui.igPopStyleVar(1);
}

pub fn showMainWindow(self: *Self, emulator: *Emulator) void {
    // Sizes the main screen window to fit it's content
    c_imgui.igSetNextWindowSize(.{.x = 0, .y = 0}, 0);
    const main_window = c_imgui.igBegin(
        "ZigNES", 
        &self.not_quit, 
        c_imgui.ImGuiWindowFlags_MenuBar     | 
        c_imgui.ImGuiWindowFlags_NoCollapse         |
        c_imgui.ImGuiWindowFlags_NoResize           |
        c_imgui.ImGuiWindowFlags_NoDocking
    );
    if (main_window) {
        self.showMainMenu(emulator);
        c_imgui.igImage(
            @ptrFromInt(self.screen_texture),  
            c_imgui.ImVec2{.x = 256 * self.screen_scale, .y = 240 * self.screen_scale}, 
            c_imgui.ImVec2{.x = 0, .y = 0}, 
            c_imgui.ImVec2{.x = 1, .y = 1},
            c_imgui.ImVec4{.x = 1, .y = 1, .z = 1, .w = 1},
            c_imgui.ImVec4{.x = 0, .y = 0, .z = 0, .w = 1} 
        );
        c_imgui.igEnd();
    }
}