const std = @import("std");
const panic = std.debug.panic;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const NROM = @import("./mappers/NROM.zig");
const SxROM = @import("./mappers/SxROM.zig");

const Self = @This();

pub const Rom = struct {
    rom_loader: *Self,

    init_fn: *const fn (*Self) anyerror!void,
    deinit_fn: *const fn (*Self) void,

    read_fn: *const fn (*Self, u16) u8,
    write_fn: *const fn (*Self, u16, u8) void,
    ppu_read_fn: *const fn (*Self, u16) u8,
    ppu_write_fn: *const fn (*Self, u16, u8) void,

    pub inline fn init(self: *Rom) !void {
        try self.init_fn(self.rom_loader);
    }

    pub inline fn deinit(self: *Rom) void {
        self.deinit_fn(self.rom_loader);
    }

    pub inline fn read(self: *Rom, address: u16) u8 {
        return self.read_fn(self.rom_loader, address);
    }

    pub inline fn write(self: *Rom, address: u16, value: u8) void {
        self.write_fn(self.rom_loader, address, value);
    }

    pub inline fn ppuRead(self: *Rom, address: u16) u8 {
        return self.ppu_read_fn(self.rom_loader, address);
    }

    pub inline fn ppuWrite(self: *Rom, address: u16, value: u8) void {
        self.ppu_write_fn(self.rom_loader, address, value);
    }
};

pub const MirroringType = enum {
    four_screen,
    horizontal,
    vertical
};

// iNES rom format
const INesHeader = struct {
    i_nes_format: u2,
    prg_ram_size: u8,
    mapper_type: u8,
    mirroring_type: MirroringType,
    has_battery_backed_ram: bool,
    has_trainer: bool,
    num_prg_rom_banks: u8, // CHR ROM
    num_chr_rom_banks: u8, // PRG ROM
};

allocator: Allocator,
header: INesHeader = undefined,
prg_rom: ArrayList(u8),
chr_rom: ArrayList(u8),
ppu_ram: ArrayList(u8),

rom_data: *anyopaque = undefined,
rom: ?Rom = null,

pub fn init(allocator: Allocator) Self {
    return .{
        .allocator = allocator,
        .prg_rom = ArrayList(u8).init(allocator),
        .chr_rom = ArrayList(u8).init(allocator),
        .ppu_ram = ArrayList(u8).init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.unloadRom();
    self.prg_rom.deinit();
    self.chr_rom.deinit();
    self.ppu_ram.deinit();
}

pub fn loadRom(self: *Self, rom_path: []const u8) !void {
    self.unloadRom();
    try self.readRomFile(rom_path);
    self.initRom() catch |e| {
        self.unloadRom();
        return e;
    };
}

fn readRomFile(self: *Self, rom_path: []const u8) !void {
    var file = try std.fs.cwd().openFile(rom_path, .{});
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    var in_stream = buf_reader.reader();

    var header_data = try in_stream.readStruct(packed struct {
        nes_string: u32, // Should contain "NES" + 0x1A
        num_prg_rom_banks: u8, // PRG ROM
        num_chr_rom_banks: u8, // CHR ROM
        control_byte_1: packed struct {
            mirroring_type: u1, // 1 for vertical, 0 for horizontal
            has_battery_backed_ram: bool, // 1 if exists (At 0x6000-0x7FFF)
            has_trainer: bool, // 1 if exists (at 0x7000-0x200)
            has_four_screen_vram: u1, // 1 if four-screen VRAM layout
            mapper_type_low: u4
        },
        control_byte_2: packed struct {
            _: u2, // Should be 0 for iNES 1.0
            i_nes_format: u2, // 0b00 = iNES 1.0, 0b00 = iNES 2.0
            mapper_type_high: u4
        },
        prg_ram_size: u8, // Size in 8 kB units
        _: u8,
        reserved: u48, // must be zero
    });

    std.debug.assert(std.mem.eql(u8, @as(*const [4]u8, @ptrCast(&header_data.nes_string)), "NES" ++ .{0x1A}));

    self.header = .{
        .i_nes_format = header_data.control_byte_2.i_nes_format,
        .prg_ram_size = header_data.prg_ram_size,
        .mapper_type = @as(u8, header_data.control_byte_2.mapper_type_high) << 4 |
            @as(u8, header_data.control_byte_1.mapper_type_low),
        .mirroring_type = switch((@as(u2, header_data.control_byte_1.has_four_screen_vram) << 1) + 
            header_data.control_byte_1.mirroring_type) {
                0 => .horizontal,
                1 => .vertical,
                else => .four_screen
            },
        .has_battery_backed_ram = header_data.control_byte_1.has_battery_backed_ram,
        .has_trainer = header_data.control_byte_1.has_trainer,
        .num_prg_rom_banks = header_data.num_prg_rom_banks,
        .num_chr_rom_banks = header_data.num_chr_rom_banks
    };

    const prg_bank_size = 0x4000;
    const prg_bytes = prg_bank_size * @as(u32, self.header.num_prg_rom_banks);
    try self.prg_rom.ensureTotalCapacityPrecise(prg_bytes);
    self.prg_rom.expandToCapacity();

    const chr_bank_size = 0x2000;
    const chr_bytes = chr_bank_size * @as(u32, self.header.num_chr_rom_banks);
    try self.chr_rom.ensureTotalCapacityPrecise(chr_bytes);
    self.chr_rom.expandToCapacity();

    const trainer_size = 512;
    if (self.header.has_trainer) {
        try in_stream.skipBytes(trainer_size, .{});
    }
    
    _ = in_stream.readAll(self.prg_rom.items) catch {};
    _ = in_stream.readAll(self.chr_rom.items) catch {};
    std.debug.print("{}\n", .{self.header});
}

fn initRom(self: *Self) !void {
    self.rom = switch (self.header.mapper_type) {
        0 => NROM.rom(),
        1 => SxROM.rom(),
        else => |mapper_id| {
            self.rom = null;
            std.debug.print("RomLoader: Unsupported mapper type: {}\n", .{mapper_id});
            return error.Unsupported;
        }
    };
    self.rom.?.rom_loader = self;
    try self.rom.?.init();
}

pub fn unloadRom(self: *Self) void {
    if (self.rom) |*rom| {
        rom.deinit();
        self.rom = null;
    }
    self.prg_rom.shrinkAndFree(0);
    self.chr_rom.shrinkAndFree(0);
}

pub fn getRom(self: *Self) Rom {
    return self.rom orelse panic("Rom requested when not initialized\n", .{});
}