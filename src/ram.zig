const Bus = @import("./bus.zig").Bus;
const BusCallback = Bus.BusCallback;

pub fn Ram(comptime N: usize) type {
    return struct {
        const Self = @This();

        ram: [N]u8 = [_]u8{0} ** N,

        fn read_byte(self: *Self, bus: *Bus, address: u16) u8 {
            _ = bus;
            return self.ram[address];
        }

        fn write_byte(self: *Self, bus: *Bus, address: u16, value: u8) void {
            _ = bus;
            self.ram[address] = value;
        }

        pub fn write_bytes(self: *Self, bytes: []u8, base_address: u16) void {
            for (bytes, 0..) |byte, i| {
                self.ram[base_address + @truncate(u16, i)] = byte;
            }
        }

        pub fn busCallback(self: *Self) BusCallback {
            return BusCallback.init(self, read_byte, write_byte);
        }
    };
}