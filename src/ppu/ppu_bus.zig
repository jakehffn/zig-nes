const std = @import("std");
const Allocator = std.mem.Allocator;

const Rom = @import("../rom/rom_loader.zig").Rom;

const Self = @This();

rom: Rom,
palette_ram_indices: [0x20]u8,

pub fn init() Self {
    var ppu_bus: Self = .{
        .rom = undefined,
        .palette_ram_indices = undefined,
    };
    @memset(ppu_bus.palette_ram_indices[0..], 0);
    return ppu_bus;
}

pub fn read(self: *Self, address: u16) u8 {
    return switch(address % 0x4000) {
        0...0x3EFF => self.rom.ppuRead(address),
        0x3F00...0x3FFF => self.palette_ram_indices[getPaletteAddress(address)],
        else => blk: {
            std.debug.print("Unmapped ppu bus read: {X}\n", .{address});
            break :blk 0;
        }
    };
}

pub fn write(self: *Self, address: u16, value: u8) void {
    switch(address % 0x4000) {
        0...0x3EFF => { 
            self.rom.ppuWrite(address, value); 
        },
        0x3F00...0x3FFF => { 
            self.palette_ram_indices[getPaletteAddress(address)] = value; 
        },
        else => {
            std.debug.print("Unmapped ppu bus read: {X}\n", .{address});
        }
    }
}

inline fn getPaletteAddress(address: u16) u16 {
    const index = address % 0x20;
    return switch(index) {
        0x10, 0x14, 0x18, 0x1C => index - 0x10,
        else => index
    };
}

pub fn setRom(self: *Self, rom: Rom) void {
    self.rom = rom;
}