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

status: struct {
    const Status = @This();
    // Writing to status enables and disables channels
    // Reading from status reports on various conditions of the actual channels, not the flags
    flags: packed union {
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
    } = .{.value = 0},

    fn read(self: *Status, bus: *Bus, address: u16) u8 {
        _ = bus;
        _ = address;
        var apu = @fieldParentPtr(Self, "status", self);

        var return_flags = @TypeOf(self.flags){.value = 0};
        return_flags.bits.pulse_one = !apu.pulse_channel_one.length_counter.halt;
        return_flags.bits.pulse_two = !apu.pulse_channel_two.length_counter.halt;
        return_flags.bits.triangle = false; // TODO: Change when triangle channel is added
        return_flags.bits.noise = false; // TODO: Change when noise channel is added
        return_flags.bits.F = apu.frame_counter.frame_interrupt;
        return_flags.bits.I = false; // TODO: Change when dmc added

        apu.frame_counter.frame_interrupt = false;
        apu.updateIrq();

        return return_flags.value;
    }

    fn write(self: *Status, bus: *Bus, address: u16, value: u8) void {
        _ = bus;
        _ = address;
        var apu = @fieldParentPtr(Self, "status", self);

        self.flags.value = value;

        if (!self.flags.bits.pulse_one) {
            apu.pulse_channel_one.length_counter.counter = 0;
        }
        if (!self.flags.bits.pulse_two) {
            apu.pulse_channel_two.length_counter.counter = 0;
        }
        // TODO: Add the other two halts after adding triangle and noise
        // TODO: Do all dmc stuff needed here
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
            // Clock envelopes
            apu.triangle_channel.linear_counter.step();
        } else if (self.counter == 14913) {
            // Clock envelopes
            apu.triangle_channel.linear_counter.step();
            // Clock length counters and sweep units
            apu.stepLengthCounters();
        } else if (self.counter == 22371) {
            // Clock envelopes
            apu.triangle_channel.linear_counter.step();
        }

        if (!self.mode) {
            if (self.counter == 29828) {
                if (!self.interrupt_inhibited) {
                    self.frame_interrupt = true;
                    apu.updateIrq();
                }
            } else if (self.counter == 29829) {
                // Clock Envelopes
                apu.triangle_channel.linear_counter.step();
                // Clock length counters and sweep units
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
                // Clock Envelopes
                apu.triangle_channel.linear_counter.step();
                // Clock length counters and sweep units
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

const LengthCounter = struct {
    halt: bool = false,
    counter: u8 = 0,

    const load_lengths = [_]u8 {
        10, 12, 254, 16, 20, 24, 2, 18, 40, 48, 4, 20, 80, 96, 6, 22,
        160, 192, 8, 24, 60, 72, 10, 26, 14, 16, 12, 28, 26, 32, 14, 30
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
        const self_field_name = if (is_pulse_one) "pulse_channel_one" else "pulse_channel_two";

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
        length_counter: LengthCounter = .{},
        duty_cycle: u2 = 0, // Determines the cycle used from the duty table

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
            var apu = @fieldParentPtr(Self, self_field_name, self);
            const channel_enabled = if (is_pulse_one) apu.status.flags.bits.pulse_one else apu.status.flags.bits.pulse_two;

            if (!channel_enabled or self.length_counter.counter == 0 or self.timer_reset.value < 8) {
                return 0;
            }
            return duty_table[self.duty_cycle][self.waveform_counter];
        }

        fn firstRegsiterWrite(self: *PulseChannelType, bus: *Bus, address: u16, value: u8) void {
            _ = bus;
            _ = address;
            const data: packed union {
                value: u8,
                bits: packed struct {
                    v: u4,
                    c: bool,
                    length_counter_halt: bool,
                    duty_cycle: u2
                }
            } = .{.value = value};

            self.duty_cycle = data.bits.duty_cycle;
            self.length_counter.halt = data.bits.length_counter_halt;
            // Constant/envelope flag
            // Volume/envelope divider period
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
            var apu = @fieldParentPtr(Self, self_field_name, self);
            const channel_enabled = if (is_pulse_one) apu.status.flags.bits.pulse_one else apu.status.flags.bits.pulse_two;
            if (channel_enabled) {
                self.length_counter.load(data.bits.l);
            }
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
        var apu = @fieldParentPtr(Self, "triangle_channel", self);

        if (!apu.status.flags.bits.triangle or self.length_counter.counter == 0 or 
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
        // Constant/envelope flag
        // Volume/envelope divider period
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
        var apu = @fieldParentPtr(Self, "triangle_channel", self);
        if (apu.status.flags.bits.triangle) {
            self.length_counter.load(data.bits.l);
        }
        self.linear_counter.reload = true;
    }

    pub fn busCallbacks(self: *TriangleChannel) [4]BusCallback {
        return [_]BusCallback{
            BusCallback.init(
                self, 
                apu_no_read(TriangleChannel, "Triangle First"), 
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
    self.status.flags.value = 0;
}

pub fn connectMainBus(self: *Self, main_bus: *MainBus) void {
    self.irq = &main_bus.irq;
}

inline fn updateIrq(self: *Self) void {
    // TODO: When DMC is added, add dmc irq check ORed
    self.irq.* = self.frame_counter.frame_interrupt;
}

inline fn stepLengthCounters(self: *Self) void {
    self.pulse_channel_one.length_counter.step();
    self.pulse_channel_two.length_counter.step();

    self.triangle_channel.length_counter.step();
}

fn getMix(self: *Self) u8 {
    // Mixer emulation and tables explained here: https://www.nesdev.org/wiki/APU_Mixer
    var data: u8 = 0;
    data += self.pulse_channel_one.output()*2;
    data += self.pulse_channel_two.output()*2;
    data += self.triangle_channel.output();
    return data*2;
}

fn sample(self: *Self) void {
    if (c_sdl.SDL_GetQueuedAudioSize(self.audio_device) < sample_buffer_size * 7) {
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
    }

    self.triangle_channel.step();

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