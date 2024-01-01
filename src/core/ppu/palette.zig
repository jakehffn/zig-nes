const std = @import("std");
const Allocator = std.mem.Allocator;

const Self = @This();
// Current fallback palette is NES Classic Edition palette
const fallback_palette_path = "fallback_palette.pal";
const fallback_palette: *[64][3]u8 = @constCast(@ptrCast(@embedFile(fallback_palette_path)));

allocator: Allocator,
palette_data: *[64][3]u8,

pub fn init(allocator: Allocator) Self {
    return .{
        .allocator = allocator,
        .palette_data = fallback_palette
    };
}

pub fn deinit(self: *Self) void {
    if (self.isPaletteAllocated()) {
        self.allocator.destroy(self.palette_data);
    }
}

pub fn getColor(self: *Self, index: usize) []u8 {
    return &self.palette_data[index];
}

fn isPaletteAllocated(self: *Self) bool {
    return self.palette_data != fallback_palette;
}

pub fn loadPalette(self: *Self, palette_path: []const u8) !void {
    var file = try std.fs.cwd().openFile(palette_path, .{});
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    var in_stream = buf_reader.reader();

    if (!self.isPaletteAllocated()) {
        self.palette_data = try self.allocator.create([64][3]u8);
    }
    _ = try in_stream.readAll(@as(*[64 * 3]u8, @ptrCast(self.palette_data)));
}

pub fn useDefaultPalette(self: *Self) void {
    if (self.isPaletteAllocated()) {
        self.allocator.free(self.palette_data);
    }
    self.palette_data = fallback_palette;
}