const std = @import("std");

const c_sdl = @cImport({
    @cInclude("SDL.h");
    @cInclude("SDL_opengl.h");
});

const sample_buffer_size = @import("../main.zig").sample_buffer_size;

const Bus = @import("../bus/bus.zig");
const BusCallback = Bus.BusCallback;
const MainBus = @import("../cpu/main_bus.zig");

const PulseChannel = @import("./pulse_channel.zig").PulseChannel;
const TriangleChannel = @import("./triangle_channel.zig");
const NoiseChannel = @import("./noise_channel.zig");
const DmcChannel = @import("./dmc_channel.zig");

const Self = @This();

const cycles_per_sample: f16 = 1789772.72 / 44100.0;
const sample_period: f32 = 1.0 / 44.10;
const cpu_period: f32 = 1.0 / 1789.77272;

audio_callback: *const fn () void,

sample_timer: f32 = 0,
sample_buffer: [sample_buffer_size]u16 = undefined,
sample_buffer_index: u16 = 0,

volume: f16 = 30000,

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
            apu.stepSweeps();
            apu.stepLengthCounters();
        } else if (self.counter == 22371) {
            apu.stepEnvelopes();
            apu.triangle_channel.linear_counter.step();
        }

        if (!self.mode) {
            if (self.counter == 29828) {
                if (!self.interrupt_inhibited) {
                    self.frame_interrupt = true;
                }
            } else if (self.counter == 29829) {
                apu.stepEnvelopes();
                apu.triangle_channel.linear_counter.step();
                apu.stepSweeps();
                apu.stepLengthCounters();
                if (!self.interrupt_inhibited) {
                    self.frame_interrupt = true;
                }
            } else if (self.counter == 29830) {
                // This is also frame 0, so the frame counter is set immediately to 1
                self.counter = 1;
                if (!self.interrupt_inhibited) {
                    self.frame_interrupt = true;
                }
            }
        } else {
            if (self.counter == 37281) {
                apu.stepEnvelopes();
                apu.triangle_channel.linear_counter.step();
                apu.stepSweeps();
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
        if (self.interrupt_inhibited) {
            self.frame_interrupt = false;
        }
    }

    pub fn busCallback(self: *FrameCounter) BusCallback {
        return BusCallback.init(self, apu_no_read(FrameCounter, "This should be joystick 2"), FrameCounter.write);
    }
} = .{},

pub fn apu_no_read(comptime Outer: type, comptime name: []const u8) fn (ptr: *Outer, bus: *Bus, address: u16) u8 {
    return BusCallback.noRead(Outer, "Cannot read from APU: " ++ name, false);
}

pub const Envelope = struct {
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

pub const LengthCounter = struct {
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

pub fn init(audio_callback: *const fn () void) Self {
    return .{.audio_callback = audio_callback};
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
    const frame_counter_irq = self.frame_counter.frame_interrupt and !self.frame_counter.interrupt_inhibited;
    const dmc_irq = self.dmc_channel.dmc_interrupt and self.dmc_channel.interrupt_enabled;
    self.irq.* = frame_counter_irq or dmc_irq;
}

inline fn stepSweeps(self: *Self) void {
    self.pulse_channel_one.sweep.step();
    self.pulse_channel_two.sweep.step();
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

fn getMix(self: *Self) u16 {
    // Mixer emulation and tables explained here: https://www.nesdev.org/wiki/APU_Mixer
    const pulse_table = comptime blk: {
        var table: [31]f16 = undefined;
        table[0] = 0;
        for (&table, 1..) |*entry, i| {
            entry.* = 95.52 / (8128.0 / @as(comptime_float, @floatFromInt(i)) + 100.0);
        }
        break :blk table;
    };

    const tnd_table = comptime blk: {
        var table: [203]f16 = undefined;
        table[0] = 0;
        for (&table, 1..) |*entry, i| {
            entry.* = 163.67 / (24329.0 / @as(comptime_float, @floatFromInt(i)) + 100.0);
        }
        break :blk table;
    };

    const pulse_index = self.pulse_channel_one.output() + self.pulse_channel_two.output();
    const tnd_index = self.triangle_channel.output() * 3 + self.noise_channel.output() * 2 + self.dmc_channel.output();
    const result = pulse_table[pulse_index] + tnd_table[tnd_index];

    return @intFromFloat(@min(60000, result * self.volume));
}

fn sample(self: *Self) void {
    if (self.sample_buffer_index < sample_buffer_size) {
        self.sample_buffer[self.sample_buffer_index] = self.getMix();
        self.sample_buffer_index += 1;
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

    self.sample_timer += cpu_period;
    if (self.sample_timer >= sample_period) {
        self.sample_timer -= sample_period;

        self.sample();
        if (self.sample_buffer_index == sample_buffer_size) {
            self.audio_callback();
            self.sample_buffer_index = 0;
        }
    }
    self.updateIrq();
}