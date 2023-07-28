const std = @import("std");
const Allocator = std.mem.Allocator;

const c_imgui = @cImport({
    @cDefine("CIMGUI_DEFINE_ENUMS_AND_STRUCTS", {});
    @cInclude("cimgui.h");
    @cDefine("CIMGUI_USE_SDL2", {});
    @cDefine("CIMGUI_USE_OPENGL3", {});
    @cInclude("cimgui_impl.h");
});

const PaletteViewer = @import("./ppu/debug/palette_viewer.zig");
const SpriteViewer = @import("./ppu/debug/sprite_viewer.zig");
const NametableViewer = @import("./ppu/debug/nametable_viewer.zig");

const Emulator = @import("emulator.zig");

const renderCallback = @import("./main.zig").renderCallback;
const emptyCallback = @import("./main.zig").emptyCallback;

const Self = @This();

const settings_path = "./settings.json";
const path_buffer_length = 2048;

allocator: Allocator,

max_recent_paths: u32 = 10,
// Screen
screen_texture: c_uint,
// Rom loader
rom_path: [path_buffer_length]u8 = undefined,
show_load_rom_modal: bool = false,
// Palette loader
palette_path: [path_buffer_length]u8 = undefined,
show_load_palette_modal: bool = false,
// Emu menu
not_quit: bool = true,
paused: bool = false,
resume_latch: bool = false,
// Palette viewer
palette_viewer_texture: c_uint,
// Sprite viewer
sprite_viewer_texture: c_uint,
// Nametable viewer
nametable_viewer_texture: c_uint,
// Performance menu
smoothed_surplus_ms: f16 = 0,

// Settings that are loaded and saved
saved_settings: struct {
    // Screen
    screen_scale: c_int = 1,
    // Rom loader
    recent_roms: [][]const u8 = &.{},
    // Palette loader
    recent_palettes: [][]const u8 = &.{},
    use_default_palette: bool = false,
    // Palette viewer
    show_palette_viewer: bool = false,
    palette_viewer_scale: c_int = 32,
    // Sprite viewer
    show_sprite_viewer: bool = false,
    sprite_viewer_scale: c_int = 4,
    // Nametable Viewer
    show_nametable_viewer: bool = false,
    nametable_viewer_scale: c_int = 1,
    // Performance menu
    show_performance_monitor: bool = false,
    surplus_ms_smoothing: f16 = 0.95, // Amount of old value to use
    // Audio
    volume: f32 = 50,
} = .{},

pub fn init(allocator: Allocator) Self {
    var gui: Self = .{
        .allocator = allocator,
        .screen_texture = undefined,
        .palette_viewer_texture = undefined,
        .sprite_viewer_texture = undefined,
        .nametable_viewer_texture = undefined
    };
    @memset(gui.rom_path[0..], 0);
    @memset(gui.palette_path[0..], 0);

    return gui;
}

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

        self.showFileMenu(emulator);
        self.showEmuMenu(emulator);
        self.showDebugMenu();
        self.showSettingsMenu(emulator);
        c_imgui.igEndMenuBar();
        c_imgui.igPopStyleVar(2);
    }
}

fn showFileMenu(self: *Self, emulator: *Emulator) void {
    if (c_imgui.igBeginMenu("File", true)) {
        self.show_load_rom_modal = c_imgui.igMenuItem_Bool("Load Rom", "", false, true);
        if (c_imgui.igBeginMenu("Recent...##rom", self.saved_settings.recent_roms.len != 0)) {
            for (self.saved_settings.recent_roms) |recent_rom| {
                const name_start = @max(
                    std.mem.lastIndexOf(u8, recent_rom, "\\") orelse 0,
                    std.mem.lastIndexOf(u8, recent_rom, "/") orelse 0
                ) + 1;
                if (c_imgui.igMenuItem_Bool(recent_rom[name_start..].ptr, "", false, true)) {
                    _ = emulator.loadRom(recent_rom);
                    movePathToFront(&self.saved_settings.recent_roms, recent_rom);
                    break;
                }
            }
            c_imgui.igEndMenu();
        }
        c_imgui.igSeparator();
        self.show_load_palette_modal = c_imgui.igMenuItem_Bool("Load Palette", "", false, true);
        if (c_imgui.igBeginMenu("Recent...##palette", self.saved_settings.recent_palettes.len != 0)) {
            for (self.saved_settings.recent_palettes) |recent_palette| {
                const name_start = @max(
                    std.mem.lastIndexOf(u8, recent_palette, "\\") orelse 0,
                    std.mem.lastIndexOf(u8, recent_palette, "/") orelse 0
                ) + 1;
                if (c_imgui.igMenuItem_Bool(recent_palette[name_start..].ptr, "", false, true)) {
                    emulator.loadPalette(recent_palette);
                    movePathToFront(&self.saved_settings.recent_palettes, recent_palette);
                    self.saved_settings.use_default_palette = false;
                    break;
                }
            }
            c_imgui.igEndMenu();
        }
        if (c_imgui.igMenuItem_Bool("Default", "", false, true)) {
            self.saved_settings.use_default_palette = true;
            emulator.ppu.palette.useDefaultPalette();
        }

        c_imgui.igEndMenu();
    }
}

fn showEmuMenu(self: *Self, emulator: *Emulator) void {
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
}

fn showDebugMenu(self: *Self) void {
    if (c_imgui.igBeginMenu("Debug", true)) {
        _ = c_imgui.igMenuItem_BoolPtr("Palette Viewer", "", &self.saved_settings.show_palette_viewer, true);
        _ = c_imgui.igMenuItem_BoolPtr("Sprite Viewer", "", &self.saved_settings.show_sprite_viewer, true);
        _ = c_imgui.igMenuItem_BoolPtr("Nametable Viewer", "", &self.saved_settings.show_nametable_viewer, true);
        _ = c_imgui.igMenuItem_BoolPtr("Performance Monitor", "", &self.saved_settings.show_performance_monitor, true);
        c_imgui.igEndMenu();
    }
}

fn showSettingsMenu(self: *Self, emulator: *Emulator) void {
    if (c_imgui.igBeginMenu("Settings", true)) {
        if (c_imgui.igBeginMenu("Volume", true)) {
            c_imgui.igPushStyleVar_Vec2(c_imgui.ImGuiStyleVar_FramePadding, .{.x = 0, .y = 100});
            c_imgui.igSetNextItemWidth(20);
            _ = c_imgui.igSliderFloat("##", &self.saved_settings.volume, 0, 100, "", 
                c_imgui.ImGuiSliderFlags_NoRoundToFormat |
                c_imgui.ImGuiSliderFlags_Vertical
            );
            emulator.setVolume(@floatCast(self.saved_settings.volume));
            c_imgui.igEndMenu();
            c_imgui.igPopStyleVar(1);
        }
        if (c_imgui.igBeginMenu("Screen Scale", true)) {
            c_imgui.igSetNextItemWidth(80);
            _ = c_imgui.igInputInt("##", &self.saved_settings.screen_scale, 1, 0, 0);
            c_imgui.igEndMenu();
        }
        c_imgui.igEndMenu();
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
            if (emulator.loadRom(&self.rom_path)) {
                self.appendToRecentPaths(&self.saved_settings.recent_roms, self.rom_path) catch {};
                self.show_load_rom_modal = false;
                c_imgui.igCloseCurrentPopup();
                @memset(self.rom_path[0..], 0);
            }
        }
        c_imgui.igEndPopup();
    }
}

pub fn showLoadPaletteModal(self: *Self, emulator: *Emulator) void {
    c_imgui.igOpenPopup_Str("Load Palette", 0);
    c_imgui.igSetNextWindowSize(.{.x = 600, .y = 0}, 0);
    const load_palette_modal = c_imgui.igBeginPopupModal(
        "Load Palette", 
        &self.show_load_palette_modal, 
        c_imgui.ImGuiWindowFlags_NoCollapse
        
    );
    if (load_palette_modal) {
        const input_text_submit = c_imgui.igInputText(
            "Palette Path", 
            &self.palette_path, 
            2048, 
            c_imgui.ImGuiInputTextFlags_EnterReturnsTrue, 
            null, 
            null
        ); 
        
        if (input_text_submit) {
            std.debug.print("{s}\n", .{&self.palette_path});
            emulator.loadPalette(&self.palette_path);
            self.saved_settings.use_default_palette = false;
            self.appendToRecentPaths(&self.saved_settings.recent_palettes, self.palette_path) catch {};
            self.show_load_palette_modal = false;
            c_imgui.igCloseCurrentPopup();
            @memset(self.palette_path[0..], 0);
        }
        c_imgui.igEndPopup();
    }
}

pub fn showPaletteViewer(self: *Self) void {
    c_imgui.igSetNextWindowSize(.{.x = 0, .y = 0}, 0);
    const palette_viewer = c_imgui.igBegin(
        "Palette Viewer", 
        &self.saved_settings.show_palette_viewer, 
        c_imgui.ImGuiWindowFlags_NoCollapse |
        c_imgui.ImGuiWindowFlags_NoResize           
    );
    if (palette_viewer) {
        c_imgui.igImage(
            @ptrFromInt(self.palette_viewer_texture),  
            c_imgui.ImVec2{
                .x = @floatFromInt(PaletteViewer.width * @as(usize, @intCast(self.saved_settings.palette_viewer_scale))), 
                .y = @floatFromInt(PaletteViewer.height * @as(usize, @intCast(self.saved_settings.palette_viewer_scale)))
            }, 
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
        &self.saved_settings.show_sprite_viewer, 
        c_imgui.ImGuiWindowFlags_NoCollapse |
        c_imgui.ImGuiWindowFlags_NoResize           
    );
    if (sprite_viewer) {
        c_imgui.igImage(
            @ptrFromInt(self.sprite_viewer_texture),  
            c_imgui.ImVec2{
                .x = @floatFromInt(SpriteViewer.width * @as(usize, @intCast(self.saved_settings.sprite_viewer_scale))), 
                .y = @floatFromInt(SpriteViewer.height * @as(usize, @intCast(self.saved_settings.sprite_viewer_scale)))
            }, 
            c_imgui.ImVec2{.x = 0, .y = 0}, 
            c_imgui.ImVec2{.x = 1, .y = 1},
            c_imgui.ImVec4{.x = 1, .y = 1, .z = 1, .w = 1},
            c_imgui.ImVec4{.x = 0, .y = 0, .z = 0, .w = 1} 
        );
        c_imgui.igEnd();
    }
}

pub fn showNametableViewer(self: *Self) void {
    c_imgui.igSetNextWindowSize(.{
        .x = 0, 
        .y = @floatFromInt(NametableViewer.width * @as(usize, @intCast(self.saved_settings.nametable_viewer_scale)) * 2)
    }, 0);
    const nametable_viewer = c_imgui.igBegin(
        "Nametable Viewer", 
        &self.saved_settings.show_nametable_viewer, 
        c_imgui.ImGuiWindowFlags_NoCollapse
    );
    if (nametable_viewer) {
        c_imgui.igImage(
            @ptrFromInt(self.nametable_viewer_texture),  
            c_imgui.ImVec2{
                .x = @floatFromInt(NametableViewer.width * @as(usize, @intCast(self.saved_settings.nametable_viewer_scale))), 
                .y = @floatFromInt(NametableViewer.height * @as(usize, @intCast(self.saved_settings.nametable_viewer_scale)))
            }, 
            c_imgui.ImVec2{.x = 0, .y = 0}, 
            c_imgui.ImVec2{.x = 1, .y = 1},
            c_imgui.ImVec4{.x = 1, .y = 1, .z = 1, .w = 1},
            c_imgui.ImVec4{.x = 0, .y = 0, .z = 0, .w = 1} 
        );
        c_imgui.igEnd();
    }
}

pub fn showPerformanceMonitor(self: *Self, surplus_time: f16) void {
    c_imgui.igPushStyleVar_Vec2(c_imgui.ImGuiStyleVar_WindowPadding, .{.x = 4, .y = 4});
    c_imgui.igSetNextWindowSize(.{.x = 200, .y = 0}, 0);
    const performance_menu = c_imgui.igBegin(
        "Performance Monitor", 
        &self.saved_settings.show_performance_monitor, 
        c_imgui.ImGuiWindowFlags_NoCollapse
    );
    if (performance_menu) {
        self.smoothed_surplus_ms = (self.saved_settings.surplus_ms_smoothing * self.smoothed_surplus_ms) + 
            ((1 - self.saved_settings.surplus_ms_smoothing) * surplus_time);
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
            c_imgui.ImVec2{
                .x = @floatFromInt(256 * self.saved_settings.screen_scale), 
                .y = @floatFromInt(240 * self.saved_settings.screen_scale)
            }, 
            c_imgui.ImVec2{.x = 0, .y = 0}, 
            c_imgui.ImVec2{.x = 1, .y = 1},
            c_imgui.ImVec4{.x = 1, .y = 1, .z = 1, .w = 1},
            c_imgui.ImVec4{.x = 0, .y = 0, .z = 0, .w = 1} 
        );
        c_imgui.igEnd();
    }
}

/// Appends paths to list of paths if the path is unique
/// If there are more than self.max_recent_paths paths in the list, move the list up, dropping the extra paths
/// If the path is not unique, it is moved to the front of the list
fn appendToRecentPaths(self: *Self, recent_paths_array: *[][]const u8, path_buffer: [path_buffer_length]u8) !void {
    // Allocate new string and copy
    // One is added to ensure that a null terminated is included in the string
    const rom_path_length = (std.mem.indexOf(u8, &path_buffer, &.{0}) orelse 0) + 1;
    var new_path_string = try self.allocator.alloc(u8, rom_path_length);
    @memcpy(new_path_string[0..], path_buffer[0..rom_path_length]);

    // Check that the path is not the same as any of the recent
    // If it's not unique, get the location of the preexisting value
    var is_unique: bool = true;
    var not_unique_loc: usize = undefined;
    for (recent_paths_array.*, 0..) |recent_path, i| {
        is_unique = is_unique and !std.mem.eql(u8, new_path_string, recent_path);
        if (!is_unique) {
            not_unique_loc = i;
            break;
        }
    }
    var new_recent_paths_list: [][]const u8 = undefined;

    // Don't append if this is the same as the most recent rom_path
    if (is_unique) {
        if (recent_paths_array.*.len < self.max_recent_paths) {
            // Allocate new array and copy old to new
            new_recent_paths_list = try self.allocator.alloc([]const u8, recent_paths_array.*.len + 1);
            @memcpy(new_recent_paths_list[1..], recent_paths_array.*[0..]);
        } else {
            // Get rid of the oldest paths if there are too many
            for (self.max_recent_paths - 1..recent_paths_array.*.len) |i| {
                self.allocator.free(recent_paths_array.*[i]);
            }
            new_recent_paths_list = try self.allocator.alloc([]const u8, self.max_recent_paths);
            @memcpy(new_recent_paths_list[1..self.max_recent_paths], recent_paths_array.*[0..self.max_recent_paths - 1]);
        }
    } else {
        // Free the old version of the path, as the new one will be placed in front
        self.allocator.free(recent_paths_array.*[not_unique_loc]);

        new_recent_paths_list = try self.allocator.alloc([]const u8, recent_paths_array.*.len);
        @memcpy(new_recent_paths_list[1..not_unique_loc + 1], recent_paths_array.*[0..not_unique_loc]);
        @memcpy(new_recent_paths_list[not_unique_loc + 1..], recent_paths_array.*[not_unique_loc + 1..]);
    }
    new_recent_paths_list[0] = new_path_string;

    // Deallocate old array and assign new
    self.allocator.free(recent_paths_array.*);
    recent_paths_array.* = new_recent_paths_list;
}

fn movePathToFront(recent_paths_array: *[][]const u8, path: []const u8) void {
    var i: usize = recent_paths_array.*.len - 1;
    while (recent_paths_array.*[i].ptr != path.ptr) {
        i -= 1;
    }
    while (i > 0) {
        recent_paths_array.*[i] = recent_paths_array.*[i - 1];
        i -= 1;
    }
    recent_paths_array.*[0] = path;
}

pub fn loadSettings(self: *Self, emulator: *Emulator) !void {
    const settings_file = try std.fs.cwd().readFileAlloc(self.allocator, settings_path, 1000000);
    defer self.allocator.free(settings_file);

    var settings_json = try std.json.parseFromSlice(@TypeOf(self.saved_settings), self.allocator, settings_file, .{});
    defer settings_json.deinit();

    self.saved_settings = settings_json.value;
    
    // The array of recent roms and recent palettes will be cleaned up by deinitializing settings_json
    // This needs to be copied over by allocating each
    var new_recent_roms_list = try self.allocator.alloc([]u8, self.saved_settings.recent_roms.len);
    for (self.saved_settings.recent_roms, 0..) |rom_path, i| {
        new_recent_roms_list[i] = try self.allocator.alloc(u8, rom_path.len);
        @memcpy(new_recent_roms_list[i][0..], rom_path[0..]);
    }
    self.saved_settings.recent_roms = new_recent_roms_list;

    var new_recent_palettes_list = try self.allocator.alloc([]u8, self.saved_settings.recent_palettes.len);
    for (self.saved_settings.recent_palettes, 0..) |palette_path, i| {
        new_recent_palettes_list[i] = try self.allocator.alloc(u8, palette_path.len);
        @memcpy(new_recent_palettes_list[i][0..], palette_path[0..]);
    }
    self.saved_settings.recent_palettes = new_recent_palettes_list;

    // Some of the settings need to be manually applied
    emulator.setVolume(@floatCast(self.saved_settings.volume));
    if (self.saved_settings.recent_palettes.len > 0 and !self.saved_settings.use_default_palette) {
        emulator.loadPalette(self.saved_settings.recent_palettes[0]);
    }
}

pub fn saveSettings(self: *Self) !void {
    var settings_file = try std.fs.cwd().createFile(settings_path, .{});
    try std.json.stringify(self.saved_settings, .{.whitespace = .{.indent = .tab}}, settings_file.writer());
}