const Self = @This();

status_one: Status = .{},
status_two: Status = .{},
current_input_one: u16 = 1,
current_input_two: u16 = 1,
strobe_mode: bool = false,

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

pub fn readControllerOne(self: *Self) u8 {
    return self.readController(self.status_one, &self.current_input_one);
}

pub fn readControllerTwo(self: *Self) u8 {
    return self.readController(self.status_two, &self.current_input_two);
}

inline fn readController(self: *Self, status: Status, current_input: *u16) u8 {
    if (current_input.* > (1 << 7)) {
        return 1;
    }
    const is_pressed = @intFromBool((@as(u8, @bitCast(status)) & current_input.*) > 0);
    if (!self.strobe_mode) {
        current_input.* <<= 1;
    }
    return is_pressed;
}

pub fn strobe(self: *Self, value: u8) void {
    self.strobe_mode = @bitCast(@as(u1, @truncate(value & 1)));
    if (self.strobe_mode) {
        self.current_input_one = 1;
        self.current_input_two = 1;
    }
}