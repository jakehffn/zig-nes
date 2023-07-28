const std = @import("std");
const Allocator = std.mem.Allocator;

const Ppu = @import("../ppu/ppu.zig");
const Apu = @import("../apu/apu.zig");
const Rom = @import("../rom/rom_loader.zig").Rom;
const Controllers = @import("../controllers.zig");

const Self = @This();

cpu_ram: [0x800]u8,
ppu: *Ppu,
apu: *Apu,
controllers: *Controllers,
rom: Rom,

nmi: bool = false,
irq: bool = false,

pub fn init(ppu: *Ppu, apu: *Apu, controllers: *Controllers) Self {
    var main_bus: Self = .{
        .cpu_ram = undefined,
        .ppu = ppu,
        .apu = apu,
        .controllers = controllers,
        .rom = undefined
    };
    @memset(main_bus.cpu_ram[0..], 0);
    return main_bus;
}

pub fn reset(self: *Self) void {
    self.irq = false;
    self.nmi = false;
}

pub fn read(self: *Self, address: u16) u8 {
    return switch (address) {
        0...0x1FFF => self.cpu_ram[address % 0x800],
        0x2000...0x3FFF => switch (address % 8) {
            2 => self.ppu.status_register.read(),
            4 => self.ppu.oam_data_register.read(),
            7 => self.ppu.data_register.read(),
            else => blk: {
                std.debug.print("Unmapped main bus read: {X}\n", .{address});
                break :blk 0;
            }
        },
        0x4015 => self.apu.status.read(),
        0x4016 => self.controllers.readControllerOne(),
        0x4017 => self.controllers.readControllerTwo(),
        0x4020...0xFFFF => self.rom.read(address),
        else => blk: {
            std.debug.print("Unmapped main bus read: {X}\n", .{address});
            break :blk 0;
        }
    };
}

pub fn write(self: *Self, address: u16, value: u8) void {
    switch (address) {
        0...0x1FFF => {
            self.cpu_ram[address % 0x800] = value;
        },
        0x2000...0x3FFF => {
            switch (address % 8) {
                0 => self.ppu.controller_register.write(value),
                1 => self.ppu.mask_register.write(value),
                3 => self.ppu.oam_address_register.write(value),
                4 => self.ppu.oam_data_register.write(value),
                5 => self.ppu.scroll_register.write(value),
                6 => self.ppu.address_register.write(value),
                7 => self.ppu.data_register.write(value),
                else => {
                    std.debug.print("Unmapped main bus write: {X}\n", .{address});
                }
            }
        },
        0x4000 => self.apu.pulse_channel_one.firstRegisterWrite(value),
        0x4001 => self.apu.pulse_channel_one.sweepRegisterWrite(value),
        0x4002 => self.apu.pulse_channel_one.timerLowRegisterWrite(value),
        0x4003 => self.apu.pulse_channel_one.fourthRegisterWrite(value),

        0x4004 => self.apu.pulse_channel_two.firstRegisterWrite(value),
        0x4005 => self.apu.pulse_channel_two.sweepRegisterWrite(value),
        0x4006 => self.apu.pulse_channel_two.timerLowRegisterWrite(value),
        0x4007 => self.apu.pulse_channel_two.fourthRegisterWrite(value),

        0x4008 => self.apu.triangle_channel.linearCounterWrite(value),
        0x400A => self.apu.triangle_channel.timerLowRegisterWrite(value),
        0x400B => self.apu.triangle_channel.fourthRegisterWrite(value),

        0x400C => self.apu.noise_channel.firstRegisterWrite(value),
        0x400E => self.apu.noise_channel.secondRegisterWrite(value),
        0x400F => self.apu.noise_channel.thirdRegisterWrite(value),

        0x4010 => self.apu.dmc_channel.flagsAndRateRegisterWrite(value),
        0x4011 => self.apu.dmc_channel.directLoadRegisterWrite(value),
        0x4012 => self.apu.dmc_channel.sampleAddressRegisterWrite(value),
        0x4013 => self.apu.dmc_channel.sampleLengthRegisterWrite(value),

        0x4014 => self.ppu.oam_dma_register.write(value),
        0x4015 => self.apu.status.write(value),
        0x4016 => self.controllers.strobe(value),
        0x4017 => self.apu.frame_counter.write(value),
        0x4020...0xFFFF => self.rom.write(address, value),
        else => {
            std.debug.print("Unmapped main bus write: {X}\n", .{address});
        }
    }
}

pub fn setRom(self: *Self, rom: Rom) void {
    self.rom = rom;
}