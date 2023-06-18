const std = @import("std");
const expect = std.testing.expect;

const CPU = @import("./cpu.zig").CPU;
const Bus = @import("./bus.zig").Bus;
const BusCallback = Bus.BusCallback;
const WorkRam = @import("./work_ram.zig").WorkRam;

const TestEnv = struct {
    const Self = @This();

    bus_callback: *BusCallback,
    bus: Bus,
    cpu: CPU,

    pub fn init(bus_callback: *BusCallback) TestEnv {
        
        var test_env = TestEnv{
            .bus_callback = bus_callback,
            .bus = undefined,
            .cpu = undefined
        };

        test_env.bus = Bus.init(bus_callback);
        test_env.cpu = CPU.init(&(test_env.bus));

        return test_env;
    }
    
    pub fn write_next(self: *Self, data: []const u8) void {
        for (data, 0..) |byte, i| {
            self.bus.write_byte(self.cpu.pc + @intCast(u16, i), byte);
        }
    }

    pub fn write_step_expect_a(self: *Self, data: []const u8, expect_a_val: u8) !void {
        self.write_next(data);
        self.cpu.step();
        try expect(self.cpu.a == expect_a_val);
    }

    pub fn test_with_env(comptime ram_size: usize, init_pc: u16, testFn: *const fn (*TestEnv) anyerror!void) !void {
        var test_memory = WorkRam(ram_size){};
        var bus_callback = test_memory.busCallback();
        var test_env = TestEnv.init(&bus_callback);

        test_env.cpu.pc = init_pc;

        try testFn(&test_env);
    }
};

test "Immediate" {
    try TestEnv.test_with_env(0x10, 0x0, struct {
        pub fn testFn(test_env: *TestEnv) !void {
            // ADC
            test_env.cpu.a = 3;
            try test_env.write_step_expect_a(&[_]u8{0x69, 2}, 5);
        }
    }.testFn);
}

test "ADC" {
    try TestEnv.test_with_env(0x4000, 0x2000, struct {
        pub fn testFn(test_env: *TestEnv) !void {
            // Immediate
            test_env.cpu.a = 3;
            try test_env.write_step_expect_a(&[_]u8{0x69, 2}, 5);

            // Zero Page
            test_env.bus.write_byte(0x0080, 4);
            try test_env.write_step_expect_a(&[_]u8{0x65, 0x80}, 9);

            //Zero Page X
            test_env.cpu.x = 0x20;
            // 0x20 + 0x60 will refer to the previously written 4 at 0x80
            try test_env.write_step_expect_a(&[_]u8{0x75, 0x60}, 13);

            // Absolute
            test_env.bus.write_byte(0x1234, 20);
            try test_env.write_step_expect_a(&[_]u8{0x6D, 0x34, 0x12}, 33);

            // Absolute X
            test_env.cpu.x = 0x34;
            // 0x1200 + 0x34 will refer to the previously written 20 at 0x1234
            try test_env.write_step_expect_a(&[_]u8{0x7D, 0x00, 0x12}, 53);
        
            // Absolute Y
            test_env.cpu.y = 0x34;
            // 0x1200 + 0x34 will refer to the previously written 20 at 0x1234
            try test_env.write_step_expect_a(&[_]u8{0x79, 0x00, 0x12}, 73);

            // Indexed Indirect
            test_env.cpu.x = 0x0F;
            test_env.bus.write_byte(0x0010, 0x34);
            test_env.bus.write_byte(0x0011, 0x12);
            try test_env.write_step_expect_a(&[_]u8{0x61, 0x01}, 93);

            // Indirect Indexed
            test_env.cpu.y = 0xFF;
            test_env.bus.write_byte(0x0010, 0x35);
            test_env.bus.write_byte(0x0011, 0x11);
            // 0x35 + 0xFF = 0x34 + C
            // 0x11 + C = 0x12
            // $0x1234 = 20
            try test_env.write_step_expect_a(&[_]u8{0x71, 0x10}, 113);

            // Flags

            // Negative and overflow
            test_env.cpu.a = 0b0111_1111;
            test_env.write_next(&[_]u8{0x69, 1});
            test_env.cpu.step();

            try expect(test_env.cpu.flags.N == 1);
            try expect(test_env.cpu.flags.V == 1);

            // Zero and carry
            test_env.cpu.a = 0xFF;
            test_env.write_next(&[_]u8{0x69, 1});
            test_env.cpu.step();

            try expect(test_env.cpu.flags.Z == 1);
            try expect(test_env.cpu.flags.C == 1);
        }
    }.testFn);
}

test "AND" {
    try TestEnv.test_with_env(0x20, 0x10, struct {
        pub fn testFn(test_env: *TestEnv) !void {
            // Immediate
            test_env.cpu.a = 0b1111_0000;
            try test_env.write_step_expect_a(&[_]u8{0x29, 0b0011_0011}, 0b0011_0000);
        }
    }.testFn);
}