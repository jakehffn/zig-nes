const std = @import("std");
const panic = std.debug.panic;
const mode = @import("builtin").mode;

const PpuBus = @import("../ppu/ppu_bus.zig");
const MainBus = @import("../cpu/main_bus.zig");

const PaletteViewer = @import("./debug/palette_viewer.zig");
const SpriteViewer = @import("./debug/sprite_viewer.zig");

const SystemPalettes = @import("./system_palettes.zig");

const ppu_log_file = @import("../main.zig").ppu_log_file;
const logging_enabled = !(ppu_log_file == null or mode == .Debug);

const Self = @This();

ppu_bus: *PpuBus,
main_bus: *MainBus,
render_callback: *const fn () void,

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

palette: *const [64][3]u8,
screen: Screen,

palette_viewer: PaletteViewer,
sprite_viewer: SpriteViewer,
log_file: ?std.fs.File,

// In CPU, mapped to:
// 0x2000
controller_register: struct {
    const ControlRegister = @This();

    flags: ControlFlags = .{},

    pub fn write(self: *ControlRegister, value: u8) void {
        var ppu = @fieldParentPtr(Self, "controller_register", self);
        const prev_v = ppu.controller_register.flags.V;
        ppu.controller_register.flags = @bitCast(value);
        ppu.t.bytes.high = (ppu.t.bytes.high & ~@as(u7, 0b1100)) | @as(u7, @truncate((value & 0b11) << 2)); 

        if (ppu.status_register.flags.V == 1 and prev_v == 0 and ppu.controller_register.flags.V == 1) {
            ppu.main_bus.nmi = true;
        }
    }
} = .{},
// 0x2001
mask_register: struct {
    const MaskRegister = @This();

    flags: MaskFlags = .{},

    pub fn write(self: *MaskRegister, value: u8) void {
        var ppu = @fieldParentPtr(Self, "mask_register", self);
        ppu.mask_register.flags = @bitCast(value);
    }
} = .{},
// 0x2002
status_register: struct {
    const StatusRegister = @This();

    flags: StatusFlags = .{},

    pub fn read(self: *StatusRegister) u8 {
        var ppu = @fieldParentPtr(Self, "status_register", self);
        ppu.w = true;
        const return_flags = self.flags;
        self.flags.V = 0;
        return @bitCast(return_flags);
    }
} = .{}, 
// 0x2003
oam_address_register: struct {
    const OamAddressRegister = @This();
    // TODO: Address should be set to 0 during each of ticks 257-320 of the pre-render and visible scanlines
    // https://www.nesdev.org/wiki/PPU_registers#OAMADDR
    address: u8 = 0,

    pub fn write(self: *OamAddressRegister, value: u8) void {
        self.address = value;
    }
} = .{},
// 0x2004
oam_data_register: struct {
    const OamDataRegister = @This();

    pub fn read(self: *OamDataRegister) u8 {
        var ppu = @fieldParentPtr(Self, "oam_data_register", self);
        return ppu.oam[ppu.oam_address_register.address];
    }

    pub fn write(self: *OamDataRegister, value: u8) void {
        var ppu = @fieldParentPtr(Self, "oam_data_register", self);
        ppu.oam[ppu.oam_address_register.address] = value;
        ppu.oam_address_register.address +%= 1;
    }
} = .{},
// 0x2005
scroll_register: struct {
    const ScrollRegister = @This();

    pub fn write(self: *ScrollRegister, value: u8) void {
        var ppu = @fieldParentPtr(Self, "scroll_register", self);
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
} = .{},
// 0x2006
address_register: struct {
    const AddressRegister = @This();
    
    pub fn write(self: *AddressRegister, value: u8) void {
        var ppu = @fieldParentPtr(Self, "address_register", self);
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
} = .{},
// 0x2007
data_register: struct {
    const DataRegister = @This();

    read_buffer: u8 = 0,

    pub fn read(self: *DataRegister) u8 { 
        var ppu = @fieldParentPtr(Self, "data_register", self);
        // When reading palette data, the data is placed immediately on the bus
        //  and the buffer instead is filled with the data from the nametables
        //  as if the mirrors continued to the end of the address range
        //  Explained here: https://www.nesdev.org/wiki/PPU_registers#PPUDATA
        var data = ppu.ppu_bus.read(ppu.v);

        if (ppu.v < 0x3F00) {
            const last_read_byte = ppu.data_register.read_buffer;
            ppu.data_register.read_buffer = data;    
            data = last_read_byte;
        } else {
            ppu.data_register.read_buffer = ppu.ppu_bus.read(ppu.v - 0x1000);
        }

        @TypeOf(ppu.address_register).incrementAddress(ppu);
        return data;
    }    

    pub fn write(self: *DataRegister, value: u8) void {
        var ppu = @fieldParentPtr(Self, "data_register", self);
        ppu.ppu_bus.write(ppu.v, value);
        @TypeOf(ppu.address_register).incrementAddress(ppu);
    }
} = .{},
// 0x4014
oam_dma_register: struct {
    const OamDmaRegister = @This();

    pub fn write(self: *OamDmaRegister, value: u8) void {
        var ppu = @fieldParentPtr(Self, "oam_dma_register", self);
        const page = @as(u16, value) << 8;
        for (0..ppu.oam.len) |_| {
            const cpu_page_offset: u16 = ppu.oam_address_register.address;
            // No need to wrap the address into cpu bus as the address register already does this
            ppu.oam_data_register.write(ppu.main_bus.read(page + cpu_page_offset));
        }
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

pub fn init(ppu_bus: *PpuBus, render_callback: *const fn () void) !Self {
    var ppu: Self = .{
        .ppu_bus = ppu_bus,
        .render_callback = render_callback,
        .main_bus = undefined,
        .oam = undefined,
        .secondary_oam = undefined,
        .palette = &SystemPalettes.default_palette,
        .screen = Screen.init(),
        .palette_viewer = PaletteViewer.init(),
        .sprite_viewer = SpriteViewer.init(),
        .log_file = blk: {
            if (!logging_enabled) {
                break :blk null;
            }
            break :blk try std.fs.cwd().createFile(
                ppu_log_file.?,
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

pub fn reset(self: *Self) void {
    @memset(self.screen.data[0..], 0);
    self.status_register.flags = .{};
}

pub fn connectMainBus(self: *Self, main_bus: *MainBus) void {
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
            self.render_callback();
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
            const tile: u16 = self.ppu_bus.read(0x2000 | (self.v & 0x0FFF));
            // Get pattern from chr_rom
            const address: u16 = (@as(u16, self.controller_register.flags.B) * 0x1000) | (((self.v >> 12) & 0x7) + (tile * 16));
            const palette_color: u16 = ((self.ppu_bus.read(address) >> (7 ^ x_offset)) & 1) | 
                                        (((self.ppu_bus.read(address + 8) >> (7 ^ x_offset)) & 1) << 1);
            
            var palette_index: u16 = 0;
            if (palette_color == 0) {
                background_is_global = true;
            } else {
                // Coarse x and coarse y are used to find the attribute byte
                // Address formula from NesDev wiki
                const attribute_byte = self.ppu_bus.read(0x23C0 | (self.v & 0x0C00) | ((self.v >> 4) & 0x38) | ((self.v >> 2) & 0x07));
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

                var lower = self.ppu_bus.read(tile_pattern_offset + @as(u16, tile_y)) >> (7 ^ tile_x);
                var upper = self.ppu_bus.read(tile_pattern_offset + @as(u16, tile_y) + 8) >> (7 ^ tile_x);
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

        var pixel_color = self.palette[self.ppu_bus.read(0x3F00 + pixel_color_address)];
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
            const sprite_y = self.oam[i*4] +| 1;
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