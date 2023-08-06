const std = @import("std");

const RomLoader = @import("../rom_loader.zig");
const Rom = RomLoader.Rom;
const MirroringType = RomLoader.MirroringType;

const Self = @This();

const prg_bank_size = 0x2000;
const chr_bank_size = 0x400;

num_prg_banks: u32 = 0,
num_chr_banks: u32 = 0,

bank_update_register: u3 = 0,
prg_bank_mode: u1 = 0,
chr_bank_mode: u1 = 0,
mirroring: u1 = 0,
irq_counter_reload: u8 = 0,
irq_counter: u8 = 0,
irq_enabled: bool = false,

bank_registers: [8]u32 = .{0} ** 8,

prg_ram: [0x8000]u8 = undefined,
chr_ram: [0x2000]u8 = undefined,

inline fn getRomData(rom_loader: *RomLoader) *Self {
    return @as(*Self, @ptrCast(@alignCast(rom_loader.rom_data)));
}

fn init(rom_loader: *RomLoader) !void {
    try rom_loader.ppu_ram.ensureTotalCapacityPrecise(0x1000);
    rom_loader.ppu_ram.expandToCapacity();
    rom_loader.rom_data = try rom_loader.allocator.create(Self);
    const self = getRomData(rom_loader);
    self.* = .{};

    self.num_prg_banks = rom_loader.header.num_prg_rom_banks * 2;
    self.num_chr_banks = rom_loader.header.num_chr_rom_banks * 8;

    @memset(self.prg_ram[0..], 0); 
    @memset(self.chr_ram[0..], 0); 
}

fn deinit(rom_loader: *RomLoader) void {
    rom_loader.allocator.destroy(getRomData(rom_loader));
}

fn getPrgAddress(rom_loader: *RomLoader, address: u16) u32 {
    const self = getRomData(rom_loader);
    if (self.prg_bank_mode == 0) {
        switch(address) {
            0x8000...0x9FFF => {
                const bank_addressing_start = 0x8000;
                return self.bank_registers[6] * prg_bank_size + @as(u32, address) - bank_addressing_start;
            },
            0xA000...0xBFFF => {
                const bank_addressing_start = 0xA000;
                return self.bank_registers[7] * prg_bank_size + @as(u32, address) - bank_addressing_start;
            },
            0xC000...0xDFFF => {
                const bank_addressing_start = 0xC000;
                return (self.num_prg_banks - 2) * prg_bank_size + @as(u32, address) - bank_addressing_start;
            },
            0xE000...0xFFFF => {
                const bank_addressing_start = 0xE000;
                return (self.num_prg_banks - 1) * prg_bank_size + @as(u32, address) - bank_addressing_start;
            },
            else => { unreachable; }
        }
    } else {
        switch(address) {
            0x8000...0x9FFF => {
                const bank_addressing_start = 0x8000;
                return (self.num_prg_banks - 2) * prg_bank_size + @as(u32, address) - bank_addressing_start;
            },
            0xA000...0xBFFF => {
                const bank_addressing_start = 0xA000;
                return self.bank_registers[7] * prg_bank_size + @as(u32, address) - bank_addressing_start;
            },
            0xC000...0xDFFF => {
                const bank_addressing_start = 0xC000;
                return self.bank_registers[6] * prg_bank_size + @as(u32, address) - bank_addressing_start;
            },
            0xE000...0xFFFF => {
                const bank_addressing_start = 0xE000;
                return (self.num_prg_banks - 1) * prg_bank_size + @as(u32, address) - bank_addressing_start;
            },
            else => { unreachable; }
        }
    }
}

fn read(rom_loader: *RomLoader, address: u16) u8 {
    const self = getRomData(rom_loader);
    switch (address) {
        0x4000...0x5FFF => {
            return 0;
        },
        0x6000...0x7FFF => {
            const prg_ram_start = 0x6000;
            const ram_address = address - prg_ram_start;
            return self.prg_ram[ram_address];
        },
        0x8000...0xFFFF => {
            return rom_loader.prg_rom.items[getPrgAddress(rom_loader, address)];
        },
        else => { unreachable; }
    } 
}

fn write(rom_loader: *RomLoader, address: u16, value: u8) void {
    const self = getRomData(rom_loader);
    switch (address) {
        0x4000...0x5FFF => {},
        0x6000...0x7FFF => {
            const prg_ram_start = 0x6000;
            const ram_address = address - prg_ram_start;
            self.prg_ram[ram_address] = value;
        },
        0x8000...0x9FFF => {
            if (address & 1 == 0) {
                const data: packed union {
                    value: u8,
                    bits: packed struct {
                        bank_update_register: u3,
                        _: u3,
                        prg_bank_mode: u1,
                        chr_bank_mode: u1
                    }
                } = .{.value = value};
                self.bank_update_register = data.bits.bank_update_register;
                self.prg_bank_mode = data.bits.prg_bank_mode;
                self.chr_bank_mode = data.bits.chr_bank_mode;
            } else {
                self.bank_registers[self.bank_update_register] = value;
            }
        },
        0xA000...0xBFFF => {
            if (address & 1 == 0) {
                self.mirroring = @truncate(value & 1);
            } else {
                // Unimplemented for compatibility with MMC6
            }
        },
        0xC000...0xDFFF => {
            if (address & 1 == 0) {
                self.irq_counter_reload = value;
            } else {
                // "Writing any value to this register clears the MMC3 IRQ counter immediately, 
                // and then reloads it at the NEXT rising edge of the PPU address, 
                // presumably at PPU cycle 260 of the current scanline."
                self.irq_counter = 0;
            }
        },
        0xE000...0xFFFF => {
            if (address & 1 == 0) {
                self.irq_enabled = false;
            } else {
                self.irq_enabled = true;
            }
        },
        else => unreachable
    }
}

fn getChrAddress(rom_loader: *RomLoader, address: u16) u32 {
    const self = getRomData(rom_loader);
    if (self.chr_bank_mode == 0) {
        switch(address) {
            0...0x7FF => {
                return (self.bank_registers[0] & 0xFE) * chr_bank_size + @as(u32, address);
            },
            0x800...0xFFF => {
                const bank_addressing_start = 0x800;
                return (self.bank_registers[1] & 0xFE) * chr_bank_size + @as(u32, address) - bank_addressing_start;
            },
            0x1000...0x13FF => {
                const bank_addressing_start = 0x1000;
                return self.bank_registers[2] * chr_bank_size + @as(u32, address) - bank_addressing_start;
            },
            0x1400...0x17FF => {
                const bank_addressing_start = 0x1400;
                return self.bank_registers[3] * chr_bank_size + @as(u32, address) - bank_addressing_start;
            },
            0x1800...0x1BFF => {
                const bank_addressing_start = 0x1800;
                return self.bank_registers[4] * chr_bank_size + @as(u32, address) - bank_addressing_start;
            },
            0x1C00...0x1FFF => {
                const bank_addressing_start = 0x1C00;
                return self.bank_registers[5] * chr_bank_size + @as(u32, address) - bank_addressing_start;
            },
            else => { unreachable; }
        }
    } else {
        switch(address) {
            0...0x3FF => {
                return self.bank_registers[2] * chr_bank_size + @as(u32, address);
            },
            0x400...0x7FF => {
                const bank_addressing_start = 0x400;
                return self.bank_registers[3] * chr_bank_size + @as(u32, address) - bank_addressing_start;
            },
            0x800...0xBFF => {
                const bank_addressing_start = 0x800;
                return self.bank_registers[4] * chr_bank_size + @as(u32, address) - bank_addressing_start;
            },
            0xC00...0xFFF => {
                const bank_addressing_start = 0xC00;
                return self.bank_registers[5] * chr_bank_size + @as(u32, address) - bank_addressing_start;
            },
            0x1000...0x17FF => {
                const bank_addressing_start = 0x1000;
                return (self.bank_registers[0] & 0xFE) * chr_bank_size + @as(u32, address) - bank_addressing_start;
            },
            0x1800...0x1FFF => {
                const bank_addressing_start = 0x1800;
                return (self.bank_registers[1] & 0xFE) * chr_bank_size + @as(u32, address) - bank_addressing_start;
            },
            else => { unreachable; }
        }
    }
}

inline fn getInternalAddress(mirroring_type: u1, address: u16) u16 {
    const nametables_start = 0x2000;
    const mirrored_address = (address - nametables_start) % 0x1000;

    return switch (mirroring_type) {
        1 =>
            switch (mirrored_address) {
                0...0x3FF => mirrored_address,
                0x400...0xBFF => mirrored_address - 0x400,
                0xC00...0xFFF => mirrored_address - 0x800,
                else => unreachable
            },
        0 => mirrored_address % 0x800
    };
}

fn ppuRead(rom_loader: *RomLoader, address: u16) u8 {
    const self = getRomData(rom_loader);
    switch(address) {
        0...0x1FFF => {
            return rom_loader.chr_rom.items[getChrAddress(rom_loader, address)];
        },
        0x2000...0x3FFF => {
            const internal_address = getInternalAddress(self.mirroring, address);
            return rom_loader.ppu_ram.items[internal_address];
        },
        else => unreachable
    }
}

fn ppuWrite(rom_loader: *RomLoader, address: u16, value: u8) void {
    const self = getRomData(rom_loader);
    switch(address) {
        0...0x1FFF => {
            rom_loader.chr_rom.items[getChrAddress(rom_loader, address)] = value;
        },
        0x2000...0x3FFF => {
            const internal_address = getInternalAddress(self.mirroring, address);
            rom_loader.ppu_ram.items[internal_address] = value;
        },
        else => unreachable
    }
}

fn mapperIrq(rom_loader: *RomLoader) void {
    const self = getRomData(rom_loader);
    if (self.irq_counter == 0) {
        self.irq_counter = self.irq_counter_reload;
    } else {
        self.irq_counter -= 1;
    }

    if (self.irq_counter == 0 and self.irq_enabled) {
        rom_loader.irq.* = true;
    }
}

pub fn rom() Rom {
    return .{
        .init_fn = init,
        .deinit_fn = deinit,
        .read_fn = read,
        .write_fn = write,
        .ppu_read_fn = ppuRead,
        .ppu_write_fn = ppuWrite,
        .mapper_irq_fn = mapperIrq
    };
}