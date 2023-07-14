const Bus = @import("../bus/bus.zig");
const BusCallback = Bus.BusCallback;

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
        sweep: packed union {
            value: u8,
            bits: packed struct {
                shift: u3 = 0,
                negate: bool = false,
                divider_period: u3 = 0,
                enable: bool = false
            }
        } = .{.value = 0},

        sweep_reload: bool = false,
        waveform_counter: u3 = 0,
        duty_cycle: u2 = 0, // Determines the cycle used from the duty table

        envelope: Envelope = .{},
        length_counter: LengthCounter = .{},

        const duty_table = [4][8]u8{
            [_]u8{0, 0, 0, 0, 0, 0, 0, 1},
            [_]u8{0, 0, 0, 0, 0, 0, 1, 1},
            [_]u8{0, 0, 0, 0, 1, 1, 1, 1},
            [_]u8{1, 1, 1, 1, 1, 1, 1, 0},
        };

        pub fn step(self: *Self) void {
            if (self.timer == 0) {
                self.timer = self.timer_reset.value;
                self.waveform_counter -%= 1;
            } else {
                self.timer -= 1;
            }
        }

        pub fn output(self: *Self) u8 {
            if (!self.channel_enabled or self.length_counter.counter == 0 or self.timer_reset.value < 8) {
                return 0;
            }
            if (duty_table[self.duty_cycle][self.waveform_counter] == 1) {
                return self.envelope.output();
            } else {
                return 0;
            }
        }

        fn firstRegsiterWrite(self: *Self, bus: *Bus, address: u16, value: u8) void {
            _ = bus;
            _ = address;
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

        fn sweepRegisterWrite(self: *Self, bus: *Bus, address: u16, value: u8) void {
            _ = bus;
            _ = address;
            self.sweep.value = value;
        }

        fn timerLowRegisterWrite(self: *Self, bus: *Bus, address: u16, value: u8) void {
            _ = bus;
            _ = address;
            self.timer_reset.bytes.low = value;
        }

        fn fourthRegisterWrite(self: *Self, bus: *Bus, address: u16, value: u8) void {
            _ = bus;
            _ = address;
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

        pub fn busCallbacks(self: *Self) [4]BusCallback {
            const channel_name = if (is_pulse_one) "Pulse 1 " else "Pulse 2 ";
            return [_]BusCallback{
                BusCallback.init(
                    self, 
                    apu_no_read(Self, channel_name ++ "First"), 
                    Self.firstRegsiterWrite
                ), // $4000/4004
                BusCallback.init(
                    self, 
                    apu_no_read(Self, channel_name ++ "Sweep"), 
                    Self.sweepRegisterWrite
                ), // $4001/4005
                BusCallback.init(
                    self, 
                    apu_no_read(Self, channel_name ++ "Timer Low"), 
                    Self.timerLowRegisterWrite
                ), // $4002/4006
                BusCallback.init(
                    self, 
                    apu_no_read(Self, channel_name ++ "Fourth"), 
                    Self.fourthRegisterWrite
                ), // $4003/4007
            };
        }
    }; 
}