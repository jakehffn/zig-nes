const std = @import("std");

const RomLoader = @import("./rom_loader.zig");
const Rom = RomLoader.Rom;
const MirroringType = RomLoader.MirroringType;

const Self = @This();

prg_rom_mirroring: u16 = 0,

inline fn getRomData(rom_loader: *RomLoader) *Self {
    return @as(*Self, @ptrCast(@alignCast(rom_loader.rom_data)));
}

fn init(rom_loader: *RomLoader) !void {
    try rom_loader.ppu_ram.ensureTotalCapacityPrecise(0x800);
    rom_loader.ppu_ram.expandToCapacity();
    rom_loader.rom_data = try rom_loader.allocator.create(Self);
    if (rom_loader.header.num_prg_rom_banks == 1) {
        getRomData(rom_loader).prg_rom_mirroring = 0x4000;
    } else {
        getRomData(rom_loader).prg_rom_mirroring = 0;
    }
}

fn deinit(rom_loader: *RomLoader) void {
    rom_loader.ppu_ram.shrinkAndFree(0);
    rom_loader.allocator.destroy(@as(*Self, @ptrCast(@alignCast(rom_loader.rom_data))));
}

fn read(rom_loader: *RomLoader, address: u16) u8 {
    const prg_rom_start = 0x8000;
    switch (address) {
        0x4000...0x7FFF => return 0,
        0x8000...0xBFFF => {
            const rom_address = address - prg_rom_start;
            return rom_loader.prg_rom.items[rom_address];
        },
        0xC000...0xFFFF => {
            const rom_address = address - prg_rom_start - getRomData(rom_loader).prg_rom_mirroring;
            return rom_loader.prg_rom.items[rom_address];
        },
        else => unreachable
    }
}

fn write(rom_loader: *RomLoader, address: u16, value: u8) void {
    _ = rom_loader;
    _ = address;
    _ = value;
    std.debug.print("Cannot write to NROM PRG_ROM\n", .{});
}

inline fn getInternalAddress(mirroring_type: MirroringType, address: u16) u16 {
    const nametables_start = 0x2000;
    const mirrored_address = (address - nametables_start) % 0x1000;

    return switch (mirroring_type) {
        .horizontal, .four_screen => 
            switch (mirrored_address) {
                0...0x3FF => mirrored_address,
                0x400...0xBFF => mirrored_address - 0x400,
                0xC00...0xFFF => mirrored_address - 0x800,
                else => 0
            },
        .vertical => mirrored_address % 0x800
    };
}

fn ppuRead(rom_loader: *RomLoader, address: u16) u8 {
    switch(address) {
        0...0x1FFF => return rom_loader.chr_rom.items[address],
        0x2000...0x3FFF => {
            const internal_address = getInternalAddress(rom_loader.header.mirroring_type, address);
            return rom_loader.ppu_ram.items[internal_address];
        },
        else => unreachable
    }
}

fn ppuWrite(rom_loader: *RomLoader, address: u16, value: u8) void {
    switch(address) {
        0...0x1FFF => std.debug.print("Cannot write to CHR_ROM\n", .{}),
        0x2000...0x3FFF => {
            const internal_address = getInternalAddress(rom_loader.header.mirroring_type, address);
            rom_loader.ppu_ram.items[internal_address] = value;
        },
        else => unreachable
    }
}

pub fn rom() Rom {
    return .{
        .rom_loader = undefined,
        .init_fn = init,
        .deinit_fn = deinit,
        .read_fn = read,
        .write_fn = write,
        .ppu_read_fn = ppuRead,
        .ppu_write_fn = ppuWrite
    };
}