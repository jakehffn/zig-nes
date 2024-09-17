const Self = @This();

pub const width: usize = 4;
pub const height: usize = 8;

data: [width*height*3]u8 = undefined,

pub fn init() Self {
    var palette_viewer: Self = .{};
    @memset(palette_viewer.data[0..], 0);
    return palette_viewer;
}

pub fn update(self: *Self, ppu: anytype) void {
    // 8 palettes
    for (0..8) |palette_index| {
        // 3 colors and a mirror per palette
        for (0..4) |palette_color_index| {
            const color_index = ppu.ppu_bus.read(
                0x3F00 + @as(u16, @truncate(palette_index))*4 + @as(u16, @truncate(palette_color_index))
            );
            const pixel = ppu.palette.getColor(color_index % 64);
            const offset = palette_index * 3 * width + palette_color_index * 3;
            @memcpy(self.data[offset..offset + 3], pixel);
        }
    }
}
