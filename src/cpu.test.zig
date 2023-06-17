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
};

fn write_next(data: []const u8, test_env: *TestEnv) void {
    for (data, 0..) |byte, i| {
        test_env.bus.write_byte(test_env.cpu.pc + @intCast(u16, i), byte);
    }
}

test "ADC" {
    var test_memory = WorkRam(0x4000){};
    var bus_callback = test_memory.busCallback();
    var test_env = TestEnv.init(&bus_callback);

    test_env.cpu.pc = 0x2000;

    // Immediate
    test_env.cpu.a = 3;
    write_next(&[_]u8{0x69, 2}, &test_env);
    test_env.cpu.step();

    try expect(test_env.cpu.a == 5);

    // Zero Page
    test_env.bus.write_byte(0x0080, 4);
    write_next(&[_]u8{0x65, 0x80}, &test_env);
    test_env.cpu.step();

    try expect(test_env.cpu.a == 9);

    //Zero Page X
    test_env.cpu.x = 0x20;
    // 0x20 + 0x60 will refer to the previously written 4 at 0x80
    write_next(&[_]u8{0x75, 0x60}, &test_env);
    test_env.cpu.step();

    try expect(test_env.cpu.a == 13);

    // Absolute
    test_env.bus.write_byte(0x1234, 20);
    write_next(&[_]u8{0x6D, 0x34, 0x12}, &test_env);
    test_env.cpu.step();

    try expect(test_env.cpu.a == 33);

    // Absolute X
    test_env.cpu.x = 0x34;
    // 0x1200 + 0x34 will refer to the previously written 20 at 0x1234
    write_next(&[_]u8{0x7D, 0x00, 0x12}, &test_env);
    test_env.cpu.step();

    try expect(test_env.cpu.a == 53);
 
    // Absolute Y
    test_env.cpu.y = 0x34;
    // 0x1200 + 0x34 will refer to the previously written 20 at 0x1234
    write_next(&[_]u8{0x79, 0x00, 0x12}, &test_env);
    test_env.cpu.step();   

    try expect(test_env.cpu.a == 73);

    // Indexed Indirect
    test_env.cpu.x = 0x0F;
    test_env.bus.write_byte(0x0010, 0x34);
    test_env.bus.write_byte(0x0011, 0x12);
    write_next(&[_]u8{0x61, 0x01}, &test_env);
    test_env.cpu.step();

    try expect(test_env.cpu.a == 93);

    // Indirect Indexed
    test_env.cpu.y = 0xFF;
    test_env.bus.write_byte(0x0010, 0x35);
    test_env.bus.write_byte(0x0011, 0x11);
    // 0x35 + 0xFF = 0x34 + C
    // 0x11 + C = 0x12
    // $0x1234 = 20
    write_next(&[_]u8{0x71, 0x10}, &test_env);
    test_env.cpu.step();

    try expect(test_env.cpu.a == 113);

    // Flags

    // Negative and overflow
    test_env.cpu.a = 0b0111_1111;
    write_next(&[_]u8{0x69, 1}, &test_env);
    test_env.cpu.step();

    try expect(test_env.cpu.flags.N == 1);
    try expect(test_env.cpu.flags.V == 1);

    // Zero and carry
    test_env.cpu.a = 0xFF;
    write_next(&[_]u8{0x69, 1}, &test_env);
    test_env.cpu.step();

    try expect(test_env.cpu.flags.Z == 1);
    try expect(test_env.cpu.flags.C == 1);
}