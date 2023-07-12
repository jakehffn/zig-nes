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
    .callback = sdlAudioCallback,
    .userdata = undefined,
    .padding = undefined
},
spec_obtained: c_sdl.SDL_AudioSpec = undefined,
audio_device: c_sdl.SDL_AudioDeviceID = undefined,
sample_timer: u16 = 0,
sample_buffer: [sample_buffer_size]u8 = undefined,
sample_buffer_length: u16 = 0,

odd_frame: bool = true,
length_counters_enabled: bool = false,
irq: *bool = undefined,

pulse_channel_one: PulseChannel(true) = .{},
pulse_channel_two: PulseChannel(false) = .{},
pulse_channel_test: PulseChannel(true) = .{},

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
            apu.pulse_channel_one.length_counter.halt = true;
        }
        if (!self.flags.bits.pulse_two) {
            apu.pulse_channel_two.length_counter.halt = true;
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
            // Clock envelopes and triangle's linear counters
        } else if (self.counter == 14913) {
            // Clock envelopes and triangle's linear counters
            // Clock length counters and sweep units
            apu.stepLengthCounters();
        } else if (self.counter == 22371) {
            // Clock envelopes and triangle's linear counters
        }

        if (!self.mode) {
            if (self.counter == 29828) {
                if (!self.interrupt_inhibited) {
                    self.frame_interrupt = true;
                    apu.updateIrq();
                }
            } else if (self.counter == 29829) {
                // Clock Envelopes and triangle's linear counter
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
                // Clock Envelopes and triangle's linear counter
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
    halt: bool = true,
    counter: u8 = 0,

    const load_lengths = [_]u8 {
        10, 254, 20,  2, 40,  4, 80,  6, 160,  8, 60, 10, 14, 12, 26, 14,
        12, 16, 24, 18, 48, 20, 96, 22, 192, 24, 72, 26, 16, 28, 32, 30
    };

    pub fn step(self: *LengthCounter) void {
        if (!self.halt) {
            self.counter -|= 1;
        }
        if (self.counter == 0) {
            self.halt = true;
        }
    }

    pub fn load(self: *LengthCounter, index: u5) void {
        self.counter = load_lengths[index];
    }
};

fn PulseChannel(comptime is_pulse_one: bool) type {
    return struct {
        const PulseChannelType = @This();

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
            // var apu = @fieldParentPtr(Self, if (is_pulse_one) "pulse_channel_one" else "pulse_channel_two", self);
            // const channel_enabled = if (is_pulse_one) apu.status.flags.bits.pulse_one else apu.status.flags.bits.pulse_two;

            // if (!channel_enabled or (!self.length_counter.halt and self.length_counter.counter == 0)) {
            //     return 0;
            // }
            if (self.timer < 8) {
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
                    l: bool,
                    D: u2
                }
            } = .{.value = value};

            self.duty_cycle = data.bits.D;
            self.length_counter.halt = data.bits.l;
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
            self.length_counter.load(data.bits.l);
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

pub fn init(self: *Self) !void {
    self.spec_requested.userdata = self;
    self.audio_device = c_sdl.SDL_OpenAudioDevice(null, 0, &self.spec_requested, &self.spec_obtained, 0);

    if (self.audio_device == 0) {
        std.debug.print("ZigNES: Unable to initialize audio device: {s}\n", .{c_sdl.SDL_GetError()});
        return error.Unable;
    }
    c_sdl.SDL_PauseAudioDevice(self.audio_device, 0);

    self.pulse_channel_test.timer_reset.value = 1708; // Middle C
    self.pulse_channel_test.duty_cycle = 2;
}

pub fn deinit(self: *Self) void {
    if (self.audio_device != 0) {
        c_sdl.SDL_CloseAudioDevice(self.audio_device);
    }
}

pub fn reset(self: *Self) void {
    self.status.flags.value = 0;
    self.irq.* = false;
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
}

fn sdlAudioCallback(userdata: ?*anyopaque, stream: [*c]u8, len: c_int) callconv(.C) void {
    const self: *Self = @ptrCast(@alignCast(userdata.?));
    const length: usize = @as(c_uint, @bitCast(len));
    @memcpy(stream[0..length], self.sample_buffer[0..length]);
    self.sample_buffer_length = 0;
    self.sample_timer = 0;
}

fn getMix(self: *Self) u8 {
    // Mixer emulation and tables explained here: https://www.nesdev.org/wiki/APU_Mixer
    var data: u8 = 0;
    data += self.pulse_channel_one.output();
    data += self.pulse_channel_two.output();
    return data*2;
}

fn sample(self: *Self) void {
    // If the callback set the length to zero, clear the old data
    if (self.sample_buffer_length == 0) {
        @memset(self.sample_buffer[0..self.sample_buffer.len], 0);
    }
    if (self.sample_buffer_length < self.sample_buffer.len) {
        self.sample_buffer[self.sample_buffer_length] = self.getMix();
        self.sample_buffer_length += 1;
    }
}

pub fn step(self: *Self) void {
    self.odd_frame = !self.odd_frame;
    if (self.odd_frame) {
        self.frame_counter.step();

        self.pulse_channel_one.step();
        self.pulse_channel_two.step();
    }

    self.sample_timer += 1;
    if (self.sample_timer == @as(u16, @intFromFloat(cycles_per_sample))) {
        self.sample_timer = 0;

        self.sample();
    }
}