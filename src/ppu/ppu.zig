const std = @import("std");
const panic = std.debug.panic;
const mode = @import("builtin").mode;

const Bus = @import("../bus/bus.zig").Bus;
const BusCallback = Bus.BusCallback;
const PpuBus = @import("../ppu/ppu_bus.zig").PpuBus;
const MainBus = @import("../cpu/main_bus.zig").MainBus;

const LoggingBusCallback = struct {
    fn logRead(
        comptime Outer: type, 
        comptime name: []const u8, 
        comptime read_callback: fn (ptr: Outer, bus: *Bus, address: u16) u8
    ) fn (ptr: Outer, bus: *Bus, address: u16) u8 {
        return struct {
            fn func(self: Outer, bus: *Bus, address: u16) u8 {
                if (self.log_file) |file| { 
                    file.writer().print(name ++ (" " ** (10 - name.len)) ++ " READ  ${X:0>4}\n", .{address}) catch {};
                }
                return @call(.always_inline, read_callback, .{self, bus, address});
            }
        }.func;
    }

    fn logWrite(
        comptime Outer: type, 
        comptime name: []const u8, 
        comptime write_callback: fn (ptr: Outer, bus: *Bus, address: u16, data: u8) void
    ) fn (ptr: Outer, bus: *Bus, address: u16, data: u8) void {
        return struct {
            fn func(self: Outer, bus: *Bus, address: u16, value: u8) void {
                if (self.log_file) |file| {
                    file.writer().print(name ++ (" " ** (10 - name.len)) ++ " WRITE ${X:0>4} 0x{X:0>2}\n", .{address, value}) catch {};
                }
                @call(.always_inline, write_callback, .{self, bus, address, value});
            }
        }.func;
    }

    pub fn init(
        comptime name: []const u8,
        ptr: anytype, 
        comptime read_callback: fn (ptr: @TypeOf(ptr), bus: *Bus, address: u16) u8, 
        comptime write_callback: fn (ptr: @TypeOf(ptr), bus: *Bus, address: u16, data: u8) void) BusCallback {
        // Comptime normal or logging BusCallback
        if (mode == .Debug) {
            return BusCallback.init(
                ptr,
                logRead(@TypeOf(ptr), name, read_callback),
                logWrite(@TypeOf(ptr), name, write_callback)
            );
        }
        return BusCallback.init(ptr, read_callback, write_callback);
    }
};

pub fn Ppu(comptime log_file_path: ?[]const u8) type {
    const debug_log_file_path = if (mode == .Debug) log_file_path else null;

    return struct {
        const Self = @This();

        bus: *Bus,
        main_bus: *MainBus,
        v: packed union {
            value: u15,
            bytes: packed struct {
                low: u8,
                high: u7
            }
        } = .{
            .value = 0
        }, // Current VRAM address
        t: u15 = 0, // Temporary VRAM address
        x: u3 = 0, // Fine X scroll
        w: bool = true, // Write toggle; True when first write 
        /// Object attribute memory
        oam: [256]u8,
        total_cycles: u32 = 0,
        scanline: u16 = 0,
        screen: Screen,

        log_file: ?std.fs.File,

        // In CPU, mapped to:
        // 0x2000
        controller_register: struct {
            const ControlRegister = @This();

            flags: ControlFlags = .{},

            fn write(ppu: *Self, bus: *Bus, address: u16, value: u8) void {
                _ = address;
                _ = bus;
                const prev_v = ppu.controller_register.flags.V;
                ppu.controller_register.flags = @bitCast(value);

                if (ppu.status_register.flags.V == 1 and prev_v == 0 and ppu.controller_register.flags.V == 1) {
                    ppu.main_bus.nmi = true;
                }
            }

            pub fn busCallback(self: *ControlRegister) BusCallback {
                return LoggingBusCallback.init(
                    "PPUCTRL",
                    @fieldParentPtr(Self, "controller_register", self),
                    BusCallback.noRead(Self, "PPU::Cannot read from PPU controller register", false),
                    ControlRegister.write
                );
            }
        } = .{},
        // 0x2001
        mask_register: struct {
            const MaskRegister = @This();

            flags: MaskFlags = .{},

            fn write(ppu: *Self, bus: *Bus, address: u16, value: u8) void {
                _ = address;
                _ = bus;
                ppu.mask_register.flags = @bitCast(value);
            }

            pub fn busCallback(self: *MaskRegister) BusCallback {
                return LoggingBusCallback.init(
                    "PPUMASK",
                    @fieldParentPtr(Self, "mask_register", self),
                    BusCallback.noRead(Self, "PPU::Cannot read from PPU mask register", false),
                    MaskRegister.write
                );
            }
        } = .{},
        // 0x2002
        status_register: struct {
            const StatusRegister = @This();

            flags: StatusFlags = .{},

            fn read(ppu: *Self, bus: *Bus, address: u16) u8 {
                _ = address;
                _ = bus;
                ppu.w = true;
                return @bitCast(ppu.status_register.flags);
            }

            pub fn busCallback(self: *StatusRegister) BusCallback {
                return LoggingBusCallback.init(
                    "PPUSTATUS",
                    @fieldParentPtr(Self, "status_register", self),
                    StatusRegister.read,
                    BusCallback.noWrite(Self, "PPU::Cannot write to PPU status register", false)
                );
            }
        } = .{}, 
        // 0x2003
        oam_address_register: struct {
            const OamAddressRegister = @This();
            // TODO: Address should be set to 0 during each of ticks 257-320 of the pre-render and visible scanlines
            // https://www.nesdev.org/wiki/PPU_registers#OAMADDR
            address: u8 = 0,

            fn write(ppu: *Self, bus: *Bus, address: u16, value: u8) void {
                _ = address;
                _ = bus;
                ppu.oam_address_register.address = value;
            }

            pub fn busCallback(self: *OamAddressRegister) BusCallback {
                return LoggingBusCallback.init(
                    "OAMADDR",
                    @fieldParentPtr(Self, "oam_address_register", self), 
                    BusCallback.noRead(Self, "PPU::Cannot read from PPU oam address register", false),
                    OamAddressRegister.write
                );
            }
        } = .{},
        // 0x2004
        oam_data_register: struct {
            const OamDataRegister = @This();

            fn read(ppu: *Self, bus: *Bus, address: u16) u8 {
                _ = bus;

                return ppu.oam[address];
            }

            fn write(ppu: *Self, bus: *Bus, address: u16, value: u8) void {
                _ = address;
                _ = bus;
                if (ppu.status_register.flags.V == 0) {
                    return;
                }
                ppu.oam[ppu.oam_address_register.address] = value;
                ppu.oam_address_register.address +%= 1;
            }

            pub fn busCallback(self: *OamDataRegister) BusCallback {
                return LoggingBusCallback.init(
                    "OAMDATA",
                    @fieldParentPtr(Self, "oam_data_register", self), 
                    OamDataRegister.read,
                    OamDataRegister.write
                );
            }
        } = .{},
        // 0x2005
        scroll_register: struct {
            const ScrollRegister = @This();

            offsets: struct {
                horizontal: u8 = 0,
                vertical: u8 = 0
            } = .{},

            fn write(ppu: *Self, bus: *Bus, address: u16, value: u8) void {
                _ = address;
                _ = bus;
                if (ppu.w) {
                    ppu.scroll_register.offsets.horizontal = value;
                } else {
                    ppu.scroll_register.offsets.vertical = value;
                } 
                ppu.w = !ppu.w;

            }

            pub fn busCallback(self: *ScrollRegister) BusCallback {
                return LoggingBusCallback.init(
                    "PPUSCROLL",
                    @fieldParentPtr(Self, "scroll_register", self), 
                    BusCallback.noRead(Self, "PPU::Cannot read from PPU scroll register", false),
                    ScrollRegister.write
                );
            }
        } = .{},
        // 0x2006
        address_register: struct {
            const AddressRegister = @This();
            
            fn write(ppu: *Self, bus: *Bus, address: u16, value: u8) void {
                _ = bus;
                _ = address;
                if (ppu.w) {
                    ppu.v.bytes.high = @truncate(value);
                } else {
                    ppu.v.bytes.low = value;
                } 
                ppu.w = !ppu.w;
            }

            fn incrementAddress(ppu: *Self) void {
                // Increment row or column based on the controller register increment flag
                ppu.v.value +%= if (ppu.controller_register.flags.I == 0) 1 else 32;
            }

            pub fn busCallback(self: *AddressRegister) BusCallback {
                var ppu = @fieldParentPtr(Self, "address_register", self);
                return LoggingBusCallback.init(
                    "PPUADDR",
                    ppu,
                    BusCallback.noRead(Self, "PPU::Cannot read from PPU address register", false),
                    AddressRegister.write
                );
            }
        } = .{},
        // 0x2007
        data_register: struct {
            const DataRegister = @This();

            read_buffer: u8 = 0,

            fn read(ppu: *Self, bus: *Bus, address: u16) u8 {
                _ = bus;
                // TODO: Read conflict with DPCM samples
                _ = address; 
                // Wrapping back to addressable range
                var mirrored_address = ppu.v.value % 0x4000;
                // When reading palette data, the data is placed immediately on the bus
                //  and the buffer instead is filled with the data from the nametables
                //  as if the mirrors continued to the end of the address range
                //  Explained here: https://www.nesdev.org/wiki/PPU_registers#PPUDATA
                if (mirrored_address >= 0x3F00) {
                    ppu.data_register.read_buffer = ppu.bus.readByte(mirrored_address - 0x1000);
                    return ppu.bus.readByte(mirrored_address);
                }
                const last_read_byte = ppu.data_register.read_buffer;
                ppu.data_register.read_buffer = ppu.bus.readByte(mirrored_address);
                return last_read_byte;
            }    

            fn write(ppu: *Self, bus: *Bus, address: u16, value: u8) void {
                _ = bus;
                _ = address;
                // Wrapping back to addressable range
                ppu.bus.writeByte(ppu.v.value % 0x4000, value);
                // if (ppu.address_register.address.value & 0x3FFF > 0x2FFF) {
                //     std.debug.print("PPU::Wrote: 0x{X} to ${X}\n", .{value, ppu.address_register.address.value & 0x3FFF});
                // }
                @TypeOf(ppu.address_register).incrementAddress(ppu);
            }

            pub fn busCallback(self: *DataRegister) BusCallback {
                return LoggingBusCallback.init(
                    "PPUDATA",
                    @fieldParentPtr(Self, "data_register", self),
                    DataRegister.read,
                    DataRegister.write
                );
            }
        } = .{},
        // 0x4014
        oam_dma_register: struct {
            const OamDmaRegister = @This();

            fn write(ppu: *Self, bus: *Bus, address: u16, value: u8) void {
                const page = @as(u16, value) << 8;
                for (0..ppu.oam.len) |i| {
                    _ = i;
                    const cpu_page_offset: u16 = ppu.oam_address_register.address;
                    @TypeOf(ppu.oam_data_register).write(ppu, bus, address, ppu.main_bus.bus.readByte(page + cpu_page_offset));
                }
            }

            pub fn busCallback(self: *OamDmaRegister) BusCallback {
                return LoggingBusCallback.init(
                    "OAMDMA",
                    @fieldParentPtr(Self, "oam_dma_register", self), 
                    BusCallback.noRead(Self, "PPU::Cannot read from PPU OAM DMA register", false),
                    OamDmaRegister.write
                );
            }
        } = .{},

        const ControlFlags = packed struct {
            N: u2 = 0, // Base nametable address
                       // `0`: $2000; `1`: $2400; `2`: $2800; `3`: $2C00
            I: u1 = 0, // VRAM addresss increment per CPU read/write of PPUDATA
                       // `0`: add 1, going across; `1`: add 32, going down
            S: u1 = 0, // Sprite pattern table address for 8x8 sprites
                       // `0`: $0000; `1`: $1000
                       // *Ignored in 8x16 mode*
            B: u1 = 0, // Background pattern table address
                       // `0`: $0000; `1`: $1000
            H: u1 = 0, // Sprite size
                       // `0`: 8x8 pixels; `1`: 8x16 pixels
            P: u1 = 0, // PPU master/slave select
                       // `0`: read backdrop from EXT pins; `1`: output color on EXT pins
            V: u1 = 0  // Generate an NMI at the start of V-blank
                       // `0`: off; `1`: on
        }; 

        const MaskFlags = packed struct {
            Gr: u1 = 0, // `0`: normal; `1`: greyscale
            m: u1 = 0,  // `0`: Show background in leftmost 8 pixels of screen; `1`: Hide
            M: u1 = 0,  // `0`: Show sprites in leftmost 8 pixels of screen; `1`: Hide 
            b: u1 = 0,  // `0`: Show background; `1`: Hide
            s: u1 = 0,  // `0`: Show spites; `1`: Hide
            R: u1 = 0,  // Emphasize red
            G: u1 = 0,  // Emphasize green
            B: u1 = 0   // Emphasize blue
        };

        const StatusFlags = packed struct {
            _: u5 = 0,
            O: u1 = 0, // Indicate sprite overflow
            S: u1 = 0, // Set when a nonzero pixel of sprite 0 overlaps a nonzero background pixel
            V: u1 = 0, // V-blank has started
        };

        const Screen = struct {
            const width: usize = 256;
            const height: usize = 240;

            data: [width*height*3]u8 = undefined,

            pub fn init() Screen {
                var screen: Screen = .{};
                @memset(screen.data[0..screen.data.len], 0);
                return screen;
            }

            pub fn setPixel(self: *Screen, x: usize, y: usize, pixel: []u8) void {
                if (x < width and y < height) {
                    const offset = y * 3 * width + x * 3;
                    @memcpy(self.data[offset..offset+3], pixel);
                }
            }
        };

        // TODO: Load palletes from somewhere else
        const palette = [64][3]u8{
            [_]u8{0x80, 0x80, 0x80}, [_]u8{0x00, 0x3D, 0xA6}, [_]u8{0x00, 0x12, 0xB0}, [_]u8{0x44, 0x00, 0x96}, [_]u8{0xA1, 0x00, 0x5E},
            [_]u8{0xC7, 0x00, 0x28}, [_]u8{0xBA, 0x06, 0x00}, [_]u8{0x8C, 0x17, 0x00}, [_]u8{0x5C, 0x2F, 0x00}, [_]u8{0x10, 0x45, 0x00},
            [_]u8{0x05, 0x4A, 0x00}, [_]u8{0x00, 0x47, 0x2E}, [_]u8{0x00, 0x41, 0x66}, [_]u8{0x00, 0x00, 0x00}, [_]u8{0x05, 0x05, 0x05},
            [_]u8{0x05, 0x05, 0x05}, [_]u8{0xC7, 0xC7, 0xC7}, [_]u8{0x00, 0x77, 0xFF}, [_]u8{0x21, 0x55, 0xFF}, [_]u8{0x82, 0x37, 0xFA},
            [_]u8{0xEB, 0x2F, 0xB5}, [_]u8{0xFF, 0x29, 0x50}, [_]u8{0xFF, 0x22, 0x00}, [_]u8{0xD6, 0x32, 0x00}, [_]u8{0xC4, 0x62, 0x00},
            [_]u8{0x35, 0x80, 0x00}, [_]u8{0x05, 0x8F, 0x00}, [_]u8{0x00, 0x8A, 0x55}, [_]u8{0x00, 0x99, 0xCC}, [_]u8{0x21, 0x21, 0x21},
            [_]u8{0x09, 0x09, 0x09}, [_]u8{0x09, 0x09, 0x09}, [_]u8{0xFF, 0xFF, 0xFF}, [_]u8{0x0F, 0xD7, 0xFF}, [_]u8{0x69, 0xA2, 0xFF},
            [_]u8{0xD4, 0x80, 0xFF}, [_]u8{0xFF, 0x45, 0xF3}, [_]u8{0xFF, 0x61, 0x8B}, [_]u8{0xFF, 0x88, 0x33}, [_]u8{0xFF, 0x9C, 0x12},
            [_]u8{0xFA, 0xBC, 0x20}, [_]u8{0x9F, 0xE3, 0x0E}, [_]u8{0x2B, 0xF0, 0x35}, [_]u8{0x0C, 0xF0, 0xA4}, [_]u8{0x05, 0xFB, 0xFF},
            [_]u8{0x5E, 0x5E, 0x5E}, [_]u8{0x0D, 0x0D, 0x0D}, [_]u8{0x0D, 0x0D, 0x0D}, [_]u8{0xFF, 0xFF, 0xFF}, [_]u8{0xA6, 0xFC, 0xFF},
            [_]u8{0xB3, 0xEC, 0xFF}, [_]u8{0xDA, 0xAB, 0xEB}, [_]u8{0xFF, 0xA8, 0xF9}, [_]u8{0xFF, 0xAB, 0xB3}, [_]u8{0xFF, 0xD2, 0xB0},
            [_]u8{0xFF, 0xEF, 0xA6}, [_]u8{0xFF, 0xF7, 0x9C}, [_]u8{0xD7, 0xE8, 0x95}, [_]u8{0xA6, 0xED, 0xAF}, [_]u8{0xA2, 0xF2, 0xDA},
            [_]u8{0x99, 0xFF, 0xFC}, [_]u8{0xDD, 0xDD, 0xDD}, [_]u8{0x11, 0x11, 0x11}, [_]u8{0x11, 0x11, 0x11}
        }; 

        pub fn init(ppu_bus: *PpuBus) !Self {
            var ppu: Self = .{
                .bus = &ppu_bus.bus,
                .main_bus = undefined,
                .oam = undefined,
                .screen = Screen.init(),
                .log_file = blk: {
                    break :blk try std.fs.cwd().createFile(
                        debug_log_file_path orelse {break :blk null;},
                        .{}
                    );
                }
            };

            @memset(ppu.oam[0..ppu.oam.len], 0);

            return ppu;
        }

        pub fn deinit(self: *Self) void {
            if (self.log_file) |file| {
                file.close();
            }
        }

        pub fn setMainBus(self: *Self, main_bus: *MainBus) void {
            self.main_bus = main_bus;
        }

        /// Takes the number of cycles of the last executed CPU instructions
        pub fn step(self: *Self, cpu_cycles: u32) void {
            self.total_cycles += 3*cpu_cycles;

            if (self.total_cycles >= 341) {
                self.total_cycles -= 341;
                self.scanline += 1;

                if (self.scanline == 241) {
                    self.status_register.flags.V = 1;
                    if (self.controller_register.flags.V == 1) {
                        self.main_bus.*.nmi = true;
                    }
                }

                if (self.scanline >= 262) {
                    self.scanline = 0;
                    self.status_register.flags.V = 0;
                }
            }
        }

        fn getBackgroundPalette(self: *Self, tile_column: usize, tile_row : usize) [4]u8 {
            const attribute_table_index = (tile_row / 4) * 8 + (tile_column / 4);
            var attribute_byte = self.bus.readByte(@truncate(0x23C0 + 0x400 * @as(u16, self.controller_register.flags.N) + attribute_table_index)); 

            const palette_index = switch (@as(u2, @truncate((((tile_row % 4) & 2) + ((tile_column % 4) / 2))))) {
                0 => attribute_byte & 0b11,
                1 => (attribute_byte >> 2) & 0b11,
                2 => (attribute_byte >> 4) & 0b11,
                3 => (attribute_byte >> 6) & 0b11,
            };

            const palettes_offset: u16 = 0x3F01;
            const pallete_start: u16 = palettes_offset + palette_index*4;
            return [_]u8{self.bus.readByte(0x3F00), self.bus.readByte(pallete_start), self.bus.readByte(pallete_start+1), self.bus.readByte(pallete_start+2)};
        }

        fn getSpritePalette(self: *Self, id: u8) [3]u8 {
            const palette_offset: u16 = 0x3F11 + @as(u16, id)*4;
            return [_]u8{self.bus.readByte(palette_offset), self.bus.readByte(palette_offset + 1), self.bus.readByte(palette_offset + 2)};
        }

        /// Draws palette for debugging
        fn drawPalette(self: *Self) void {
            const left_offset = 8;
            const border = 2;
            var border_color = palette[5];
            // 8 palettes
            for (0..8) |palette_index| {
                for (0..3) |palette_color_index| {
                    const color_index = self.bus.readByte(
                        0x3F01 + @as(u16, @truncate(palette_index))*4 + @as(u16, @truncate(palette_color_index))
                    );
                    var pixel = palette[color_index];
                    for (0..11 + border*2) |y| {
                        const iy: i16 = @bitCast(@as(u16, @truncate(y)));
                        const pixel_y: u16 = @bitCast(239 - 8 - border - iy);
                        for (0..11 + border*2) |x| {
                            const ix: i16 = @bitCast(@as(u16, @truncate(x)));
                            const pixel_x: u16 = @bitCast(@as(i16, @bitCast(@as(u16, @truncate(left_offset - border + (30 * palette_index) + (10 * palette_color_index))))) + ix);
                            
                            if (iy - border < 0 or iy - border >= 10 or (ix - border < 0 and (palette_color_index + palette_index == 0)) or (ix - border >= 10 and (palette_color_index + palette_index == 9))) {
                                self.screen.setPixel(pixel_x, pixel_y, &border_color);
                            } else {
                                self.screen.setPixel(pixel_x, pixel_y, &pixel);
                            }
                        }
                    }
                }
            }
        }

        pub fn render(self: *Self) void {
            const background_bank: u16 = self.controller_register.flags.B;

            // Drawing Background
            // The screen is filled with 960 tiles
            for (0..960) |i| {
                const tile: u16 = self.bus.readByte(0x2000 + 0x400 * @as(u16, self.controller_register.flags.N) + @as(u16, @truncate(i)));
                const tile_x = i % 32;
                const tile_y = i / 32;
                const base_offset = (background_bank * 0x1000) + (tile * 16);
                // const base_offset = @as(u16, @truncate(i)) * 16;

                const bg_palette = self.getBackgroundPalette(tile_x, tile_y);
                // std.debug.print("Palette: Bg:{} 0:{} 1:{} 2:{}\n", .{bg_palette[0], bg_palette[1], bg_palette[2], bg_palette[3]});

                for (0..8) |y| {
                    var lower = self.bus.readByte(base_offset + @as(u16, @truncate(y)));
                    var upper = self.bus.readByte(base_offset + @as(u16, @truncate(y + 8)));

                    for (0..8) |x| {
                        const val: u2 = @truncate( (upper & 1) << 1 | (lower & 1));
                        upper >>= 1;
                        lower >>= 1;
                        var pixel = palette[bg_palette[val]];
                        self.screen.setPixel((tile_x * 8) + (7-x), (tile_y * 8) + y, &pixel);
                    }
                }
            }

            // Drawing Sprites
            const sprite_bank: u16 = self.controller_register.flags.S;
            
            for (0..self.oam.len/4) |i| {
                const sprite_index = i * 4;
                const tile_y = self.oam[sprite_index];
                const tile: u16 = self.oam[sprite_index + 1];
                const palette_id: u2 = @truncate(self.oam[sprite_index + 2]);
                const sprite_palette = self.getSpritePalette(palette_id);
                const flip_horizontal = self.oam[sprite_index + 2] >> 6 & 1 == 1;
                const flip_vertical = self.oam[sprite_index + 2] >> 7 & 1 == 1;
                const tile_x = self.oam[sprite_index + 3];


                if (tile_y >= 0xEF) {
                    continue;
                }

                const base_offset = (sprite_bank * 0x1000) + (tile * 16);

                for (0..8) |y| {
                    var lower = self.bus.readByte(base_offset + @as(u16, @truncate(y)));
                    var upper = self.bus.readByte(base_offset + @as(u16, @truncate(y + 8)));

                    for (0..8) |x| {
                        const val: u2 = @truncate( (upper & 1) << 1 | (lower & 1));
                        upper >>= 1;
                        lower >>= 1;
                        if (val == 0) {
                            continue;
                        }
                        var pixel = palette[sprite_palette[val-1]];
                        const x_offset = if (flip_horizontal) x else (7 - x);
                        const y_offset = if (flip_vertical) (7 - y) else y;
                        self.screen.setPixel(tile_x + x_offset, tile_y + y_offset, &pixel);
                    }
                }
            }
        }
    };
} 