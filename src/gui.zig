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

const Self = @This();

not_quit: bool = true,
paused: bool = false,
resume_latch: bool = false,

screen_texture: c_uint,
screen_scale: f32 = 2,

rom_path: [2048]u8 = undefined,

show_load_rom_modal: bool = false,

show_palette_viewer: bool = false,
palette_viewer_texture: c_uint,
palette_viewer_scale: f32 = 32,

show_sprite_viewer: bool = false,
sprite_viewer_texture: c_uint,
sprite_viewer_scale: f32 = 4,

show_tile_viewer: bool = false,
tile_viewer_texture: c_uint,
tile_viewer_scale: f32 = 1,

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
}

fn showMainMenu(self: *Self, emulator: *Emulator) void {
    if (c_imgui.igBeginMenuBar()) {
        c_imgui.igPushStyleVar_Vec2(c_imgui.ImGuiStyleVar_WindowPadding, .{.x = 8, .y = 8});
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
            c_imgui.igEndMenu();
        }
        if (c_imgui.igBeginMenu("Debug", true)) {
            _ = c_imgui.igMenuItem_BoolPtr("Palette Viewer", "", &self.show_palette_viewer, true);
            _ = c_imgui.igMenuItem_BoolPtr("Sprite Viewer", "", &self.show_sprite_viewer, true);
            _ = c_imgui.igMenuItem_BoolPtr("Tile Viewer", "", &self.show_tile_viewer, false); // TODO: Finish this
            c_imgui.igEndMenu();
        }
        c_imgui.igEndMenuBar();
        c_imgui.igPopStyleVar(1);
    }
}

pub fn showLoadRomModal(self: *Self, emulator: *Emulator, allocator: Allocator) void {
    c_imgui.igOpenPopup_Str("Load ROM", 0);
    // Sizes the main screen window to fit it's content
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
            emulator.loadRom(&self.rom_path, allocator);
            self.show_load_rom_modal = false;
            c_imgui.igCloseCurrentPopup();
        }
        
        c_imgui.igEndPopup();
    }
}

pub fn showPaletteViewer(self: *Self) void {
    // Fit to content
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
    // Fit to content
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
    // Sizes the main screen window to fit it's content
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