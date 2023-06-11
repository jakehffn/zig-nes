const BusCallback = @import("./bus.zig").Bus.BusCallback;

pub const TestMemory = struct {
    const Self = @This();

    example_mem: [1 << 16 - 1]u8 = [_]u8{0} ** (1 << 16 - 1),

    fn exampleMemRead(self: *Self, address: u16) u8 {
        return self.example_mem[address];
    }

    fn exampleMemWrite(self: *Self, address: u16, data: u8) void {
        self.example_mem[address] = data;
    }

    pub fn busCallback(self: *Self) BusCallback {
        return BusCallback.init(self, exampleMemRead, exampleMemWrite);
    }
};