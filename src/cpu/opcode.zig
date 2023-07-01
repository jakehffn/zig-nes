pub const Mnemonic = enum {
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

pub const AddressingMode = enum {
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

pub const Instruction = struct {
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

// [mnemonic][group]
pub const mnemonic = [8][3]?Mnemonic {
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
pub const addressing_mode = [8][3]?AddressingMode {
    [_]?AddressingMode {.immediate, .indirect_x, .immediate},
    [_]?AddressingMode {.zero_page, .zero_page, .zero_page},
    [_]?AddressingMode {null, .immediate, .accumulator},
    [_]?AddressingMode {.absolute, .absolute, .absolute},
    [_]?AddressingMode {null, .indirect_y, null},
    [_]?AddressingMode {.zero_page_x, .zero_page_x, .zero_page_x},
    [_]?AddressingMode {null, .absolute_y, null},
    [_]?AddressingMode {.absolute_x, .absolute_x, .absolute_x}
};

pub const instruction_exception = init: {
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

    defaults[0x96] = .{.mnemonic = .STX, .addressing_mode = .zero_page_y};
    defaults[0xB6] = .{.mnemonic = .LDX, .addressing_mode = .zero_page_y};
    defaults[0xBE] = .{.mnemonic = .LDX, .addressing_mode = .absolute_y};

    break :init defaults;
};

pub const opcode_cycles = [0x100]u8 {
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
        return .{};
    } 

    // Return NOP if the opcode is an exception or doesn't have a mapped mnemonic or addressing mode
    return instruction_exception[inst.raw] orelse 
        Instruction{
            .mnemonic = mnemonic[inst.data.mnemonic][inst.data.group] orelse return .{},
            .addressing_mode = addressing_mode[inst.data.addressing_mode][inst.data.group] orelse return .{}
        };
}