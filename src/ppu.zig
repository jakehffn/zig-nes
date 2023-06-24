const std = @import("std");
const panic = std.debug.panic;

const Bus = @import("./bus.zig").Bus;
const BusCallback = Bus.BusCallback;

pub const PPU = struct {
    const Self = @This();

    bus: *Bus,

    controller_register: u8 = undefined,
    mask_register: u8 = undefined,
    status_register: u8 = undefined, 
    oam_address_register: u8 = undefined,
    oam_data_register: u8 = undefined,
    scroll_register: u8 = undefined,
    address_register: struct {
        address_low: u8 = 0,
        address_high: u8 = 0,

        pub fn busCallback(self: *@This()) BusCallback {
            return BusCallback.init(
                @fieldParentPtr(PPU, "address_register", self),
                BusCallback.disallowedRead(Self, "Cannot read from PPU address register"),
                Self.addressRegisterWrite
            );
        }
    } = .{},
    data_register: u8 = undefined,
    oam_dma_register: u8 = undefined,

    pub fn init(bus: *Bus) PPU {
        return .{
            .bus = bus
        };
    }

    pub fn addressRegisterWrite(self: *Self, bus: *Bus, address: u16, value: u8) void {
        _ = bus;
        _ = address;
        self.address_register.address_high = self.address_register.address_low;
        self.address_register.address_low = value;
    } 
};