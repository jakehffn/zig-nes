const std = @import("std");
const mode = @import("builtin").mode;

const MainBus = @import("./main_bus.zig");
const OpCode = @import("./opcode.zig");

const cpu_log_file = @import("../../main.zig").Frontend.cpu_log_file;
const logging_enabled = !(cpu_log_file == null or mode != .Debug);

const Self = @This();

pc: u16 = 0xC000,   // Program counter
s: u8 = 0xFD,       // Stack pointer
a: u8 = 0,          // Accumulator
x: u8 = 0,          // X register
y: u8 = 0,          // Y register
p: Flags = @bitCast(@as(u8, 0x24)), // Processor status flags

bus: *MainBus,
nmi: *bool,
irq: *bool,

total_cycles: u32 = 0,
step_cycles: u8 = 0,
wait_cycles: u8 = 0,

curr_step: struct {
    pc: u16 = 0,
    instruction: OpCode.Instruction = .{},
    operand: u8 = 0,
    operand_address: u16 = 0,
    indirect_address: u16 = 0,
    bytes: [3]u8 = [_]u8{0, 0, 0},
    num_bytes: u16 = 0,
    total_cycles: u32 = 0
} = .{},

log_file: std.fs.File,
should_log: bool = false,

/// CPU status register layout
/// 
/// In the NES, the D (decimal mode) flag has no effect
/// 
/// Bits 5 and 4 don't represent state, but how the value was pushed to the stack
/// Bit 5 should always be set, but bit 4, when not set, indicates that the value
/// was pushed to the stack while processing an interrupt.
const Flags = packed struct {
    C: u1 = 0, // Carry
    Z: u1 = 0, // Zero
    I: u1 = 0, // Interrupt Disable
    D: u1 = 0, // Decimal Mode
    B: u1 = 0, // Break Command
    must_be_one: u1 = 1,
    V: u1 = 0, // Overflow
    N: u1 = 0, // Negative
};

pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    _ = options;
    _ = fmt;
    // Program counter at instruction first byte
    try writer.print("{X:0>4}  ", .{self.curr_step.pc});
    // All bytes of instruction
    for (0..3) |i| {
        if (i < self.curr_step.num_bytes) {
            try writer.print("{X:0>2} ", .{self.curr_step.bytes[i]});
        } else {
            try writer.print("   ", .{});
        }
    }
    // Instruction mnemonic
    // Take slice of first 3 characters to avoid versions addressing mode.secific names
    try writer.print(" {s} ", .{@tagName(self.curr_step.instruction.mnemonic)[0..3]});
    // Operand data, per addressing mode
    switch(self.curr_step.instruction.addressing_mode) {
        .accumulator => {
            try writer.print("A" ++ (" " ** 27), .{});
        },
        .absolute, .relative => {
            try writer.print("${X:0>4}" ++ (" " ** 23), .{self.curr_step.operand_address});
        },
        .absolute_x => {
            try writer.print("${X:0>4},X @ {X:0>4} = {X:0>2}"  ++ (" " ** 9), .{
                self.curr_step.operand_address -% self.x, 
                self.curr_step.operand_address, 
                0x0
            });
        },
        .absolute_y => {
            try writer.print("${X:0>4},Y @ {X:0>4} = {X:0>2}" ++ (" " ** 9), .{
                self.curr_step.operand_address -% self.y, 
                self.curr_step.operand_address, 
                0x0
            });
        },
        .immediate => {
            try writer.print("#${X:0>2}" ++ (" " ** 24), .{0x0});
        },
        .implied => {
            try writer.print(" " ** 28, .{});
        },
        .indirect => {
            try writer.print("(${X:0>4}) = {X:0>4}" ++ (" " ** 14), .{
                (@as(u16, self.curr_step.bytes[2]) << 8) | self.curr_step.bytes[1], 
                self.curr_step.operand_address
            });
        },
        .indirect_x => {
            try writer.print("(${X:0>2},X) @ {X:0>2} = {X:0>4} = {X:0>2}    ", .{
                self.curr_step.bytes[1], 
                self.curr_step.bytes[1] +% self.x, 
                self.curr_step.operand_address, 
                0x0
            });
        },
        .indirect_y => {
            try writer.print("(${X:0>2}),Y = {X:0>4} @ {X:0>4} = {X:0>2}  ", .{
                self.curr_step.bytes[1],
                self.curr_step.operand_address -% self.y,
                self.curr_step.operand_address,
                0x0
            });
        },
        .zero_page => {
            try writer.print("${X:0>2} = {X:0>2}" ++ (" " ** 20), .{self.curr_step.operand_address, 0x0});
        },
        .zero_page_x => {
            try writer.print("${X:0>2},X @ {X:0>2} = {X:0>2}" ++ (" " ** 13), .{
                self.curr_step.operand_address -% self.x, 
                self.curr_step.operand_address, 
                0x0
            });
        },
        .zero_page_y => {
            try writer.print("${X:0>2},Y @ {X:0>2} = {X:0>2}"  ++ (" " ** 13), .{
                self.curr_step.operand_address -% self.y, 
                self.curr_step.operand_address, 
                0x0
            });
        }
    }

    try writer.print("A:{X:0>2} X:{X:0>2} Y:{X:0>2} P:{X:0>2} S:{X:0>2} PPU:{d: >3},{d: >3} CYC:{d: >5}", .{
        self.a,
        self.x,
        self.y,
        @as(u8, @bitCast(self.p)),
        self.s,
        0,
        0,
        self.curr_step.total_cycles
    });
}

pub fn init() !Self {
    return .{
        .bus = undefined,
        .nmi = undefined,
        .irq = undefined,
        .log_file = blk: {
            if (!logging_enabled) {
                break :blk undefined;
            }
            break :blk try std.fs.cwd().createFile(
                cpu_log_file.?, 
                .{}
            );
        }
    };
}

pub fn deinit(self: *Self) void {
    if (logging_enabled) {
        self.log_file.close();
    }
}

pub fn connectMainBus(self: *Self, main_bus: *MainBus) void {
    self.bus = main_bus;
    self.nmi = &main_bus.nmi;
    self.irq = &main_bus.irq;
}

fn nonMaskableInterrupt(self: *Self) void {
    self.stackPush(@truncate(self.pc >> 8));
    self.stackPush(@truncate(self.pc));
    self.stackPush(@bitCast(self.p));
    self.p.I = 1;
    // Note interrupt vector location
    const addr_low: u16 = self.bus.read(0xFFFA);
    const addr_high: u16 = self.bus.read(0xFFFB);
    self.pc = (addr_high << 8) | addr_low;
    self.total_cycles +|= 7;
    self.nmi.* = false;
}

pub fn reset(self: *Self) void {
    // Note interrupt vector location
    const addr_low: u16 = self.bus.read(0xFFFC);
    const addr_high: u16 = self.bus.read(0xFFFD);
    self.pc = (addr_high << 8) | addr_low;
    self.total_cycles = 8;

    self.p = @bitCast(@as(u8, 0));
    self.a = 0;
    self.x = 0;
    self.y = 0;
    self.total_cycles = 0;
    self.wait_cycles = 0;
}

fn interruptRequest(self: *Self) void {
    self.stackPush(@truncate(self.pc >> 8));
    self.stackPush(@truncate(self.pc));
    self.stackPush(@bitCast(self.p));
    self.p.I = 1;
    // Note interrupt vector location
    const addr_low: u16 = self.bus.read(0xFFFE);
    const addr_high: u16 = self.bus.read(0xFFFF);
    self.pc = (addr_high << 8) | addr_low;
    self.total_cycles +|= 7;
    self.irq.* = false;
}

pub fn step(self: *Self) void {
    if (self.wait_cycles > 0) {
        self.wait_cycles -= 1;
        return;
    }

    if (self.nmi.*) {
        self.nonMaskableInterrupt();
    }

    if (self.irq.* and self.p.I == 0) {
        self.interruptRequest();
    }

    self.step_cycles = 0;

    self.curr_step.total_cycles = self.total_cycles;
    self.curr_step.bytes[0] = self.bus.read(self.pc);
    self.curr_step.pc = self.pc;
    self.pc +%= 1;

    self.curr_step.instruction = OpCode.instructions[self.curr_step.bytes[0]];
    self.loadInstruction();
    self.curr_step.num_bytes = self.pc -| self.curr_step.pc;
    
    if (logging_enabled) {
        if (self.should_log) {
            self.log_file.writer().print("{any}\n", .{self.*}) catch {};
        }
    }

    self.step_cycles += OpCode.cycles[self.curr_step.bytes[0]];
    self.execute();
    self.total_cycles +%= self.step_cycles;

    self.wait_cycles = self.step_cycles -| 1;
}

inline fn branch(self: *Self, address: u16) void {
    if ((self.pc >> 8) == (address >> 8)) {
        self.step_cycles += 1;
    } else {
        self.step_cycles += 2;
    }
    self.pc = address;
} 

inline fn stackPush(self: *Self, value: u8) void {
    self.bus.write(0x100 | @as(u16, self.s), value);
    self.s -%= 1;
}

inline fn stackPop(self: *Self) u8 {
    self.s +%= 1;
    return self.bus.read(0x100 | @as(u16, self.s));
}

inline fn setFlagsNZ(self: *Self, value: u8) void {
    self.p.N = @truncate(value >> 7);
    self.p.Z = @bitCast(value == 0);
}

inline fn loadInstruction(self: *Self) void {
    self.curr_step.operand_address = switch(self.curr_step.instruction.addressing_mode) {
        .accumulator => 0,
        .absolute => blk: {
            self.curr_step.bytes[1] = self.bus.read(self.pc);
            self.curr_step.bytes[2] = self.bus.read(self.pc +% 1);
            const addr_low: u16 = self.curr_step.bytes[1];
            const addr_high: u16 = self.curr_step.bytes[2];
            self.pc +%= 2;

            const addr: u16 = (addr_high << 8) | addr_low;
            break :blk addr;
        },
        .absolute_x => blk: {
            // TODO: Add cycle for page crossing
            self.curr_step.bytes[1] = self.bus.read(self.pc);
            self.curr_step.bytes[2] = self.bus.read(self.pc +% 1);
            const addr_low: u16 = self.curr_step.bytes[1];
            const addr_high: u16 = self.curr_step.bytes[2];
            self.pc +%= 2;

            const addr: u16 = ((addr_high << 8) | addr_low) +% self.x;
            break :blk addr;
        },
        .absolute_y => blk: {
            // TODO: Add cycle for page crossing
            self.curr_step.bytes[1] = self.bus.read(self.pc);
            self.curr_step.bytes[2] = self.bus.read(self.pc +% 1);
            const addr_low: u16 = self.curr_step.bytes[1];
            const addr_high: u16 = self.curr_step.bytes[2];
            self.pc +%= 2;

            const addr: u16 = ((addr_high << 8) | addr_low) +% self.y;
            break :blk addr;
        },
        .immediate => blk: {
            const addr = self.pc;
            self.curr_step.bytes[1] = self.bus.read(self.pc);
            self.pc +%= 1;

            break :blk addr;
        },
        // Implied does not require an address or value
        .implied => 0,
        .indirect => blk: {
            // Indirect is only used by the JMP instruction, so no need to get value
            self.curr_step.bytes[1] = self.bus.read(self.pc);
            self.curr_step.bytes[2] = self.bus.read(self.pc +% 1);
            const addr_low: u8 = @as(u8, self.curr_step.bytes[1]);
            const addr_high: u16 = self.curr_step.bytes[2];
            self.pc +%= 2;

            const target_addr_low: u16 = (addr_high << 8) | addr_low;
            const target_addr_high: u16 = (addr_high << 8) | (addr_low +% 1);
            self.curr_step.indirect_address = target_addr_low;

            const target_low: u16 = self.bus.read(target_addr_low);
            const target_high: u16 = self.bus.read(target_addr_high);
            const target: u16 = (target_high << 8) | target_low; 
            break :blk target;
        },
        .indirect_x => blk: {
            self.curr_step.bytes[1] = self.bus.read(self.pc);
            const indirect_addr = self.curr_step.bytes[1] +% self.x;
            self.curr_step.indirect_address = indirect_addr;
            self.pc +%= 1;

            const addr_low: u16 = self.bus.read(indirect_addr);
            const addr_high: u16 = self.bus.read(indirect_addr +% 1);
            const addr: u16 = (addr_high << 8) | addr_low;
            break :blk addr;
        },
        .indirect_y => blk: {
            // TODO: Add cycle for page crossing
            self.curr_step.bytes[1] = self.bus.read(self.pc);
            const indirect_addr = self.curr_step.bytes[1];
            self.curr_step.indirect_address = indirect_addr;
            self.pc +%= 1;

            const addr_low: u16 = self.bus.read(indirect_addr);
            const addr_high: u16 = self.bus.read(indirect_addr +% 1);
            const addr: u16 = ((addr_high << 8) | addr_low) +% @as(u16, self.y);
            break :blk addr;
        },
        .relative => blk: {
            // Relative is only used by the branch instructions, so no need to get value
            // Relative addressing adds a signed value to pc, so the values can be cast to signed integers to get signed addition
            self.curr_step.bytes[1] = self.bus.read(self.pc);
            const addr: u16 = @bitCast(@as(i8, @bitCast(self.curr_step.bytes[1])) +% @as(i16, @bitCast(self.pc)) +% 1);
            self.pc +%= 1;

            break :blk addr;
        },
        .zero_page => blk: { 
            self.curr_step.bytes[1] = self.bus.read(self.pc);
            const addr = self.curr_step.bytes[1];
            self.pc +%= 1;

            break :blk addr;
        },
        .zero_page_x => blk: { 
            self.curr_step.bytes[1] = self.bus.read(self.pc);
            const addr = self.curr_step.bytes[1] +% self.x;
            self.pc +%= 1;

            break :blk addr;
        },
        .zero_page_y => blk: {
            self.curr_step.bytes[1] = self.bus.read(self.pc);
            const addr = self.curr_step.bytes[1] +% self.y;
            self.pc +%= 1;

            break :blk addr;
        }
    };
}

inline fn execute(self: *Self) void {
    switch(self.curr_step.instruction.mnemonic) { 
        .ADC => { 
            const add_op = self.bus.read(self.curr_step.operand_address);
            const op = self.a;
            self.a = op +% add_op +% self.p.C;
            // Overflow occurs iff the result has a different sign than both operands
            self.p.V = @truncate(((self.a ^ op) & (self.a ^ add_op)) >> 7);
            self.p.C = @bitCast(self.a < (@as(u16, add_op) +% self.p.C));
            self.setFlagsNZ(self.a);
        },
        .AND => {
            const op = self.a;
            self.a = op & self.bus.read(self.curr_step.operand_address);
            self.setFlagsNZ(self.a);
        },
        .ASL => {
            const op = self.bus.read(self.curr_step.operand_address);
            const res = op << 1;
            self.bus.write(self.curr_step.operand_address, res);
            self.p.C = @truncate(op >> 7);
            self.setFlagsNZ(res);
        },
        .ASL_acc => {
            self.p.C = @truncate(self.a >> 7);
            self.a <<= 1;
            self.setFlagsNZ(self.a);
        },
        .BCC => {
            if (self.p.C == 0) {
                self.branch(self.curr_step.operand_address);
            }
        },
        .BCS => {
            if (self.p.C == 1) {
                self.branch(self.curr_step.operand_address);
            }
        },
        .BEQ => {
            if (self.p.Z == 1) {
                self.branch(self.curr_step.operand_address);
            }
        },
        .BIT => {
            const op = self.bus.read(self.curr_step.operand_address);
            self.p.Z = @bitCast((self.a & op) == 0);
            self.p.V = @truncate(op >> 6);
            self.p.N = @truncate(op >> 7);
        },
        .BMI => {
            if (self.p.N == 1) {
                self.branch(self.curr_step.operand_address);
            }
        },
        .BNE => {
            if (self.p.Z == 0) {
                self.branch(self.curr_step.operand_address);
            }
        },
        .BPL => {
            if (self.p.N == 0) {
                self.branch(self.curr_step.operand_address);
            }
        },
        .BRK => {
            const stored_pc = self.pc +% 1;
            self.stackPush(@truncate(stored_pc >> 8));
            self.stackPush(@truncate(stored_pc));
            self.p.B = 1;
            self.stackPush(@bitCast(self.p));
            self.p.B = 0;
            self.p.I = 1;
            const addr_low: u16 = self.bus.read(0xFFFE);
            const addr_high: u16 = self.bus.read(0xFFFF);
            self.pc = (addr_high << 8) | addr_low;
        },
        .BVC => {
            if (self.p.V == 0) {
                self.branch(self.curr_step.operand_address);
            }
        },
        .BVS => {
            if (self.p.V == 1) {
                self.branch(self.curr_step.operand_address);
            }
        },
        .CLC => {
            self.p.C = 0;
        },
        .CLD => {
            self.p.D = 0;
        },
        .CLI => {
            self.p.I = 0;
        },
        .CLV => {
            self.p.V = 0;
        },
        .CMP => {
            const op = self.bus.read(self.curr_step.operand_address);
            const res = self.a -% op;
            self.p.C = @bitCast(self.a >= op);
            self.setFlagsNZ(res);
        },
        .CPX => {
            const op = self.bus.read(self.curr_step.operand_address);
            const res = self.x -% op;
            self.p.C = @bitCast(self.x >= op);
            self.setFlagsNZ(res);
        },
        .CPY => {
            const op = self.bus.read(self.curr_step.operand_address);
            const res = self.y -% op;
            self.p.C = @bitCast(self.y >= op);
            self.setFlagsNZ(res);
        },
        .DEC => {
            const res = self.bus.read(self.curr_step.operand_address) -% 1;
            self.bus.write(self.curr_step.operand_address, res);
            self.setFlagsNZ(res);
        },
        .DEX => {
            self.x -%= 1;
            self.setFlagsNZ(self.x);
        },
        .DEY => {
            self.y -%= 1;
            self.setFlagsNZ(self.y);
        },
        .EOR => {
            const op = self.a;
            self.a = op ^ self.bus.read(self.curr_step.operand_address);
            self.setFlagsNZ(self.a);
        },
        .INC => {
            const res = self.bus.read(self.curr_step.operand_address) +% 1;
            self.bus.write(self.curr_step.operand_address, res);
            self.setFlagsNZ(res);
        },
        .INX => {
            self.x +%= 1;
            self.setFlagsNZ(self.x);
        },
        .INY => {
            self.y +%= 1;
            self.setFlagsNZ(self.y);
        },
        .JMP => {
            self.branch(self.curr_step.operand_address);
        },
        .JSR => {
            const stored_pc = self.pc -% 1;
            self.stackPush(@truncate(stored_pc >> 8));
            self.stackPush(@truncate(stored_pc));
            self.pc = self.curr_step.operand_address;
        },
        .LDA => {
            self.a = self.bus.read(self.curr_step.operand_address);
            self.setFlagsNZ(self.a);
        },
        .LDX => {
            self.x = self.bus.read(self.curr_step.operand_address);
            self.setFlagsNZ(self.x);
        },
        .LDY => {
            self.y = self.bus.read(self.curr_step.operand_address);
            self.setFlagsNZ(self.y);
        },
        .LSR => { 
            const op = self.bus.read(self.curr_step.operand_address);
            const res = op >> 1;
            self.bus.write(self.curr_step.operand_address, res);
            self.p.C = @truncate(op);
            self.setFlagsNZ(res);
        },
        .LSR_acc => {
            self.p.C = @truncate(self.a);
            self.a >>= 1;
            self.setFlagsNZ(self.a);
        },
        .NOP => {},
        .ORA => {
            const op = self.a;
            self.a = op | self.bus.read(self.curr_step.operand_address);
            self.setFlagsNZ(self.a);
        },
        .PHA => {
            self.stackPush(self.a);
        },
        .PHP => {
            var op = self.p;
            op.must_be_one = 1;
            op.B = 1;
            self.stackPush(@bitCast(op));
        },
        .PLA => { 
            self.a = self.stackPop();
            self.setFlagsNZ(self.a);
        },
        .PLP => {
            self.p = @bitCast(self.stackPop());
            self.p.must_be_one = 1;
            self.p.B = 0;
        },
        .ROL => {
            const op = self.bus.read(self.curr_step.operand_address);
            const res = (op << 1) | self.p.C;
            self.bus.write(self.curr_step.operand_address, res);
            self.p.C = @truncate(op >> 7);
            self.setFlagsNZ(res);
        },
        .ROL_acc => {                
            const res = (self.a << 1) | self.p.C;
            self.p.C = @truncate(self.a >> 7);
            self.a = res;
            self.setFlagsNZ(self.a); 
        },
        .ROR => {
            const op = self.bus.read(self.curr_step.operand_address);
            const res = (op >> 1) | (@as(u8, self.p.C) << 7);
            self.bus.write(self.curr_step.operand_address, res);
            self.p.C = @truncate(op);
            self.setFlagsNZ(res);
        },
        .ROR_acc => {
            const op = self.a;          
            self.a = (self.a >> 1) | (@as(u8, self.p.C) << 7);
            self.p.C = @truncate(op);
            self.setFlagsNZ(self.a);
        },
        .RTI => { 
            self.p = @bitCast(self.stackPop());
            self.p.must_be_one = 1;
            self.p.B = 0;
            const addr_low: u16 = self.stackPop();
            const addr_high: u16 = self.stackPop();
            self.pc = (addr_high << 8) | addr_low;
        },
        .RTS => {
            const addr_low: u16 = self.stackPop();
            const addr_high: u16 = self.stackPop();
            self.pc = ((addr_high << 8) | addr_low) +% 1;
        },
        .SBC => {
            const sub_op = self.bus.read(self.curr_step.operand_address);
            const op = self.a;
            self.a = op -% sub_op -% (1 - self.p.C);
            // Overflow will occur iff the operands have different signs, and 
            //      the result has a different sign than the minuend
            self.p.V = @truncate(((op ^ sub_op) & (op ^ self.a)) >> 7);
            self.p.C = @bitCast((@as(u16, sub_op) +% (1 - self.p.C)) <= op);
            self.setFlagsNZ(self.a);
        },
        .SEC => {
            self.p.C = 1;
        },
        .SED => {
            self.p.D = 1;
        },
        .SEI => {
            self.p.I = 1;
        },
        .STA => {
            self.bus.write(self.curr_step.operand_address, self.a);
        },
        .STX => {
            self.bus.write(self.curr_step.operand_address, self.x);
        },
        .STY => {
            self.bus.write(self.curr_step.operand_address, self.y);
        },
        .TAX => {
            self.x = self.a;
            self.setFlagsNZ(self.x);
        },
        .TAY => {
            self.y = self.a;
            self.setFlagsNZ(self.y);
        },
        .TSX => {
            self.x = self.s;
            self.setFlagsNZ(self.x);
        },
        .TXA => {
            self.a = self.x;
            self.setFlagsNZ(self.a);
        },
        .TXS => {
            self.s = self.x;
        },
        .TYA => {
            self.a = self.y;
            self.setFlagsNZ(self.a);
        }
    }
}