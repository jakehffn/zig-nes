const Bus = @import("./bus.zig");
const BusCallback = Bus.BusCallback;

pub fn Ram(comptime N: usize) type {
    return struct {
        const Self = @This();

        ram: [N]u8 = undefined,

        pub fn init() Self {
            var ram: Self = .{};

            @memset(ram.ram[0..], 0);

            return ram;
        }

        fn read(self: *Self, bus: *Bus, address: u16) u8 {
            _ = bus;
            return self.ram[address];
        }

        fn write(self: *Self, bus: *Bus, address: u16, value: u8) void {
            _ = bus;
            self.ram[address] = value;
        }

        pub fn write_bytes(self: *Self, bytes: []u8, base_address: u16) void {
            for (bytes, 0..) |byte, i| {
                self.ram[base_address + @as(u16, @truncate(i))] = byte;
            }
        }

        pub fn busCallback(self: *Self) BusCallback {
            return BusCallback.init(self, read, write);
        }
    };
}