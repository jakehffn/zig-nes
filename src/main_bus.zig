const std = @import("std");
const Allocator = std.mem.Allocator;

const Bus = @import("./bus.zig").Bus;

const Ram = @import("./ram.zig").Ram;
const Rom = @import("./rom.zig").Rom;
const MemoryMirror = @import("./memory_mirror.zig").MemoryMirror;

pub const MainBus = struct {
    const Self = @This();

    bus: Bus,
    cpu_ram: Ram(0x800),
    cpu_ram_mirrors: MemoryMirror(0x0000, 0x0800) = .{},
    ppu_registers_mirrors: MemoryMirror(0x2000, 0x2008) = .{},

    pub fn init(allocator: Allocator) !MainBus {

        var main_bus = MainBus {
            .bus = try Bus.init(allocator, 0x10000, null),
            .cpu_ram = Ram(0x800).init()
        };

        main_bus.bus.setCallbacks(
            main_bus.cpu_ram.busCallback(), 
            0x0000, 0x0800
        );
        main_bus.bus.setCallbacks(
            main_bus.cpu_ram_mirrors.busCallback(), 
            0x0800, 0x2000
        );
        main_bus.bus.setCallbacks(
            main_bus.ppu_registers_mirrors.busCallback(), 
            0x2008, 0x4000
        );

        return main_bus;
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