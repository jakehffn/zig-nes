const Bus = @import("./bus.zig").Bus;
const BusCallback = Bus.BusCallback;

pub const Controller = struct {
    const Self = @This();

    status: Status = .{},
    strobe_mode: bool = false,
    current_input: u3 = 0,
    
    pub const Status = packed struct {
        b: u1 = 0,
        a: u1 = 0,
        select: u1 = 0,
        start: u1 = 0,
        up: u1 = 0,
        down: u1 = 0,
        left: u1 = 0,
        right: u1 = 0,
    };

    fn read(self: *Self, bus: *Bus, address: u16) u8 {
        _ = address;
        _ = bus;
        if (self.current_input > 7) {
            return 1;
        }
        const is_pressed = (@as(u8, @bitCast(self.status)) & (@as(u8, 1) << self.current_input)) >> self.current_input;   
        if (!self.strobe_mode) {
            self.current_input += 1;
        }
        return is_pressed;
    }

    fn write(self: *Self, bus: *Bus, address: u16, value: u8) void {
        _ = address;
        _ = bus;
        self.strobe_mode = @bitCast(@as(u1, @truncate(value & 1)));
        if (self.strobe_mode) {
            self.current_input = 0;
        }
    }

    pub fn busCallback(self: *Self) BusCallback {
        return BusCallback.init(self, read, write);
    }
};