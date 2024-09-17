const Self = @This();

pub const width: usize = 32*8;
pub const height: usize = 4*30*8;

data: [width*height*3]u8 = undefined,

pub fn init() Self {
    var nametable_viewer: Self = .{};
    @memset(nametable_viewer.data[0..], 0);
    return nametable_viewer;
}

fn getBackgroundPalette(ppu: anytype, tile_column: usize, tile_row: usize) [4]u8 {
    const attribute_table_index = (tile_row / 4) * 8 + (tile_column / 4);
    const attribute_byte = ppu.ppu_bus.read(
        @truncate(0x23C0 + 0x400 * @as(u16, ppu.controller_register.flags.N) + attribute_table_index)
    ); 

    const palette_index = switch (@as(u2, @truncate((((tile_row % 4) & 2) + ((tile_column % 4) / 2))))) {
        0 => attribute_byte & 0b11,
        1 => (attribute_byte >> 2) & 0b11,
        2 => (attribute_byte >> 4) & 0b11,
        3 => (attribute_byte >> 6) & 0b11,
    };

    const palettes_offset: u16 = 0x3F01;
    const pallete_start: u16 = palettes_offset + palette_index*4;
    return [_]u8{
        ppu.ppu_bus.read(0x3F00), 
        ppu.ppu_bus.read(pallete_start), 
        ppu.ppu_bus.read(pallete_start+1), 
        ppu.ppu_bus.read(pallete_start+2)
    };
}

pub fn update(self: *Self, ppu: anytype) void {
    const tile_bank: u16 = ppu.controller_register.flags.B;

    for (0..4) |nametable| {
        for (0..32) |tile_x| {
            for (0..30) |tile_y| {
                const tile: u16 = ppu.ppu_bus.read(@truncate(0x2000 + (0x400 * nametable) + tile_y * 32 + tile_x));
                const base_offset = (tile_bank * 0x1000) + (tile * 16);

                const bg_palette = getBackgroundPalette(ppu, tile_x, tile_y);

                for (0..8) |y| {
                    var lower = ppu.ppu_bus.read(base_offset + @as(u16, @truncate(y)));
                    var upper = ppu.ppu_bus.read(base_offset + @as(u16, @truncate(y + 8)));

                    for (0..8) |x| {
                        const palette_color: u2 = @truncate( (upper & 1) << 1 | (lower & 1));
                        upper >>= 1;
                        lower >>= 1;
                        const color: u8 = bg_palette[palette_color];
                        const pixel = ppu.palette.getColor(color);
                        const x_offset = 7 - x;
                        const y_offset = y;
                        const texture_tile_y = tile_y + 30 * nametable;
                        const offset = ((texture_tile_y * 8 + y_offset) * 32 * 8 * 3) + (tile_x * 8 + x_offset) * 3;
                        @memcpy(self.data[offset..offset + 3], pixel);
                    }
                }
            }
        }
    }
}