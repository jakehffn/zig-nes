const std = @import("std");

const c_sdl = @cImport({
    @cInclude("SDL.h");
    @cInclude("SDL_opengl.h");
});

const Bus = @import("../bus/bus.zig");
const BusCallback = Bus.BusCallback;
const MainBus = @import("../cpu/main_bus.zig");

const Self = @This();

spec_requested: c_sdl.SDL_AudioSpec = .{
    .freq = 44100, 
    .format = c_sdl.AUDIO_U8,
    .channels = 1,
    .silence = undefined,
    .samples = 1024,
    .size = undefined,
    .callback = null,
    .userdata = undefined,
    .padding = undefined
},
spec_obtained: c_sdl.SDL_AudioSpec = undefined,
audio_device: c_sdl.SDL_AudioDeviceID = undefined,

length_counters_enabled: bool = false,

frame_counter: FrameCounter = .{.irq = undefined},

pulse_channel_one: PulseChannel(true) = .{},
pulse_channel_two: PulseChannel(false) = .{},

fn apu_no_read(comptime Outer: type) fn (ptr: *Outer, bus: *Bus, address: u16) u8 {
    return BusCallback.noRead(Outer, "Cannot read from APU", false);
}

const FrameCounter = struct {
    counter: u16 = 0,
    mode: bool = false,
    interrupt_inhibited: bool = false,

    irq: *bool,

    inline fn step(self: *FrameCounter, apu: *Self) void {
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
                    self.irq.* = true;
                }
            } else if (self.counter == 29829) {
                // Clock Envelopes and triangle's linear counter
                // Clock length counters and sweep units
                apu.stepLengthCounters();
                if (!self.interrupt_inhibited) {
                    self.irq.* = false;
                }
            } else if (self.counter == 29830) {
                // This is also frame 0, so the frame counter is set immediately to 1
                self.counter = 1;
                if (!self.interrupt_inhibited) {
                    self.irq.* = false;
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
        self.mode_zero = data.bits.M;
        if (self.interrupt_inhibited) {
            self.irq.* = false;
        }
    }

    pub fn busCallback(self: *FrameCounter) BusCallback {
        return BusCallback.init(self, apu_no_read(FrameCounter), FrameCounter.write);
    }
};

const LengthCounter = struct {
    halt: bool = false,
    counter: u8 = 0,

    const load_lengths = [_]u8 {
        10, 254, 20,  2, 40,  4, 80,  6, 160,  8, 60, 10, 14, 12, 26, 14,
        12, 16, 24, 18, 48, 20, 96, 22, 192, 24, 72, 26, 16, 28, 32, 30
    };

    pub fn step(self: *LengthCounter) void {
        if (!self.halt) {
            self.counter -|= 1;
        }
    }

    pub fn load(self: *LengthCounter, index: u5) void {
        self.counter = load_lengths[index];
    }
};

fn PulseChannel(comptime is_pulse_one: bool) type {
    _ = is_pulse_one;
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
                self.waveform_counter -%= 1;
                self.timer = self.timer_reset.value;
            } else {
                self.timer -= 1;
            }
        }

        pub fn output(self: *PulseChannelType) u8 {
            if (!self.length_counter.halt and self.length_counter.counter == 0) {
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
            return [_]BusCallback{
                BusCallback.init(
                    self, 
                    apu_no_read(PulseChannelType), 
                    PulseChannelType.firstRegsiterWrite
                ), // $4000/4004
                BusCallback.init(
                    self, 
                    apu_no_read(PulseChannelType), 
                    PulseChannelType.sweepRegisterWrite
                ), // $4001/4005
                BusCallback.init(
                    self, 
                    apu_no_read(PulseChannelType), 
                    PulseChannelType.timerLowRegisterWrite
                ), // $4002/4006
                BusCallback.init(
                    self, 
                    apu_no_read(PulseChannelType), 
                    PulseChannelType.fourthRegisterWrite
                ), // $4003/4007
            };
        }
    }; 
}

pub fn init() !Self {
    var apu: Self = .{
        .irq = undefined,
    };

    apu.audio_device = c_sdl.SDL_OpenAudioDevice(null, 0, &apu.spec_requested, &apu.spec_obtained, 0);

    if (apu.audio_device == 0) {
        std.debug.print("ZigNES: Unable to initialize audio device: {s}\n", .{c_sdl.SDL_GetError()});
        return error.Unable;
    }
    c_sdl.SDL_PauseAudioDevice(apu.audio_device, 0);

    return apu;
}

pub fn deinit(self: *Self) void {
    c_sdl.SDL_CloseAudioDevice(self.audio_device);
}

pub fn connectMainBus(self: *Self, main_bus: *MainBus) void {
    self.frame_counter.irq = &main_bus.irq;
}

inline fn stepLengthCounters(self: *Self) void {
    self.pulse_channel_one.length_counter.step();
    self.pulse_channel_two.length_counter.step();
}

inline fn stepChannels(self: *Self) void {
    self.pulse_channel_one.step();
    self.pulse_channel_two.step();
}

inline fn getMix(self: *Self) u8 {
    // Mixer emulation and tables explained here: https://www.nesdev.org/wiki/APU_Mixer
    var data = 0;
    data += self.pulse_channel_one.output();
    data += self.pulse_channel_two.output();
}

pub fn step(self: *Self) void {
    self.frame_counter.step(self);
    self.stepChannels();

    var data: u8 = self.getMix();

    if (c_sdl.SDL_QueueAudio(self.audio_device, &data, 1) != 0) {
        std.debug.print("ZigNES: Unable to queue audio: {s}\n", .{c_sdl.SDL_GetError()});
    }
}