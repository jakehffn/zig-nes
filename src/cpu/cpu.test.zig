const std = @import("std");
const expect = std.testing.expect;
const allocator = std.testing.allocator;

const Cpu = @import("./cpu.zig").Cpu;
const Bus = @import("../bus//bus.zig");
const BusCallback = Bus.BusCallback;
const Ram = @import("../bus/ram.zig").Ram;

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
        env.cpu.s = state.s;
        env.cpu.a = state.a;
        env.cpu.x = state.x;
        env.cpu.y = state.y;
        env.cpu.p = @bitCast(state.p);

        for (state.ram orelse unreachable) |data| {
            env.bus.writeByte(data[0], data[1]);
        }
        env.cpu.wait_cycles = 0;
    }

    fn checkState(env: *TestEnv, state: CpuState) bool {
        var is_correct = true;
        is_correct = is_correct and env.cpu.pc == state.pc;
        is_correct = is_correct and env.cpu.s == state.s;
        is_correct = is_correct and env.cpu.a == state.a;
        is_correct = is_correct and env.cpu.x == state.x;
        is_correct = is_correct and env.cpu.y == state.y;
        is_correct = is_correct and @as(u8, @bitCast(env.cpu.p)) == state.p;

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
                .s = env.cpu.s, 
                .a = env.cpu.a, 
                .x = env.cpu.x, 
                .y = env.cpu.y, 
                .p = @as(u8, @bitCast(env.cpu.p)),
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
            test_env.cpu.step();
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

test "ADC Immediate"        { try TestEnv.testOpcode(tests_path ++ "69.json"); }
test "ADC Zero Page"        { try TestEnv.testOpcode(tests_path ++ "65.json"); }
test "ADC Zero Page, X"     { try TestEnv.testOpcode(tests_path ++ "75.json"); }
test "ADC Absolute"         { try TestEnv.testOpcode(tests_path ++ "6D.json"); }
test "ADC Absolute, X"      { try TestEnv.testOpcode(tests_path ++ "7D.json"); }
test "ADC Absolute, Y"      { try TestEnv.testOpcode(tests_path ++ "79.json"); }
test "ADC (Indirect, X)"    { try TestEnv.testOpcode(tests_path ++ "61.json"); }
test "ADC (Indirect), Y"    { try TestEnv.testOpcode(tests_path ++ "71.json"); }

test "AND Immediate"        { try TestEnv.testOpcode(tests_path ++ "29.json"); }
test "AND Zero Page"        { try TestEnv.testOpcode(tests_path ++ "25.json"); }
test "AND Zero Page, X"     { try TestEnv.testOpcode(tests_path ++ "35.json"); }
test "AND Absolute"         { try TestEnv.testOpcode(tests_path ++ "2D.json"); }
test "AND Absolute, X"      { try TestEnv.testOpcode(tests_path ++ "3D.json"); }
test "AND Absolute, Y"      { try TestEnv.testOpcode(tests_path ++ "39.json"); }
test "AND (Indirect, X)"    { try TestEnv.testOpcode(tests_path ++ "21.json"); }
test "AND (Indirect), Y"    { try TestEnv.testOpcode(tests_path ++ "31.json"); }

test "ASL Accumulator"      { try TestEnv.testOpcode(tests_path ++ "0A.json"); }
test "ASL Zero Page"        { try TestEnv.testOpcode(tests_path ++ "06.json"); }
test "ASL Zero Page, X"     { try TestEnv.testOpcode(tests_path ++ "16.json"); }
test "ASL Absolute"         { try TestEnv.testOpcode(tests_path ++ "0E.json"); }
test "ASL Absolute, X"      { try TestEnv.testOpcode(tests_path ++ "1E.json"); }

test "BCC Relative"         { try TestEnv.testOpcode(tests_path ++ "90.json"); }

test "BCS Relative"         { try TestEnv.testOpcode(tests_path ++ "B0.json"); }

test "BEQ Relative"         { try TestEnv.testOpcode(tests_path ++ "F0.json"); }

test "BIT Zero Page"        { try TestEnv.testOpcode(tests_path ++ "24.json"); }
test "BIT Absolute"         { try TestEnv.testOpcode(tests_path ++ "2C.json"); }

test "BMI Relative"         { try TestEnv.testOpcode(tests_path ++ "30.json"); }

test "BNE Relative"         { try TestEnv.testOpcode(tests_path ++ "D0.json"); }

test "BPL Relative"         { try TestEnv.testOpcode(tests_path ++ "10.json"); }

test "BRK Implied"          { try TestEnv.testOpcode(tests_path ++ "00.json"); }

test "BVC Relative"         { try TestEnv.testOpcode(tests_path ++ "50.json"); }

test "BVS Relative"         { try TestEnv.testOpcode(tests_path ++ "70.json"); }

test "CLC Implied"          { try TestEnv.testOpcode(tests_path ++ "18.json"); }

test "CLD Implied"          { try TestEnv.testOpcode(tests_path ++ "D8.json"); }

test "CLI Implied"          { try TestEnv.testOpcode(tests_path ++ "58.json"); }

test "CLV Implied"          { try TestEnv.testOpcode(tests_path ++ "B8.json"); }

test "CMP Immediate"        { try TestEnv.testOpcode(tests_path ++ "C9.json"); }
test "CMP Zero Page"        { try TestEnv.testOpcode(tests_path ++ "C5.json"); }
test "CMP Zero Page, X"     { try TestEnv.testOpcode(tests_path ++ "D5.json"); }
test "CMP Absolute"         { try TestEnv.testOpcode(tests_path ++ "CD.json"); }
test "CMP Absolute, X"      { try TestEnv.testOpcode(tests_path ++ "DD.json"); }
test "CMP Absolute, Y"      { try TestEnv.testOpcode(tests_path ++ "D9.json"); }
test "CMP (Indirect, X)"    { try TestEnv.testOpcode(tests_path ++ "C1.json"); }
test "CMP (Indirect), Y"    { try TestEnv.testOpcode(tests_path ++ "D1.json"); }

test "CPX Immediate"        { try TestEnv.testOpcode(tests_path ++ "E0.json"); }
test "CPX Zero Page"        { try TestEnv.testOpcode(tests_path ++ "E4.json"); }
test "CPX Absolute"         { try TestEnv.testOpcode(tests_path ++ "EC.json"); }

test "CPY Immediate"        { try TestEnv.testOpcode(tests_path ++ "C0.json"); }
test "CPY Zero Page"        { try TestEnv.testOpcode(tests_path ++ "C4.json"); }
test "CPY Absolute"         { try TestEnv.testOpcode(tests_path ++ "CC.json"); }

test "DEC Zero Page"        { try TestEnv.testOpcode(tests_path ++ "C6.json"); }
test "DEC Zero Page, X"     { try TestEnv.testOpcode(tests_path ++ "D6.json"); }
test "DEC Absolute"         { try TestEnv.testOpcode(tests_path ++ "CE.json"); }
test "DEC Absolute, X"      { try TestEnv.testOpcode(tests_path ++ "DE.json"); }

test "DEX Implied"          { try TestEnv.testOpcode(tests_path ++ "CA.json"); }

test "DEY Implied"          { try TestEnv.testOpcode(tests_path ++ "88.json"); }

test "EOR Immediate"        { try TestEnv.testOpcode(tests_path ++ "49.json"); }
test "EOR Zero Page"        { try TestEnv.testOpcode(tests_path ++ "45.json"); }
test "EOR Zero Page, X"     { try TestEnv.testOpcode(tests_path ++ "55.json"); }
test "EOR Absolute"         { try TestEnv.testOpcode(tests_path ++ "4D.json"); }
test "EOR Absolute, X"      { try TestEnv.testOpcode(tests_path ++ "5D.json"); }
test "EOR Absolute, Y"      { try TestEnv.testOpcode(tests_path ++ "59.json"); }
test "EOR (Indirect, X)"    { try TestEnv.testOpcode(tests_path ++ "41.json"); }
test "EOR (Indirect), Y"    { try TestEnv.testOpcode(tests_path ++ "51.json"); }

test "INC Zero Page"        { try TestEnv.testOpcode(tests_path ++ "E6.json"); }
test "INC Zero Page, X"     { try TestEnv.testOpcode(tests_path ++ "F6.json"); }
test "INC Absolute"         { try TestEnv.testOpcode(tests_path ++ "EE.json"); }
test "INC Absolute, X"      { try TestEnv.testOpcode(tests_path ++ "FE.json"); }

test "INX Implied"          { try TestEnv.testOpcode(tests_path ++ "E8.json"); }

test "INY Implied"          { try TestEnv.testOpcode(tests_path ++ "C8.json"); }

test "JMP Absolute"         { try TestEnv.testOpcode(tests_path ++ "4C.json"); }
test "JMP Indirect"         { try TestEnv.testOpcode(tests_path ++ "6C.json"); }

test "JSR Absolute"         { try TestEnv.testOpcode(tests_path ++ "20.json"); }

test "LDA Immediate"        { try TestEnv.testOpcode(tests_path ++ "A9.json"); }
test "LDA Zero Page"        { try TestEnv.testOpcode(tests_path ++ "A5.json"); }
test "LDA Zero Page, X"     { try TestEnv.testOpcode(tests_path ++ "B5.json"); }
test "LDA Absolute"         { try TestEnv.testOpcode(tests_path ++ "AD.json"); }
test "LDA Absolute, X"      { try TestEnv.testOpcode(tests_path ++ "BD.json"); }
test "LDA Absolute, Y"      { try TestEnv.testOpcode(tests_path ++ "B9.json"); }
test "LDA (Indirect, X)"    { try TestEnv.testOpcode(tests_path ++ "A1.json"); }
test "LDA (Indirect), Y"    { try TestEnv.testOpcode(tests_path ++ "B1.json"); }

test "LDX Immediate"        { try TestEnv.testOpcode(tests_path ++ "A2.json"); }
test "LDX Zero Page"        { try TestEnv.testOpcode(tests_path ++ "A6.json"); }
test "LDX Zero Page, Y"     { try TestEnv.testOpcode(tests_path ++ "B6.json"); }
test "LDX Absolute"         { try TestEnv.testOpcode(tests_path ++ "AE.json"); }
test "LDX Absolute, Y"      { try TestEnv.testOpcode(tests_path ++ "BE.json"); }

test "LDY Immediate"        { try TestEnv.testOpcode(tests_path ++ "A0.json"); }
test "LDY Zero Page"        { try TestEnv.testOpcode(tests_path ++ "A4.json"); }
test "LDY Zero Page, X"     { try TestEnv.testOpcode(tests_path ++ "B4.json"); }
test "LDY Absolute"         { try TestEnv.testOpcode(tests_path ++ "AC.json"); }
test "LDY Absolute, X"      { try TestEnv.testOpcode(tests_path ++ "BC.json"); }

test "LSR Immediate"        { try TestEnv.testOpcode(tests_path ++ "4A.json"); }
test "LSR Zero Page"        { try TestEnv.testOpcode(tests_path ++ "46.json"); }
test "LSR Zero Page, X"     { try TestEnv.testOpcode(tests_path ++ "56.json"); }
test "LSR Absolute"         { try TestEnv.testOpcode(tests_path ++ "4E.json"); }
test "LSR Absolute, X"      { try TestEnv.testOpcode(tests_path ++ "5E.json"); }

test "NOP Implied"          { try TestEnv.testOpcode(tests_path ++ "EA.json"); }

test "ORA Immediate"        { try TestEnv.testOpcode(tests_path ++ "09.json"); }
test "ORA Zero Page"        { try TestEnv.testOpcode(tests_path ++ "05.json"); }
test "ORA Zero Page, X"     { try TestEnv.testOpcode(tests_path ++ "15.json"); }
test "ORA Absolute"         { try TestEnv.testOpcode(tests_path ++ "0D.json"); }
test "ORA Absolute, X"      { try TestEnv.testOpcode(tests_path ++ "1D.json"); }
test "ORA Absolute, Y"      { try TestEnv.testOpcode(tests_path ++ "19.json"); }
test "ORA (Indirect, X)"    { try TestEnv.testOpcode(tests_path ++ "01.json"); }
test "ORA (Indirect), Y"    { try TestEnv.testOpcode(tests_path ++ "11.json"); }

test "PHA Implied"          { try TestEnv.testOpcode(tests_path ++ "48.json"); }

test "PHP Implied"          { try TestEnv.testOpcode(tests_path ++ "08.json"); }

test "PLA Implied"          { try TestEnv.testOpcode(tests_path ++ "68.json"); }

test "PLP Implied"          { try TestEnv.testOpcode(tests_path ++ "28.json"); }

test "ROL Immediate"        { try TestEnv.testOpcode(tests_path ++ "2A.json"); }
test "ROL Zero Page"        { try TestEnv.testOpcode(tests_path ++ "26.json"); }
test "ROL Zero Page, X"     { try TestEnv.testOpcode(tests_path ++ "36.json"); }
test "ROL Absolute"         { try TestEnv.testOpcode(tests_path ++ "2E.json"); }
test "ROL Absolute, X"      { try TestEnv.testOpcode(tests_path ++ "3E.json"); }

test "ROR Immediate"        { try TestEnv.testOpcode(tests_path ++ "6A.json"); }
test "ROR Zero Page"        { try TestEnv.testOpcode(tests_path ++ "66.json"); }
test "ROR Zero Page, X"     { try TestEnv.testOpcode(tests_path ++ "76.json"); }
test "ROR Absolute"         { try TestEnv.testOpcode(tests_path ++ "6E.json"); }
test "ROR Absolute, X"      { try TestEnv.testOpcode(tests_path ++ "7E.json"); }

test "RTI Implied"          { try TestEnv.testOpcode(tests_path ++ "40.json"); }

test "RTS Implied"          { try TestEnv.testOpcode(tests_path ++ "60.json"); }

test "SBC Immediate"        { try TestEnv.testOpcode(tests_path ++ "E9.json"); }
test "SBC Zero Page"        { try TestEnv.testOpcode(tests_path ++ "E5.json"); }
test "SBC Zero Page, X"     { try TestEnv.testOpcode(tests_path ++ "F5.json"); }
test "SBC Absolute"         { try TestEnv.testOpcode(tests_path ++ "ED.json"); }
test "SBC Absolute, X"      { try TestEnv.testOpcode(tests_path ++ "FD.json"); }
test "SBC Absolute, Y"      { try TestEnv.testOpcode(tests_path ++ "F9.json"); }
test "SBC (Indirect, X)"    { try TestEnv.testOpcode(tests_path ++ "E1.json"); }
test "SBC (Indirect), Y"    { try TestEnv.testOpcode(tests_path ++ "F1.json"); }

test "SEC Implied"          { try TestEnv.testOpcode(tests_path ++ "38.json"); }

test "SED Implied"          { try TestEnv.testOpcode(tests_path ++ "F8.json"); }

test "SEI Implied"          { try TestEnv.testOpcode(tests_path ++ "78.json"); }

test "STA Zero Page"        { try TestEnv.testOpcode(tests_path ++ "85.json"); }
test "STA Zero Page, X"     { try TestEnv.testOpcode(tests_path ++ "95.json"); }
test "STA Absolute"         { try TestEnv.testOpcode(tests_path ++ "8D.json"); }
test "STA Absolute, X"      { try TestEnv.testOpcode(tests_path ++ "9D.json"); }
test "STA Absolute, Y"      { try TestEnv.testOpcode(tests_path ++ "99.json"); }
test "STA (Indirect, X)"    { try TestEnv.testOpcode(tests_path ++ "81.json"); }
test "STA (Indirect), Y"    { try TestEnv.testOpcode(tests_path ++ "91.json"); }

test "STX Zero Page"        { try TestEnv.testOpcode(tests_path ++ "86.json"); }
test "STX Zero Page, Y"     { try TestEnv.testOpcode(tests_path ++ "96.json"); }
test "STX Absolute"         { try TestEnv.testOpcode(tests_path ++ "8E.json"); }

test "STY Zero Page"        { try TestEnv.testOpcode(tests_path ++ "84.json"); }
test "STY Zero Page, X"     { try TestEnv.testOpcode(tests_path ++ "94.json"); }
test "STY Absolute"         { try TestEnv.testOpcode(tests_path ++ "8C.json"); }

test "TAX Implied"          { try TestEnv.testOpcode(tests_path ++ "AA.json"); }

test "TAY Implied"          { try TestEnv.testOpcode(tests_path ++ "A8.json"); }

test "TSX Implied"          { try TestEnv.testOpcode(tests_path ++ "BA.json"); }

test "TXA Implied"          { try TestEnv.testOpcode(tests_path ++ "8A.json"); }

test "TXS Implied"          { try TestEnv.testOpcode(tests_path ++ "9A.json"); }

test "TYA Implied"          { try TestEnv.testOpcode(tests_path ++ "98.json"); }