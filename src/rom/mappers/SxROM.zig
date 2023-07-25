const std = @import("std");

const RomLoader = @import("../rom_loader.zig");
const Rom = RomLoader.Rom;
const MirroringType = RomLoader.MirroringType;

const Self = @This();

const prg_bank_size = 0x4000;
const chr_bank_size = 0x1000;

has_chr_ram: bool = false,
num_chr_banks: u16 = 0,

shift_register: u5 = 0,
shift_counter: u8 = 5,
control_register: packed union {
    value: u5,
    bits: packed struct {
        mirroring: u2,
        prg_rom_bank_mode: u2,
        chr_rom_two_bank_mode: bool
    }
} = .{.value = 0},
chr_bank_zero: u5 = 0,
chr_bank_one: u5 = 0,
prg_bank: u5 = 0,

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

    self.control_register.value |= 0xC;
    self.has_chr_ram = rom_loader.header.num_chr_rom_banks == 0;
    self.num_chr_banks = if (!self.has_chr_ram) rom_loader.header.num_chr_rom_banks * 2 else 2;
    self.control_register.bits.prg_rom_bank_mode = 3;
    @memset(self.prg_ram[0..], 0); 
    @memset(self.chr_ram[0..], 0); 
}

fn deinit(rom_loader: *RomLoader) void {
    rom_loader.allocator.destroy(getRomData(rom_loader));
}

fn read(rom_loader: *RomLoader, address: u16) u8 {
    const self = getRomData(rom_loader);
    switch (address) {
        0x4000...0x5FFF => return 0,
        0x6000...0x7FFF => {
            const prg_ram_start = 0x6000;
            const ram_address = address - prg_ram_start;
            return self.prg_ram[ram_address];
        },
        0x8000...0xBFFF => {
            const bank_addressing_start = 0x8000;
            const rom_address: u32 = address - bank_addressing_start;
            const banking_offset = switch (self.control_register.bits.prg_rom_bank_mode) {
                0, 1 => @as(u32, self.prg_bank & 0x1E) * prg_bank_size,
                2 => 0,
                3 => @as(u32, self.prg_bank) * prg_bank_size
            };
            return rom_loader.prg_rom.items[rom_address + banking_offset];
        },
        0xC000...0xFFFF => {
            const bank_addressing_start = 0xC000;
            const rom_address: u32 = address - bank_addressing_start;
            const banking_offset = switch (self.control_register.bits.prg_rom_bank_mode) {
                0, 1 => @as(u32, self.prg_bank | 1) * prg_bank_size,
                2 => @as(u32, self.prg_bank) * prg_bank_size,
                3 => @as(u32, rom_loader.header.num_prg_rom_banks -| 1) * prg_bank_size
            };
            return rom_loader.prg_rom.items[rom_address + banking_offset];
        },
        else => unreachable
    }
}

fn write(rom_loader: *RomLoader, address: u16, value: u8) void {
    const self = getRomData(rom_loader);
    if (value & 0x80 == 0x80) {
        self.shift_register = 0;
        self.shift_counter = 5;
        self.control_register.value |= 0xC;
        return;
    }
    self.shift_register >>= 1;
    self.shift_register |= @truncate((value & 1) << 4);
    self.shift_counter -= 1;

    if (self.shift_counter == 0) {
        switch (address) {
            0x4000...0x5FFF => {},
            0x6000...0x7FFF => {
                const prg_ram_start = 0x6000;
                const ram_address = address - prg_ram_start;
                self.prg_ram[ram_address] = value;
            },
            0x8000...0x9FFF => {
                self.control_register.value = self.shift_register;
            },
            0xA000...0xBFFF => {
                self.chr_bank_zero = self.shift_register & @as(u5, @truncate(self.num_chr_banks -| 1));
            },
            0xC000...0xDFFF => {
                self.chr_bank_one = self.shift_register & @as(u5, @truncate(self.num_chr_banks -| 1));
            },
            0xE000...0xFFFF => {
                self.prg_bank = self.shift_register & @as(u5, @truncate(rom_loader.header.num_prg_rom_banks -| 1));
                // TODO: Implement bit 4 logic
            },
            else => unreachable
        }
        self.shift_register = 0;
        self.shift_counter = 5;
    }
}

inline fn getInternalAddress(mirroring: u4, address: u16) u16 {
    const nametables_start = 0x2000;
    const mirrored_address = (address - nametables_start) % 0x1000;
    // 0: Single-screen, low bank
    // 1: Single-screen, high bank
    // 2: Vertical
    // 3: Horizontal
    return switch (mirroring) {
        0 => mirrored_address % 0x400,
        1 => (mirrored_address % 0x400) + 0x400,
        2 => mirrored_address % 0x800,
        3 => switch (mirrored_address) {
            0...0x3FF => mirrored_address,
            0x400...0xBFF => mirrored_address - 0x400,
            0xC00...0xFFF => mirrored_address - 0x800,
            else => 0
        },
        else => 0
    };
}

fn ppuRead(rom_loader: *RomLoader, address: u16) u8 {
    const self = getRomData(rom_loader);
    switch(address) {
        0...0x0FFF => {
            // Get total offset into chr memory
            var banking_offset: u32 = undefined;
            if (self.control_register.bits.chr_rom_two_bank_mode) {
                banking_offset = @as(u32, self.chr_bank_zero) * chr_bank_size;
            } else {
                banking_offset = @as(u32, self.chr_bank_zero & 0x1E) * chr_bank_size;
            }
            if (self.has_chr_ram) {
                return self.chr_ram[address + banking_offset];
            } else {
                return rom_loader.chr_rom.items[address + banking_offset];
            }
        },
        0x1000...0x1FFF => {
            const rom_offset = 0x1000;
            const rom_address: u32 = address - rom_offset;
            // Get total offset into chr memory
            var banking_offset: u32 = undefined;
            if (self.control_register.bits.chr_rom_two_bank_mode) {
                banking_offset = @as(u32, self.chr_bank_one) * chr_bank_size;
            } else {
                banking_offset = @as(u32, self.chr_bank_zero | 1) * chr_bank_size;
            }
            if (self.has_chr_ram) {
                return self.chr_ram[rom_address + banking_offset];
            } else {
                return rom_loader.chr_rom.items[rom_address + banking_offset];
            }
        },
        0x2000...0x3FFF => {
            const internal_address = getInternalAddress(self.control_register.bits.mirroring, address);
            return rom_loader.ppu_ram.items[internal_address];
        },
        else => unreachable
    }
}

fn ppuWrite(rom_loader: *RomLoader, address: u16, value: u8) void {
    const self = getRomData(rom_loader);
    switch(address) {
        0...0x0FFF => {
            // Get total offset into chr memory
            var banking_offset: u32 = undefined;
            if (self.control_register.bits.chr_rom_two_bank_mode) {
                banking_offset = @as(u32, self.chr_bank_zero) * chr_bank_size;
            } else {
                banking_offset = @as(u32, self.chr_bank_zero & 0x1E) * chr_bank_size;
            }
            if (self.has_chr_ram) {
                self.chr_ram[address + banking_offset] = value;
            } else {
                rom_loader.chr_rom.items[address + banking_offset] = value;
            }
        },
        0x1000...0x1FFF => {
            const rom_offset = 0x1000;
            const rom_address: u32 = address - rom_offset;
            // Get total offset into chr memory
            var banking_offset: u32 = undefined;
            if (self.control_register.bits.chr_rom_two_bank_mode) {
                banking_offset = @as(u32, self.chr_bank_one) * chr_bank_size;
            } else {
                banking_offset = @as(u32, self.chr_bank_zero | 1) * chr_bank_size;
            }
            if (self.has_chr_ram) {
                self.chr_ram[rom_address + banking_offset] = value;
            } else {
                rom_loader.chr_rom.items[rom_address + banking_offset] = value;
            }
        },
        0x2000...0x3FFF => {
            const internal_address = getInternalAddress(self.control_register.bits.mirroring, address);
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