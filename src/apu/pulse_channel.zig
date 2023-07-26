const Envelope = @import("./apu.zig").Envelope;
const LengthCounter = @import("./apu.zig").LengthCounter;
const apu_no_read = @import("./apu.zig").apu_no_read;

pub fn PulseChannel(comptime is_pulse_one: bool) type {
    return struct {
        const Self = @This();
        
        channel_enabled: bool = true,

        timer: u11 = 0,
        timer_reset: packed union {
            value: u11,
            bytes: packed struct {
                low: u8 = 0,
                high: u3 = 0
            }
        } = .{.value = 0},

        waveform_counter: u3 = 0,
        duty_cycle: u2 = 0, // Determines the cycle used from the duty table

        envelope: Envelope = .{},
        length_counter: LengthCounter = .{},
        sweep: struct {
            const Sweep = @This();

            shift: u3 = 0,
            negate: bool = false,
            divider: u3 = 0,
            divider_period: u3 = 0,
            enabled: bool = false,
            target_period: u11 = 0,
            reload: bool = false,

            pub fn step(self: *Sweep) void {
                var pulse_channel = @fieldParentPtr(Self, "sweep", self);
                const current_period = pulse_channel.timer_reset.value;
                self.divider -|= 1;

                if (self.divider == 0 and self.enabled and current_period >= 8 and self.target_period < 0x800) {
                    pulse_channel.timer_reset.value = self.target_period;
                }

                if (self.divider == 0 or self.reload) {
                    self.divider = self.divider_period;
                    self.reload = false;
                }
            }

            fn updateTargetPeriod(self: *Sweep, current_period: u11) void {
                var change_amount = current_period >> self.shift;
                if (!self.negate) {
                    self.target_period = current_period +| change_amount;
                } else {
                    if (is_pulse_one) {
                        self.target_period = current_period -| change_amount -| 1;
                    } else {
                        self.target_period = current_period -| change_amount;
                    }
                }
            }

            inline fn isMuted(self: *Sweep, current_period: u11) bool {
                return current_period < 8 or (!self.negate and self.target_period >= 0x800);
            }
        } = .{},

        const duty_table = [4][8]u8{
            [_]u8{0, 0, 0, 0, 0, 0, 0, 1},
            [_]u8{0, 0, 0, 0, 0, 0, 1, 1},
            [_]u8{0, 0, 0, 0, 1, 1, 1, 1},
            [_]u8{1, 1, 1, 1, 1, 1, 1, 0},
        };

        pub fn step(self: *Self) void {
            self.sweep.updateTargetPeriod(self.timer_reset.value);
            if (self.timer == 0) {
                self.timer = self.timer_reset.value;
                self.waveform_counter -%= 1;
            } else {
                self.timer -= 1;
            }
        }

        pub fn output(self: *Self) u8 {
            if (!self.channel_enabled or self.length_counter.counter == 0 or 
                self.sweep.isMuted(self.timer_reset.value)) {
                    return 0;
            }
            if (duty_table[self.duty_cycle][self.waveform_counter] == 1) {
                return self.envelope.output();
            } else {
                return 0;
            }
        }

        pub inline fn firstRegisterWrite(self: *Self, value: u8) void {
            const data: packed union {
                value: u8,
                bits: packed struct {
                    divider_reset_value: u4,
                    constant_volume: bool,
                    length_counter_halt: bool,
                    duty_cycle: u2
                }
            } = .{.value = value};

            self.duty_cycle = data.bits.duty_cycle;
            self.length_counter.halt = data.bits.length_counter_halt;
            self.envelope.loop = data.bits.length_counter_halt;
            self.envelope.constant_volume = data.bits.constant_volume;
            self.envelope.divider_reset_value = data.bits.divider_reset_value;
        }

        pub inline fn sweepRegisterWrite(self: *Self, value: u8) void {
            var data: packed union {
                value: u8,
                bits: packed struct {
                    shift: u3 = 0,
                    negate: bool = false,
                    divider_period: u3 = 0,
                    enabled: bool = false
                }
            } = .{.value = value};

            self.sweep.shift = data.bits.shift;
            self.sweep.negate = data.bits.negate;
            self.sweep.divider_period = data.bits.divider_period;
            self.sweep.enabled = data.bits.enabled;
            self.sweep.reload = true;
        }

        pub inline fn timerLowRegisterWrite(self: *Self, value: u8) void {
            self.timer_reset.bytes.low = value;
        }

        pub inline fn fourthRegisterWrite(self: *Self, value: u8) void {
            const data: packed union {
                value: u8,
                bits: packed struct {
                    H: u3,
                    l: u5
                }
            } = .{.value = value};
            self.timer_reset.bytes.high = data.bits.H;
            if (self.channel_enabled) {
                self.length_counter.load(data.bits.l);
            }
            self.envelope.start = true;
            self.waveform_counter = 0;
        }
    }; 
}