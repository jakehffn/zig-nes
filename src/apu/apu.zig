const std = @import("std");

const c_sdl = @cImport({
    @cInclude("SDL.h");
    @cInclude("SDL_opengl.h");
});

const Bus = @import("../bus/bus.zig");
const BusCallback = Bus.BusCallback;
const MainBus = @import("../cpu/main_bus.zig");

const Self = @This();

const cycles_per_sample: f16 = 1789772.72 / 44100.0;
const sample_buffer_size = 1024;

spec_requested: c_sdl.SDL_AudioSpec = .{
    .freq = 44100, 
    .format = c_sdl.AUDIO_U8,
    .channels = 1,
    .silence = undefined,
    .samples = sample_buffer_size,
    .size = undefined,
    .callback = null,
    .userdata = undefined,
    .padding = undefined
},
spec_obtained: c_sdl.SDL_AudioSpec = undefined,
audio_device: c_sdl.SDL_AudioDeviceID = undefined,
sample_timer: u16 = 0,
sample_buffer: [sample_buffer_size]u8 = undefined,
sample_buffer_index: u16 = 0,

odd_frame: bool = true,
irq: *bool = undefined,

pulse_channel_one: PulseChannel(true) = .{},
pulse_channel_two: PulseChannel(false) = .{},
triangle_channel: TriangleChannel = .{},
noise_channel: NoiseChannel = .{},
dmc_channel: DmcChannel = .{},

status: struct {
    const Status = @This();
    // Writing to status enables and disables channels
    // Reading from status reports on various conditions of the actual channels, not the flags
    fn read(self: *Status, bus: *Bus, address: u16) u8 {
        _ = bus;
        _ = address;
        var apu = @fieldParentPtr(Self, "status", self);

        var return_flags: packed union {
            value: u8,
            bits: packed struct {
                pulse_one: bool,
                pulse_two: bool,
                triangle: bool,
                noise: bool,
                dmc_enabled: bool,
                _: u1,
                F: bool, // Only used on read
                I: bool, // Only used on read
            }
        } = .{.value = 0};
        return_flags.bits.pulse_one = !apu.pulse_channel_one.length_counter.halt;
        return_flags.bits.pulse_two = !apu.pulse_channel_two.length_counter.halt;
        return_flags.bits.triangle = !apu.triangle_channel.length_counter.halt;
        return_flags.bits.noise = !apu.noise_channel.length_counter.halt;
        return_flags.bits.F = apu.frame_counter.frame_interrupt;
        return_flags.bits.I = apu.dmc_channel.dmc_interrupt;

        apu.frame_counter.frame_interrupt = false;
        apu.updateIrq();

        return return_flags.value;
    }

    fn write(self: *Status, bus: *Bus, address: u16, value: u8) void {
        _ = bus;
        _ = address;
        var apu = @fieldParentPtr(Self, "status", self);

        var flags: packed union {
            value: u8,
            bits: packed struct {
                pulse_one: bool,
                pulse_two: bool,
                triangle: bool,
                noise: bool,
                dmc_enabled: bool,
                _: u3
            }
        } = .{.value = value};

        apu.pulse_channel_one.channel_enabled = flags.bits.pulse_one;
        if (!flags.bits.pulse_one) {
            apu.pulse_channel_one.length_counter.counter = 0;
        }

        apu.pulse_channel_two.channel_enabled = flags.bits.pulse_two;
        if (!flags.bits.pulse_two) {
            apu.pulse_channel_two.length_counter.counter = 0;
        }

        apu.triangle_channel.channel_enabled = flags.bits.triangle;
        if (!flags.bits.triangle) {
            apu.triangle_channel.length_counter.counter = 0;
        }

        apu.noise_channel.channel_enabled = flags.bits.noise;
        if (!flags.bits.noise) {
            apu.noise_channel.length_counter.counter = 0;
        }

        apu.dmc_channel.channel_enabled = flags.bits.dmc_enabled;
        if (!flags.bits.dmc_enabled) {
            apu.dmc_channel.bytes_remaining = 0;
        } else {
            if (apu.dmc_channel.bytes_remaining != 0) {
                flags.bits.dmc_enabled = false;
            }
        }
        apu.dmc_channel.dmc_interrupt = false;
    }

    pub fn busCallback(self: *Status) BusCallback {
        return BusCallback.init(self, read, write);
    }
} = .{},

frame_counter: struct {
    const FrameCounter = @This();

    counter: u16 = 0,
    mode: bool = false,
    interrupt_inhibited: bool = true,
    frame_interrupt: bool = false,

    inline fn step(self: *FrameCounter) void {
        var apu = @fieldParentPtr(Self, "frame_counter", self);
        self.counter += 1;
        
        if (self.counter == 7457) {
            apu.stepEnvelopes();
            apu.triangle_channel.linear_counter.step();
        } else if (self.counter == 14913) {
            apu.stepEnvelopes();
            apu.triangle_channel.linear_counter.step();
            // Clock sweep units
            apu.stepLengthCounters();
        } else if (self.counter == 22371) {
            apu.stepEnvelopes();
            apu.triangle_channel.linear_counter.step();
        }

        if (!self.mode) {
            if (self.counter == 29828) {
                if (!self.interrupt_inhibited) {
                    self.frame_interrupt = true;
                    apu.updateIrq();
                }
            } else if (self.counter == 29829) {
                apu.stepEnvelopes();
                apu.triangle_channel.linear_counter.step();
                // Clock sweep units
                apu.stepLengthCounters();
                if (!self.interrupt_inhibited) {
                    self.frame_interrupt = true;
                    apu.updateIrq();
                }
            } else if (self.counter == 29830) {
                // This is also frame 0, so the frame counter is set immediately to 1
                self.counter = 1;
                if (!self.interrupt_inhibited) {
                    self.frame_interrupt = true;
                    apu.updateIrq();
                }
            }
        } else {
            if (self.counter == 37281) {
                apu.stepEnvelopes();
                apu.triangle_channel.linear_counter.step();
                // sweep units
                apu.stepLengthCounters();
            } else if (self.counter == 37282) {
                self.counter = 1;
            }
        }
    }

    fn write(self: *FrameCounter, bus: *Bus, address: u16, value: u8) void {
        _ = bus;
        _ = address;
        const data: packed union {
            value: u8,
            bits: packed struct {
                _: u6,
                I: bool,
                M: bool
            }
        } = .{.value = value};
        self.interrupt_inhibited = data.bits.I;
        self.mode = data.bits.M;
        const apu = @fieldParentPtr(Self, "frame_counter", self);
        if (self.interrupt_inhibited) {
            self.frame_interrupt = false;
            apu.updateIrq();
        }
    }

    fn read(self: *FrameCounter, bus: *Bus, address: u16) u8 {
        _ = bus;
        _ = address;
        var data: packed union {
            value: u8,
            bits: packed struct {
                _: u6,
                I: bool,
                M: bool
            }
        } = .{.value = 0};
        data.bits.I = self.frame_interrupt;
        data.bits.M = self.mode;
        return data.value;
    }

    pub fn busCallback(self: *FrameCounter) BusCallback {
        return BusCallback.init(self, FrameCounter.read, FrameCounter.write);
    }
} = .{},

fn apu_no_read(comptime Outer: type, comptime name: []const u8) fn (ptr: *Outer, bus: *Bus, address: u16) u8 {
    return BusCallback.noRead(Outer, "Cannot read from APU: " ++ name, false);
}

const Envelope = struct {
    start: bool = false,
    loop: bool = false, // Is the same as the length counter halt
    constant_volume: bool = false,

    divider: u4 = 0, 
    divider_reset_value: u4 = 0,
    decay_level: u4 = 0,

    pub fn step(self: *Envelope) void {
        if (!self.start) {
            if (self.divider != 0) {
                self.divider -= 1;
            } else {
                self.divider = self.divider_reset_value;
                if (self.decay_level != 0) {
                    self.decay_level -= 1;
                } else {
                    if (self.loop) {
                        self.decay_level = 15;
                    }
                }
            }
        } else {
            self.start = false;
            self.decay_level = 15;
            self.divider = self.divider_reset_value;
        }
    }

    pub fn output(self: *Envelope) u8 {
        if (self.constant_volume) {
            return self.divider_reset_value;
        } else {
            return self.decay_level;
        }
    }
};

const LengthCounter = struct {
    halt: bool = true,
    counter: u8 = 0,

    const load_lengths = [_]u8 {
        10, 254, 20, 2, 40, 4, 80, 6, 160, 8, 60, 10, 14, 12, 26, 14,
        12, 16, 24, 18, 48, 20, 96, 22, 192, 24, 72, 26, 16, 28, 32, 30
    };

    pub fn step(self: *LengthCounter) void {
        if (!self.halt and self.counter > 0) {
            self.counter -= 1;
        }
    }

    pub fn load(self: *LengthCounter, index: u5) void {
        self.counter = load_lengths[index];
    }
};

fn PulseChannel(comptime is_pulse_one: bool) type {
    return struct {
        const PulseChannelType = @This();
        
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

        pub fn step(self: *PulseChannelType) void {
            if (self.timer == 0) {
                self.timer = self.timer_reset.value;
                self.waveform_counter -%= 1;
            } else {
                self.timer -= 1;
            }
        }

        pub fn output(self: *PulseChannelType) u8 {
            if (!self.channel_enabled or self.length_counter.counter == 0 or self.timer_reset.value < 8) {
                return 0;
            }
            if (duty_table[self.duty_cycle][self.waveform_counter] == 1) {
                return self.envelope.output();
            } else {
                return 0;
            }
        }

        fn firstRegsiterWrite(self: *PulseChannelType, bus: *Bus, address: u16, value: u8) void {
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

        fn sweepRegisterWrite(self: *PulseChannelType, bus: *Bus, address: u16, value: u8) void {
            _ = bus;
            _ = address;
            self.sweep.value = value;
        }

        fn timerLowRegisterWrite(self: *PulseChannelType, bus: *Bus, address: u16, value: u8) void {
            _ = bus;
            _ = address;
            self.timer_reset.bytes.low = value;
        }

        fn fourthRegisterWrite(self: *PulseChannelType, bus: *Bus, address: u16, value: u8) void {
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

        pub fn busCallbacks(self: *PulseChannelType) [4]BusCallback {
            const channel_name = if (is_pulse_one) "Pulse 1 " else "Pulse 2 ";
            return [_]BusCallback{
                BusCallback.init(
                    self, 
                    apu_no_read(PulseChannelType, channel_name ++ "First"), 
                    PulseChannelType.firstRegsiterWrite
                ), // $4000/4004
                BusCallback.init(
                    self, 
                    apu_no_read(PulseChannelType, channel_name ++ "Sweep"), 
                    PulseChannelType.sweepRegisterWrite
                ), // $4001/4005
                BusCallback.init(
                    self, 
                    apu_no_read(PulseChannelType, channel_name ++ "Timer Low"), 
                    PulseChannelType.timerLowRegisterWrite
                ), // $4002/4006
                BusCallback.init(
                    self, 
                    apu_no_read(PulseChannelType, channel_name ++ "Fourth"), 
                    PulseChannelType.fourthRegisterWrite
                ), // $4003/4007
            };
        }
    }; 
}

const TriangleChannel = struct {
    channel_enabled: bool = true,

    timer: u11 = 0,
    timer_reset: packed union {
        value: u11,
        bytes: packed struct {
            low: u8 = 0,
            high: u3 = 0
        }
    } = .{.value = 0},
    linear_counter: struct {
        const LinearCounter = @This();

        counter: u7 = 0,
        reload_value: u7 = 0,
        reload: bool = false,

        pub fn step(self: *LinearCounter) void {
            if (self.reload) {
                self.counter = self.reload_value;
            } else {
                if (self.counter != 0) {
                    self.counter -= 1;
                }
            }
            var triangle_channel = @fieldParentPtr(TriangleChannel, "linear_counter", self);
            if (!triangle_channel.length_counter.halt) {
                self.reload = false;
            }
        }
    } = .{},
    control: bool = false,
    waveform_counter: u5 = 0,
    length_counter: LengthCounter = .{},

    const sequence = [32]u8{
        15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0,
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
    };

    pub fn step(self: *TriangleChannel) void {
        if (self.timer == 0) {
            self.timer = self.timer_reset.value;
            if (self.length_counter.counter != 0 and self.linear_counter.counter != 0) {
                self.waveform_counter -%= 1;
            }
        } else {
            self.timer -= 1;
        }
    }

    pub fn output(self: *TriangleChannel) u8 {
        if (!self.channel_enabled or self.length_counter.counter == 0 or 
            self.linear_counter.counter == 0 or self.timer_reset.value < 2) {
                return 0;
        }
        return sequence[self.waveform_counter];
    }

    fn linearCounterWrite(self: *TriangleChannel, bus: *Bus, address: u16, value: u8) void {
        _ = bus;
        _ = address;
        const data: packed union {
            value: u8,
            bits: packed struct {
                counter_reload: u7,
                c: bool
            }
        } = .{.value = value};

        self.linear_counter.reload_value = data.bits.counter_reload;
        self.length_counter.halt = data.bits.c;
    }

    fn timerLowRegisterWrite(self: *TriangleChannel, bus: *Bus, address: u16, value: u8) void {
        _ = bus;
        _ = address;
        self.timer_reset.bytes.low = value;
    }

    fn fourthRegisterWrite(self: *TriangleChannel, bus: *Bus, address: u16, value: u8) void {
        _ = bus;
        _ = address;
        const data: packed union {
            value: u8,
            bits: packed struct {
                timer_high: u3,
                l: u5
            }
        } = .{.value = value};
        self.timer_reset.bytes.high = data.bits.timer_high;
        if (self.channel_enabled) {
            self.length_counter.load(data.bits.l);
        }
        self.linear_counter.reload = true;
    }

    pub fn busCallbacks(self: *TriangleChannel) [4]BusCallback {
        return [_]BusCallback{
            BusCallback.init(
                self, 
                apu_no_read(TriangleChannel, "Triangle Linear Counter"), 
                TriangleChannel.linearCounterWrite
            ), // $4008
            BusCallback.init(
                self, 
                apu_no_read(TriangleChannel, "Triangle Unused"), 
                BusCallback.noWrite(TriangleChannel, "Triangle Unused", false)
            ), // $4009
            BusCallback.init(
                self, 
                apu_no_read(TriangleChannel, "Triangle Timer Low"), 
                TriangleChannel.timerLowRegisterWrite
            ), // $400A
            BusCallback.init(
                self, 
                apu_no_read(TriangleChannel, "Triangle Fourth"), 
                TriangleChannel.fourthRegisterWrite
            ), // $400B
        };
    }
};

const NoiseChannel = struct {
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

    pub fn step(self: *NoiseChannel) void {
        if (self.timer == 0) {
            self.timer = self.timer_reset;
            const feedback = self.lfsr.bits.zero ^ if (self.mode) self.lfsr.bits.six else self.lfsr.bits.one;
            self.lfsr.value >>= 1;
            self.lfsr.bits.fourteen = feedback;
        } else {
            self.timer -= 1;
        }
    }

    pub fn output(self: *NoiseChannel) u8 {
        if (!self.channel_enabled or self.length_counter.counter == 0 or self.lfsr.bits.zero == 1) {
            return 0;
        }
        return self.envelope.output();
    }

    fn firstRegisterWrite(self: *NoiseChannel, bus: *Bus, address: u16, value: u8) void {
        _ = bus;
        _ = address;
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

    fn secondRegisterWrite(self: *NoiseChannel, bus: *Bus, address: u16, value: u8) void {
        _ = bus;
        _ = address;
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

    fn fourthRegisterWrite(self: *NoiseChannel, bus: *Bus, address: u16, value: u8) void {
        _ = bus;
        _ = address;
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

    pub fn busCallbacks(self: *NoiseChannel) [4]BusCallback {
        return [_]BusCallback{
            BusCallback.init(
                self, 
                apu_no_read(NoiseChannel, "Noise First"), 
                NoiseChannel.firstRegisterWrite
            ), // $400C
            BusCallback.init(
                self, 
                apu_no_read(NoiseChannel, "Noise Unused"), 
                BusCallback.noWrite(NoiseChannel, "Noise Unused", false)
            ), // $400D
            BusCallback.init(
                self, 
                apu_no_read(NoiseChannel, "Noise Second"), 
                NoiseChannel.secondRegisterWrite
            ), // $400E
            BusCallback.init(
                self, 
                apu_no_read(NoiseChannel, "Noise Fourth"), 
                NoiseChannel.fourthRegisterWrite
            ), // $400F
        };
    }
};

const DmcChannel = struct {
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

    bus: *Bus = undefined,

    const rate_table = [16]u12{
        428, 380, 340, 320, 286, 254, 226, 214, 190, 160, 142, 128, 106,  84,  72,  54
    };

    pub fn step(self: *DmcChannel) void {
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

    pub fn output(self: *DmcChannel) u8 {
        if (!self.channel_enabled) {
            return 0;
        }
        return self.output_level;
    }

    inline fn fillSampleBuffer(self: *DmcChannel) void {
        self.sample_buffer = self.bus.readByte(self.address_counter);
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

    fn flagsAndRateRegisterWrite(self: *DmcChannel, bus: *Bus, address: u16, value: u8) void {
        _ = bus;
        _ = address;
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
    }

    fn directLoadRegisterWrite(self: *DmcChannel, bus: *Bus, address: u16, value: u8) void {
        _ = bus;
        _ = address;
        const data: packed union {
            value: u8,
            bits: packed struct {
                output_level: u7,
                _: u1
            }
        } = .{.value = value};
        self.output_level = data.bits.output_level;
    }

    fn sampleAddressRegisterWrite(self: *DmcChannel, bus: *Bus, address: u16, value: u8) void {
        _ = bus;
        _ = address;
        self.sample_address = 0xC000 | (@as(u16, value) << 6);
    }

    fn sampleLengthRegisterWrite(self: *DmcChannel, bus: *Bus, address: u16, value: u8) void {
        _ = bus;
        _ = address;
        self.sample_length = (@as(u12, value) << 4) | 1;
    }

    pub fn busCallbacks(self: *DmcChannel) [4]BusCallback {
        return [_]BusCallback{
            BusCallback.init(
                self, 
                apu_no_read(DmcChannel, "DMC First"), 
                DmcChannel.flagsAndRateRegisterWrite
            ), // $400C
            BusCallback.init(
                self, 
                apu_no_read(DmcChannel, "DMC Unused"), 
                DmcChannel.directLoadRegisterWrite
            ), // $400D
            BusCallback.init(
                self, 
                apu_no_read(DmcChannel, "DMC Second"), 
                DmcChannel.sampleAddressRegisterWrite
            ), // $400E
            BusCallback.init(
                self, 
                apu_no_read(DmcChannel, "DMC Fourth"), 
                DmcChannel.sampleLengthRegisterWrite
            ), // $400F
        };
    }
};

pub fn init(self: *Self) !void {
    self.audio_device = c_sdl.SDL_OpenAudioDevice(null, 0, &self.spec_requested, &self.spec_obtained, 0);

    if (self.audio_device == 0) {
        std.debug.print("ZigNES: Unable to initialize audio device: {s}\n", .{c_sdl.SDL_GetError()});
        return error.Unable;
    }
    c_sdl.SDL_PauseAudioDevice(self.audio_device, 0);
}

pub fn deinit(self: *Self) void {
    if (self.audio_device != 0) {
        c_sdl.SDL_CloseAudioDevice(self.audio_device);
    }
}

pub fn reset(self: *Self) void {
    var unused_callback = [_]?BusCallback{null};
    var unused_bus = Bus{.bus_callbacks = &unused_callback};
    self.status.write(&unused_bus, 0, 0);
}

pub fn connectMainBus(self: *Self, main_bus: *MainBus) void {
    self.irq = &main_bus.irq;
    self.dmc_channel.bus = &main_bus.bus;
}

inline fn updateIrq(self: *Self) void {
    self.irq.* = self.frame_counter.frame_interrupt or self.dmc_channel.dmc_interrupt;
}

inline fn stepEnvelopes(self: *Self) void {
    self.pulse_channel_one.envelope.step();
    self.pulse_channel_two.envelope.step();
    self.noise_channel.envelope.step();
}

inline fn stepLengthCounters(self: *Self) void {
    self.pulse_channel_one.length_counter.step();
    self.pulse_channel_two.length_counter.step();
    self.triangle_channel.length_counter.step();
    self.noise_channel.length_counter.step();
}

fn getMix(self: *Self) u8 {
    // Mixer emulation and tables explained here: https://www.nesdev.org/wiki/APU_Mixer
    const pulse_table = comptime blk: {
        var table: [31]u8 = undefined;
        table[0] = 0;
        for (&table, 1..) |*entry, i| {
            entry.* = @intFromFloat((95.52 / (8128.0 / @as(comptime_float, @floatFromInt(i)) + 100)) * 255);
        }
        break :blk table;
    };

    const tnd_table = comptime blk: {
        var table: [203]u8 = undefined;
        table[0] = 0;
        for (&table, 1..) |*entry, i| {
            entry.* = @intFromFloat((163.67 / (24329.0 / @as(comptime_float, @floatFromInt(i)) + 100)) * 255);
        }
        break :blk table;
    };

    const pulse_index = self.pulse_channel_one.output() + self.pulse_channel_two.output();
    const tnd_index = self.triangle_channel.output() * 3 + self.noise_channel.output() * 2 + self.dmc_channel.output();
    
    return pulse_table[pulse_index] + tnd_table[tnd_index];
}

fn sample(self: *Self) void {
    if (c_sdl.SDL_GetQueuedAudioSize(self.audio_device) < sample_buffer_size * 10) {
        if (self.sample_buffer_index < sample_buffer_size) {
            self.sample_buffer[self.sample_buffer_index] = self.getMix();
            self.sample_buffer_index += 1;
        }
    }
}

pub fn step(self: *Self) void {
    self.odd_frame = !self.odd_frame;
    if (self.odd_frame) {
        self.frame_counter.step();

        self.pulse_channel_one.step();
        self.pulse_channel_two.step();
        self.noise_channel.step();
    }

    self.triangle_channel.step();
    self.dmc_channel.step();

    self.sample_timer += 1;
    if (self.sample_timer == @as(u16, @intFromFloat(cycles_per_sample))) {
        self.sample_timer = 0;

        self.sample();
        if (self.sample_buffer_index == sample_buffer_size) {
            _ = c_sdl.SDL_QueueAudio(self.audio_device, &self.sample_buffer, sample_buffer_size);
            self.sample_buffer_index = 0;
        }    
    }
}