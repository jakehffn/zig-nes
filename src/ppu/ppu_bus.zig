const std = @import("std");
const Allocator = std.mem.Allocator;

const Bus = @import("../bus/bus.zig");

const Ram = @import("../bus/ram.zig").Ram;
const Rom = @import("../rom/rom.zig");
const MemoryMirror = @import("../bus/memory_mirror.zig").MemoryMirror;
const MirroringRam = @import("../rom/mirroring_ram.zig");

const Self = @This();

bus: Bus,
ram: MirroringRam,
ppu_ram_mirrors: MemoryMirror(0x2000, 0x3000) = .{},
palette_ram_indices: Ram(0x20),
background_palette_first_byte_mirrors: MemoryMirror(0x3F00, 0x3F10) = .{},
palette_ram_indices_mirrors: MemoryMirror(0x3F00, 0x3F20) = .{},

pub fn init(allocator: Allocator) !Self {

    return .{
        .bus = try Bus.init(allocator, 0x4000, null),
        .ram = MirroringRam.init(),
        .palette_ram_indices = Ram(0x20).init()
    };
}

pub fn setCallbacks(self: *Self) void {
    self.bus.setCallbacks(
        self.ram.busCallback(), 
        0x2000, 0x3000
    );
    self.bus.setCallbacks(
        self.ppu_ram_mirrors.busCallback(), 
        0x3000, 0x3F00
    );
    self.bus.setCallbacks(
        self.palette_ram_indices.busCallback(), 
        0x3F00, 0x3F20
    );

    self.bus.setCallbacks(
        self.palette_ram_indices_mirrors.busCallback(), 
        0x3F20, 0x4000
    );

    self.bus.setCallbacksArray(
        self.background_palette_first_byte_mirrors.busCallback(), 
        &[_]u16{0x3F10, 0x3F14, 0x3F18, 0x3F1C}
    );
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.bus.deinit(allocator);
}

pub fn loadRom(self: *Self, rom: *Rom) void {
    self.ram.mirroring_type = rom.header.mirroring_type;
    self.bus.setCallbacks(
        rom.chr_rom.busCallback(), 
        0x0000, 0x2000
    );
}