const std = @import("std");
const Allocator = std.mem.Allocator;

const MainBus = @import("./cpu/main_bus.zig");
const Cpu = @import("./cpu/cpu.zig");
const PpuBus = @import("./ppu/ppu_bus.zig");
const Ppu = @import("./ppu/ppu.zig");
const Apu = @import("./apu/apu.zig");

const RomLoader = @import("./rom/rom_loader.zig");

const Controllers = @import("./controllers.zig");
const ControllerStatus = Controllers.Status;

const sample_buffer_size = @import("./main.zig").sample_buffer_size;

const Self = @This();

cpu: Cpu = undefined,
main_bus: MainBus = undefined,
ppu: Ppu = undefined,
ppu_bus: PpuBus = undefined,
apu: Apu = undefined,

rom_loader: RomLoader = undefined,
controllers: Controllers = .{},

frame_ready: bool = false,

pub fn init(self: *Self, allocator: Allocator, render_callback: *const fn () void, audio_callback: *const fn () void) !void {
    self.ppu_bus = PpuBus.init();

    self.apu = Apu.init(audio_callback);
    self.cpu = try Cpu.init();
    self.ppu = try Ppu.init(&self.ppu_bus, render_callback);

    self.main_bus = MainBus.init(&self.ppu, &self.apu, &self.controllers);

    self.cpu.connectMainBus(&self.main_bus);
    self.ppu.connectMainBus(&self.main_bus);
    self.apu.connectMainBus(&self.main_bus);

    self.rom_loader = RomLoader.init(allocator);
}

pub fn deinit(self: *Self) void {
    self.ppu.deinit();
    self.cpu.deinit();
    self.rom_loader.deinit();
}

pub fn loadRom(self: *Self, rom_path: []const u8) void {
    self.rom_loader.unloadRom();
    self.rom_loader.loadRom(rom_path) catch {
        std.debug.print("ZigNES: Unable to load ROM file", .{});
        return;
    };

    self.main_bus.setRom(self.rom_loader.getRom());
    self.ppu_bus.setRom(self.rom_loader.getRom());

    // Reset vectors only available at this point
    self.reset();
}

/// Steps cpu, ppu, and apu until a frame is rendered
pub fn stepFrame(self: *Self) void {
    if (!self.rom_loader.rom_loaded) {
        return;
    }
    while (!self.frame_ready) {
        self.cpu.step();
        // In the future, it would be nice to implement a PPU stack
        // Explained in this: https://gist.github.com/adamveld12/d0398717145a2c8dedab
        self.ppu.step();
        self.ppu.step();
        self.ppu.step();

        self.apu.step();
    }
    self.frame_ready = false;
}

/// Steps cpu, ppu, and apu n cycles
pub fn stepN(self: *Self, n: usize) void {
    if (!self.rom_loader.rom_loaded) {
        return;
    }
    for (0..n) |_| {
        self.cpu.step();
        
        self.ppu.step();
        self.ppu.step();
        self.ppu.step();

        self.apu.step();
    }
}

pub fn endFrame(self: *Self) void {
    self.frame_end = true;
}

pub fn setControllerOneStatus(self: *Self, controller_status: ControllerStatus) void {
    self.controllers.status_one = controller_status;
}

pub fn getPaletteViewerPixels(self: *Self) *anyopaque {
    if (self.rom_loader.rom_loaded) {
        self.ppu.palette_viewer.update(&self.ppu);
    }
    return &self.ppu.palette_viewer.data;
}

pub fn getSpriteViewerPixels(self: *Self) *anyopaque {
    if (self.rom_loader.rom_loaded) {
        self.ppu.sprite_viewer.update(&self.ppu);
    }
    return &self.ppu.sprite_viewer.data;
}

pub fn getScreenPixels(self: *Self) *anyopaque {
    return &self.ppu.screen.data;
}

pub fn reset(self: *Self) void {
    self.cpu.reset();
    self.ppu.reset();
    self.apu.reset();
}

pub fn setVolume(self: *Self, volume: f16) void {
    const max_volume: f16 = 60000;
    self.apu.volume = volume/100.0 * max_volume;
}

pub fn getSampleBuffer(self: *Self) *anyopaque {
    return &self.apu.sample_buffer;
}