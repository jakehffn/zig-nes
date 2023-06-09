pub const Bus = struct {
    read_callback: [1 << 16]?ReadCallback,
    write_callback: [1 << 16]?WriteCallback,

    pub const BusError = error {
        UndefinedRead,
        UndefinedWrite
    };

    pub const ReadCallback = *const fn (address: u16) u8;
    pub const WriteCallback = *const fn (address: u16, value: u8) void;

    pub fn init() Bus {
        return .{
            .read_callback = [_]?ReadCallback{null} ** (1 << 16),
            .write_callback = [_]?WriteCallback{null} ** (1 << 16)
        };
    }

    pub fn read_byte(self: Bus, address: u16) !u8 {
        if (self.read_callback[address]) |callback| {
            return callback(address); 
        } else {
            return BusError.UndefinedRead;
        }
    }

    pub fn write_byte(self: Bus, address: u16, data: u8) !void {
        if (self.write_callback[address]) |callback| {
            callback(address, data);
        } else {
            return BusError.UndefinedWrite;
        }
    }

    pub fn set_read_callback(self: *Bus, start: u16, end: u16, callback: ReadCallback) void {
        @memset(self.read_callback[start..end], callback);
    }

    pub fn set_write_callback(self: *Bus, start: u16, end: u16, callback: WriteCallback) void {
        @memset(self.write_callback[start..end], callback);
    }
};