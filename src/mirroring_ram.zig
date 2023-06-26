const std = @import("std");
const panic = std.debug.panic;

const Bus = @import("./bus.zig").Bus;
const BusCallback = Bus.BusCallback;
const MirroringType = @import("./rom.zig").MirroringType;

pub const MirroringRam = struct {
    const Self = @This();

    ram: [0x1000]u8,
    mirroring_type: MirroringType,

    pub fn init() MirroringRam {
        var mirroring_ram: MirroringRam = .{
            .ram = undefined,
            .mirroring_type = undefined
        };

        @memset(mirroring_ram.ram[0..mirroring_ram.ram.len], 0);

        return mirroring_ram;
    }

    inline fn getInternalAddress(self: *MirroringRam, address: u16) u16 {
        return switch (self.mirroring_type) {
            .horizontal => {
                switch (address) {
                    0...0x400 => address,
                    0x400...0x800, 0x800...0xC00 => address - 0x400,
                    0xC00...0x1000 => address - 0x800
                }
            },
            .vertical => address % 0x800,
            else => {
                panic("Mirroring type {} not supported", .{self.mirroring_type});
            }
        };
    }

    fn read(ppu: *Self, bus: *Bus, address: u16) u8 {
        _ = bus;
        return ppu.ram.ram[ppu.ram.getInternalAddress(address)];
    }

    fn write(ppu: *Self, bus: *Bus, address: u16, value: u8) void {
        _ = bus;
        ppu.ram.ram[ppu.ram.getInternalAddress(address)] = value;
    }

    pub fn busCallback(self: *MirroringRam) BusCallback {
        return BusCallback.init(
            self,
            MirroringRam.read,
            MirroringRam.write
        );
    }
};