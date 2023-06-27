const std = @import("std");
const Allocator = std.mem.Allocator;

const Bus = @import("./bus.zig").Bus;

const Ppu = @import("./ppu.zig").Ppu;
const Ram = @import("./ram.zig").Ram;
const Rom = @import("./rom.zig").Rom;
const MemoryMirror = @import("./memory_mirror.zig").MemoryMirror;

pub const MainBus = struct {
    const Self = @This();

    bus: Bus,
    cpu_ram: Ram(0x800),
    cpu_ram_mirrors: MemoryMirror(0x0000, 0x0800) = .{},
    ppu_registers_mirrors: MemoryMirror(0x2000, 0x2008) = .{},
    rom_mirror: MemoryMirror(0x8000, 0xC000) = .{},

    nmi: bool = false,

    pub fn init(allocator: Allocator) !MainBus {

        return .{
            .bus = try Bus.init(allocator, 0x10000, null),
            .cpu_ram = Ram(0x800).init()
        };
    }

    pub fn setCallbacks(self: *Self, ppu: *Ppu) void {

        self.bus.setCallbacks(
            self.cpu_ram.busCallback(), 
            0x0000, 0x0800
        );
        self.bus.setCallbacks(
            self.cpu_ram_mirrors.busCallback(), 
            0x0800, 0x2000
        );
        
        self.bus.setCallback(ppu.controller_register.busCallback(), 0x2000);
        self.bus.setCallback(ppu.mask_register.busCallback(), 0x2001);
        self.bus.setCallback(ppu.status_register.busCallback(), 0x2002);
        self.bus.setCallback(ppu.oam_address_register.busCallback(), 0x2003);
        self.bus.setCallback(ppu.oam_data_register.busCallback(), 0x2004);
        self.bus.setCallback(ppu.scroll_register.busCallback(), 0x2005);
        self.bus.setCallback(ppu.address_register.busCallback(), 0x2006);
        self.bus.setCallback(ppu.data_register.busCallback(), 0x2007);
        self.bus.setCallback(ppu.oam_dma_register.busCallback(), 0x4014);
        
        self.bus.setCallbacks(
            self.ppu_registers_mirrors.busCallback(), 
            0x2008, 0x4000
        );
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
};