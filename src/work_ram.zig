const BusCallback = @import("./bus.zig").Bus.BusCallback;

pub fn WorkRam(comptime N: usize) type {
    return struct {
        const Self = @This();

        ram: [N]u8 = [_]u8{0} ** N,

        fn read_byte(self: *Self, address: u16) u8 {
            return self.ram[address];
        }

        fn write_byte(self: *Self, address: u16, value: u8) void {
            self.ram[address] = value;
        }

        pub fn write_bytes(self: *Self, bytes: []u8, base_address: u16) void {
            for (bytes, 0..) |byte, i| {
                self.write_byte(base_address + @truncate(u16, i), byte);
            }
        }

        pub fn busCallback(self: *Self) BusCallback {
            return BusCallback.init(self, read_byte, write_byte);
        }
    };
}