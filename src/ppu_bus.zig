const std = @import("std");
const Allocator = std.mem.Allocator;

const Bus = @import("./bus.zig").Bus;

const Ram = @import("./ram.zig").Ram;
const Rom = @import("./rom.zig").Rom;
const MemoryMirror = @import("./memory_mirror.zig").MemoryMirror;

pub const PPUBus = struct {
    const Self = @This();

    bus: Bus,
    name_table_mirrors: MemoryMirror(0x2000, 0x2F00) = .{},
    palette_ram_index_mirrors: MemoryMirror(0x3F00, 0x3F20) = .{},

    pub fn init(allocator: Allocator) !PPUBus {

        var ppu_bus = PPUBus {
            .bus = try Bus.init(allocator, 0x4000, null)
        };

        ppu_bus.bus.setCallbacks(
            ppu_bus.name_table_mirrors.busCallback(), 
            0x3000, 0x3F20
        );
        ppu_bus.bus.setCallbacks(
            ppu_bus.palette_ram_index_mirrors.busCallback(), 
            0x3F20, 0x4000
        );

        return ppu_bus;
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        self.bus.deinit(allocator);
    }

    pub fn loadRom(self: *Self, rom: *Rom) void {
        self.bus.setCallbacks(
            rom.prg_rom.busCallback(), 
            0x8000, 0x10000
        );
    }
};