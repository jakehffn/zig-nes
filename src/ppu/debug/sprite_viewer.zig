const Self = @This();

pub const width: usize = 8*8;
pub const height: usize = 8*8;

data: [width*height*3]u8 = undefined,

pub fn init() Self {
    var sprite_viewer: Self = .{};
    @memset(sprite_viewer.data[0..], 0);
    return sprite_viewer;
}

pub fn update(self: *Self, ppu: anytype) void {
    const sprite_bank: u16 = ppu.controller_register.flags.S;

    for (0..ppu.oam.len/4) |i| {
        const sprite_index = i * 4;
        const sprite_y = ppu.oam[sprite_index];
        _ = sprite_y;
        const tile: u16 = ppu.oam[sprite_index + 1];
        const palette_id: u2 = @truncate(ppu.oam[sprite_index + 2]);
        const flip_horizontal = ppu.oam[sprite_index + 2] >> 6 & 1 == 1;
        const flip_vertical = ppu.oam[sprite_index + 2] >> 7 & 1 == 1;
        const sprite_x = ppu.oam[sprite_index + 3];
        _ = sprite_x;

        const base_offset = (sprite_bank * 0x1000) + (tile * 16);

        for (0..8) |y| {
            var lower = ppu.ppu_bus.read(base_offset + @as(u16, @truncate(y)));
            var upper = ppu.ppu_bus.read(base_offset + @as(u16, @truncate(y + 8)));

            for (0..8) |x| {
                const palette_color: u2 = @truncate( (upper & 1) << 1 | (lower & 1));
                upper >>= 1;
                lower >>= 1;
                var color: u8 = undefined;
                if (palette_color == 0) {
                    color = ppu.ppu_bus.read(0x3F00);
                } else {
                    color = ppu.ppu_bus.read(0x3F10 + @as(u16, palette_id) * 4 + palette_color);
                }
                var pixel = &ppu.palette[color];
                const x_offset = if (flip_horizontal) x else (7 - x);
                const y_offset = if (flip_vertical) (7 - y) else y;
                const offset =  (((i / 8) * 8 + y_offset) * width + ((i % 8) * 8 + x_offset)) * 3;
                @memcpy(self.data[offset..offset + 3], pixel);
            }
        }
    }
}