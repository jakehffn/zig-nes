const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const Bus = @import("../bus/bus.zig");
const BusCallback = Bus.BusCallback;

const MappedArray = struct {
    const Self = @This();

    array: ArrayList(u8),

    pub fn init(allocator: Allocator) MappedArray {
        return .{
            .array = ArrayList(u8).init(allocator)
        };
    }

    pub fn deinit(self: *Self) void {
        self.array.deinit();
    }

    fn read(self: *Self, bus: *Bus, address: u16) u8 {
        _ = bus;
        return self.array.items[address];
    }
    
    pub fn busCallback(self: *Self) BusCallback {
        return BusCallback.init(self, read, BusCallback.noWrite(Self, "Cannot write to ROM", false));
    }
};

pub const MirroringType = enum {
    four_screen,
    horizontal,
    vertical
};

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

// iNES rom format
const Rom = @This();

header: INesHeader,
prg_rom: MappedArray,
chr_rom: MappedArray,

pub fn init(allocator: Allocator) Rom {
    return .{
        .header = undefined,
        .prg_rom = MappedArray.init(allocator),
        .chr_rom = MappedArray.init(allocator),
    };
}

pub fn deinit(self: *Rom) void {
    self.prg_rom.deinit();
    self.chr_rom.deinit();
}

pub fn load(self: *Rom, rom_path: []const u8) !void {
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

    if (self.header.mapper_type != 0) {
        std.debug.print("ZigNES: Unsupported Mapper\n", .{});
        return error.Unsupported;
    }

    const prg_bank_size = 0x4000;
    const prg_bytes = prg_bank_size * @as(u32, self.header.num_prg_rom_banks);
    try self.prg_rom.array.ensureTotalCapacityPrecise(prg_bytes);
    self.prg_rom.array.expandToCapacity();

    const chr_bank_size = 0x2000;
    const chr_bytes = chr_bank_size * @as(u32, self.header.num_chr_rom_banks);
    try self.chr_rom.array.ensureTotalCapacityPrecise(chr_bytes);
    self.chr_rom.array.expandToCapacity();

    const trainer_size = 512;
    if (self.header.has_trainer) {
        try in_stream.skipBytes(trainer_size, .{});
    }
    
    _ = in_stream.readAll(self.prg_rom.array.items) catch {};
    _ = in_stream.readAll(self.chr_rom.array.items) catch {};

    std.log.info("{}\n", .{self.header});
}