const Envelope = @import("./apu.zig").Envelope;
const LengthCounter = @import("./apu.zig").LengthCounter;
const apu_no_read = @import("./apu.zig").apu_no_read;

const Self = @This();

channel_enabled: bool = true,

timer: u12 = 0,
timer_reset: u12 = 0,
mode: bool = false,

envelope: Envelope = .{},
length_counter: LengthCounter = .{},

lfsr: packed union {
    value: u15,
    bits: packed struct {
        zero: u1,
        one: u1,
        unused_one: u4,
        six: u1,
        unused_two: u7,
        fourteen: u1
    }
} = .{.value = 1},

const timer_period_table = [16]u12{
    4, 8, 16, 32, 64, 96, 128, 160, 202, 254, 380, 508, 762, 1016, 2034, 4068
};

pub fn step(self: *Self) void {
    if (self.timer == 0) {
        self.timer = self.timer_reset;
        const feedback = self.lfsr.bits.zero ^ if (self.mode) self.lfsr.bits.six else self.lfsr.bits.one;
        self.lfsr.value >>= 1;
        self.lfsr.bits.fourteen = feedback;
    } else {
        self.timer -= 1;
    }
}

pub fn output(self: *Self) u8 {
    if (!self.channel_enabled or self.length_counter.counter == 0 or self.lfsr.bits.zero == 1) {
        return 0;
    }
    return self.envelope.output();
}

pub inline fn firstRegisterWrite(self: *Self, value: u8) void {
    const data: packed union {
        value: u8,
        bits: packed struct {
            divider_reset_value: u4,
            constant_volume: bool,
            length_counter_halt: bool,
            _: u2
        }
    } = .{.value = value};

    self.length_counter.halt = data.bits.length_counter_halt;
    self.envelope.loop = data.bits.length_counter_halt;
    self.envelope.divider_reset_value = data.bits.divider_reset_value;
    self.envelope.constant_volume = data.bits.constant_volume;
}

pub inline fn secondRegisterWrite(self: *Self, value: u8) void {
    const data: packed union {
        value: u8,
        bits: packed struct {
            timer_reset_index: u4,
            _: u3,
            mode: bool
        }
    } = .{.value = value};
    self.timer_reset = timer_period_table[data.bits.timer_reset_index];
    self.mode = data.bits.mode;
}

pub inline fn thirdRegisterWrite(self: *Self, value: u8) void {
    const data: packed union {
        value: u8,
        bits: packed struct {
            _: u3,
            length_counter_reload: u5
        }
    } = .{.value = value};
    self.length_counter.load(data.bits.length_counter_reload);
    self.envelope.start = true;
}