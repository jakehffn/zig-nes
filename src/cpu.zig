const print = @import("std").debug.print;

const Bus = @import("./bus.zig").Bus;

pub const CPU = struct {
    const Self = @This();

    pc: u16 = 0,
    sp: u8 = 0,
    a: u8 = 0,
    x: u8 = 0,
    y: u8 = 0,
    flags: Flags = .{},
    bus: Bus,
    total_cycles: u32 = 0,

    const Flags = packed struct {
        S: u1 = 0, // Sign
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
        x_indirect,
        indirect_y,
        relative,
        zero_page,
        zero_page_x,
        zero_page_y
    };

    const Instruction = struct {
        mnemonic: Mnemonic,
        addressing_mode: AddressingMode
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
        [_]?AddressingMode {.immediate, .zero_page_x, .immediate},
        [_]?AddressingMode {.zero_page, .zero_page, .zero_page},
        [_]?AddressingMode {null, .immediate, .accumulator},
        [_]?AddressingMode {.absolute, .absolute, .absolute},
        [_]?AddressingMode {null, .zero_page_y, null},
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
        defaults[0x71] = .{.mnemonic = .BCC, .addressing_mode = .relative}; 
        defaults[0x90] = .{.mnemonic = .BCS, .addressing_mode = .relative}; 
        defaults[0xB0] = .{.mnemonic = .BNE, .addressing_mode = .relative}; 
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

    pub fn getInstruction(inst: Byte) Instruction {
        // Unmapped opcodes are treated as NOP
        if (opcode_cycles[inst.raw] == 0) {
            return .{.mnemonic = .NOP, .addressing_mode = .implied};
        } 
        
        return (instruction_exception[inst.raw]) orelse 
            inst: {
                if (mnemonic[inst.data.mnemonic][inst.data.group]) |mnem| {
                    if (addressing_mode[inst.data.addressing_mode][inst.data.group]) |addr_mode| {
                        break :inst .{.mnemonic = mnem, .addressing_mode = addr_mode};
                    }
                }
                break :inst .{.mnemonic = .NOP, .addressing_mode = .implied};
            };
    }

    pub fn init(bus: Bus) CPU {
        return .{.bus = bus};
    }

    pub fn step(self: *Self) void {
        var byte = self.bus.read_byte(self.pc);
        self.execute(Byte{.raw = byte});
        self.total_cycles += opcode_cycles[byte];
    }
    
    pub fn execute(self: *Self, inst: Byte) void {
        _ = self;

        defer print("Group: {}\nAddressing Mode: {}\nMnemonic: {}\n\n", .{inst.data.group, inst.data.addressing_mode, inst.data.mnemonic});    
        var curr_instruction = getInstruction(inst);

        switch(curr_instruction.mnemonic) { 
            .ADC => { 
                print("ADC\n", .{});

            },
            .AND => { print("AND\n", .{}); },
            .ASL => { print("ASL\n", .{}); },
            .BCC => { print("BCC\n", .{}); },
            .BCS => { print("BCS\n", .{}); },
            .BEQ => { print("BEQ\n", .{}); },
            .BIT => { print("BIT\n", .{}); },
            .BMI => { print("BMI\n", .{}); },
            .BNE => { print("BNE\n", .{}); },
            .BPL => { print("BPL\n", .{}); },
            .BRK => { print("BRK\n", .{}); },
            .BVC => { print("BVC\n", .{}); },
            .BVS => { print("BVS\n", .{}); },
            .CLC => { print("CLC\n", .{}); },
            .CLD => { print("CLD\n", .{}); },
            .CLI => { print("CLI\n", .{}); },
            .CLV => { print("CLV\n", .{}); },
            .CMP => { print("CMP\n", .{}); },
            .CPX => { print("CPX\n", .{}); },
            .CPY => { print("CPY\n", .{}); },
            .DEC => { print("DEC\n", .{}); },
            .DEX => { print("DEX\n", .{}); },
            .DEY => { print("DEY\n", .{}); },
            .EOR => { print("EOR\n", .{}); },
            .INC => { print("INC\n", .{}); },
            .INX => { print("INX\n", .{}); },
            .INY => { print("INY\n", .{}); },
            .JMP => { print("JMP\n", .{}); },
            .JMP_abs => { print("JMP_abs\n", .{}); },
            .JSR_abs => { print("JSR_abs\n", .{}); },
            .LDA => { print("LDA\n", .{}); },
            .LDX => { print("LDX\n", .{}); },
            .LDY => { print("LDY\n", .{}); },
            .LSR => { print("LSR\n", .{}); },
            .NOP => { print("NOP\n", .{}); },
            .ORA => { print("ORA\n", .{}); },
            .PHA => { print("PHA\n", .{}); },
            .PHP => { print("PHP\n", .{}); },
            .PLA => { print("PLA\n", .{}); },
            .PLP => { print("PLP\n", .{}); },
            .ROL => { print("ROL\n", .{}); },
            .ROR => { print("ROR\n", .{}); },
            .RTI => { print("RTI\n", .{}); },
            .RTS => { print("RTS\n", .{}); },
            .SBC => { print("SBC\n", .{}); },
            .SEC => { print("SEC\n", .{}); },
            .SED => { print("SED\n", .{}); },
            .SEI => { print("SEI\n", .{}); },
            .STA => { print("STA\n", .{}); },
            .STX => { print("STX\n", .{}); },
            .STY => { print("STY\n", .{}); },
            .TAX => { print("TAX\n", .{}); },
            .TAY => { print("TAY\n", .{}); },
            .TSX => { print("TSX\n", .{}); },
            .TXA => { print("TXA\n", .{}); },
            .TXS => { print("TXS\n", .{}); },
            .TYA => { print("TYA\n", .{}); }
        }
    }
}; 