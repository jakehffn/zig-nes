const std = @import("std");
const Allocator = std.mem.Allocator;

const Bus = @import("../bus/bus.zig");

const Ppu = @import("../ppu/ppu.zig").Ppu;
const Apu = @import("../apu/apu.zig");
const Ram = @import("../bus/ram.zig").Ram;
const Rom = @import("../rom/rom.zig");
const MemoryMirror = @import("../bus/memory_mirror.zig").MemoryMirror;
const Controller = @import("../bus/controller.zig");

const Self = @This();

bus: Bus,
cpu_ram: Ram(0x800),
cpu_ram_mirrors: MemoryMirror(0x0000, 0x0800) = .{},
ppu_registers_mirrors: MemoryMirror(0x2000, 0x2008) = .{},
rom_mirror: MemoryMirror(0x8000, 0xC000) = .{},
controller: Controller = .{},

nmi: bool = false,
irq: bool = false,

pub fn init(allocator: Allocator) !Self {

    return .{
        .bus = try Bus.init(allocator, 0x10000, null),
        .cpu_ram = Ram(0x800).init()
    };
}

pub fn setCallbacks(self: *Self, ppu: anytype, apu: *Apu) void {

    self.bus.setCallbacks(
        self.cpu_ram.busCallback(), 
        0x0000, 0x0800
    );
    self.bus.setCallbacks(
        self.cpu_ram_mirrors.busCallback(), 
        0x0800, 0x2000
    );
    
    // PPU registers
    self.bus.setCallback(ppu.controller_register.busCallback(), 0x2000);
    self.bus.setCallback(ppu.mask_register.busCallback(), 0x2001);
    self.bus.setCallback(ppu.status_register.busCallback(), 0x2002);
    self.bus.setCallback(ppu.oam_address_register.busCallback(), 0x2003);
    self.bus.setCallback(ppu.oam_data_register.busCallback(), 0x2004);
    self.bus.setCallback(ppu.scroll_register.busCallback(), 0x2005);
    self.bus.setCallback(ppu.address_register.busCallback(), 0x2006);
    self.bus.setCallback(ppu.data_register.busCallback(), 0x2007);
    self.bus.setCallback(ppu.oam_dma_register.busCallback(), 0x4014);
    self.bus.setCallback(self.controller.busCallback(), 0x4016);
    
    self.bus.setCallbacks(
        self.ppu_registers_mirrors.busCallback(), 
        0x2008, 0x4000
    );

    for (apu.pulse_channel_one.busCallbacks(), 0x4000..) |bc, i| {
        self.bus.setCallback(bc, @truncate(i));
    }
    for (apu.pulse_channel_two.busCallbacks(), 0x4004..) |bc, i| {
        self.bus.setCallback(bc, @truncate(i));
    }
    self.bus.setCallback(apu.status.busCallback(), 0x4015);
    self.bus.setCallback(apu.frame_counter.busCallback(), 0x4017);
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.bus.deinit(allocator);
}

pub fn loadRom(self: *Self, rom: *Rom) void {
    if (rom.prg_rom.array.items.len >= 0x8000) {
        self.bus.setCallbacks(
            rom.prg_rom.busCallback(), 
            0x8000, 0x10000
        );
    } else {
        self.bus.setCallbacks(
            rom.prg_rom.busCallback(),
            0x8000, 0xC000
        );
        self.bus.setCallbacks(
            self.rom_mirror.busCallback(),
            0xC000, 0x10000
        );
    }
}