const std = @import("std");
const expect = std.testing.expect;
const allocator = std.testing.allocator;

const Cpu = @import("./cpu.zig").Cpu;
const Bus = @import("./bus.zig").Bus;
const BusCallback = Bus.BusCallback;
const Ram = @import("./ram.zig").Ram;

const OpCodeError = error {
    UnexpectedBehaviour
};

const TestEnv = struct {
    const Self = @This();

    const CpuState = struct {
        pc: u16,
        s: u8,
        a: u8,
        x: u8,
        y: u8,
        p: u8,
        /// address, value
        ram: ?[]struct {u16, u8},
    };

    const Test = struct {
        name: []const u8,
        initial: CpuState,
        final: CpuState,
        cycles: []const Cycle,
        const Cycle = struct {u16, u8, []const u8};
    };

    bus: Bus,
    cpu: Cpu(null),
    unused: bool = false,

    fn init(ram: *Ram(0x10000)) !TestEnv {
        return .{
            .bus = try Bus.init(allocator, 0x10000, ram.busCallback()),
            .cpu = undefined,
        };
    }

    fn initCpu(self: *Self) void {
        self.cpu = Cpu(null).initWithTestBus(&self.bus, &self.unused) catch unreachable;
    }

    fn deinit(self: *Self) void {
        self.cpu.deinit();
        self.bus.deinit(allocator);
    }

    fn setState(env: *TestEnv, state: CpuState) void {
        env.cpu.pc = state.pc;
        env.cpu.sp = state.s;
        env.cpu.a = state.a;
        env.cpu.x = state.x;
        env.cpu.y = state.y;
        env.cpu.flags = @bitCast(state.p);

        for (state.ram orelse unreachable) |data| {
            env.bus.writeByte(data[0], data[1]);
        }
    }

    fn checkState(env: *TestEnv, state: CpuState) bool {
        var is_correct = true;
        is_correct = is_correct and env.cpu.pc == state.pc;
        is_correct = is_correct and env.cpu.sp == state.s;
        is_correct = is_correct and env.cpu.a == state.a;
        is_correct = is_correct and env.cpu.x == state.x;
        is_correct = is_correct and env.cpu.y == state.y;
        is_correct = is_correct and @as(u8, @bitCast(env.cpu.flags)) == state.p;

        for (state.ram orelse unreachable) |data| {
            is_correct = is_correct and env.bus.readByte(data[0]) == data[1];
        }

        return is_correct;
    }

    fn printFailure(env: *TestEnv, test_num: usize, initial: CpuState, expected: CpuState) void {
        std.debug.print("\nFailed Test {}:\n\tInitial: {}\n\tExpected: {}\n\tActual: ", .{test_num, initial, expected});
        std.debug.print("{}\n", .{
            CpuState{
                .pc = env.cpu.pc, 
                .s = env.cpu.sp, 
                .a = env.cpu.a, 
                .x = env.cpu.x, 
                .y = env.cpu.y, 
                .p = @as(u8, @bitCast(env.cpu.flags)),
                .ram = null
            },
        });
        for (expected.ram orelse unreachable) |data| {
            const value = env.bus.readByte(data[0]);
            std.debug.print("\t${X:0>4}: 0x{X:0>2}\tEx: 0x{X:0>2}\n", .{data[0], value, data[1]});
        }
    }

    pub fn testOpcode(opcode_tests_path: []const u8) !void {
        // Load the json tests
        // The largest test file is ~5000 KB
        const tests_file = try std.fs.cwd().readFileAlloc(allocator, opcode_tests_path, 5500 * 1000);
        defer allocator.free(tests_file);
  
        var tests_json = try std.json.parseFromSlice([]const Test, allocator, tests_file, .{});
        defer tests_json.deinit();

        // Prepare the test environment
        var test_memory = Ram(0x10000){};
        var test_env = try TestEnv.init(&test_memory);
        defer test_env.deinit();
        test_env.initCpu();

        var num_not_passed: u16 = 0;

        for (0..tests_json.value.len) |i| {
            const case = tests_json.value[i];

            setState(&test_env, case.initial);
            _ = test_env.cpu.step();
            const passed = checkState(&test_env, case.final);

            if (!passed) {
                num_not_passed += 1;
                printFailure(&test_env, i, case.initial, case.final);
            }
        }

        std.debug.print("\n{s}: Passed {}/{} tests\n", .{opcode_tests_path, tests_json.value.len - num_not_passed, tests_json.value.len});
        if (num_not_passed > 0) {
            return OpCodeError.UnexpectedBehaviour;
        }
    }
};

const tests_path = "./test-files/tom_harte_nes6502/v1/";

test "ADC Immediate" {
    try TestEnv.testOpcode(tests_path ++ "69.json");
}