const std = @import("std");
const cpu_execute_log = std.log.scoped(.cpu_execute);

const Bus = @import("./bus.zig").Bus;

pub fn CPU(comptime log_file_path: ?[]const u8) type { 
    return struct {
        const Self = @This();

        pc: u16 = 0,
        sp: u8 = 0xFD, // Documented startup value
        a: u8 = 0,
        x: u8 = 0,
        y: u8 = 0,
        flags: Flags = .{},
        bus: *Bus,
        total_cycles: u32 = 0,
        log_file: std.fs.File,

        const Flags = packed struct {
            N: u1 = 0, // Negative
            V: u1 = 0, // Overflow
            _: u1 = 1,
            B: u1 = 0, // Break Command
            D: u1 = 0, // Decimal Mode
            I: u1 = 0, // Interrupt Disable
            Z: u1 = 0, // Zero
            C: u1 = 0, // Carry
        };

        const Mnemonic = enum {
            ADC,
            AND,
            ASL,
            ASL_acc,
            BCC,
            BCS,
            BEQ,
            BIT,
            BMI,
            BNE,
            BPL,
            BRK,
            BVC,
            BVS,
            CLC,
            CLD,
            CLI,
            CLV,
            CMP,
            CPX,
            CPY,
            DEC,
            DEX,
            DEY,
            EOR,
            INC,
            INX,
            INY,
            JMP,
            JSR,
            LDA,
            LDX,
            LDY,
            LSR,
            LSR_acc,
            NOP,
            ORA,
            PHA,
            PHP,
            PLA,
            PLP,
            ROL,
            ROL_acc,
            ROR,
            ROR_acc,
            RTI,
            RTS,
            SBC,
            SEC,
            SED,
            SEI,
            STA,
            STX,
            STY,
            TAX,
            TAY,
            TSX,
            TXA,
            TXS,
            TYA
        };

        const AddressingMode = enum {
            accumulator,
            absolute,
            absolute_x,
            absolute_y,
            immediate,
            implied,
            indirect,
            indirect_x,
            indirect_y,
            relative,
            zero_page,
            zero_page_x,
            zero_page_y
        };

        const Instruction = struct {
            mnemonic: Mnemonic = .NOP,
            addressing_mode: AddressingMode = .implied
        };

        pub const Byte = packed union {
            raw: u8,    
            data: packed struct {
                group: u2,
                addressing_mode: u3,
                mnemonic: u3
            }
        };

        const Operand = struct {
            address: u16 = 0,
            value: u8 = 0
        };

        const StepLogData = struct {
            pc: u16,
            mnemonic: Mnemonic,
            addressing_mode: AddressingMode,
            operand: Operand,
            cpu: *Self,

            pub fn format(value: StepLogData, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
                _ = options;
                _ = fmt;
                // Program counter at instruction first byte
                try writer.print("{X:0>4}  ", .{value.pc});
                // All bytes of instruction
                var bytes = [_]u16{0xFF, 0xFF, 0xFF};
                const read_bytes = value.cpu.pc - value.pc;
                for (0..3) |i| {
                    if (i < read_bytes) {
                        bytes[i] = value.cpu.bus.read_byte(value.pc + @truncate(u8, i));
                        try writer.print("{X:0>2} ", .{bytes[i]});
                    } else {
                        try writer.print("   ", .{});
                    }
                }
                // Instruction mnemonic
                // Take slice of first 3 characters to avoid versions addressing mode specific names
                try writer.print(" {s} ", .{@tagName(value.mnemonic)[0..3]});
                // Operand data, per addressing mode
                switch(value.addressing_mode) {
                    .accumulator => {
                        try writer.print("A" ++ (" " ** 27), .{});
                    },
                    .absolute, .relative => {
                        try writer.print("${X:0>4}" ++ (" " ** 23), .{value.operand.address});
                    },
                    .absolute_x => {
                        try writer.print("${X:0>4},X @ {X:0>4} = {X:0>2}"  ++ (" " ** 10), .{
                            value.operand.address - value.cpu.x, 
                            value.operand.address, 
                            value.operand.value
                        });
                    },
                    .absolute_y => {
                        try writer.print("${X:0>4},Y @ {X:0>4} = {X:0>2}" ++ (" " ** 10), .{
                            value.operand.address - value.cpu.y, 
                            value.operand.address, 
                            value.operand.value
                        });
                    },
                    .immediate => {
                        try writer.print("#${X:0>2}" ++ (" " ** 24), .{value.operand.address});
                    },
                    .implied => {
                        try writer.print(" " ** 28, .{});
                    },
                    .indirect => {
                        try writer.print("(${X:0>4}) = {X:0>4}" ++ (" " ** 14), .{
                            (@as(u16, bytes[2]) << 8) | bytes[1], 
                            value.operand.address
                        });
                    },
                    .indirect_x => {
                        try writer.print("(${X:0>2},X) @ {X:0>2} = {X:0>4} = {X:0>2}    ", .{
                            bytes[1], 
                            bytes[1] +% value.cpu.x, 
                            value.operand.address, 
                            value.operand.value
                        });
                    },
                    .indirect_y => {
                        try writer.print("(${X:0>2}),Y @ {X:0>4} = {X:0>4} = {X:0>2}  ", .{
                            bytes[1],
                            value.operand.address - value.cpu.y,
                            value.operand.address,
                            value.operand.value
                        });
                    },
                    .zero_page => {
                        try writer.print("${X:0>2} = {X:0>2}" ++ (" " ** 20), .{value.operand.address, value.operand.value});
                    },
                    .zero_page_x => {
                        try writer.print("${X:0>2},X @ {X:0>2} = {X:0>2}" ++ (" " ** 13), .{
                            value.operand.address - value.cpu.x, 
                            value.operand.address, 
                            value.operand.value
                        });
                    },
                    .zero_page_y => {
                        try writer.print("${X:0>2},Y @ {X:0>2} = {X:0>2}"  ++ (" " ** 13), .{
                            value.operand.address - value.cpu.y, 
                            value.operand.address, 
                            value.operand.value
                        });
                    }
                }

                try writer.print("A:{X:0>2} X:{X:0>2} Y:{X:0>2} P:{X:0>2} SP:{X:0>2} PPU:{d: >3},{d: >3} CYC:{d: >5}", .{
                    value.cpu.a,
                    value.cpu.x,
                    value.cpu.y,
                    @bitCast(u8, value.cpu.flags),
                    value.cpu.sp,
                    0,
                    0,
                    value.cpu.total_cycles
                });
            }
        };

        // [mnemonic][group]
        const mnemonic = [8][3]?Mnemonic {
            [_]?Mnemonic {null, .ORA, .ASL},
            [_]?Mnemonic {.BIT, .AND, .ROL},
            [_]?Mnemonic {.JMP, .EOR, .LSR},
            [_]?Mnemonic {null, .ADC, .ROR},
            [_]?Mnemonic {.STY, .STA, .STX},
            [_]?Mnemonic {.LDY, .LDA, .LDX},
            [_]?Mnemonic {.CPY, .CMP, .DEC},
            [_]?Mnemonic {.CPX, .SBC, .INC}
        };

        // [addr_mode][group]
        const addressing_mode = [8][3]?AddressingMode {
            [_]?AddressingMode {.immediate, .indirect_x, .immediate},
            [_]?AddressingMode {.zero_page, .zero_page, .zero_page},
            [_]?AddressingMode {null, .immediate, .accumulator},
            [_]?AddressingMode {.absolute, .absolute, .absolute},
            [_]?AddressingMode {null, .indirect_y, null},
            [_]?AddressingMode {.zero_page_x, .zero_page_x, .zero_page_x},
            [_]?AddressingMode {null, .absolute_y, null},
            [_]?AddressingMode {.absolute_x, .absolute_x, .absolute_x}
        };

        const instruction_exception = init: {
            var defaults = [_]?Instruction{null}**0x100;
            // Branching instructions
            defaults[0x10] = .{.mnemonic = .BPL, .addressing_mode = .relative}; 
            defaults[0x30] = .{.mnemonic = .BMI, .addressing_mode = .relative}; 
            defaults[0x50] = .{.mnemonic = .BVC, .addressing_mode = .relative}; 
            defaults[0x70] = .{.mnemonic = .BVS, .addressing_mode = .relative}; 
            defaults[0x90] = .{.mnemonic = .BCC, .addressing_mode = .relative}; 
            defaults[0xB0] = .{.mnemonic = .BCS, .addressing_mode = .relative}; 
            defaults[0xD0] = .{.mnemonic = .BNE, .addressing_mode = .relative}; 
            defaults[0xF0] = .{.mnemonic = .BEQ, .addressing_mode = .relative}; 
            // Interrupt and subroutine instructions
            defaults[0x00] = .{.mnemonic = .BRK, .addressing_mode = .implied}; 
            defaults[0x20] = .{.mnemonic = .JSR, .addressing_mode = .absolute}; 
            defaults[0x40] = .{.mnemonic = .RTI, .addressing_mode = .implied}; 
            defaults[0x60] = .{.mnemonic = .RTS, .addressing_mode = .implied}; 

            defaults[0x08] = .{.mnemonic = .PHP, .addressing_mode = .implied}; 
            defaults[0x28] = .{.mnemonic = .PLP, .addressing_mode = .implied}; 
            defaults[0x48] = .{.mnemonic = .PHA, .addressing_mode = .implied}; 
            defaults[0x68] = .{.mnemonic = .PLA, .addressing_mode = .implied}; 
            defaults[0x88] = .{.mnemonic = .DEY, .addressing_mode = .implied}; 
            defaults[0xA8] = .{.mnemonic = .TAY, .addressing_mode = .implied}; 
            defaults[0xC8] = .{.mnemonic = .INY, .addressing_mode = .implied}; 
            defaults[0xE8] = .{.mnemonic = .INX, .addressing_mode = .implied}; 

            defaults[0x18] = .{.mnemonic = .CLC, .addressing_mode = .implied}; 
            defaults[0x38] = .{.mnemonic = .SEC, .addressing_mode = .implied}; 
            defaults[0x58] = .{.mnemonic = .CLI, .addressing_mode = .implied}; 
            defaults[0x78] = .{.mnemonic = .SEI, .addressing_mode = .implied}; 
            defaults[0x98] = .{.mnemonic = .TYA, .addressing_mode = .implied}; 
            defaults[0xB8] = .{.mnemonic = .CLV, .addressing_mode = .implied}; 
            defaults[0xD8] = .{.mnemonic = .CLD, .addressing_mode = .implied}; 
            defaults[0xF8] = .{.mnemonic = .SED, .addressing_mode = .implied}; 

            defaults[0x8A] = .{.mnemonic = .TXA, .addressing_mode = .implied}; 
            defaults[0x9A] = .{.mnemonic = .TXS, .addressing_mode = .implied}; 
            defaults[0xAA] = .{.mnemonic = .TAX, .addressing_mode = .implied}; 
            defaults[0xBA] = .{.mnemonic = .TSX, .addressing_mode = .implied}; 
            defaults[0xCA] = .{.mnemonic = .DEX, .addressing_mode = .implied}; 
            defaults[0xEA] = .{.mnemonic = .NOP, .addressing_mode = .implied}; 

            defaults[0x0A] = .{.mnemonic = .ASL_acc, .addressing_mode = .accumulator};
            defaults[0x2A] = .{.mnemonic = .ROL_acc, .addressing_mode = .accumulator};
            defaults[0x4A] = .{.mnemonic = .LSR_acc, .addressing_mode = .accumulator};
            defaults[0x6A] = .{.mnemonic = .ROR_acc, .addressing_mode = .accumulator};

            defaults[0x6C] = .{.mnemonic = .JMP, .addressing_mode = .indirect};

            break :init defaults;
        };

        const opcode_cycles = [0x100]u8 {
            7, 6, 0, 0, 0, 3, 5, 0, 3, 2, 2, 0, 0, 4, 6, 0,
            2, 5, 0, 0, 0, 4, 6, 0, 2, 4, 0, 0, 0, 4, 7, 0,
            6, 6, 0, 0, 3, 3, 5, 0, 4, 2, 2, 0, 4, 4, 6, 0,
            2, 5, 0, 0, 0, 4, 6, 0, 2, 4, 0, 0, 0, 4, 7, 0,
            6, 6, 0, 0, 0, 3, 5, 0, 3, 2, 2, 0, 3, 4, 6, 0,
            2, 5, 0, 0, 0, 4, 6, 0, 2, 4, 0, 0, 0, 4, 7, 0,
            6, 6, 0, 0, 0, 3, 5, 0, 4, 2, 2, 0, 5, 4, 6, 0,
            2, 5, 0, 0, 0, 4, 6, 0, 2, 4, 0, 0, 0, 4, 7, 0,
            0, 6, 0, 0, 3, 3, 3, 0, 2, 0, 2, 0, 4, 4, 4, 0,
            2, 6, 0, 0, 4, 4, 4, 0, 2, 5, 2, 0, 0, 5, 0, 0,
            2, 6, 2, 0, 3, 3, 3, 0, 2, 2, 2, 0, 4, 4, 4, 0,
            2, 5, 0, 0, 4, 4, 4, 0, 2, 4, 2, 0, 4, 4, 4, 0,
            2, 6, 0, 0, 3, 3, 5, 0, 2, 2, 2, 0, 4, 4, 6, 0,
            2, 5, 0, 0, 0, 4, 6, 0, 2, 4, 0, 0, 0, 4, 7, 0,
            2, 6, 0, 0, 3, 3, 5, 0, 2, 2, 2, 2, 4, 4, 6, 0,
            2, 5, 0, 0, 0, 4, 6, 0, 2, 4, 0, 0, 0, 4, 7, 0,
        };

        pub fn init(bus: *Bus) !Self {
            return .{
                .bus = bus,
                .log_file = blk: {
                    if (log_file_path) |path| {
                        break :blk try std.fs.cwd().createFile(path, .{});
                    } else {
                        break :blk undefined;
                    }
                }
            };
        }

        pub fn deinit(self: *Self) void {
            self.log_file.close();
        }

        pub fn getInstruction(inst: Byte) Instruction {
            // Unmapped opcodes are treated as NOP
            if (opcode_cycles[inst.raw] == 0) {
                return .{};
            } 

            // Return NOP if the opcode is an exception or doesn't have a mapped mnemonic or addressing mode
            return instruction_exception[inst.raw] orelse 
                Instruction{
                    .mnemonic = mnemonic[inst.data.mnemonic][inst.data.group] orelse return .{},
                    .addressing_mode = addressing_mode[inst.data.addressing_mode][inst.data.group] orelse return .{}
                };
        }

        pub fn step(self: *Self) void {
            var byte = Byte{ .raw = self.bus.read_byte(self.pc)};
            const read_byte_addr = self.pc;

            self.pc += 1;

            var curr_instruction = getInstruction(byte);
            const operand: Operand = self.getOperand(curr_instruction.addressing_mode);
            
            if (log_file_path) |_| {
                self.log_file.writer().print("{any}\n", .{StepLogData{
                    .pc = read_byte_addr,
                    .mnemonic = curr_instruction.mnemonic,
                    .addressing_mode = curr_instruction.addressing_mode,
                    .operand = operand,
                    .cpu = self
                }}) catch {};
            }

            self.execute(curr_instruction.mnemonic, operand);

            self.total_cycles += opcode_cycles[byte.raw];
        }

        inline fn branch(self: *Self, address: u16) void {
            if ((self.pc / 256) == (address / 256)) {
                self.total_cycles += 1;
            } else {
                self.total_cycles += 2;
            }
            self.pc = address;
        } 

        inline fn stackPush(self: *Self, value: u8) void {
            self.bus.write_byte(0x100 | @as(u16, self.sp), value);
            self.sp -= 1;
        }

        inline fn stackPop(self: *Self) u8 {
            self.sp += 1;
            return self.bus.read_byte(0x100 | @as(u16, self.sp));
        }

        inline fn setFlagsNZ(self: *Self, value: u8) void {
            self.flags.N = @truncate(u1, value >> 7);
            self.flags.Z = @boolToInt(value == 0);
        }

        inline fn getOperand(self: *Self, addr_mode: AddressingMode) Operand {
            return switch(addr_mode) {
                .accumulator => .{.value = self.a},
                .absolute => blk: {
                    const addr_low: u16 = self.bus.read_byte(self.pc);
                    const addr_high: u16 = self.bus.read_byte(self.pc + 1);
                    self.pc += 2;
                    const addr: u16 = (addr_high << 8) | addr_low;
                    break :blk .{.address = addr, .value = self.bus.read_byte(addr)};
                },
                .absolute_x => blk: {
                    // TODO: Add cycle for page crossing
                    const addr_low: u16 = self.bus.read_byte(self.pc);
                    const addr_high: u16 = self.bus.read_byte(self.pc + 1);
                    self.pc += 2;
                    const addr: u16 = ((addr_high << 8) | addr_low) + self.x;
                    break :blk .{.address = addr, .value = self.bus.read_byte(addr)};
                },
                .absolute_y => blk: {
                    // TODO: Add cycle for page crossing
                    const addr_low: u16 = self.bus.read_byte(self.pc);
                    const addr_high: u16 = self.bus.read_byte(self.pc + 1);
                    self.pc += 2;
                    const addr: u16 = ((addr_high << 8) | addr_low) + self.y;
                    break :blk .{.address = addr, .value = self.bus.read_byte(addr)};
                },
                .immediate => blk: {
                    const val = self.bus.read_byte(self.pc);
                    self.pc += 1;
                    break :blk .{.value = val};
                },
                // Implied does not require an address or value
                .implied => .{},
                .indirect => blk: {
                    // Indirect is only used by the JMP instruction, so no need to get value
                    const addr_low: u16 = self.bus.read_byte(self.pc);
                    const addr_high: u16 = self.bus.read_byte(self.pc + 1);
                    self.pc += 2;
                    const addr: u16 = (addr_high << 8) | addr_low;
                    const target_low: u16 = self.bus.read_byte(addr);
                    const target_high: u16 = self.bus.read_byte(addr + 1);
                    const target: u16 = (target_high << 8) | target_low; 
                    break :blk .{.address = target};
                },
                .indirect_x => blk: {
                    const indirect_addr = self.bus.read_byte(self.pc) +% self.x;
                    self.pc += 1;
                    const addr_low: u16 = self.bus.read_byte(indirect_addr);
                    const addr_high: u16 = self.bus.read_byte(indirect_addr +% 1);
                    const addr: u16 = (addr_high << 8) | addr_low;
                    break :blk .{.address = addr, .value = self.bus.read_byte(addr)};
                },
                .indirect_y => blk: {
                    // TODO: Add cycle for page crossing
                    const indirect_addr = self.bus.read_byte(self.pc); 
                    self.pc += 1;
                    const addr_low: u16 = self.bus.read_byte(indirect_addr);
                    const addr_high: u16 = self.bus.read_byte(indirect_addr +% 1);
                    const addr: u16 = ((addr_high << 8) | addr_low) +% @as(u16, self.y);
                    break :blk .{.address = addr, .value = self.bus.read_byte(addr)};
                },
                .relative => blk: {
                    // Relative is only used by the branch instructions, so no need to get value
                    const addr = @bitCast(u16, @bitCast(i8, self.bus.read_byte(self.pc)) + @bitCast(i16, self.pc) + 1);
                    self.pc += 1;
                    break :blk .{.address = addr};
                },
                .zero_page => blk: { 
                    const addr = self.bus.read_byte(self.pc);
                    self.pc += 1;
                    break :blk .{.address = addr, .value = self.bus.read_byte(addr)};
                },
                .zero_page_x => blk: { 
                    const addr = self.bus.read_byte(self.pc) + self.x;
                    self.pc += 1;
                    break :blk .{.address = addr, .value = self.bus.read_byte(addr)};
                },
                .zero_page_y => blk: {
                    const addr = self.bus.read_byte(self.pc) + self.y;
                    self.pc += 1;
                    break :blk .{.address = addr, .value = self.bus.read_byte(addr)};
                }
            };
        }

        inline fn execute(self: *Self, mnem: Mnemonic, operand: Operand) void {
            switch(mnem) { 
                .ADC => { 
                    const op = self.a;
                    self.a = op +% operand.value +% self.flags.C;
                    // Overflow occurs iff the result has a different sign than both operands
                    self.flags.V = @truncate(u1,((self.a ^ op) & (self.a ^ operand.value)) >> 7);
                    self.flags.C = @boolToInt(self.a < operand.value);
                    self.setFlagsNZ(self.a);
                },
                .AND => {
                    const op = self.a;
                    self.a = op & operand.value;
                    self.setFlagsNZ(self.a);
                },
                .ASL => {
                    const res = operand.value << 1;
                    self.bus.write_byte(operand.address, res);
                    self.flags.C = @truncate(u1, operand.value >> 7);
                    self.setFlagsNZ(res);
                },
                .ASL_acc => {
                    const res = operand.value << 1;
                    self.a = res;
                    self.flags.C = @truncate(u1, operand.value >> 7);
                    self.setFlagsNZ(res);
                },
                .BCC => {
                    if (self.flags.C == 0) {
                        self.branch(operand.address);
                    }
                },
                .BCS => {
                    if (self.flags.C == 1) {
                        self.branch(operand.address);
                    }
                },
                .BEQ => {
                    if (self.flags.Z == 1) {
                        self.branch(operand.address);
                    }
                },
                .BIT => {
                    self.flags.Z = @boolToInt((self.a & operand.value) == 0);
                    self.flags.V = @truncate(u1, operand.value >> 6);
                    self.flags.N = @truncate(u1, operand.value >> 7);
                },
                .BMI => {
                    if (self.flags.N == 1) {
                        self.branch(operand.address);
                    }
                },
                .BNE => {
                    if (self.flags.Z == 0) {
                        self.branch(operand.address);
                    }
                },
                .BPL => {
                    if (self.flags.N == 0) {
                        self.branch(operand.address);
                    }
                },
                .BRK => {
                    // TODO: Check this logic
                    self.stackPush(@truncate(u8, self.pc >> 8));
                    self.stackPush(@truncate(u8, self.pc));
                    self.stackPush(@bitCast(u8, self.flags));
                    const addr_low: u16 = self.bus.read_byte(0xFFFE);
                    const addr_high: u16 = self.bus.read_byte(0xFFFF);
                    self.flags.B = 1;
                    self.pc = (addr_high << 8) | addr_low;
                },
                .BVC => {
                    if (self.flags.V == 0) {
                        self.branch(operand.address);
                    }
                },
                .BVS => {
                    if (self.flags.V == 1) {
                        self.branch(operand.address);
                    }
                },
                .CLC => {
                    self.flags.C = 0;
                },
                .CLD => {
                    self.flags.D = 0;
                },
                .CLI => {
                    self.flags.I = 0;
                },
                .CLV => {
                    self.flags.V = 0;
                },
                .CMP => {
                    const res = self.a -% operand.value;
                    self.flags.C = @boolToInt(self.a >= operand.value);
                    self.setFlagsNZ(res);
                },
                .CPX => {
                    const res = self.x -% operand.value;
                    self.flags.C = @boolToInt(self.a >= operand.value);
                    self.setFlagsNZ(res);
                },
                .CPY => {
                    const res = self.y -% operand.value;
                    self.flags.C = @boolToInt(self.a >= operand.value);
                    self.setFlagsNZ(res);
                },
                .DEC => {
                    const res = operand.value -% 1;
                    self.bus.write_byte(operand.address, res);
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
                    self.a = op ^ operand.value;
                    self.setFlagsNZ(self.a);
                },
                .INC => {
                    const res = operand.value +% 1;
                    self.bus.write_byte(operand.address, res);
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
                    self.branch(operand.address);
                },
                .JSR => {
                    self.stackPush(@truncate(u8, self.pc >> 8));
                    self.stackPush(@truncate(u8, self.pc));
                    self.pc = operand.address;
                },
                .LDA => {
                    self.a = operand.value;
                    self.setFlagsNZ(self.a);
                },
                .LDX => {
                    self.x = operand.value;
                    self.setFlagsNZ(self.x);
                },
                .LDY => {
                    self.y = operand.value;
                    self.setFlagsNZ(self.y);
                },
                .LSR => { 
                    const res = operand.value >> 1;
                    self.bus.write_byte(operand.address, res);
                    self.flags.C = @truncate(u1, operand.value);
                    self.setFlagsNZ(res);
                },
                .LSR_acc => {
                    const res = operand.value >> 1;
                    self.a = res;
                    self.flags.C = @truncate(u1, operand.value);
                    self.setFlagsNZ(res);
                },
                .NOP => {},
                .ORA => {
                    const op = self.a;
                    self.a = op | operand.value;
                    self.setFlagsNZ(self.a);
                },
                .PHA => {
                    self.stackPush(self.a);
                },
                .PHP => {
                    self.stackPush(@bitCast(u8, self.flags));
                },
                .PLA => { 
                    self.a = self.stackPop();
                    self.setFlagsNZ(self.a);
                },
                .PLP => {
                    self.flags = @bitCast(Flags, self.stackPop());
                },
                .ROL => {
                    const res = (operand.value << 1) | self.flags.C;
                    self.bus.write_byte(operand.address, res);
                    self.flags.C = @truncate(u1, operand.value >> 7);
                    self.setFlagsNZ(res);
                },
                .ROL_acc => {
                    const op = self.a;                
                    self.a = (op << 1) | self.flags.C;
                    self.flags.C = @truncate(u1, op >> 7);
                    self.setFlagsNZ(self.a); 
                },
                .ROR => {
                    const res = (operand.value >> 1) | (@as(u8, self.flags.C) << 7);
                    self.bus.write_byte(operand.address, res);
                    self.flags.C = @truncate(u1, operand.value);
                    self.setFlagsNZ(res);
                },
                .ROR_acc => {
                    const op = self.a;                
                    self.a = (op >> 1) | (@as(u8, self.flags.C) << 7);
                    self.flags.C = @truncate(u1, op);
                    self.setFlagsNZ(self.a);
                },
                .RTI => { 
                    self.flags = @bitCast(Flags, self.stackPop());
                    const addr_low: u16 = self.stackPop();
                    const addr_high: u16 = self.stackPop();
                    self.pc = (addr_high << 8) | addr_low;
                },
                .RTS => {
                    const addr_low: u16 = self.stackPop();
                    const addr_high: u16 = self.stackPop();
                    self.pc = (addr_high << 8) | addr_low;
                },
                .SBC => {
                    const op = self.a;
                    self.a = op -% operand.value -% (1 - self.flags.C);
                    // Overflow will occur iff the operands have different signs, and 
                    //      the result has a different sign than the minuend
                    self.flags.V = @truncate(u1,((op ^ operand.value) & (op ^ self.a)) >> 7);
                    self.flags.C = @boolToInt(((operand.value +% (1 - self.flags.C)) <= op));
                    self.setFlagsNZ(self.a);
                },
                .SEC => {
                    self.flags.C = 1;
                },
                .SED => {
                    self.flags.D = 1;
                },
                .SEI => {
                    self.flags.I = 1;
                },
                .STA => {
                    self.bus.write_byte(operand.address, self.a);
                },
                .STX => {
                    self.bus.write_byte(operand.address, self.x);
                },
                .STY => {
                    self.bus.write_byte(operand.address, self.y);
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
                    self.x = self.sp;
                    self.setFlagsNZ(self.x);
                },
                .TXA => {
                    self.a = self.x;
                    self.setFlagsNZ(self.a);
                },
                .TXS => {
                    self.sp = self.x;
                    self.setFlagsNZ(self.sp);
                },
                .TYA => {
                    self.a = self.y;
                    self.setFlagsNZ(self.a);
                }
            }
        }
    };
} 