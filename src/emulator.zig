const std = @import("std");
const Allocator = std.mem.Allocator;

const MainBus = @import("./cpu/main_bus.zig");
const Cpu = @import("./cpu/cpu.zig").Cpu;

const PpuBus = @import("./ppu/ppu_bus.zig");
const Ppu = @import("./ppu/ppu.zig").Ppu;

const Apu = @import("./apu/apu.zig");

const Ram = @import("./bus/ram.zig").Ram;
const MemoryMirror = @import("./bus/memory_mirror.zig").MemoryMirror;
const Rom = @import("./rom/rom.zig");

const ControllerStatus = @import("./bus/controller.zig").Status;

const sample_buffer_size = @import("./main.zig").sample_buffer_size;

const Self = @This();

const CpuType = Cpu("./log/ZigNES.log");
const PpuType = Ppu("./log/ZigNES_PPU.log");

cpu: CpuType = undefined,
main_bus: MainBus = undefined,

ppu: PpuType = undefined,
ppu_bus: PpuBus = undefined,

apu: Apu = undefined,

rom: ?Rom = null,

frame_end: bool = false,

pub fn init(self: *Self, allocator: Allocator, render_callback: *const fn () void, audio_callback: *const fn () void) !void {
    self.ppu_bus = try PpuBus.init(allocator);
    self.ppu_bus.setCallbacks();

    self.apu = Apu.init(audio_callback);
    self.cpu = try CpuType.init();
    self.ppu = try PpuType.init(&self.ppu_bus, render_callback);

    self.main_bus = try MainBus.init(allocator);
    self.main_bus.setCallbacks(&self.ppu, &self.apu);

    self.cpu.connectMainBus(&self.main_bus);
    self.ppu.connectMainBus(&self.main_bus);
    self.apu.connectMainBus(&self.main_bus);
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.ppu_bus.deinit(allocator);
    self.ppu.deinit();
    self.main_bus.deinit(allocator);
    self.cpu.deinit();
    self.apu.deinit();

    if (self.rom) |*rom| {
        rom.deinit();
    }
}

pub fn loadRom(self: *Self, rom_path: []const u8, allocator: Allocator) void {

    if (self.rom) |*old_rom| {
        old_rom.deinit();
    }
   
    self.rom = Rom.init(allocator);
    self.rom.?.load(rom_path) catch {
        self.rom.?.deinit();
        self.rom = null;
        std.debug.print("ZigNES: Unable to load ROM file", .{});
        return;
    };

    self.main_bus.loadRom(&self.rom.?);
    self.ppu_bus.loadRom(&self.rom.?);

    // Reset vectors only available at this point
    self.reset();
}

/// Steps cpu, ppu, and apu until a frame is rendered
pub fn stepFrame(self: *Self) void {
    if (self.rom == null) {
        return;
    }
    while (!self.frame_end) {
        self.cpu.step();
        // In the future, it would be nice to implement a PPU stack
        // Explained in this: https://gist.github.com/adamveld12/d0398717145a2c8dedab
        self.ppu.step();
        self.ppu.step();
        self.ppu.step();

        self.apu.step();
    }
    self.frame_end = false;
}

/// Steps cpu, ppu, and apu enough to fill the audio buffer again
pub fn stepAudioBuffer(self: *Self) void {
    if (self.rom == null) {
        return;
    }
    for (0..sample_buffer_size) |_| {
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

pub fn setControllerStatus(self: *Self, controller_status: ControllerStatus) void {
    self.main_bus.controller.status = controller_status;
}

pub fn getPaletteViewerPixels(self: *Self) *anyopaque {
    if (self.rom != null) {
        self.ppu.palette_viewer.update(&self.ppu);
    }
    return &self.ppu.palette_viewer.data;
}

pub fn getSpriteViewerPixels(self: *Self) *anyopaque {
    if (self.rom != null) {
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