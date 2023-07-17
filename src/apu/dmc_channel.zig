const MainBus = @import("../cpu/main_bus.zig");
const Envelope = @import("./apu.zig").Envelope;
const LengthCounter = @import("./apu.zig").LengthCounter;
const apu_no_read = @import("./apu.zig").apu_no_read;

const Self = @This();

channel_enabled: bool = true,

timer: u12 = 0,
timer_reset: u12 = 0,
loop: bool = false,
output_level: u7 = 0,
silence: bool = false,

sample_address: u16 = 0,
sample_length: u12 = 0,
sample_buffer: u8 = 0,
bits_remaining: u4 = 0,
shift_register: u8 = 0,

address_counter: u16 = 0,
bytes_remaining: u12 = 0,

interrupt_enabled: bool = false,
dmc_interrupt: bool = false,

main_bus: *MainBus = undefined,

const rate_table = [16]u12{
    428, 380, 340, 320, 286, 254, 226, 214, 190, 160, 142, 128, 106,  84,  72,  54
};

pub fn step(self: *Self) void {
    if (!self.channel_enabled) {
        return;
    }

    if (self.timer == 0) {
        self.timer = self.timer_reset;

        if (!self.silence) {
            if (self.shift_register & 1 == 1) {
                if (self.output_level < 126) {
                    self.output_level += 2;
                }
            } else {
                if (self.output_level > 1) {
                    self.output_level -= 2;
                }
            }
        }

        self.shift_register >>= 1;
        
        self.bits_remaining -|= 1;
        if (self.bits_remaining == 0) {
            self.bits_remaining = 8;
            if (self.sample_buffer == 0) {
                self.silence = true;
            } else {
                self.silence = false;
                self.shift_register = self.sample_buffer;

                self.fillSampleBuffer();
            }
        }
    } else {
        self.timer -= 1;
    }
}

pub fn output(self: *Self) u8 {
    if (!self.channel_enabled) {
        return 0;
    }
    return self.output_level;
}

inline fn fillSampleBuffer(self: *Self) void {
    self.sample_buffer = self.main_bus.read(self.address_counter);
    if (self.address_counter == 0xFFFF) {
        self.address_counter = 0x8000;
    } else {
        self.address_counter += 1;
    }
    self.bytes_remaining -= 1;
    if (self.bytes_remaining == 0) {
        if (self.loop) {
            self.bytes_remaining = self.sample_length;
        } else {
            if (self.interrupt_enabled) {
                self.dmc_interrupt = true;
            }
        }
    }
}

pub inline fn flagsAndRateRegisterWrite(self: *Self, value: u8) void {
    const data: packed union {
        value: u8,
        bits: packed struct {
            rate_index: u4,
            _: u2,
            loop: bool,
            interrupt_enabled: bool
        }
    } = .{.value = value};

    self.timer_reset = rate_table[data.bits.rate_index];
    self.loop = data.bits.loop;
    self.interrupt_enabled = data.bits.interrupt_enabled;
    self.dmc_interrupt = data.bits.interrupt_enabled;
}

pub inline fn directLoadRegisterWrite(self: *Self, value: u8) void {
    const data: packed union {
        value: u8,
        bits: packed struct {
            output_level: u7,
            _: u1
        }
    } = .{.value = value};
    self.output_level = data.bits.output_level;
}

pub inline fn sampleAddressRegisterWrite(self: *Self, value: u8) void {
    self.sample_address = 0xC000 | (@as(u16, value) << 6);
}

pub inline fn sampleLengthRegisterWrite(self: *Self, value: u8) void {
    self.sample_length = (@as(u12, value) << 4) | 1;
}