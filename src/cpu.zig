const std = @import("std");
const print = std.debug.print;

const cpu_execute_log = std.log.scoped(.cpu_execute);

const Bus = @import("./bus.zig").Bus;

pub const CPU = struct {
    const Self = @This();

    pc: u16 = 0,
    sp: u8 = 0,
    a: u8 = 0,
    x: u8 = 0,
    y: u8 = 0,
    flags: Flags = .{},
    bus: *Bus,
    total_cycles: u32 = 0,

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
		ORA,
		AND,
		EOR,
		ADC,
		STA,
		LDA,
		CMP,
		SBC,
		ASL,
		ROL,
		LSR,
		ROR,
		STX,
		LDX,
		DEC,
		INC,
		BIT,
		JMP,
		JMP_abs,
		STY,
		LDY,
		CPY,
		CPX,
		BPL,
		BMI,
		BVC,
		BVS,
		BCC,
		BCS,
		BNE,
		BEQ,
		BRK,
		JSR_abs,
		RTI,
		RTS,
		PHP,
		PLP,
		PHA,
		PLA,
		DEY,
		TAY,
		INY,
		INX,
		CLC,
		SEC,
		CLI,
		SEI,
		TYA,
		CLV,
		CLD,
		SED,
		TXA,
		TXS,
		TAX,
		TSX,
		DEX,
		NOP
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
        data: DecodeData
    };

    pub const DecodeData = packed struct {
        group: u2,
        addressing_mode: u3,
        mnemonic: u3
    };

    // [mnemonic][group]
    const mnemonic = [8][3]?Mnemonic {
        [_]?Mnemonic {null, .ORA, .ASL},
        [_]?Mnemonic {.BIT, .AND, .ROL},
        [_]?Mnemonic {.JMP, .EOR, .LSR},
        [_]?Mnemonic {.JMP, .ADC, .ROR},
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
        defaults[0x20] = .{.mnemonic = .JSR_abs, .addressing_mode = .absolute}; 
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

    fn getInstruction(inst: Byte) Instruction {
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

    pub fn init(bus: *Bus) CPU {
        return .{.bus = bus};
    }

    pub fn step(self: *Self) void {
        var byte = self.bus.read_byte(self.pc);
        self.pc += 1;
        self.execute(Byte{.raw = byte});
        self.total_cycles += opcode_cycles[byte];
    }
    
    fn execute(self: *Self, inst: Byte) void {
        var curr_instruction = getInstruction(inst);

        const Operand = struct {
            address: u16 = 0,
            value: u8 = 0
        };

        std.debug.print("\nMnemonic: {}\nAddressing mode: {}\n", 
            .{curr_instruction.mnemonic, curr_instruction.addressing_mode});

        const operand: Operand = switch(curr_instruction.addressing_mode) {
            .accumulator => .{.value = self.a},
            .absolute => blk: {
                const addr_low: u16 = self.bus.read_byte(self.pc);
                const addr_high: u16 = self.bus.read_byte(self.pc + 1);
                self.pc += 2;
                const addr: u16 = (addr_high << 8) | addr_low;
                break :blk .{.address = addr, .value = self.bus.read_byte(addr)};
            },
            .absolute_x => blk: {
                const addr_low: u16 = self.bus.read_byte(self.pc);
                const addr_high: u16 = self.bus.read_byte(self.pc + 1);
                self.pc += 2;
                const addr: u16 = (addr_high << 8) | addr_low + self.x;
                break :blk .{.address = addr, .value = self.bus.read_byte(addr)};
            },
            .absolute_y => blk: {
                const addr_low: u16 = self.bus.read_byte(self.pc);
                const addr_high: u16 = self.bus.read_byte(self.pc + 1);
                self.pc += 2;
                const addr: u16 = (addr_high << 8) | addr_low + self.y;
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
                break :blk .{.address = self.bus.read_byte(addr)};
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
                const indirect_addr = self.bus.read_byte(self.pc); 
                self.pc += 1;
                const indexed_addr_low: u16 = @as(u16, self.bus.read_byte(indirect_addr)) + @as(u16, self.y);
                const carry = indexed_addr_low >> 8;
                const addr_low: u16 = @truncate(u8, indexed_addr_low);
                const addr_high: u16 = self.bus.read_byte(indirect_addr +% 1) +% carry;
                const addr: u16 = (addr_high << 8) | addr_low;
                break :blk .{.address = addr, .value = self.bus.read_byte(addr)};
            },
            .relative => blk: {
                // Relative is only used by the branch instructions, so no need to get value
                const addr = self.bus.read_byte(self.pc) + self.pc;
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

        switch(curr_instruction.mnemonic) { 
            .ADC => { 
                cpu_execute_log.info("ADC\n", .{});
                const op = self.a;
                self.a = op + operand.value;
                self.flags.N = @truncate(u1, self.a >> 7);
                self.flags.Z = @boolToInt(self.a == 0);
                self.flags.C = @boolToInt(self.a < operand.value);
                self.flags.V = @truncate(u1,((self.a ^ op) & (self.a ^ operand.value)));
            },
            .AND => {},
            .ASL => {},
            .BCC => {},
            .BCS => {},
            .BEQ => {},
            .BIT => {},
            .BMI => {},
            .BNE => {},
            .BPL => {},
            .BRK => {},
            .BVC => {},
            .BVS => {},
            .CLC => {},
            .CLD => {},
            .CLI => {},
            .CLV => {},
            .CMP => {},
            .CPX => {},
            .CPY => {},
            .DEC => {},
            .DEX => {},
            .DEY => {},
            .EOR => {},
            .INC => {},
            .INX => {},
            .INY => {},
            .JMP => {},
            .JMP_abs => {},
            .JSR_abs => {},
            .LDA => {},
            .LDX => {},
            .LDY => {},
            .LSR => {},
            .NOP => {},
            .ORA => {},
            .PHA => {},
            .PHP => {},
            .PLA => {},
            .PLP => {},
            .ROL => {},
            .ROR => {},
            .RTI => {},
            .RTS => {},
            .SBC => {},
            .SEC => {},
            .SED => {},
            .SEI => {},
            .STA => {},
            .STX => {},
            .STY => {},
            .TAX => {},
            .TAY => {},
            .TSX => {},
            .TXA => {},
            .TXS => {},
            .TYA => {}
        }
    }
}; 