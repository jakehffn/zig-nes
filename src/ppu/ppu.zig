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

        v: u15 = 0, // Current VRAM address
        t: packed union {
            value: u15,
            bytes: packed struct {
                low: u8,
                high: u7
            },
            scroll: packed struct {
                coarse_x: u5,
                coarse_y: u5,
                nametable: u2,
                fine_y: u3
            }
        } = .{
            .value = 0
        }, // Temporary VRAM address
        x: u3 = 0, // Fine X scroll
        w: bool = true, // Write toggle; True when first write

        scanline: u16 = 0,
        dot: u16 = 0,
        pre_render_dot_skip: bool = false,
        total_cycles: u32 = 0,
        /// Object attribute memory
        oam: [256]u8,
        secondary_oam: [8]u8, // Will just hold indices into oam
        secondary_oam_size: u8 = 0,

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
                ppu.t.bytes.high = (ppu.t.bytes.high & ~@as(u7, 0b1100)) | @as(u7, @truncate((value & 0b11) << 2)); 

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
                const return_flags = ppu.status_register.flags;
                ppu.status_register.flags.V = 0;
                return @bitCast(return_flags);
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
                _ = address;
                _ = bus;
                return ppu.oam[ppu.oam_address_register.address];
            }

            fn write(ppu: *Self, bus: *Bus, address: u16, value: u8) void {
                _ = address;
                _ = bus;
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

            fn write(ppu: *Self, bus: *Bus, address: u16, value: u8) void {
                _ = address;
                _ = bus;
                if (ppu.w) {
                    // First write
                    // t: ....... ...ABCDE <- d: ABCDE...
                    // x:              FGH <- d: .....FGH
                    // w:                  <- 1
                    ppu.t.bytes.low = (ppu.t.bytes.low & ~@as(u8, 0b11111)) | (value >> 3);
                    ppu.x = @truncate(value);
                } else {
                    // Second write
                    // t: FGH..AB CDE..... <- d: ABCDEFGH
                    // w:                  <- 0
                    ppu.t.bytes.high = @truncate((ppu.t.bytes.high & ~@as(u7, 0b1110011)) | ((0b111 & value) << 4) | (value >> 6));
                    ppu.t.bytes.low = (ppu.t.bytes.low & ~@as(u8, 0b11100000)) | ((value & 0b111000) << 2);
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
                    // First write
                    // t: .CDEFGH ........ <- d: ..CDEFGH
                    //        <unused>     <- d: AB......
                    // t: Z...... ........ <- 0 (bit Z is cleared)
                    // w:                  <- 1
                    ppu.t.bytes.high = @truncate(value & 0b111111);
                } else {
                    // t: ....... ABCDEFGH <- d: ABCDEFGH
                    // v: <...all bits...> <- t: <...all bits...>
                    // w:                  <- 0
                    ppu.t.bytes.low = value;
                    ppu.v = ppu.t.value;
                } 
                ppu.w = !ppu.w;
            }

            fn incrementAddress(ppu: *Self) void {
                // Increment row or column based on the controller register increment flag
                ppu.v +%= if (ppu.controller_register.flags.I == 0) 1 else 32;
                ppu.v &= 0x3FFF; // TODO: Check if this is correct
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
                _ = address; 
                // When reading palette data, the data is placed immediately on the bus
                //  and the buffer instead is filled with the data from the nametables
                //  as if the mirrors continued to the end of the address range
                //  Explained here: https://www.nesdev.org/wiki/PPU_registers#PPUDATA
                var data = ppu.bus.readByte(ppu.v);

                if (ppu.v < 0x3F00) {
                    const last_read_byte = ppu.data_register.read_buffer;
                    ppu.data_register.read_buffer = data;    
                    data = last_read_byte;
                } else {
                    ppu.data_register.read_buffer = ppu.bus.readByte(ppu.v - 0x1000);
                }

                @TypeOf(ppu.address_register).incrementAddress(ppu);
                return data;
            }    

            fn write(ppu: *Self, bus: *Bus, address: u16, value: u8) void {
                _ = bus;
                _ = address;
                ppu.bus.writeByte(ppu.v, value);
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
                for (0..ppu.oam.len) |_| {
                    const cpu_page_offset: u16 = ppu.oam_address_register.address;
                    // No need to wrap the address into cpu bus as the address register already does this
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
                       // Not used directly from here
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
            m: u1 = 0,  // `1`: Show background in leftmost 8 pixels of screen; `0`: Hide
            M: u1 = 0,  // `1`: Show sprites in leftmost 8 pixels of screen; `0`: Hide 
            b: u1 = 0,  // `1`: Show background; `0`: Hide
            s: u1 = 0,  // `1`: Show spites; `0`: Hide
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
                .secondary_oam = undefined,
                .screen = Screen.init(),
                .log_file = blk: {
                    break :blk try std.fs.cwd().createFile(
                        debug_log_file_path orelse {break :blk null;},
                        .{}
                    );
                }
            };

            @memset(ppu.oam[0..ppu.oam.len], 0);
            @memset(ppu.secondary_oam[0..ppu.secondary_oam.len], 0);

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
        pub fn step(self: *Self) void {
            if (self.scanline == 261) {
                self.prerenderStep();
            } else if (self.scanline < 240) {
                self.renderStep();
            } else {
                // Start of V-blank
                if (self.scanline == 241 and self.dot == 1) {
                    self.status_register.flags.V = 1;
                    if (self.controller_register.flags.V == 1) {
                        self.main_bus.*.nmi = true;
                    }
                }
            }    
            self.dotIncrement();
        }

        inline fn dotIncrement(self: *Self) void {
            self.total_cycles +%= 1;
            // Every step one pixel should be drawn
            self.dot += 1;

            // Start scanline 0 after 263 scanlines
            if (self.scanline == 262) {
                self.scanline = 0;
            }

            // Each scanline is 341 dots
            if (self.dot == 341) {
                self.dot -= 341;
                self.scanline += 1;
            }
        }

        inline fn prerenderStep(self: *Self) void {
            if (self.dot == 1) {
                self.status_register.flags.O = 0;
                self.status_register.flags.S = 0;
                self.status_register.flags.V = 0;
            }
            // Horizontal position is copied from t to v dot 257 of each scanline
            if (self.dot == 258 and self.mask_register.flags.b == 1 and self.mask_register.flags.s == 1) {
                self.v = (self.v & ~@as(u15, 0x41F)) | (self.t.value & 0x41F);
            }
            // Vertical part of t is copied to v
            if (self.dot > 280 and self.dot <= 304 and self.mask_register.flags.b == 1 and self.mask_register.flags.s == 1) {
                self.v = (self.v & ~@as(u15, 0x7BE0)) | (self.t.value & 0x7BE0);
            }

            // Dot 339 is skipped on every odd frame
            if (self.dot == 338) {
                if (self.pre_render_dot_skip and self.mask_register.flags.b == 1 and self.mask_register.flags.s == 1) {
                    self.dot += 1;
                }
                self.pre_render_dot_skip = !self.pre_render_dot_skip;
            }
        }

        fn renderStep(self: *Self) void {
            
            if (self.dot > 0 and self.dot <= 256) {
                var pixel_color_address: u16 = 0;
                var background_is_global = false;

                // If background rendering is active...
                if (self.mask_register.flags.b == 1) {

                    const x_offset: u3 = @truncate((self.dot + self.x - 1) % 8);

                    // Get tile from nametable
                    const tile: u16 = self.bus.readByte(0x2000 | (self.v & 0x0FFF));
                    // Get pattern from chr_rom
                    const address: u16 = (@as(u16, self.controller_register.flags.B) * 0x1000) | (((self.v >> 12) & 0x7) + (tile * 16));
                    const palette_color: u16 = ((self.bus.readByte(address) >> (7 ^ x_offset)) & 1) | 
                                               (((self.bus.readByte(address + 8) >> (7 ^ x_offset)) & 1) << 1);

                    var palette_index: u16 = 0;
                    if (palette_color == 0) {
                        background_is_global = true;
                    } else {
                        // Coarse x and coarse y are used to find the attribute byte
                        // Address formula from NesDev wiki
                        const attribute_byte = self.bus.readByte(0x23C0 | (self.v & 0x0C00) | ((self.v >> 4) & 0x38) | ((self.v >> 2) & 0x07));
                        palette_index = (attribute_byte >> @truncate(((self.v >> 4) & 4) | (self.v & 2))) & 0b11;
                    }

                    pixel_color_address = ((palette_index << 2) | palette_color);

                    if (x_offset == 7) {
                        // Horizontal part of v is incremented every 8 dots
                        // From the NesDev wiki
                        if ((self.v & 0x001F) == 31) {
                            self.v &= ~@as(u15, 0x001F);
                            self.v ^= 0x0400;
                        } else {
                            self.v += 1;
                        }
                    }
                }
                // If sprite rendering is active...
                if (self.mask_register.flags.s == 1) {
                    for (0..self.secondary_oam_size) |i| {
                        const oam_sprite_offset = self.secondary_oam[i] * 4; 
                        const sprite_x = self.oam[oam_sprite_offset + 3] +| 1;

                        const distance = self.dot -% @as(u16, sprite_x);
                        if (distance >= 8) {
                            continue;
                        }

                        const sprite_y = self.oam[oam_sprite_offset] +% 1;
                        const tile: u16 = self.oam[oam_sprite_offset + 1];
                        const palette_index: u2 = @truncate(self.oam[oam_sprite_offset + 2]);
                        const priority = self.oam[oam_sprite_offset + 2] >> 5 & 1 == 0;
                        const flip_horizontal = self.oam[oam_sprite_offset + 2] >> 6 & 1 == 1;
                        const flip_vertical = self.oam[oam_sprite_offset + 2] >> 7 & 1 == 1;

                        const tile_pattern_offset = (@as(u16, self.controller_register.flags.S) * 0x1000) + (tile * 16);

                        var tile_y = self.scanline -| sprite_y;
                        if (flip_vertical) {
                            tile_y = 7 - tile_y;
                        }
                        var tile_x: u3 = @truncate(self.dot -| sprite_x);
                        if (flip_horizontal) {
                            tile_x = 7 - tile_x;
                        }

                        var lower = self.bus.readByte(tile_pattern_offset + @as(u16, tile_y)) >> (7 ^ tile_x);
                        var upper = self.bus.readByte(tile_pattern_offset + @as(u16, tile_y) + 8) >> (7 ^ tile_x);
                        const palette_color: u2 = @truncate( (upper & 1) << 1 | (lower & 1));
                        // Don't draw anything if index 0
                        if (palette_color == 0) {
                            continue;
                        }
                        // Set sprite zero hit if background is not the global background color
                        if (oam_sprite_offset == 0 and !background_is_global and self.status_register.flags.S == 0) {
                            self.status_register.flags.S = 1;
                        }
                        // Sprite's are only shown if the background is the global background color 
                        //  or if the sprite has priority
                        if (priority or background_is_global) {
                            pixel_color_address = (0x10 + @as(u16, palette_index) * 4) + @as(u16, palette_color);
                        }
                    }
                }

                var pixel_color = palette[self.bus.readByte(0x3F00 + pixel_color_address)];
                self.screen.setPixel(self.dot - 1, self.scanline, &pixel_color);
            } 
            
            if (self.dot == 257 and self.mask_register.flags.b == 1) {
                // Vertical part of v is incremented after dot 256 of each scanline
                // Also From the NesDev wiki
                if ((self.v & 0x7000) != 0x7000) {
                    self.v += 0x1000;
                } else {
                    self.v &= ~@as(u15, 0x7000);
                    var y = (self.v & 0x03E0) >> 5;
                    if (y == 29) {
                        y = 0;
                        self.v ^= 0x0800;
                    } else if (y == 31) {
                        y = 0;
                    } else {
                        y += 1;
                    }
                    self.v = (self.v & ~@as(u15, 0x03E0)) | (y << 5);
                }
            }

            // Horizontal position is copied from t to v after dot 257 of each scanline
            if (self.dot == 258 and self.mask_register.flags.b == 1 and self.mask_register.flags.s == 1) {
                self.v = (self.v & ~@as(u15, 0x41F)) | (self.t.value & 0x41F);
            }

            // At the end of each visible scanline, add the next scanline sprites to secondary oam
            if (self.dot == 340) {
                // Clear the sprite list
                self.secondary_oam_size = 0;

                const sprite_height = 8;

                for (0..64) |i| {
                    const sprite_y = self.oam[i*4] +% 1;
                    // Checking if the sprite is on the next scanline
                    const distance = (self.scanline + 1) -% sprite_y;
                    // Sprites are visible if the distance between the scanline and the sprite's y
                    //  position is less than the sprite height
                    // Because of wrapping during subtraction, a value less than zero will be large
                    if (distance < sprite_height) {
                        if (self.secondary_oam_size == 8) {
                            self.status_register.flags.O = 1;
                            break;
                        }
                        self.secondary_oam[self.secondary_oam_size] = @truncate(i);
                        self.secondary_oam_size += 1;
                    }
                }
            }
        }

        fn getSpritePalette(self: *Self, id: u8) [3]u8 {
            const palette_offset: u16 = 0x3F11 + @as(u16, id)*4;
            return [_]u8{self.bus.readByte(palette_offset), self.bus.readByte(palette_offset + 1), self.bus.readByte(palette_offset + 2)};
        }

        /// Draws palettes for debugging
        pub fn drawPalettes(self: *Self) void {
            const palette_color_width = 8;
            // 8 palettes
            for (0..8) |palette_index| {
                // 3 colors and a mirror per palette
                for (0..4) |palette_color_index| {
                    const color_index = self.bus.readByte(
                        0x3F00 + @as(u16, @truncate(palette_index))*4 + @as(u16, @truncate(palette_color_index))
                    );
                    var pixel = palette[color_index % 64];
                    for (0..palette_color_width) |y| {
                        for (0..palette_color_width) |x| {
                            self.screen.setPixel(
                                x + palette_color_index * palette_color_width, 
                                y + palette_index * palette_color_width, 
                                &pixel);
                        }
                    }
                }
            }
        }
    };
} 