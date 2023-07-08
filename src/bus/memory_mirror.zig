const Bus = @import("./bus.zig");
const BusCallback = Bus.BusCallback;

pub fn MemoryMirror(comptime mirror_start: u16, comptime mirror_end: u16) type {
    return struct {
        const Self = @This();

        const size: u16 = mirror_end - mirror_start;
        const start: u16 = mirror_start;
        
        fn read(self: *Self, bus: *Bus, address: u16) u8 {
            _ = self;
            return bus.readByte(start + (address % size));
        }

        fn write(self: *Self, bus: *Bus, address: u16, value: u8) void {
            _ = self;
            bus.writeByte(start + (address % size), value);
        }

        pub fn busCallback(self: *Self) BusCallback {
            return BusCallback.init(self, read, write);
        }
    };
}