const print = @import("std").debug.print;

const Bus = @import("./bus.zig").Bus;

pub const CPU = struct {
    pc: u16 = 0,
    sp: u8 = 0,
    a: u8 = 0,
    x: u8 = 0,
    y: u8 = 0,
    flags: Flags = .{},
    bus: Bus,

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

    pub const Instruction = packed union {
        byte: u8,    
        data: InstructionData
    };

    pub const InstructionData = packed struct {
        group: u2,
        addr_mode: u3,
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
        var defaults = [_]?Mnemonic{null}**0x100;
        // Branching instructions
        defaults[0x10] = .BPL;
        defaults[0x30] = .BMI;
        defaults[0x50] = .BVC;
        defaults[0x71] = .BCC;
        defaults[0x90] = .BCS;
        defaults[0xB0] = .BNE;
        defaults[0xF0] = .BEQ;
        // Interrupt and subroutine instructions
        defaults[0x00] = .BRK;
        defaults[0x20] = .JSR_abs;
        defaults[0x40] = .RTI;
        defaults[0x60] = .RTS;

        defaults[0x08] = .PHP;
        defaults[0x28] = .PLP;
        defaults[0x48] = .PHA;
        defaults[0x68] = .PLA;
        defaults[0x88] = .DEY;
        defaults[0xA8] = .TAY;
        defaults[0xC8] = .INY;
        defaults[0xE8] = .INX;

        defaults[0x18] = .CLC;
        defaults[0x38] = .SEC;
        defaults[0x58] = .CLI;
        defaults[0x78] = .SEI;
        defaults[0x98] = .TYA;
        defaults[0xB8] = .CLV;
        defaults[0xD8] = .CLD;
        defaults[0xF8] = .SED;

        defaults[0x8A] = .TXA;
        defaults[0x9A] = .TXS;
        defaults[0xAA] = .TAX;
        defaults[0xBA] = .TSX;
        defaults[0xCA] = .DEX;
        defaults[0xEA] = .NOP;

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

    pub fn init(bus: Bus) CPU {
        return .{.bus = bus};
    }
    
    pub fn execute(self: CPU, inst: Instruction) void {
        _ = self;

        defer print("Group: {}\nAddressing Mode: {}\nMnemonic: {}\n\n", .{inst.data.group, inst.data.addr_mode, inst.data.mnemonic});    

        var curr_mnemonic = instruction_exception[inst.byte] orelse 
            mnemonic[inst.data.mnemonic][inst.data.group] orelse return;

        switch(curr_mnemonic) { 
            .ORA => { print("ORA\n", .{}); },
            .AND => { print("AND\n", .{}); },
            .EOR => { print("EOR\n", .{}); },
            .ADC => { print("ADC\n", .{}); },
            .STA => { print("STA\n", .{}); },
            .LDA => { print("LDA\n", .{}); },
            .CMP => { print("CMP\n", .{}); },
            .SBC => { print("SBC\n", .{}); },
            .ASL => { print("ASL\n", .{}); },
            .ROL => { print("ROL\n", .{}); },
            .LSR => { print("LSR\n", .{}); },
            .ROR => { print("ROR\n", .{}); },
            .STX => { print("STX\n", .{}); },
            .LDX => { print("LDX\n", .{}); },
            .DEC => { print("DEC\n", .{}); },
            .INC => { print("INC\n", .{}); },
            .BIT => { print("BIT\n", .{}); },
            .JMP => { print("JMP\n", .{}); },
            .JMP_abs => { print("JMP_abs\n", .{}); },
            .STY => { print("STY\n", .{}); },
            .LDY => { print("LDY\n", .{}); },
            .CPY => { print("CPY\n", .{}); },
            .CPX => { print("CPX\n", .{}); },
            .BPL => { print("BPL\n", .{}); },
            .BMI => { print("BMI\n", .{}); },
            .BVC => { print("BVC\n", .{}); },
            .BVS => { print("BVS\n", .{}); },
            .BCC => { print("BCC\n", .{}); },
            .BCS => { print("BCS\n", .{}); },
            .BNE => { print("BNE\n", .{}); },
            .BEQ => { print("BEQ\n", .{}); },
            .BRK => { print("BRK\n", .{}); },
            .JSR_abs => { print("JSR_abs\n", .{}); },
            .RTI => { print("RTI\n", .{}); },
            .RTS => { print("RTS\n", .{}); },
            .PHP => { print("PHP\n", .{}); },
            .PLP => { print("PLP\n", .{}); },
            .PHA => { print("PHA\n", .{}); },
            .PLA => { print("PLA\n", .{}); },
            .DEY => { print("DEY\n", .{}); },
            .TAY => { print("TAY\n", .{}); },
            .INY => { print("INY\n", .{}); },
            .INX => { print("INX\n", .{}); },
            .CLC => { print("CLC\n", .{}); },
            .SEC => { print("SEC\n", .{}); },
            .CLI => { print("CLI\n", .{}); },
            .SEI => { print("SEI\n", .{}); },
            .TYA => { print("TYA\n", .{}); },
            .CLV => { print("CLV\n", .{}); },
            .CLD => { print("CLD\n", .{}); },
            .SED => { print("SED\n", .{}); },
            .TXA => { print("TXA\n", .{}); },
            .TXS => { print("TXS\n", .{}); },
            .TAX => { print("TAX\n", .{}); },
            .TSX => { print("TSX\n", .{}); },
            .DEX => { print("DEX\n", .{}); },
            .NOP => { print("NOP\n", .{}); }
        }
    }
}; 