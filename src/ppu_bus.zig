const std = @import("std");
const Allocator = std.mem.Allocator;

const Bus = @import("./bus.zig").Bus;

const Ram = @import("./ram.zig").Ram;
const Rom = @import("./rom.zig").Rom;
const MemoryMirror = @import("./memory_mirror.zig").MemoryMirror;
const MirroringRam = @import("./mirroring_ram.zig").MirroringRam;

pub const PpuBus = struct {
    const Self = @This();

    bus: Bus,
    ram: MirroringRam,
    ppu_ram_mirrors: MemoryMirror(0x2000, 0x2F00) = .{},
    palette_ram_indices: Ram(0x20),
    palette_ram_indices_mirrors: MemoryMirror(0x3F00, 0x3F20) = .{},

    pub fn init(allocator: Allocator) !PpuBus {

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
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        self.bus.deinit(allocator);
    }

    pub fn loadRom(self: *Self, rom: *Rom) void {
        self.bus.setCallbacks(
            rom.chr_rom.busCallback(), 
            0x0000, 0x2000
        );
    }
};