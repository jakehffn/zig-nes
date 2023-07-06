const std = @import("std");
const panic = std.debug.panic;

const Bus = @import("../bus/bus.zig").Bus;
const BusCallback = Bus.BusCallback;
const MirroringType = @import("./rom.zig").MirroringType;

pub const MirroringRam = struct {
    const Self = @This();

    ram: [0x800]u8,
    mirroring_type: MirroringType,

    pub fn init() Self {
        var mirroring_ram: MirroringRam = .{
            .ram = undefined,
            .mirroring_type = undefined
        };

        @memset(mirroring_ram.ram[0..mirroring_ram.ram.len], 0);

        return mirroring_ram;
    }

    fn getInternalAddress(self: *Self, address: u16) u16 {
        return switch (self.mirroring_type) {
            .horizontal, .four_screen => 
                switch (address) {
                    0...0x3FF => address,
                    0x400...0xBFF => address - 0x400,
                    0xC00...0xFFF => address - 0x800,
                    else => 0
                },
            .vertical => address % 0x800
        };
    }

    fn read(self: *Self, bus: *Bus, address: u16) u8 {
        _ = bus;
        return self.ram[self.getInternalAddress(address)];
    }

    fn write(self: *Self, bus: *Bus, address: u16, value: u8) void {
        _ = bus;
        self.ram[self.getInternalAddress(address)] = value;
    }

    pub fn busCallback(self: *Self) BusCallback {
        return BusCallback.init(
            self,
            read,
            write
        );
    }
};